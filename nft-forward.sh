#!/usr/bin/env bash
# =========================================================
# nftables 转发管理脚本 - 现代化迁移版
# =========================================================

RULES_FILE="/etc/nft-forward-rules.conf"
NFT_TABLE="throttle_forward"

# -------------------------------
# 1. 基础环境检测与安装
# -------------------------------
check_env() {
    if ! command -v nft >/dev/null 2>&1; then
        echo "未检测到 nftables。"
        read -p "是否尝试自动安装 nftables? [y/N]: " i
        if [[ "$i" =~ ^[Yy]$ ]]; then
            if command -v apt >/dev/null 2>&1; then
                apt update
                apt install nftables -y
                systemctl enable nftables
                systemctl start nftables
            elif command -v yum >/dev/null 2>&1; then
                yum install nftables -y
                systemctl enable nftables
                systemctl start nftables
            else
                echo "不支持的包管理器，请手动安装 nftables。"
                exit 1
            fi
        else
            echo "未安装必要依赖，退出。"
            exit 1
        fi
    fi
}

# -------------------------------
# 2. 开启内核转发并初始化 nftables 表
# -------------------------------
init_nft() {
    # 开启内核转发
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi

    # 初始化 nftables 结构
    if ! nft list table ip $NFT_TABLE >/dev/null 2>&1; then
        nft add table ip $NFT_TABLE
        nft add chain ip $NFT_TABLE prerouting { type nat hook prerouting priority dstnat \; policy accept \; }
        nft add chain ip $NFT_TABLE postrouting { type nat hook postrouting priority srcnat \; policy accept \; }
    fi
}

# -------------------------------
# 3. 持久化规则
# -------------------------------
save_rules() {
    # 导出当前 nftables 配置到系统标准路径
    if [[ -d /etc/nftables ]] || [[ -f /etc/nftables.conf ]]; then
        nft list ruleset > /etc/nftables.conf
        echo "nftables 规则已持久化到 /etc/nftables.conf ✔"
    else
        echo "警告: 未找到标准 nftables 配置文件路径，请手动备份规则。"
    fi
}

# -------------------------------
# 辅助函数：校验端口和IP
# -------------------------------
is_valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

is_valid_ip() {
    [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]
}

# -------------------------------
# 4. 添加转发
# -------------------------------
add_rule() {
    read -p "请输入本地监听端口 (1-65535): " LPORT
    if ! is_valid_port "$LPORT"; then echo "错误: 本地端口无效！"; return; fi

    read -p "请输入目标机器 IP: " TIP
    if ! is_valid_ip "$TIP"; then echo "错误: IP 地址格式无效！"; return; fi

    read -p "请输入目标机器端口 (1-65535): " TPORT
    if ! is_valid_port "$TPORT"; then echo "错误: 目标端口无效！"; return; fi

    # 为 TCP 和 UDP 添加规则
    for proto in tcp udp; do
        # 移除旧规则（如果存在）通过 handle 或直接匹配（nft 较难直接通过内容删除，建议先清理表再重载或精准管理）
        # 这里采用简单的规则追加，管理文件用于重载
        nft add rule ip $NFT_TABLE prerouting $proto dport "$LPORT" dnat to "$TIP:$TPORT"
        nft add rule ip $NFT_TABLE postrouting ip daddr "$TIP" $proto dport "$TPORT" masquerade
    done

    # 记录到自定义文件以便管理和重载
    sed -i "/^$LPORT $TIP $TPORT$/d" "$RULES_FILE" 2>/dev/null || true
    echo "$LPORT $TIP $TPORT" >> "$RULES_FILE"
    
    save_rules
    echo "转发已成功通过 nftables 添加并生效 ✔"
}

# -------------------------------
# 5. 查看转发
# -------------------------------
list_rules() {
    echo
    echo "==== 当前由本脚本管理的转发记录 ===="
    if [[ -f "$RULES_FILE" && -s "$RULES_FILE" ]]; then
        nl -w2 -s'. ' "$RULES_FILE"
    else
        echo "暂无记录"
    fi
    echo "===================================="
    # 可选：显示底层 nftables 规则
    # nft list table ip $NFT_TABLE
}

# -------------------------------
# 6. 删除转发
# -------------------------------
delete_rule() {
    list_rules
    if [[ ! -f "$RULES_FILE" || ! -s "$RULES_FILE" ]]; then return; fi

    read -p "请输入要删除的记录序号: " num
    if ! [[ "$num" =~ ^[0-9]+$ ]]; then echo "错误: 请输入有效的数字！"; return; fi

    rule=$(sed -n "${num}p" "$RULES_FILE" 2>/dev/null)
    if [[ -z "$rule" ]]; then echo "错误: 该序号不存在！"; return; fi

    # 为了彻底删除，最安全的方式是清理链并根据规则文件重载
    sed -i "${num}d" "$RULES_FILE"
    reload_rules
    echo "记录 $num 已成功删除 ✔"
}

# -------------------------------
# 7. 重载规则 (全量刷新)
# -------------------------------
reload_rules() {
    echo "正在刷新 nftables 转发规则..."
    # 清理旧有的自定义表
    nft delete table ip $NFT_TABLE 2>/dev/null
    
    # 重新初始化
    init_nft

    # 从文件加载
    if [[ -f "$RULES_FILE" ]]; then
        while read -r LPORT TIP TPORT; do
            [[ -z "$LPORT" ]] && continue
            for proto in tcp udp; do
                nft add rule ip $NFT_TABLE prerouting $proto dport "$LPORT" dnat to "$TIP:$TPORT"
                nft add rule ip $NFT_TABLE postrouting ip daddr "$TIP" $proto dport "$TPORT" masquerade
            done
        done < "$RULES_FILE"
    fi

    save_rules
    echo "规则重载完毕 ✔"
}

# -------------------------------
# 主菜单
# -------------------------------
menu() {
    echo
    echo "====== nftables 端口转发管理 ======"
    echo "1. 添加转发"
    echo "2. 查看转发"
    echo "3. 删除转发"
    echo "4. 重载规则 (全量刷新)"
    echo "5. 退出"
    echo "==================================="
    read -p "请输入对应数字选择: " choice

    case $choice in
        1) add_rule ;;
        2) list_rules ;;
        3) delete_rule ;;
        4) reload_rules ;;
        5) exit 0 ;;
        *) echo "无效选择，请重新输入" ;;
    esac
}

# -------------------------------
# 启动逻辑
# -------------------------------
if [[ $EUID -ne 0 ]]; then
   echo "错误: 本脚本必须以 root 权限运行 (请使用 sudo)" 
   exit 1
fi

check_env
init_nft

while true; do
    menu
done
