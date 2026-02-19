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

validate_port() {
    local port=$1
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        log_error "端口必须为数字"
        return 1
    fi
    if [[ "$port" -lt 1 || "$port" -gt 65535 ]]; then
        log_error "端口范围必须在 1-65535 之间"
        return 1
    fi
    return 0
}

# 对字符串进行 sed 转义，防止特殊字符破坏替换
sed_escape() {
    printf '%s\n' "$1" | sed -e 's/[&/\|]/\\&/g'
}

# 从 gost 服务配置中提取所有已使用的端口
get_gost_used_ports() {
    local service_file="/etc/systemd/system/gost.service"
    if [[ ! -f "$service_file" ]]; then
        return
    fi
    local exec_line=$(grep "^ExecStart=" "$service_file" | sed 's/ExecStart=//')
    if [[ -z "$exec_line" ]]; then
        return
    fi
    # 从所有 -L 参数中提取端口号 (格式: protocol://[auth@][host]:port[?...])
    echo "$exec_line" | grep -oP '(?<=-L[\s=])\S+' | while read -r url; do
        # 移除 scheme
        local temp=${url#*://}
        # 移除 auth
        temp=${temp#*@}
        # 提取 host:port 部分 (去掉 path 和 query)
        local listen=${temp%%[/?]*}
        # 提取端口
        local port=${listen##*:}
        [[ -n "$port" && "$port" =~ ^[0-9]+$ ]] && echo "$port"
    done
}

# 检查端口是否与 gost 已有配置冲突
# 返回 0 = 有冲突, 1 = 无冲突
check_gost_port_conflict() {
    local port=$1
    local used_ports=$(get_gost_used_ports)
    if [[ -z "$used_ports" ]]; then
        return 1
    fi
    if echo "$used_ports" | grep -qx "$port"; then
        log_warn "端口 $port 已在 GOST 现有配置中使用！"
        echo -e "      ${YELLOW}如果继续，gost 重启后会因端口重复绑定而失败。${NC}"
        return 0
    fi
    return 1
}

check_port_occupied() {
    local port=$1
    local verbose=$2 # 传入 "verbose" 显示详细错误
    local check_udp=$3 # 传入 "udp" 同时检查 UDP 端口
    
    # 检查工具是否存在
    if ! command -v ss &>/dev/null && ! command -v netstat &>/dev/null && ! command -v lsof &>/dev/null; then
        echo "无法检测端口占用 (缺少 ss/netstat/lsof)"
        return 1
    fi

    # 返回值约定 (注意与 bash 惯例相反，调用时需注意):
    #   0 = 端口被占用 (非 gost 进程)
    #   1 = 端口未被占用 (可用)
    #   2 = 端口被 gost 自身占用
    local is_occ=1 # 1=未占用, 0=占用
    local proc_name=""

    # TCP 检测
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

    # UDP 检测 (如果指定了 udp 参数且 TCP 未发现占用)
    if [[ $is_occ -eq 1 && "$check_udp" == "udp" ]]; then
        if command -v ss &>/dev/null; then
            if ss -lnup | grep -qE ":$port\s+"; then
                is_occ=0
                proc_name=$(ss -lnup | grep -E ":$port\s+" | awk '{print $NF}' | cut -d'"' -f2 | head -1)
                [[ "$verbose" == "verbose" ]] && log_warn "端口 $port 的 UDP 已被占用！"
            fi
        elif command -v netstat &>/dev/null; then
            if netstat -nlpu | grep -qE ":$port\s+"; then
                is_occ=0
                proc_name=$(netstat -nlpu | grep -E ":$port\s+" | awk '{print $NF}' | cut -d'/' -f2 | head -1)
                [[ "$verbose" == "verbose" ]] && log_warn "端口 $port 的 UDP 已被占用！"
            fi
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

# 验证 IP 地址或域名格式
validate_ip() {
    local ip=$1
    # IPv4
    if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    fi
    # 域名 (简单检测: 包含字母和点)
    if [[ "$ip" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
        return 0
    fi
    return 1
}

# 创建基础 systemd 服务文件 (无代理配置，仅 gost 骨架)
create_base_service() {
    if [[ ! -f "$INSTALL_PATH" ]] && ! command -v gost &>/dev/null; then
        log_error "未找到 GOST 二进制文件，请先安装 GOST (选项 1)"
        return 1
    fi
    log_info "自动创建基础 systemd 服务..."
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=GOST Proxy Service
After=network.target

[Service]
Type=simple
ExecStart=$INSTALL_PATH
Restart=always
RestartSec=5
User=root
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable gost --quiet
    log_info "基础服务文件已创建"
    return 0
}

# 安全地更新 service 文件的 ExecStart 行 (避免 awk 特殊字符问题)
update_service_exec() {
    local new_cmd="$1"
    local service_file="$2"
    # 使用 perl 替换，比 awk -v 更安全处理特殊字符
    if command -v perl &>/dev/null; then
        local tmpfile=$(mktemp)
        NEW_CMD="$new_cmd" perl -pe 'BEGIN{$r=$ENV{NEW_CMD}} s/^ExecStart=.*/ExecStart=$r/' "$service_file" > "$tmpfile" && mv "$tmpfile" "$service_file"
    else
        # Fallback: 纯 bash 重写 (最安全)
        local tmpfile=$(mktemp)
        while IFS= read -r line; do
            if [[ "$line" == ExecStart=* ]]; then
                echo "ExecStart=$new_cmd"
            else
                echo "$line"
            fi
        done < "$service_file" > "$tmpfile" && mv "$tmpfile" "$service_file"
    fi
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
    
    # 情况2: 是我们脚本安装的 systemd 服务 (运行中或已启用)
    if [[ -f "$SERVICE_FILE" ]] && (systemctl is-active gost &>/dev/null || systemctl is-enabled gost &>/dev/null); then
        log_info "检测到已安装的 GOST 服务 (systemd managed)。"
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
    
    # 尝试获取当前运行的 gost 命令行参数
    local current_cmdline=""
    if [[ $has_process -eq 1 ]]; then
        local gost_pid=$(pgrep -x gost | head -1)
        if [[ -n "$gost_pid" && -f "/proc/$gost_pid/cmdline" ]]; then
            current_cmdline=$(cat /proc/$gost_pid/cmdline 2>/dev/null | tr '\0' ' ' | sed 's/ $//')
        fi
        if [[ -n "$current_cmdline" ]]; then
            echo -e "      启动命令: ${CYAN}$current_cmdline${NC}"
        fi
    fi
    
    echo ""
    echo "请选择操作:"
    echo "  1) 强制覆盖安装 (将停止旧进程并替换)"
    echo "  2) 接管到 systemd 管理 (保留当前配置，纳入 systemd 自动管理)"
    echo "  3) 退出安装"
    echo ""
    read -p "请输入 [1-3]: " conflict_choice
    
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
        2)
            # 接管到 systemd 管理
            if [[ -z "$current_cmdline" ]]; then
                log_error "无法读取当前 gost 进程的启动参数，无法接管"
                return 1
            fi
            
            # 将命令中的旧路径替换为标准路径
            local adopt_cmd="$current_cmdline"
            if [[ "$binary_path" != "$INSTALL_PATH" && -n "$binary_path" ]]; then
                adopt_cmd=$(echo "$adopt_cmd" | sed "s|$binary_path|$INSTALL_PATH|g")
            fi
            # 确保命令以标准路径开头
            if [[ "$adopt_cmd" != "$INSTALL_PATH"* ]]; then
                # 替换命令开头的 gost 为完整路径
                adopt_cmd=$(echo "$adopt_cmd" | sed "s|^gost |$INSTALL_PATH |; s|^[^ ]*/gost |$INSTALL_PATH |")
            fi
            
            log_info "正在创建 systemd 服务..."
            echo -e "  将使用命令: ${CYAN}$adopt_cmd${NC}"
            
            # 如果二进制不在标准路径，复制过去
            if [[ "$binary_path" != "$INSTALL_PATH" && -f "$binary_path" ]]; then
                cp "$binary_path" "$INSTALL_PATH"
                chmod +x "$INSTALL_PATH"
                log_info "已将二进制文件复制到 $INSTALL_PATH"
            fi
            
            # 停止旧进程
            pkill -x gost || true
            sleep 1
            
            # 创建 systemd service
            cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=GOST Proxy Service
After=network.target

[Service]
Type=simple
ExecStart=$adopt_cmd
Restart=always
RestartSec=5
User=root
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
            
            systemctl daemon-reload
            systemctl enable gost --quiet
            if systemctl start gost; then
                echo ""
                log_info "✅ 接管成功！GOST 已纳入 systemd 管理。"
                show_proxy_info
            else
                log_error "systemd 启动失败，请检查: journalctl -u gost"
            fi
            
            # 清理旧的二进制
            if [[ -f "$binary_path" && "$binary_path" != "$INSTALL_PATH" ]]; then
                read -p "是否删除旧的二进制文件? [Y/n]: " del_old
                if [[ ! "$del_old" =~ ^[Nn]$ ]]; then
                    rm -f "$binary_path"
                    log_info "已删除旧二进制文件"
                fi
            fi
            
            # 接管完成后回到主菜单，不继续安装流程
            return 1
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
    
    # 验证解压后的二进制文件是否存在
    if [[ ! -f "$tmp_dir/gost" ]]; then
        log_error "解压后未找到 gost 二进制文件，tar 包结构可能已变化"
        rm -rf "$tmp_dir"
        exit 1
    fi
    
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
        
        if ! validate_port "$PORT"; then
            continue
        fi
        
        local status=0
        check_port_occupied "$PORT" "verbose" || status=$?
        
        if [[ $status -eq 1 ]]; then
            # 端口未被系统占用，但还需检查 gost 配置内部冲突
            if check_gost_port_conflict "$PORT"; then
                read -p "是否仍要使用此端口? [y/N]: " confirm
                [[ "$confirm" =~ ^[Yy]$ ]] && break
                log_info "请重新设置端口"
            else
                break
            fi
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
            
            if ! validate_port "$PORT2"; then
                continue
            fi
            
            # 检查是否与第一个端口相同
            if [[ "$PORT2" == "$PORT" ]]; then
                log_error "HTTP 端口不能与 SOCKS5 端口相同 ($PORT)"
                continue
            fi
            
            local status=0
            check_port_occupied "$PORT2" "verbose" || status=$?
            
            if [[ $status -eq 1 ]]; then
                if check_gost_port_conflict "$PORT2"; then
                    read -p "是否仍要使用此端口? [y/N]: " confirm
                    [[ "$confirm" =~ ^[Yy]$ ]] && break
                    log_info "请重新设置端口"
                else
                    break
                fi
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
        read -p "设置用户名: " PROXY_USER
        read -s -p "设置密码: " PROXY_PASS
        echo ""
    else
        PROXY_USER=""
        PROXY_PASS=""
    fi
    
    # 构建命令
    build_command
}

build_command() {
    local auth_str=""
    [[ -n "$PROXY_USER" && -n "$PROXY_PASS" ]] && auth_str="${PROXY_USER}:${PROXY_PASS}@"
    
    case "$PROTO_CHOICE" in
        1) 
            PROTO="socks5"
            CMD="$INSTALL_PATH -L ${PROTO}://${auth_str}:${PORT}?keepalive=true"
            ;;
        2) 
            PROTO="http"
            CMD="$INSTALL_PATH -L ${PROTO}://${auth_str}:${PORT}?keepalive=true"
            ;;
        3) 
            PROTO="socks5+http"
            CMD="$INSTALL_PATH -L socks5://${auth_str}:${PORT}?keepalive=true -L http://${auth_str}:${PORT2}?keepalive=true"
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
    [[ -n "$PROXY_USER" ]] && echo -e "  ${CYAN}认证:${NC} $PROXY_USER:****"
    echo ""
    echo -e "${YELLOW}═══════════════ 测试命令 ═══════════════${NC}"
    
    if [[ -n "$PROXY_USER" ]]; then
        if [[ "$PROTO_CHOICE" == "2" ]]; then
            echo -e "curl -x http://${PROXY_USER}:${PROXY_PASS}@${public_ip}:${PORT} https://www.google.com"
        else
            echo -e "curl -x socks5://${PROXY_USER}:${PROXY_PASS}@${public_ip}:${PORT} https://www.google.com"
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
    pkill -x gost || true
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
    
    # 使用 sysctl.d 目录写入drop-in配置，不覆盖原有 sysctl.conf
    mkdir -p /etc/sysctl.d
    
    cat > /etc/sysctl.d/99-gost-bbr.conf << 'EOF'
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
    
    # 解析协议 (取第一个 -L 的协议)
    local first_url=$(echo "$exec_line" | grep -oP '(?<=-L[\s=])\S+' | head -1)
    if [[ "$first_url" =~ ^socks5:// ]]; then
        current_proto="socks5"
    elif [[ "$first_url" =~ ^http:// ]]; then
        current_proto="http"
    fi
    
    # 检测是否为双协议模式
    local is_dual=0
    local proto_count=$(echo "$exec_line" | grep -oP '(?<=-L[\s=])\S+' | grep -cE '^(socks5|http)://')
    if [[ $proto_count -ge 2 ]]; then
        is_dual=1
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
                
                if ! validate_port "$new_port"; then
                    continue
                fi
                
                local status=0
                check_port_occupied "$new_port" "verbose" || status=$?
                
                if [[ $status -eq 1 ]]; then
                    if check_gost_port_conflict "$new_port"; then
                        read -p "是否仍要使用此端口? [y/N]: " confirm
                        [[ "$confirm" =~ ^[Yy]$ ]] && break
                        log_info "请重新设置端口"
                    else
                        break
                    fi
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
            update_service_exec "$new_exec" "$SERVICE_FILE"
            
            log_info "端口已修改为: $new_port"
            ;;
        2)
            read -p "输入新用户名 (当前: ${current_user:-无}, 留空取消认证): " new_user
            read -s -p "输入新密码: " new_pass
            echo ""
            
            local new_exec="$exec_line"
            
            if [[ -n "$new_user" && -n "$new_pass" ]]; then
                # 对特殊字符转义
                local esc_cur_user=$(sed_escape "$current_user")
                local esc_cur_pass=$(sed_escape "$current_pass")
                local esc_new_user=$(sed_escape "$new_user")
                local esc_new_pass=$(sed_escape "$new_pass")
                if [[ -n "$current_user" ]]; then
                    # 替换现有认证
                    new_exec=$(echo "$exec_line" | sed -E "s|://${esc_cur_user}:${esc_cur_pass}@|://${esc_new_user}:${esc_new_pass}@|g")
                else
                    # 添加认证
                    new_exec=$(echo "$exec_line" | sed -E "s|://:([0-9]+)|://${esc_new_user}:${esc_new_pass}@:\1|g")
                fi
                log_info "认证已修改为: ${new_user}:****"
            else
                # 移除认证
                if [[ -n "$current_user" ]]; then
                    local esc_cur_user=$(sed_escape "$current_user")
                    local esc_cur_pass=$(sed_escape "$current_pass")
                    new_exec=$(echo "$exec_line" | sed -E "s|://${esc_cur_user}:${esc_cur_pass}@|://|g")
                fi
                log_info "认证已取消"
            fi
            
            update_service_exec "$new_exec" "$SERVICE_FILE"
            ;;
        3)
            echo "选择新协议:"
            echo "  1) SOCKS5"
            echo "  2) HTTP"
            read -p "请输入 [1-2]: " proto_choice
            
            local new_proto="socks5"
            [[ "$proto_choice" == "2" ]] && new_proto="http"
            
            if [[ $is_dual -eq 1 ]]; then
                log_warn "当前为双协议模式，修改将应用于第一个节点的协议。"
            fi
            
            # 只替换第一个匹配的协议，而不是全局替换
            local new_exec=$(echo "$exec_line" | sed -E "0,/${current_proto}:\/\//s|${current_proto}://|${new_proto}://|")
            update_service_exec "$new_exec" "$SERVICE_FILE"
            
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
        log_warn "未找到 GOST 服务配置，正在自动创建..."
        create_base_service || return 1
    fi
    
    # 1. 设置新代理参数
    echo "请配置新节点参数:"
    
    # 协议
    echo "协议类型:"
    echo "  1) SOCKS5 (默认)"
    echo "  2) HTTP"
    local node_proto_choice
    read -p "请输入 [1-2]: " node_proto_choice
    node_proto_choice=${node_proto_choice:-1}
    [[ "$node_proto_choice" == "2" ]] && NEW_PROTO="http" || NEW_PROTO="socks5"
    
    # 端口
    while true; do
        read -p "设置端口 (例如 1080): " NEW_PORT
        if [[ -z "$NEW_PORT" ]]; then
            log_error "端口不能为空"
            continue
        fi
        if ! validate_port "$NEW_PORT"; then
            continue
        fi
        
        local status=0
        check_port_occupied "$NEW_PORT" "verbose" || status=$?
        
        if [[ $status -eq 1 ]]; then
            # 端口未被系统占用，检查 gost 配置内部冲突
            if check_gost_port_conflict "$NEW_PORT"; then
                read -p "是否仍要使用此端口? [y/N]: " confirm
                [[ "$confirm" =~ ^[Yy]$ ]] && break
                log_info "请重新设置端口"
            else
                break
            fi
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
    NEW_ARG="-L ${NEW_PROTO}://${NEW_AUTH}:${NEW_PORT}?keepalive=true"
    
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
    
    # 安全写入新内容
    update_service_exec "$new_cmd" "$SERVICE_FILE"
    
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
        systemctl restart gost 2>/dev/null || true
        log_info "已恢复原有配置。"
        return 1
    fi
}


add_forwarding_rule() {
    echo ""
    echo -e "${BLUE}═══════════════ 添加流量转发规则 ═══════════════${NC}"
    echo ""

    if [[ ! -f "$SERVICE_FILE" ]]; then
        log_warn "未找到 GOST 服务配置，正在自动创建..."
        create_base_service || return 1
    fi

    # 1. 本地监听端口
    while true; do
        read -p "设置本地监听端口 (例如 8080): " LOCAL_PORT
        if [[ -z "$LOCAL_PORT" ]]; then
            log_error "端口不能为空"
            continue
        fi
        if ! validate_port "$LOCAL_PORT"; then
            continue
        fi
        
        local status=0
        check_port_occupied "$LOCAL_PORT" "verbose" "udp" || status=$?
        
        if [[ $status -eq 1 ]]; then
             # 端口未被系统占用，检查 gost 配置内部冲突
             if check_gost_port_conflict "$LOCAL_PORT"; then
                 read -p "是否仍要使用此端口? [y/N]: " confirm
                 [[ "$confirm" =~ ^[Yy]$ ]] && break
                 continue
             fi
             break
        elif [[ $status -eq 2 ]]; then
             read -p "端口被旧的 GOST 服务占用，是否继续? [Y/n]: " confirm
             [[ "$confirm" =~ ^[Nn]$ ]] || break
        else
            read -p "端口被其他程序占用，可能导致启动失败。是否继续? [y/N]: " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                break
            fi
        fi
    done

    # 2. 本地监听IP
    echo "设置本地监听 IP:"
    echo "  1) 监听所有 IP (0.0.0.0, 默认)"
    echo "  2) 指定 IP"
    read -p "请输入 [1-2]: " BIND_CHOICE
    
    local LOCAL_BIND=""
    if [[ "$BIND_CHOICE" == "2" ]]; then
        read -p "请输入要监听的 IP: " LOCAL_IP
        LOCAL_BIND="$LOCAL_IP"
    fi

    # 3. 目标地址
    while true; do
        read -p "设置目标 IP (例如 1.1.1.1): " DEST_IP
        if [[ -z "$DEST_IP" ]]; then
             log_error "目标 IP 不能为空"
             continue
        fi
        if ! validate_ip "$DEST_IP"; then
             log_error "无效的 IP 地址或域名格式"
             continue
        fi
        break
    done

    while true; do
        read -p "设置目标端口 (例如 80): " DEST_PORT
        if [[ -z "$DEST_PORT" ]]; then
             log_error "目标端口不能为空"
             continue
        fi
        if ! validate_port "$DEST_PORT"; then
             continue
        fi
        break
    done

    # 4. 协议选择
    echo "请选择转发协议:"
    echo "  1) TCP Only"
    echo "  2) UDP Only"
    echo "  3) TCP + UDP"
    local fwd_proto_choice
    read -p "请输入 [1-3]: " fwd_proto_choice
    
    local forward_path="/${DEST_IP}:${DEST_PORT}"
    local new_args=""
    
    # 构造 args
    # 格式: -L protocol://[bind_ip]:port/remote_ip:remote_port
    
    case "$fwd_proto_choice" in
        1)
            new_args="-L tcp://${LOCAL_BIND}:${LOCAL_PORT}${forward_path}"
            ;;
        2)
            new_args="-L udp://${LOCAL_BIND}:${LOCAL_PORT}${forward_path}"
            ;;
        3)
            new_args="-L tcp://${LOCAL_BIND}:${LOCAL_PORT}${forward_path} -L udp://${LOCAL_BIND}:${LOCAL_PORT}${forward_path}"
            ;;
        *)
            log_warn "无效选择，默认使用 TCP"
            new_args="-L tcp://${LOCAL_BIND}:${LOCAL_PORT}${forward_path}"
            ;;
    esac

    # 5. 追加到 Service 文件
    cp "$SERVICE_FILE" "${SERVICE_FILE}.bak"
    local output=$(grep "^ExecStart=" "$SERVICE_FILE")
    local current_cmd=${output#ExecStart=}
    local new_cmd="${current_cmd} ${new_args}"
    
    # 安全写入新内容
    update_service_exec "$new_cmd" "$SERVICE_FILE"
    
    log_info "已添加转发规则: 本地 ${LOCAL_BIND}:${LOCAL_PORT} -> 目标 ${DEST_IP}:${DEST_PORT}"
    
    systemctl daemon-reload
    if systemctl restart gost; then
        echo ""
        log_info "服务已重启，转发规则已生效！"
        show_proxy_info
    else
        echo ""
        log_error "服务启动失败！正在回滚..."
        mv "${SERVICE_FILE}.bak" "$SERVICE_FILE"
        systemctl daemon-reload
        systemctl restart gost 2>/dev/null || true
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
                
                # 提取所有 -L 参数 (支持 -L protocol:// 和 -L=protocol://)
                local nodes_raw=$(echo "$exec_line" | grep -oP '(?<=-L[\s=])\S+' || echo "")
                
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
                         
                         update_service_exec "$new_exec" "$SERVICE_FILE"
                         systemctl daemon-reload
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
                        new_exec="${new_exec} -L ${nodes[n]}"
                    fi
                done
                
                update_service_exec "$new_exec" "$SERVICE_FILE"
                
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
                 
                local new_cmd="${current_cmd} -L ${target_resume}"
                
                # Update service
                 update_service_exec "$new_cmd" "$SERVICE_FILE"
                 
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

install_sstp_vpn() {
    echo ""
    echo -e "${BLUE}═══════════════ 搭建 SSTP VPN ═══════════════${NC}"
    echo ""

    if [[ ! -f /etc/redhat-release ]] && ! grep -Eqi "debian|ubuntu" /etc/issue; then
        log_error "不支持的操作系统，仅支持 Debian/Ubuntu/CentOS"
        return 1
    fi

    local vpn_port=443
    local status=0
    # 检查默认端口 443
    check_port_occupied "$vpn_port" "silent" || status=$?
    
    # 额外检查 gost 配置冲突
    local gost_conflict=0
    if check_gost_port_conflict "$vpn_port" >/dev/null 2>&1; then
        gost_conflict=1
    fi
    
    if [[ $status -eq 0 || $status -eq 2 || $gost_conflict -eq 1 ]]; then
        if [[ $gost_conflict -eq 1 ]]; then
            log_warn "默认端口 443 已被 GOST 配置占用。"
        else
            log_warn "默认端口 443 已被占用。"
        fi
        
        read -p "请输入其他端口 (例如 8443): " vpn_port
        if [[ -z "$vpn_port" ]]; then
            log_error "端口不能为空"
            return 1
        fi
        
        status=0
        check_port_occupied "$vpn_port" "verbose" || status=$?
        
        # 再次检查 gost 冲突
        if check_gost_port_conflict "$vpn_port"; then
             log_error "端口 $vpn_port 已被 GOST 占用，请选择其他端口。"
             return 1
        fi
        
        if [[ $status -eq 0 || $status -eq 2 ]]; then
             log_error "端口 $vpn_port 也被占用，请先释放端口或选择其他端口。"
             return 1
        fi
    fi

    # 2. 安装依赖
    log_info "正在安装依赖 (accel-ppp)..."
    if [[ -f /etc/redhat-release ]]; then
        yum install -y epel-release
        yum install -y accel-ppp openssl iptables-services
    else
        apt-get update
        apt-get install -y accel-ppp openssl iptables
    fi
    
    if ! command -v accel-cmd &>/dev/null; then
        log_error "accel-ppp 安装失败！请检查包管理器源或手动安装。"
        return 1
    fi

    # 3. 生成证书
    log_info "正在生成 SSL 证书..."
    local cert_dir="/etc/accel-ppp/certs"
    mkdir -p "$cert_dir"
    
    # CA (使用绝对路径，避免 cd 改变工作目录)
    if ! openssl genrsa -out "$cert_dir/ca.key" 2048 >/dev/null 2>&1; then
        log_error "证书生成失败 (openssl error)"
        return 1
    fi
    openssl req -new -x509 -days 3650 -key "$cert_dir/ca.key" -out "$cert_dir/ca.crt" \
        -subj "/C=CN/ST=State/L=City/O=SSTP-VPN/CN=SSTP-VPN-CA" >/dev/null 2>&1

    # Server Cert
    local public_ip=$(get_public_ip)
    openssl genrsa -out "$cert_dir/server.key" 2048 >/dev/null 2>&1
    openssl req -new -key "$cert_dir/server.key" -out "$cert_dir/server.csr" \
        -subj "/C=CN/ST=State/L=City/O=SSTP-VPN/CN=$public_ip" >/dev/null 2>&1
    openssl x509 -req -days 3650 -in "$cert_dir/server.csr" -CA "$cert_dir/ca.crt" -CAkey "$cert_dir/ca.key" -set_serial 01 -out "$cert_dir/server.crt" >/dev/null 2>&1

    # 4. 配置文件
    log_info "正在配置 accel-ppp..."
    [[ -f /etc/accel-ppp.conf ]] && cp /etc/accel-ppp.conf /etc/accel-ppp.conf.bak.$(date +%F_%T)

    cat > /etc/accel-ppp.conf <<EOF
[modules]
log_syslog
ppp
pptp
l2tp
sstp
auth_mschap_v2
auth_pap
auth_chap
ip_pool
chap-secrets

[core]
log-error=/var/log/accel-ppp/core.log
thread-count=4

[common]
#single-session=replace
#sid-case=upper
#sid-source=seq

[ppp]
verbose=1
min-mtu=1280
mtu=1400
mru=1400
ipv4=require
ipv6=deny
ipv6-intf-id=0:0:0:1
lcp-echo-interval=20
lcp-echo-failure=3

[sstp]
verbose=1
accept=any
listen=0.0.0.0:$vpn_port
cert-hash-algo=sha1
ssl-ciphers=DEFAULT
ssl-prefer-server-ciphers=0
ssl-ecdh-curve=prime256v1
ssl-pemfile=$cert_dir/server.crt
ssl-keyfile=$cert_dir/server.key
ssl-ca-file=$cert_dir/ca.crt

[auth]
any-login=0
noauth=0

[dns]
dns1=8.8.8.8
dns2=1.1.1.1

[ip-pool]
gw-ip-address=192.168.100.1
attr=Framed-Pool
192.168.100.2-254,name=pool1

[chap-secrets]
gw-ip-address=192.168.100.1
chap-secrets=/etc/ppp/chap-secrets
encrypted=0
EOF

    # 5. 用户设置
    read -p "设置 SSTP 用户名: " vpn_user
    read -s -p "设置 SSTP 密码: " vpn_pass
    echo ""
    
    mkdir -p /etc/ppp
    # 清理旧的用户如果存在 (简单追加)
    if grep -q "\"$vpn_user\"" /etc/ppp/chap-secrets 2>/dev/null; then
         # 如果用户已存在，尝试删除旧行 (简单处理)
         sed -i "/\"$vpn_user\"/d" /etc/ppp/chap-secrets
    fi
    echo "\"$vpn_user\" * \"$vpn_pass\" *" >> /etc/ppp/chap-secrets

    # 6. 网络设置
    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
    fi

    # IPTables NAT (Idempotent check)
    if ! iptables -t nat -C POSTROUTING -s 192.168.100.0/24 -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -s 192.168.100.0/24 -j MASQUERADE
    fi
    
    # 尝试保存
    if [[ -f /etc/redhat-release ]]; then
        service iptables save >/dev/null 2>&1
    elif command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >/dev/null 2>&1
    fi

    # 7. 启动服务
    systemctl enable accel-ppp --quiet
    if systemctl restart accel-ppp; then
        echo ""
    else
        log_error "启动 accel-ppp 失败！请检查日志: journalctl -u accel-ppp"
        return 1
    fi

    # 8. 输出信息
    echo ""
    echo -e "${GREEN}SSTP VPN 部署完成！${NC}"
    echo -e "  服务器 IP: ${CYAN}$public_ip${NC}"
    echo -e "  端口: ${CYAN}$vpn_port${NC}"
    echo -e "  CA 证书路径: ${CYAN}/etc/accel-ppp/certs/ca.crt${NC}"
    echo -e "  ${YELLOW}注意: 请务必下载 ca.crt 并导入到客户端设备的“受信任的根证书颁发机构”中，否则连接会失败。${NC}"
    echo -e "  用户名: ${CYAN}$vpn_user${NC}"
    echo -e "  密码: ${CYAN}$vpn_pass${NC}"
    echo ""
    
    # 简单的提供下载方式提示
    echo "您可以使用以下命令在本地下载证书 (需在本地终端运行):"
    echo -e "scp root@$public_ip:/etc/accel-ppp/certs/ca.crt ./"
    echo ""
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
        
        # 提取目标地址 (转发模式)
        # 格式: schema://[user:pass@][host]:port/target_addr:target_port
        local target=""
        # 匹配 /ip:port 结尾
        if [[ "$proxy_url" =~ /([^/]+:[0-9]+)$ ]]; then
            target="${BASH_REMATCH[1]}"
        fi
        
        # 提取本地端口
        # 移除 scheme
        local temp_url=${proxy_url#*://}
        # 移除 auth
        temp_url=${temp_url#*@}
        # 截取 host:port 部分 (去掉可能的 path)
        local listen_part=${temp_url%%/*}
        # 移除 query (Suggestion 3)
        listen_part=${listen_part%%\?*}
        # 截取端口 (最后冒号后的部分)
        local port=${listen_part##*:}

        echo ""
        echo -e "  ${GREEN}[$proxy_count]${NC} 协议: ${YELLOW}$proto${NC}"
        echo -e "      本地监听: ${YELLOW}${port:-未知}${NC}"
        if [[ -n "$target" ]]; then
            echo -e "      转发目标: ${YELLOW}$target${NC}"
        fi
        if [[ -n "$auth" ]]; then
            echo -e "      认证: ${YELLOW}$auth${NC}"
        elif [[ -z "$target" ]]; then
            echo -e "      认证: ${YELLOW}无${NC}"
        fi
        
    done < <(echo "$exec_line" | grep -oP '(?<=-L[\s=])\S+')
    
    # 显示连接信息
    echo ""
    echo -e "${YELLOW}═══════════════ 连接信息 ═══════════════${NC}"
    echo -e "  服务器 IP: ${CYAN}$public_ip${NC}"
    
    # SSTP 检测
    if systemctl is-active --quiet accel-ppp; then
        echo -e "  SSTP VPN: ${GREEN}运行中${NC}"
        local sstp_port=$(grep "listen=" /etc/accel-ppp.conf 2>/dev/null | cut -d: -f2)
        echo -e "  SSTP 端口: ${CYAN}${sstp_port:-443}${NC}"
    fi

    # 生成测试命令
    echo ""
    echo -e "${YELLOW}═══════════════ 测试命令 ═══════════════${NC}"
    
    # 从解析结果生成第一个非转发代理的测试命令
    local first_proxy=$(echo "$exec_line" | grep -oP '(?<=-L[\s=])\S+' | grep -v "/" | head -1)
    if [[ -n "$first_proxy" ]]; then
        local proto=$(echo "$first_proxy" | grep -oE "^[a-z0-9]+")
        local port=$(echo "$first_proxy" | grep -oE ":([0-9]+)\?" | tr -d ':?')
        [[ -z "$port" ]] && port=$(echo "$first_proxy" | grep -oE ":([0-9]+)$" | tr -d ':')
        
        if [[ "$first_proxy" =~ ://([^:]+):([^@]+)@ ]]; then
            echo -e "  curl -x ${proto}://${BASH_REMATCH[1]}:${BASH_REMATCH[2]}@${public_ip}:${port} https://www.google.com"
        else
            echo -e "  curl -x ${proto}://${public_ip}:${port} https://www.google.com"
        fi
    fi
    
    echo ""
}

install_gost_flow() {
    check_root
    check_dependencies
    
    # Check if we are updating
    local is_update=0
    if [[ -f "$SERVICE_FILE" ]]; then
        is_update=1
    fi

    check_existing_installation || return 0
    get_latest_version
    detect_arch
    download_and_install
    
    if [[ $is_update -eq 1 ]]; then
        echo ""
        log_info "检测到您是更新操作。"
        read -p "是否保留当前的代理配置? [Y/n]: " keep_config
        keep_config=${keep_config:-Y}
        
        if [[ "$keep_config" =~ ^[Yy]$ ]]; then
            log_info "正在保留配置并启动服务..."
            systemctl daemon-reload
            systemctl restart gost
            echo ""
            log_info "GOST 更新完成！"
            show_proxy_info
            return
        else
            log_info "已清除旧配置。请通过主菜单选项 5 或 6 重新配置代理。"
            # 停止旧服务
            systemctl stop gost 2>/dev/null || true
            return
        fi
    fi
    
    # 全新安装完成，提示用户通过菜单配置
    echo ""
    log_info "GOST 安装完成！"
    log_info "请返回主菜单，选择以下选项来配置代理："
    echo -e "  ${CYAN}5)${NC} 修改代理配置"
    echo -e "  ${CYAN}6)${NC} 添加新代理节点 (多端口)"
    echo -e "  ${CYAN}7)${NC} 添加流量转发规则 (TCP/UDP)"
}

show_menu() {
    while true; do
        print_banner
        echo "请选择操作:"
        echo "  1) 安装/更新 GOST"
        echo "  2) 卸载 GOST"
        echo "  3) 查看运行状态"
        echo "  4) 查看代理配置"
        echo "  5) 修改代理配置"
        echo "  6) 添加新代理节点 (多端口)"
        echo "  7) 添加流量转发规则 (TCP/UDP)"
        echo "  8) BBR & TCP 网络优化"
        echo "  9) 管理暂停的规则 (代理/转发)"
        echo "  10) 搭建 SSTP VPN (一键部署)"
        echo "  11) 更新脚本"
        echo "  0) 退出"
        echo ""
        read -p "请输入 [0-11]: " choice
        
        case "$choice" in
            1) 
                install_gost_flow
                read -p "按任意键返回主菜单..."
                ;;
            2)
                check_root
                uninstall
                read -p "按任意键返回主菜单..."
                ;;
            3)
                local gost_found=0
                if systemctl is-active --quiet gost 2>/dev/null; then
                    log_info "GOST 运行中 (systemd 服务)"
                    systemctl status gost --no-pager
                    gost_found=1
                fi
                # 同时检查是否有独立运行的 gost 进程
                local gost_pids=$(pgrep -x gost 2>/dev/null || true)
                if [[ -n "$gost_pids" && $gost_found -eq 0 ]]; then
                    log_info "GOST 运行中 (独立进程)"
                    echo -e "  PID: ${CYAN}$gost_pids${NC}"
                    echo -e "  ${YELLOW}注意: 该进程未被本脚本的 systemd 服务管理。${NC}"
                    echo -e "  运行命令:"
                    for pid in $gost_pids; do
                        echo -e "    ${CYAN}$(cat /proc/$pid/cmdline 2>/dev/null | tr '\0' ' ')${NC}"
                    done
                    gost_found=1
                fi
                if [[ $gost_found -eq 0 ]]; then
                    log_warn "GOST 未运行"
                fi
                if systemctl is-active --quiet accel-ppp 2>/dev/null; then
                    echo ""
                    log_info "SSTP VPN 运行中"
                    systemctl status accel-ppp --no-pager
                fi
                read -p "按任意键返回主菜单..."
                ;;
            4)
                show_proxy_info
                read -p "按任意键返回主菜单..."
                ;;
            5)
                check_root
                modify_proxy
                read -p "按任意键返回主菜单..."
                ;;
            6)
                check_root
                add_proxy_node
                read -p "按任意键返回主菜单..."
                ;;
            7)
                check_root
                add_forwarding_rule
                read -p "按任意键返回主菜单..."
                ;;
            8)
                check_root
                optimize_network
                read -p "按任意键返回主菜单..."
                ;;
            9)
                check_root
                manage_paused_proxies
                read -p "按任意键返回主菜单..."
                ;;
            10)
                check_root
                install_sstp_vpn
                read -p "按任意键返回主菜单..."
                ;;
            11)
                update_script
                # 如果 exec 成功，此处不会执行；如果更新失败，回到菜单
                read -p "按任意键返回主菜单..."
                ;;
            0)
                exit 0
                ;;
            *)
                log_error "无效选项"
                read -p "按任意键重试..."
                ;;
        esac
    done
}

# --- 主入口 ---
show_menu
