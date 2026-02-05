#!/bin/bash

# ============================================
# GOST 代理一键部署脚本 (优化版)
# ============================================

# set -e # 移除全局中断，改用手动检查

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- 全局变量 ---
INSTALL_PATH="/usr/local/bin/gost"
SERVICE_FILE="/etc/systemd/system/gost.service"
PAUSED_FILE="/etc/gost/paused_nodes.conf"

# --- 辅助函数 ---
print_banner() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════╗"
    echo "║       GOST 代理一键部署脚本 v2.0          ║"
    echo "╚═══════════════════════════════════════════╝"
    echo -e "${NC}"
}

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "请使用 root 用户运行此脚本"
        exit 1
    fi
}

check_dependencies() {
    local deps=("curl" "tar")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            log_error "缺少依赖: $dep，请先安装"
            exit 1
        fi
    done
}

check_port_occupied() {
    local port=$1
    local verbose=$2 # 传入 "verbose" 显示详细错误
    
    # 检查工具是否存在
    if ! command -v ss &>/dev/null && ! command -v netstat &>/dev/null && ! command -v lsof &>/dev/null; then
        echo "无法检测端口占用 (缺少 ss/netstat/lsof)"
        return 1
    fi

    local is_occ=1 # 1=未占用, 0=占用
    local proc_name=""

    if command -v ss &>/dev/null; then
        if ss -lntp | grep -qE ":$port\s+"; then
            is_occ=0
            proc_name=$(ss -lntp | grep -E ":$port\s+" | awk '{print $NF}' | cut -d'"' -f2 | head -1)
        fi
    elif command -v netstat &>/dev/null; then
        if netstat -nlpt | grep -qE ":$port\s+"; then
            is_occ=0
            proc_name=$(netstat -nlpt | grep -E ":$port\s+" | awk '{print $NF}' | cut -d'/' -f2 | head -1)
        fi
    elif command -v lsof &>/dev/null; then
        if lsof -i :$port -sTCP:LISTEN -P -n &>/dev/null; then
            is_occ=0
            proc_name=$(lsof -i :$port -sTCP:LISTEN -P -n | awk 'NR==2{print $1}' | head -1)
        fi
    fi

    if [[ $is_occ -eq 0 ]]; then
        if [[ "$verbose" == "verbose" ]]; then
            log_warn "端口 $port 已被占用！"
            [[ -n "$proc_name" ]] && echo -e "      占用进程: ${YELLOW}$proc_name${NC}"
        fi
        
        # 如果是 gost 自身占用，由于我们会重启服务，所以通常没问题，但要提示
        if [[ "$proc_name" == "gost" ]]; then
           if [[ "$verbose" == "verbose" ]]; then
               log_info "检测到端口被旧的 GOST 服务占用，这通常是正常的，重启后会覆盖。"
           fi
           # 返回 2 表示被 gost 占用
           return 2
        fi
        return 0
    fi
    
    return 1
}

# 确保配置目录存在
init_config_dir() {
    if [[ ! -d "/etc/gost" ]]; then
        mkdir -p "/etc/gost"
    fi
    if [[ ! -f "$PAUSED_FILE" ]]; then
        touch "$PAUSED_FILE"
    fi
}

check_existing_installation() {
    log_info "检查现有环境..."
    
    local has_binary=0
    local has_process=0
    local binary_path=""
    
    # 检查二进制文件
    if command -v gost &>/dev/null; then
        has_binary=1
        binary_path=$(command -v gost)
    fi
    
    if [[ -f "$INSTALL_PATH" ]]; then
        has_binary=1
        binary_path="$INSTALL_PATH"
    fi
    
    # 检查进程
    if pgrep -x "gost" >/dev/null; then
        has_process=1
    fi
    
    # 情况1: 完全干净
    if [[ $has_binary -eq 0 && $has_process -eq 0 ]]; then
        return 0
    fi
    
    # 情况2: 是我们脚本安装的 systemd 服务
    if [[ -f "$SERVICE_FILE" ]] && systemctl is-active gost &>/dev/null; then
        log_info "检测到已安装并运行的 GOST 服务 (systemd managed)。"
        # 脚本可以继续更新
        return 0
    fi
    
    echo ""
    log_warn "⚠️  检测到系统中存在手动安装的 GOST 环境！"
    
    if [[ $has_binary -eq 1 ]]; then
        echo -e "      二进制路径: ${YELLOW}$binary_path${NC}"
    fi
    
    if [[ $has_process -eq 1 ]]; then
        echo -e "      运行状态: ${YELLOW}正在运行 (PID: $(pgrep -x gost | head -1))${NC}"
        echo -e "      ${RED}注意: 该进程似乎未被本脚本的 systemd 服务管理。${NC}"
    fi
    
    echo ""
    echo "请选择操作:"
    echo "  1) 强制覆盖安装 (将停止旧进程并替换)"
    echo "  2) 退出安装"
    echo ""
    read -p "请输入 [1-2]: " conflict_choice
    
    case "$conflict_choice" in
        1)
            log_info "正在停止旧进程并清理..."
            pkill -x gost || true
            if [[ -f "$binary_path" && "$binary_path" != "$INSTALL_PATH" ]]; then
                log_warn "注意: 旧的二进制文件位于 $binary_path，本脚本将安装到 $INSTALL_PATH"
                read -p "是否删除旧的二进制文件以防冲突? [Y/n]: " del_old
                if [[ ! "$del_old" =~ ^[Nn]$ ]]; then
                    rm -f "$binary_path"
                    log_info "已删除旧二进制文件"
                fi
            fi
            return 0
            ;;
        *)
            log_info "已取消安装"
            exit 0
            ;;
    esac
}

get_public_ip() {
    curl -s --max-time 5 ifconfig.me 2>/dev/null || \
    curl -s --max-time 5 ip.sb 2>/dev/null || \
    echo "YOUR_IP"
}

# --- 核心功能 ---
get_latest_version() {
    log_info "正在获取 GOST 最新版本..."
    LATEST_TAG=$(curl -s --max-time 10 https://api.github.com/repos/ginuerzh/gost/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    
    if [[ -z "$LATEST_TAG" ]]; then
        log_error "无法获取最新版本，请检查网络连接"
        exit 1
    fi
    
    VERSION=${LATEST_TAG#v}
    log_info "最新版本: ${CYAN}$LATEST_TAG${NC}"
}

detect_arch() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  GOST_ARCH="linux_amd64" ;;
        aarch64) GOST_ARCH="linux_arm64" ;;
        armv7l)  GOST_ARCH="linux_armv7" ;;
        i686)    GOST_ARCH="linux_386" ;;
        *) 
            log_error "不支持的系统架构: $ARCH"
            exit 1 
            ;;
    esac
    log_info "系统架构: ${CYAN}$ARCH${NC} -> ${CYAN}$GOST_ARCH${NC}"
}

download_and_install() {
    local url="https://github.com/ginuerzh/gost/releases/download/${LATEST_TAG}/gost_${VERSION}_${GOST_ARCH}.tar.gz"
    local tmp_dir=$(mktemp -d)
    
    log_info "正在下载: $url"
    
    if ! curl -L --progress-bar -o "$tmp_dir/gost.tar.gz" "$url"; then
        log_error "下载失败"
        rm -rf "$tmp_dir"
        exit 1
    fi
    
    log_info "正在解压安装..."
    tar -zxf "$tmp_dir/gost.tar.gz" -C "$tmp_dir"
    
    # 停止现有服务
    if systemctl is-active --quiet gost 2>/dev/null; then
        systemctl stop gost
    fi
    
    chmod +x "$tmp_dir/gost"
    mv "$tmp_dir/gost" "$INSTALL_PATH"
    rm -rf "$tmp_dir"
    
    log_info "安装完成: ${CYAN}$INSTALL_PATH${NC}"
}

configure_proxy() {
    echo ""
    echo -e "${BLUE}═══════════════ 代理配置 ═══════════════${NC}"
    echo ""
    
    # 协议选择
    echo "请选择代理协议:"
    echo "  1) SOCKS5 (默认)"
    echo "  2) HTTP"
    echo "  3) SOCKS5 + HTTP 双协议"
    read -p "请输入 [1-3]: " PROTO_CHOICE
    PROTO_CHOICE=${PROTO_CHOICE:-1}
    
    # 端口设置
    while true; do
        read -p "设置端口 (默认 443): " PORT
        PORT=${PORT:-443}
        
        local status=0
        check_port_occupied "$PORT" "verbose" || status=$?
        
        if [[ $status -eq 1 ]]; then
            # 未占用
            break
        elif [[ $status -eq 2 ]]; then
            # 被 gost 占用
            read -p "端口被旧的 GOST 服务占用，是否继续覆盖? [Y/n]: " confirm
            [[ "$confirm" =~ ^[Nn]$ ]] || break
        else
            # 被其他程序占用
            read -p "端口被其他程序占用，强制使用可能导致启动失败。是否继续? [y/N]: " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                break
            else
                log_info "请重新设置端口"
            fi
        fi
    done
    
    # 第二端口 (双协议模式)
    if [[ "$PROTO_CHOICE" == "3" ]]; then
        while true; do
            read -p "设置 HTTP 端口 (默认 8080): " PORT2
            PORT2=${PORT2:-8080}
            
            local status=0
            check_port_occupied "$PORT2" "verbose" || status=$?
            
            if [[ $status -eq 1 ]]; then
                break
            elif [[ $status -eq 2 ]]; then
                 read -p "端口被旧的 GOST 服务占用，是否继续覆盖? [Y/n]: " confirm
                 [[ "$confirm" =~ ^[Nn]$ ]] || break
            else
                read -p "端口被其他程序占用，强制使用可能导致启动失败。是否继续? [y/N]: " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    break
                else
                     log_info "请重新设置端口"
                fi
            fi
        done
    fi
    
    # 认证设置
    echo ""
    read -p "是否启用认证? [y/N]: " ENABLE_AUTH
    if [[ "$ENABLE_AUTH" =~ ^[Yy]$ ]]; then
        read -p "设置用户名: " USER
        read -s -p "设置密码: " PASS
        echo ""
    fi
    
    # 构建命令
    build_command
}

build_command() {
    local auth_str=""
    [[ -n "$USER" && -n "$PASS" ]] && auth_str="${USER}:${PASS}@"
    
    case "$PROTO_CHOICE" in
        1) 
            PROTO="socks5"
            CMD="gost -L '${PROTO}://${auth_str}:${PORT}?keepalive=true'"
            ;;
        2) 
            PROTO="http"
            CMD="gost -L '${PROTO}://${auth_str}:${PORT}?keepalive=true'"
            ;;
        3) 
            PROTO="socks5+http"
            CMD="gost -L 'socks5://${auth_str}:${PORT}?keepalive=true' -L 'http://${auth_str}:${PORT2}?keepalive=true'"
            ;;
    esac
}

create_systemd_service() {
    log_info "正在创建 systemd 服务..."
    
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=GOST Proxy Service
After=network.target

[Service]
Type=simple
ExecStart=$CMD
Restart=always
RestartSec=5
User=root
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable gost --quiet
    systemctl start gost
    
    log_info "systemd 服务已创建并启动"
}

show_result() {
    local public_ip=$(get_public_ip)
    
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║            部署成功！                     ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${CYAN}协议:${NC} $PROTO"
    echo -e "  ${CYAN}端口:${NC} $PORT"
    [[ "$PROTO_CHOICE" == "3" ]] && echo -e "  ${CYAN}HTTP端口:${NC} $PORT2"
    [[ -n "$USER" ]] && echo -e "  ${CYAN}认证:${NC} $USER:****"
    echo ""
    echo -e "${YELLOW}═══════════════ 测试命令 ═══════════════${NC}"
    
    if [[ -n "$USER" ]]; then
        if [[ "$PROTO_CHOICE" == "2" ]]; then
            echo -e "curl -x http://${USER}:${PASS}@${public_ip}:${PORT} https://www.google.com"
        else
            echo -e "curl -x socks5://${USER}:${PASS}@${public_ip}:${PORT} https://www.google.com"
        fi
    else
        if [[ "$PROTO_CHOICE" == "2" ]]; then
            echo -e "curl -x http://${public_ip}:${PORT} https://www.google.com"
        else
            echo -e "curl -x socks5://${public_ip}:${PORT} https://www.google.com"
        fi
    fi
    
    echo ""
    echo -e "${YELLOW}═══════════════ 管理命令 ═══════════════${NC}"
    echo -e "  启动: ${CYAN}systemctl start gost${NC}"
    echo -e "  停止: ${CYAN}systemctl stop gost${NC}"
    echo -e "  重启: ${CYAN}systemctl restart gost${NC}"
    echo -e "  状态: ${CYAN}systemctl status gost${NC}"
    echo -e "  日志: ${CYAN}journalctl -u gost -f${NC}"
    echo ""
}

uninstall() {
    log_warn "正在卸载 GOST..."
    
    if systemctl is-active --quiet gost 2>/dev/null; then
        systemctl stop gost
    fi
    systemctl disable gost --quiet 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    rm -f "$INSTALL_PATH"
    systemctl daemon-reload
    
    log_info "卸载完成"
}

optimize_network() {
    echo ""
    echo -e "${BLUE}═══════════════ BBR & TCP 网络优化 ═══════════════${NC}"
    echo ""
    
    # 检查 BBR 支持
    if ! grep -q "tcp_bbr" /proc/modules 2>/dev/null && ! lsmod | grep -q "tcp_bbr"; then
        modprobe tcp_bbr 2>/dev/null || true
    fi
    
    log_info "正在应用网络优化配置..."
    
    # 备份原配置
    if [[ -f /etc/sysctl.conf ]]; then
        cp /etc/sysctl.conf /etc/sysctl.conf.bak.$(date +%Y%m%d%H%M%S)
        log_info "已备份原配置到 /etc/sysctl.conf.bak.*"
    fi
    
    cat > /etc/sysctl.conf << 'EOF'
# ========================================
# BBR & TCP 网络优化配置
# Generated by GOST 部署脚本
# ========================================

# 文件描述符限制
fs.file-max = 6815744

# TCP 基础优化
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_ecn=0
net.ipv4.tcp_frto=0
net.ipv4.tcp_mtu_probing=0
net.ipv4.tcp_rfc1337=0
net.ipv4.tcp_sack=1
net.ipv4.tcp_fack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_adv_win_scale=1
net.ipv4.tcp_moderate_rcvbuf=1

# 缓冲区优化 (32MB)
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.ipv4.tcp_rmem=4096 87380 33554432
net.ipv4.tcp_wmem=4096 16384 33554432
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192

# IP 转发
net.ipv4.ip_forward=1
net.ipv4.conf.all.route_localnet=1
net.ipv4.conf.all.forwarding=1
net.ipv4.conf.default.forwarding=1

# BBR 拥塞控制
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# IPv6 转发
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1
EOF

    # 应用配置
    sysctl -p > /dev/null 2>&1
    sysctl --system > /dev/null 2>&1
    
    echo ""
    log_info "网络优化配置已应用!"
    echo ""
    
    # 显示当前状态
    echo -e "  ${CYAN}当前拥塞控制:${NC} $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '未知')"
    echo -e "  ${CYAN}队列调度:${NC} $(sysctl -n net.core.default_qdisc 2>/dev/null || echo '未知')"
    echo -e "  ${CYAN}IP 转发:${NC} $(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo '未知')"
    echo -e "  ${CYAN}文件描述符:${NC} $(sysctl -n fs.file-max 2>/dev/null || echo '未知')"
    echo ""
}

modify_proxy() {
    echo ""
    echo -e "${BLUE}═══════════════ 修改代理配置 ═══════════════${NC}"
    echo ""
    
    if [[ ! -f "$SERVICE_FILE" ]]; then
        log_error "未找到 GOST 服务配置，请先安装"
        return 1
    fi
    
    # 解析当前配置
    local exec_line=$(grep "^ExecStart=" "$SERVICE_FILE" | sed 's/ExecStart=//')
    
    if [[ -z "$exec_line" ]]; then
        log_error "无法解析当前配置"
        return 1
    fi
    
    echo -e "  ${CYAN}当前配置:${NC} $exec_line"
    echo ""
    
    # 提取当前值
    local current_proto=""
    local current_port=""
    local current_user=""
    local current_pass=""
    
    # 解析协议
    if [[ "$exec_line" =~ socks5:// ]]; then
        current_proto="socks5"
    elif [[ "$exec_line" =~ http:// ]]; then
        current_proto="http"
    fi
    
    # 解析用户名密码
    if [[ "$exec_line" =~ ://([^:]+):([^@]+)@ ]]; then
        current_user="${BASH_REMATCH[1]}"
        current_pass="${BASH_REMATCH[2]}"
    fi
    
    # 解析端口
    current_port=$(echo "$exec_line" | grep -oE ":([0-9]+)\?" | head -1 | tr -d ':?')
    
    echo "请选择要修改的项目:"
    echo "  1) 修改端口 (当前: ${current_port:-未知})"
    echo "  2) 修改用户名密码 (当前: ${current_user:-无})"
    echo "  3) 修改协议 (当前: ${current_proto:-未知})"
    echo "  4) 全部重新配置"
    echo "  0) 返回"
    echo ""
    read -p "请输入 [0-4]: " modify_choice
    
    case "$modify_choice" in
        1)
            while true; do
                read -p "输入新端口 (当前: ${current_port}): " new_port
                new_port=${new_port:-$current_port}
                
                # 如果没改端口，直接退出
                if [[ "$new_port" == "$current_port" ]]; then
                    break
                fi
                
                local status=0
                check_port_occupied "$new_port" "verbose" || status=$?
                
                if [[ $status -eq 1 ]]; then
                    break
                elif [[ $status -eq 2 ]]; then
                     read -p "端口被旧的 GOST 服务占用，是否继续覆盖? [Y/n]: " confirm
                     [[ "$confirm" =~ ^[Nn]$ ]] || break
                else
                    read -p "端口被其他程序占用，强制使用可能导致启动失败。是否继续? [y/N]: " confirm
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        break
                    else
                         log_info "请重新设置端口"
                    fi
                fi
            done
            
            # 替换端口
            local new_exec=$(echo "$exec_line" | sed -E "s/:${current_port}\?/:${new_port}?/g")
            sed -i "s|^ExecStart=.*|ExecStart=$new_exec|" "$SERVICE_FILE"
            
            log_info "端口已修改为: $new_port"
            ;;
        2)
            read -p "输入新用户名 (当前: ${current_user:-无}, 留空取消认证): " new_user
            read -s -p "输入新密码: " new_pass
            echo ""
            
            local new_exec="$exec_line"
            
            if [[ -n "$new_user" && -n "$new_pass" ]]; then
                if [[ -n "$current_user" ]]; then
                    # 替换现有认证
                    new_exec=$(echo "$exec_line" | sed -E "s|://${current_user}:${current_pass}@|://${new_user}:${new_pass}@|g")
                else
                    # 添加认证
                    new_exec=$(echo "$exec_line" | sed -E "s|://:([0-9]+)|://${new_user}:${new_pass}@:\1|g")
                fi
                log_info "认证已修改为: ${new_user}:****"
            else
                # 移除认证
                if [[ -n "$current_user" ]]; then
                    new_exec=$(echo "$exec_line" | sed -E "s|://${current_user}:${current_pass}@|://|g")
                fi
                log_info "认证已取消"
            fi
            
            sed -i "s|^ExecStart=.*|ExecStart=$new_exec|" "$SERVICE_FILE"
            ;;
        3)
            echo "选择新协议:"
            echo "  1) SOCKS5"
            echo "  2) HTTP"
            read -p "请输入 [1-2]: " proto_choice
            
            local new_proto="socks5"
            [[ "$proto_choice" == "2" ]] && new_proto="http"
            
            local new_exec=$(echo "$exec_line" | sed -E "s|${current_proto}://|${new_proto}://|g")
            sed -i "s|^ExecStart=.*|ExecStart=$new_exec|" "$SERVICE_FILE"
            
            log_info "协议已修改为: $new_proto"
            ;;
        4)
            configure_proxy
            create_systemd_service
            show_result
            return 0
            ;;
        0)
            return 0
            ;;
        *)
            log_error "无效选项"
            return 1
            ;;
    esac
    
    # 重启服务
    systemctl daemon-reload
    systemctl restart gost
    
    echo ""
    log_info "配置已更新，服务已重启"
    
    # 显示新配置
    show_proxy_info
}

add_proxy_node() {
    echo ""
    echo -e "${BLUE}═══════════════ 添加新代理节点 ═══════════════${NC}"
    echo ""
    
    if [[ ! -f "$SERVICE_FILE" ]]; then
        log_error "未找到 GOST 服务配置，请先安装"
        return 1
    fi
    
    # 1. 设置新代理参数
    echo "请配置新节点参数:"
    
    # 协议
    echo "协议类型:"
    echo "  1) SOCKS5 (默认)"
    echo "  2) HTTP"
    read -p "请输入 [1-2]: " PROTO_CHOICE
    PROTO_CHOICE=${PROTO_CHOICE:-1}
    [[ "$PROTO_CHOICE" == "2" ]] && NEW_PROTO="http" || NEW_PROTO="socks5"
    
    # 端口
    while true; do
        read -p "设置端口 (例如 1080): " NEW_PORT
        if [[ -z "$NEW_PORT" ]]; then
            log_error "端口不能为空"
            continue
        fi
        
        local status=0
        check_port_occupied "$NEW_PORT" "verbose" || status=$?
        
        if [[ $status -eq 1 ]]; then
            break
        elif [[ $status -eq 2 ]]; then
             read -p "端口被旧的 GOST 服务占用，是否继续? [Y/n]: " confirm
             [[ "$confirm" =~ ^[Nn]$ ]] || break
        else
            read -p "端口被其他程序占用，强制使用可能导致启动失败。是否继续? [y/N]: " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                break
            else
                 log_info "请重新设置端口"
            fi
        fi
    done
    
    # 认证
    read -p "是否启用认证? [y/N]: " ENABLE_AUTH
    NEW_AUTH=""
    if [[ "$ENABLE_AUTH" =~ ^[Yy]$ ]]; then
        read -p "设置用户名: " NEW_USER
        read -s -p "设置密码: " NEW_PASS
        echo ""
        if [[ -n "$NEW_USER" && -n "$NEW_PASS" ]]; then
            NEW_AUTH="${NEW_USER}:${NEW_PASS}@"
        fi
    fi
    
    # 2. 构造新参数
    NEW_ARG="-L '${NEW_PROTO}://${NEW_AUTH}:${NEW_PORT}?keepalive=true'"
    
    # 3. 读取当前 ExecStart (处理多行情况)
    # 注意：systemd service 文件中 ExecStart 可能很长。简单处理：假设在一行或者追加到最后。
    # 更稳妥的方式是：读取整行，去掉最后的 "，追加 new_arg
    
    local output=$(grep "^ExecStart=" "$SERVICE_FILE")
    local current_cmd=${output#ExecStart=}
    
    # 4. 追加新参数
    # 如果原本就是 gost -L ... 格式，直接追加
    local new_cmd="${current_cmd} ${NEW_ARG}"
    
    # 5. 更新文件
    # 使用 awk 或 sed 替换。由于包含特殊字符，sed 比较麻烦，尝试用临时文件
    # 这里为了简单，我们用 perl 或者纯 bash 生成新内容
    
    # 备份
    cp "$SERVICE_FILE" "${SERVICE_FILE}.bak"
    
    # 写入新内容 (使用 awk 避免转义噩梦)
    awk -v new="$new_cmd" '/^ExecStart=/ {$0="ExecStart=" new} 1' "${SERVICE_FILE}.bak" > "$SERVICE_FILE"
    
    log_info "已添加新节点配置。"
    
    # 重启服务
    systemctl daemon-reload
    if systemctl restart gost; then
        echo ""
        log_info "服务已重启，新节点已生效！"
        show_proxy_info
    else
        echo ""
        log_error "服务启动失败！正在回滚配置..."
        mv "${SERVICE_FILE}.bak" "$SERVICE_FILE"
        systemctl daemon-reload
        systemctl restart gost
        log_info "已恢复原有配置。"
        return 1
    fi
}

manage_paused_proxies() {
    init_config_dir
    
    while true; do
        echo ""
        echo -e "${BLUE}═══════════════ 管理暂停的代理 ═══════════════${NC}"
        echo ""
        echo "请选择操作:"
        echo "  1) 暂停运行中的代理"
        echo "  2) 恢复已暂停的代理"
        echo "  0) 返回主菜单"
        echo ""
        read -p "请输入 [0-2]: " pause_choice
        
        case "$pause_choice" in
            1)
                if [[ ! -f "$SERVICE_FILE" ]]; then
                    log_error "未找到 GOST 服务配置"
                    continue
                fi
                
                local exec_line=$(grep "^ExecStart=" "$SERVICE_FILE" | sed 's/ExecStart=//')
                if [[ -z "$exec_line" ]]; then
                    log_error "无法解析服务配置"
                    continue
                fi
                
                # 解析运行中的代理节点
                nodes=()
                
                # 提取所有 -L 参数。支持单引号、双引号或无引号。
                # 逻辑：查找 -L 后面跟着的内容，直到下一个 -L 或行尾。
                local temp_exec="$exec_line"
                # 预处理：将所有 -L 'url' 格式提取出来
                local nodes_raw=$(echo "$exec_line" | grep -oE "\-L\s+('[^']+'|\"[^\"]+\"|[^ ]+)" | sed -E 's/^-L\s+//; s/^['"'""]//; s/['"'""]$//' || echo "")
                
                if [[ -n "$nodes_raw" ]]; then
                    while read -r node; do
                        [[ -n "$node" ]] && nodes+=("$node")
                    done <<< "$nodes_raw"
                fi
                
                if [[ ${#nodes[@]} -eq 0 ]]; then
                    log_warn "未检测到代理节点。配置内容: $exec_line"
                    continue
                fi
                
                echo "运行中的节点:"
                for ((j=0; j<${#nodes[@]}; j++)); do
                   echo "  $((j+1))) ${nodes[j]}"
                done
                echo "  0) 返回"
                
                read -p "选择要暂停的节点 [1-${#nodes[@]}]: " node_idx
                 
                if [[ "$node_idx" == "0" ]]; then
                    continue
                fi
                
                if [[ ! "$node_idx" =~ ^[0-9]+$ ]] || [[ "$node_idx" -gt "${#nodes[@]}" ]] || [[ "$node_idx" -lt 1 ]]; then
                    log_error "无效选择"
                    continue
                fi
                
                local target_node="${nodes[$((node_idx-1))]}"
                
                # 处理唯一节点的情况
                if [[ ${#nodes[@]} -eq 1 ]]; then
                    log_warn "这是唯一运行的节点，暂停将导致服务无法启动。建议直接停止服务。"
                    read -p "是否确认暂停并停止服务? [y/N]: " confirm_stop
                    if [[ "$confirm_stop" =~ ^[Yy]$ ]]; then
                         # save to paused file
                         echo "$target_node" >> "$PAUSED_FILE"
                         # stop service
                         systemctl stop gost
                         # 清理 ExecStart 参数
                         local new_exec=${exec_line%% -L*}
                         
                         sed -i "s|^ExecStart=.*|ExecStart=$new_exec|" "$SERVICE_FILE"
                         log_info "唯一节点已暂停，服务已停止。"
                         continue
                    else
                        continue
                    fi
                fi
                
                # Regular removal
                local cmd_prefix=${exec_line%% -L*}
                local new_exec="$cmd_prefix"
                
                for ((n=0; n<${#nodes[@]}; n++)); do
                    if [[ $n -ne $((node_idx-1)) ]]; then
                        new_exec="${new_exec} -L '${nodes[n]}'"
                    fi
                done
                
                sed -i "s|^ExecStart=.*|ExecStart=$new_exec|" "$SERVICE_FILE"
                
                # Save to paused file
                echo "$target_node" >> "$PAUSED_FILE"
                log_info "节点已暂停并保存: $target_node"
                
                systemctl daemon-reload
                systemctl restart gost
                log_info "服务已重启"
                ;;
                
            2)
                if [[ ! -s "$PAUSED_FILE" ]]; then
                    log_warn "没有已暂停的节点"
                    continue
                fi
                
                declare -a paused_nodes
                local k=0
                while read -r line; do
                    [[ -z "$line" ]] && continue
                    paused_nodes[k]="$line"
                    ((k++))
                done < "$PAUSED_FILE"
                
                echo "已暂停的节点:"
                for ((m=0; m<${#paused_nodes[@]}; m++)); do
                    echo "  $((m+1))) ${paused_nodes[m]}"
                done
                echo "  0) 返回"
                
                read -p "选择要恢复的节点 [1-${#paused_nodes[@]}]: " resume_idx
                
                if [[ "$resume_idx" == "0" ]]; then
                    continue
                fi
                
                if [[ ! "$resume_idx" =~ ^[0-9]+$ ]] || [[ "$resume_idx" -gt "${#paused_nodes[@]}" ]] || [[ "$resume_idx" -lt 1 ]]; then
                    log_error "无效选择"
                    continue
                fi
                
                local target_resume="${paused_nodes[$((resume_idx-1))]}"
                
                # Add back to service
                # Check if service file exists, create if not (edge case: uninstalled but file remains?)
                if [[ ! -f "$SERVICE_FILE" ]]; then
                    # If service doesn't exist, we basically need to re-install or at least re-create skeleton.
                    # Simplified: assume service exists if we are here, or warn.
                     log_error "服务文件不存在，无法恢复。请先安装 GOST。"
                     continue
                fi
                
                local exec_line=$(grep "^ExecStart=" "$SERVICE_FILE")
                local current_cmd=${exec_line#ExecStart=}
                
                # if current_cmd is just "gost" or empty (after manual mess up), fix it
                 if [[ -z "$current_cmd" ]]; then
                    # Should re-build basic cmd
                     current_cmd="gost"
                 fi
                 
                local new_cmd="${current_cmd} -L '${target_resume}'"
                
                # Update service
                # escape special chars for sed is hard, using tmp file method again or awk
                 awk -v new="$new_cmd" '/^ExecStart=/ {$0="ExecStart=" new} 1' "$SERVICE_FILE" > "${SERVICE_FILE}.tmp" && mv "${SERVICE_FILE}.tmp" "$SERVICE_FILE"
                 
                 # Remove from paused file
                 # We use grep -v to filter out the exact line. 
                 # Edge case: duplicate lines? safely remove one instance or all matching? 
                 # Let's remove matches.
                 grep -vFx "$target_resume" "$PAUSED_FILE" > "${PAUSED_FILE}.tmp" && mv "${PAUSED_FILE}.tmp" "$PAUSED_FILE"
                 
                 log_info "节点已恢复: $target_resume"
                 
                 systemctl daemon-reload
                 systemctl restart gost
                 log_info "服务已重启"
                ;;
                
            0)
                return 0
                ;;
            *)
                log_error "无效选项"
                ;;
        esac
    done
}

update_script() {
    echo -e "${BLUE}═══════════════ 更新脚本 ═══════════════${NC}"
    local update_url="https://raw.githubusercontent.com/suxayii/Throttle/refs/heads/master/gost-proxy.sh"
    local script_path=$(readlink -f "$0")
    
    # 检查是否是在通过管道运行 (bash <(curl ...))
    # 管道运行下 $0 通常是 bash 或者 /dev/fd/*
    if [[ "$script_path" == "/dev/fd/"* ]] || [[ "$0" == "bash" ]] || [[ ! -f "$script_path" ]] || [[ ! -w "$script_path" ]]; then
        log_warn "由于您当前是直接通过网络链接 (curl) “在线运行”的脚本，无法自行修改磁盘文件进行更新。"
        echo ""
        log_info "如果您想支持本地自动更新，请先执行以下命令下载脚本到本地："
        echo -e "  ${CYAN}curl -O $update_url && chmod +x gost-proxy.sh${NC}"
        echo ""
        log_info "下载后，请使用 ${CYAN}./gost-proxy.sh${NC} 运行。"
        return 1
    fi
    
    log_info "正在检查更新..."
    
    if curl -sL --fail "$update_url" -o "${script_path}.tmp"; then
        mv "${script_path}.tmp" "$script_path"
        chmod +x "$script_path"
        log_info "脚本更新成功！正在重新启动..."
        sleep 1
        exec bash "$script_path"
    else
        log_error "更新失败，请检查网络连接。"
        rm -f "${script_path}.tmp"
    fi
}

show_proxy_info() {
    local public_ip=$(get_public_ip)
    
    echo ""
    echo -e "${BLUE}═══════════════ 当前代理配置 ═══════════════${NC}"
    echo ""
    
    if [[ ! -f "$SERVICE_FILE" ]]; then
        log_warn "未找到 GOST 服务配置文件"
        return 1
    fi
    
    # 从服务文件中提取 ExecStart 命令
    local exec_line=$(grep "^ExecStart=" "$SERVICE_FILE" | sed 's/ExecStart=//')
    
    if [[ -z "$exec_line" ]]; then
        log_warn "无法解析服务配置"
        return 1
    fi
    
    echo -e "  ${CYAN}完整命令:${NC}"
    echo -e "  $exec_line"
    echo ""
    
    # 解析每个 -L 参数
    echo -e "  ${CYAN}代理详情:${NC}"
    
    local proxy_count=0
    while read -r proxy_url; do
        ((proxy_count++))
        
        # 提取协议
        local proto=$(echo "$proxy_url" | grep -oE "^[a-z0-9]+" || echo "unknown")
        
        # 提取用户名密码
        local auth=""
        if [[ "$proxy_url" =~ ://([^:]+):([^@]+)@ ]]; then
            local user="${BASH_REMATCH[1]}"
            local pass="${BASH_REMATCH[2]}"
            auth="$user:$pass"
        fi
        
        # 提取端口
        local port=$(echo "$proxy_url" | grep -oE ":([0-9]+)\?" | tr -d ':?')
        [[ -z "$port" ]] && port=$(echo "$proxy_url" | grep -oE ":([0-9]+)'" | tr -d ":'" )
        [[ -z "$port" ]] && port=$(echo "$proxy_url" | grep -oE ":([0-9]+)$" | tr -d ':')
        
        echo ""
        echo -e "  ${GREEN}[$proxy_count]${NC} 协议: ${YELLOW}$proto${NC}"
        echo -e "      端口: ${YELLOW}${port:-未知}${NC}"
        if [[ -n "$auth" ]]; then
            echo -e "      认证: ${YELLOW}$auth${NC}"
        else
            echo -e "      认证: ${YELLOW}无${NC}"
        fi
        
    done < <(echo "$exec_line" | grep -oE "'[^']+'" | tr -d "'")
    
    # 显示连接信息
    echo ""
    echo -e "${YELLOW}═══════════════ 连接信息 ═══════════════${NC}"
    echo -e "  服务器 IP: ${CYAN}$public_ip${NC}"
    
    # 生成测试命令
    echo ""
    echo -e "${YELLOW}═══════════════ 测试命令 ═══════════════${NC}"
    
    # 从解析结果生成测试命令
    local first_proxy=$(echo "$exec_line" | grep -oE "'[^']+'" | head -1 | tr -d "'")
    if [[ -n "$first_proxy" ]]; then
        local proto=$(echo "$first_proxy" | grep -oE "^[a-z0-9]+")
        local port=$(echo "$first_proxy" | grep -oE ":([0-9]+)\?" | tr -d ':?')
        [[ -z "$port" ]] && port=$(echo "$first_proxy" | grep -oE ":([0-9]+)'" | tr -d ":'" )
        
        if [[ "$first_proxy" =~ ://([^:]+):([^@]+)@ ]]; then
            echo -e "  curl -x ${proto}://${BASH_REMATCH[1]}:${BASH_REMATCH[2]}@${public_ip}:${port} https://www.google.com"
        else
            echo -e "  curl -x ${proto}://${public_ip}:${port} https://www.google.com"
        fi
    fi
    
    echo ""
}

show_menu() {
    print_banner
    echo "请选择操作:"
    echo "  1) 安装/更新 GOST"
    echo "  2) 卸载 GOST"
    echo "  3) 查看运行状态"
    echo "  4) 查看代理配置"
    echo "  5) 修改代理配置"
    echo "  6) 添加新代理节点 (多端口)"
    echo "  7) BBR & TCP 网络优化"
    echo "  8) 管理暂停的代理"
    echo "  9) 更新脚本"
    echo "  0) 退出"
    echo ""
    read -p "请输入 [0-9]: " choice
    
    case "$choice" in
        1) 
            check_root
            check_dependencies
            check_existing_installation
            get_latest_version
            detect_arch
            download_and_install
            configure_proxy
            create_systemd_service
            show_result
            read -p "按任意键返回主菜单..."
            show_menu
            ;;
        2)
            check_root
            uninstall
            read -p "按任意键返回主菜单..."
            show_menu
            ;;
        3)
            if systemctl is-active --quiet gost 2>/dev/null; then
                log_info "GOST 运行中"
                systemctl status gost --no-pager
            else
                log_warn "GOST 未运行"
            fi
            read -p "按任意键返回主菜单..."
            show_menu
            ;;
        4)
            show_proxy_info
            read -p "按任意键返回主菜单..."
            show_menu
            ;;
        5)
            check_root
            modify_proxy
            read -p "按任意键返回主菜单..."
            show_menu
            ;;
        6)
            check_root
            add_proxy_node
            read -p "按任意键返回主菜单..."
            show_menu
            ;;
        7)
            check_root
            optimize_network
            read -p "按任意键返回主菜单..."
            show_menu
            ;;
        8)
            check_root
            manage_paused_proxies
            read -p "按任意键返回主菜单..."
            show_menu
            ;;
        9)
            update_script
            ;;
        0)
            exit 0
            ;;
        *)
            log_error "无效选项"
            read -p "按任意键重试..."
            show_menu
            ;;
    esac
}

# --- 主入口 ---
show_menu
