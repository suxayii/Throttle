#!/bin/bash

# ==========================================
# Linux 端口限速工具 (v6.1 - WARP/物理网卡修正版)
# ==========================================

CONFIG_DIR="/etc/port-limit"
CONFIG_FILE="$CONFIG_DIR/settings.conf"
LOG_FILE="$CONFIG_DIR/port-limit.log"
MARK=10

# --- 核心修复：优化网卡识别逻辑 ---
# 解释：优先匹配 eth/ens/enp/eno 开头的物理接口，避开 wgcf/tun/cloudflare 等虚拟接口
detect_interface() {
    # 1. 尝试直接通过名称获取物理网卡
    local phy_iface=$(ip -o link show | awk -F': ' '{print $2}' | grep -E "^(eth|ens|enp|eno)[0-9]*" | head -n 1)
    
    if [ -n "$phy_iface" ]; then
        echo "$phy_iface"
    else
        # 2. 如果没找到标准名称，尝试获取默认路由，但排除已知的虚拟网卡关键词
        local route_iface=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $5; exit}')
        if [[ "$route_iface" =~ ^(wg|tun|ppp|cloudflare|utun) ]]; then
            # 如果默认路由是虚拟卡，强制回退到 eth0 (绝大多数情况下的保底)
            echo "eth0"
        else
            echo "$route_iface"
        fi
    fi
}

INTERFACE=$(detect_interface)
[ -z "$INTERFACE" ] && INTERFACE="eth0"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# --- 基础函数 ---

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误: 必须使用 Root 权限运行${PLAIN}"
        exit 1
    fi
}

check_dependencies() {
    local missing=()
    [ ! -x "$(command -v tc)" ] && missing+=("iproute2")
    [ ! -x "$(command -v iptables)" ] && missing+=("iptables")
    [ ! -x "$(command -v awk)" ] && missing+=("awk")
    
    if [ ${#missing[@]} -ne 0 ]; then
        if [ -x "$(command -v apt)" ]; then apt update && apt install -y "${missing[@]}"; 
        elif [ -x "$(command -v yum)" ]; then yum install -y "${missing[@]}"; 
        else echo "请手动安装: ${missing[*]}"; exit 1; fi
    fi
}

init_config() {
    mkdir -p "$CONFIG_DIR"
    touch "$LOG_FILE"
}

# 强制切断输入流，防止 awk 等待导致卡死
validate_number() {
    local input=$1
    if [[ ! "$input" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        return 1
    fi
    awk -v val="$input" 'BEGIN { if (val > 0) exit 0; else exit 1 }' < /dev/null
}

pause() {
    echo ""
    read -p "按回车键返回主菜单..."
}

# --- 核心逻辑 ---

remove_rules() {
    local quiet=$1
    if [ -f "$CONFIG_FILE" ]; then
        local OLD_PORTS=$(grep "^PORTS=" "$CONFIG_FILE" | cut -d'=' -f2)
        if [ -n "$OLD_PORTS" ]; then
            IFS=',' read -ra PORT_ARR <<< "$OLD_PORTS"
            for PORT in "${PORT_ARR[@]}"; do
                iptables -t mangle -D OUTPUT -o "$INTERFACE" -p tcp --sport "$PORT" -j MARK --set-mark $MARK 2>/dev/null
                iptables -t mangle -D OUTPUT -o "$INTERFACE" -p udp --sport "$PORT" -j MARK --set-mark $MARK 2>/dev/null
                if [ -x "$(command -v ip6tables)" ]; then
                    ip6tables -t mangle -D OUTPUT -o "$INTERFACE" -p tcp --sport "$PORT" -j MARK --set-mark $MARK 2>/dev/null
                    ip6tables -t mangle -D OUTPUT -o "$INTERFACE" -p udp --sport "$PORT" -j MARK --set-mark $MARK 2>/dev/null
                fi
            done
        fi
    fi
    tc qdisc del dev "$INTERFACE" root 2>/dev/null
    [ "$quiet" != "quiet" ] && log "旧规则已清理 (接口: $INTERFACE)"
}

add_firewall_rules() {
    local port=$1
    iptables -t mangle -A OUTPUT -o "$INTERFACE" -p tcp --sport "$port" -j MARK --set-mark $MARK
    iptables -t mangle -A OUTPUT -o "$INTERFACE" -p udp --sport "$port" -j MARK --set-mark $MARK
    if [ -f /proc/net/if_inet6 ] && [ -x "$(command -v ip6tables)" ]; then
        ip6tables -t mangle -A OUTPUT -o "$INTERFACE" -p tcp --sport "$port" -j MARK --set-mark $MARK 2>/dev/null
        ip6tables -t mangle -A OUTPUT -o "$INTERFACE" -p udp --sport "$port" -j MARK --set-mark $MARK 2>/dev/null
    fi
}

set_limit() {
    echo -e "${YELLOW}提示：设置将覆盖旧规则。${PLAIN}"
    echo -e "当前操作网卡: ${GREEN}$INTERFACE${PLAIN} (请确认这是你的物理网卡)"
    read -p "请输入端口 (逗号分隔): " INPUT_PORTS
    [ -z "$INPUT_PORTS" ] && return
    
    read -p "请输入限制速率 (单位 MB/s, 支持小数, 如 0.5): " INPUT_MB
    
    if ! validate_number "$INPUT_MB"; then 
        echo -e "${RED}错误：数值无效 (必须是大于0的数字)${PLAIN}"
        pause
        return
    fi
    
    local LIMIT_KB=$(awk -v val="$INPUT_MB" 'BEGIN {printf "%d", val * 1024}' < /dev/null)
    local SHOW_MBPS=$(awk -v val="$INPUT_MB" 'BEGIN {printf "%.2f", val * 8}' < /dev/null)
    
    if [ "$LIMIT_KB" -lt 1 ]; then LIMIT_KB=1; fi
    local PHY_LIMIT=$((1000 * 1024)) 
    
    remove_rules "quiet"
    
    # --- TC 规则区 ---
    tc qdisc add dev "$INTERFACE" root handle 1: htb default 30
    tc class add dev "$INTERFACE" parent 1: classid 1:1 htb rate "${PHY_LIMIT}kbps" quantum 200000
    tc class add dev "$INTERFACE" parent 1: classid 1:10 htb rate "${LIMIT_KB}kbps" ceil "${LIMIT_KB}kbps" burst 15k quantum 3000 prio 1
    tc class add dev "$INTERFACE" parent 1: classid 1:30 htb rate "${PHY_LIMIT}kbps" ceil "${PHY_LIMIT}kbps" burst 15k quantum 200000 prio 0
    
    tc filter add dev "$INTERFACE" protocol ip parent 1:0 prio 1 handle $MARK fw flowid 1:10
    tc filter add dev "$INTERFACE" protocol ipv6 parent 1:0 prio 1 handle $MARK fw flowid 1:10 2>/dev/null

    # --- 防火墙区 ---
    IFS=',' read -ra PORT_ARR <<< "$INPUT_PORTS"
    for PORT in "${PORT_ARR[@]}"; do
        add_firewall_rules "$PORT"
    done
    
    cat > "$CONFIG_FILE" << EOF
PORTS=$INPUT_PORTS
LIMIT_MB=$INPUT_MB
EOF
    
    log "已限速: 端口 [$INPUT_PORTS] -> $INPUT_MB MB/s ($LIMIT_KB KB/s) @ $INTERFACE"
    echo -e "${GREEN}设置成功！${PLAIN}"
    echo -e "当前限制: ${YELLOW}$INPUT_MB MB/s${PLAIN} (约 $SHOW_MBPS Mbps)"
    
    pause
}

show_status() {
    echo -e "${YELLOW}--- 当前配置 ($INTERFACE) ---${PLAIN}"
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        echo "监听端口: $PORTS"
        local CUR_MBPS=$(awk -v val="$LIMIT_MB" 'BEGIN {printf "%.2f", val * 8}' < /dev/null)
        echo "限制速率: $LIMIT_MB MB/s (约 $CUR_MBPS Mbps)"
    else
        echo "无配置文件"
    fi
    
    echo -e "\n${YELLOW}--- 流量统计 ---${PLAIN}"
    tc -s class show dev "$INTERFACE" | grep -A 5 "class htb 1:10"
    
    echo -e "\n${YELLOW}--- 命中包数 (pkts) ---${PLAIN}"
    iptables -t mangle -L OUTPUT -v -n | grep "MARK set 0x$((MARK))"
    
    pause
}

clear_all() {
    remove_rules
    rm -f "$CONFIG_FILE"
    echo -e "${GREEN}已清除所有限制。${PLAIN}"
    pause
}

main() {
    check_root
    check_dependencies
    init_config
    trap "exit 1" INT

    while true; do
        clear
        echo "=================================="
        echo "    Linux 端口限速工具 (v6.1)"
        echo "    当前操作网卡: ${GREEN}$INTERFACE${PLAIN}"
        echo "=================================="
        echo " 1. 设置/更新 端口限速 (支持小数)"
        echo " 2. 查看状态 (排查故障)"
        echo " 3. 清除限制"
        echo " 0. 退出"
        echo "=================================="
        read -p "请输入选项 [0-3]: " CHOICE
        
        case $CHOICE in
            1) set_limit ;;
            2) show_status ;;
            3) clear_all ;;
            0) exit 0 ;;
            *) echo "无效选项"; sleep 1 ;;
        esac
    done
}

main
