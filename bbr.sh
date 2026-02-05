#!/bin/bash
# =========================================================
# BBR + 网络优化自动配置脚本 (v7.2 - 快捷指令版)
# - 支持 BBRv3 检测
# - 支持多种队列算法 (fq, fq_codel, fq_pie, cake)
# - 自动模块加载与持久化
# - 支持非交互模式 (-y)
# - Hysteria2 / VLESS-WS / VLESS-XTLS 协议专用优化
# - 🚀 自动安装 'bb' 快捷指令
# =========================================================
set -Eeuo pipefail

# --- 变量定义 ---
LOG_FILE="/var/log/bbr-optimize.log"
LIMITS_CONF="/etc/security/limits.conf"
SYSTEMD_CONF="/etc/systemd/system.conf"
BACKUP_DIR="/etc/sysctl.d/backup"
ORIGINAL_BACKUP_DIR="$BACKUP_DIR/original"
HISTORY_BACKUP_DIR="$BACKUP_DIR/history"
VALID_QDISC=("fq" "fq_codel" "fq_pie" "cake")
DEFAULT_QDISC="fq"
SYSCTL_CONF="/etc/sysctl.d/99-bbr.conf"
MODULES_CONF="/etc/modules-load.d/qdisc.conf"
AUTO_YES=false
MAX_HISTORY_BACKUPS=10
VERSION="7.2"
UPDATE_URL="https://raw.githubusercontent.com/suxayii/Throttle/refs/heads/master/bbr.sh"

# --- 颜色 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# --- 基础函数 ---
log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

show_help() {
    echo "用法: $0 [-y] [fq|fq_codel|fq_pie|cake|hysteria2|vless-ws|vless-xtls|mixed|restore]"
    echo ""
    echo "通用优化选项:"
    echo "  fq, fq_codel, fq_pie, cake  选择队列调度算法 (BBR + TCP)"
    echo ""
    echo "协议专用优化:"
    echo "  hysteria2                    Hysteria2 专用优化 (UDP/QUIC)"
    echo "  vless-ws                     VLESS-WS 专用优化 (TCP/WebSocket)"
    echo "  vless-xtls                   VLESS-XTLS/Reality 专用优化 (TCP/TLS + UDP透传)"
    echo "  mixed                        混合模式 (全协议兼容)"
    echo ""
    echo "其他选项:"
    echo "  restore                      恢复原始配置"
    echo "  -y                           非交互模式，跳过所有确认提示"
    echo "  -h, --help                   显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  $0                 # 交互式菜单"
    echo "  $0 fq              # 直接使用 fq 算法"
    echo "  $0 hysteria2       # Hysteria2 专用优化"
    echo "  $0 ws-cdn          # VLESS-WS (Cloudflare CDN) 优化"
    echo "  $0 streaming       # 直播专用优化 (低延迟/抗抖动)"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}❌ 错误: 必须使用 Root 权限运行${PLAIN}"
        exit 1
    fi
}

check_kernel() {
    local kernel_version=$(uname -r | cut -d. -f1-2)
    local major=$(echo "$kernel_version" | cut -d. -f1)
    local minor=$(echo "$kernel_version" | cut -d. -f2)
    
    if [[ $major -lt 4 ]] || [[ $major -eq 4 && $minor -lt 9 ]]; then
        echo -e "${RED}❌ 错误: 内核版本 $kernel_version 不支持 BBR (需要 4.9+)${PLAIN}"
        echo -e "${YELLOW}提示: 请先升级内核后再运行此脚本${PLAIN}"
        exit 1
    fi
    log "✅ 内核版本检查通过: $kernel_version"
}

check_dependencies() {
    local missing=()
    for cmd in curl ip sysctl awk sed grep modprobe; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [ ${#missing[@]} -ne 0 ]; then
        log "正在安装依赖: ${missing[*]}"
        if command -v apt-get &> /dev/null; then
            apt-get update -qq && apt-get install -y -qq "${missing[@]}"
        elif command -v yum &> /dev/null; then
            yum install -y -q "${missing[@]}"
        else
            echo -e "${RED}❌ 请手动安装依赖: ${missing[*]}${PLAIN}"
            exit 1
        fi
    fi
}

# --- 检查更新 ---
check_update() {
    echo -e "\n${CYAN}--- 🔄 检查更新 ---${PLAIN}"
    log "正在检查新版本..."
    
    local latest_script
    if ! latest_script=$(curl -sL --connect-timeout 5 "$UPDATE_URL"); then
        echo -e "${RED}❌ 检查更新失败: 无法连接到 GitHub${PLAIN}"
        return
    fi
    
    local latest_ver=$(echo "$latest_script" | sed -n 's/.*VERSION="\([^"]*\)".*/\1/p' | head -1)
    
    if [[ -z "$latest_ver" ]]; then
         # 尝试从注释中获取 (v7.2 - xxx)
         latest_ver=$(echo "$latest_script" | sed -n 's/.*v\([0-9.]*\)\s*-.*/\1/p' | head -1)
    fi
    
    if [[ -n "$latest_ver" && "$latest_ver" != "$VERSION" ]]; then
        echo -e "发现新版本: ${GREEN}v$latest_ver${PLAIN} (当前: v$VERSION)"
        echo -e "更新内容可能包含: 算法优化、新协议支持或 Bug 修复。"
        
        local choice
        read -p "是否立即更新? [y/N]: " choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            log "正在下载更新..."
            if echo "$latest_script" > "$0"; then
                chmod +x "$0"
                log "✅ 更新成功! 正在重启脚本..."
                exec "$0" # 重启并进入菜单
            else
                echo -e "${RED}❌ 更新写入失败${PLAIN}"
            fi
        fi
    else
        echo -e "${GREEN}✅ 当前已是最新版本 (v$VERSION)${PLAIN}"
        echo -e "无需更新。"
        read -p "按回车键返回菜单..."
    fi
}

# --- 快捷指令安装 ---
install_shortcut() {
    local install_path="/usr/bin/bb"
    # 如果脚本当前不在 /usr/bin/bb，则复制自身
    if [[ "$0" != "$install_path" ]]; then
        # 备份原始文件(如果有)并覆盖
        cp -f "$0" "$install_path"
        chmod +x "$install_path"
        log "✅ 已添加快捷指令: 输入 ${GREEN}bb${PLAIN} 即可再次运行此脚本"
    fi
}

# --- 系统更新 ---
update_system() {
    echo -e "\n${CYAN}--- 系统更新 ---${PLAIN}"
    local choice="n"
    if [[ "$AUTO_YES" == true ]]; then
        log "非交互模式: 跳过系统更新"
        return
    fi
    read -p "是否更新系统软件包? (可能需要较长时间) [y/N]: " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        log "正在更新系统..."
        if command -v apt-get &> /dev/null; then
            apt-get update -y && apt-get upgrade -y
        elif command -v yum &> /dev/null; then
            yum update -y
        elif command -v dnf &> /dev/null; then
            dnf update -y
        else
            log "⚠️ 未知包管理器，跳过系统更新"
            return
        fi
        log "✅ 系统更新完成"
    else
        log "已跳过系统更新"
    fi
}

# --- BBR 版本检测 ---
check_bbr_version() {
    echo -e "\n${CYAN}--- BBR 版本检测 ---${PLAIN}"
    local bbr_info=""
    local bbr_ver=""
    
    if modinfo tcp_bbr &>/dev/null; then
        bbr_info=$(modinfo tcp_bbr)
        bbr_ver=$(echo "$bbr_info" | grep "^version:" | awk '{print $2}' || true)
    fi

    if [[ "$bbr_ver" == "3" ]]; then
        echo -e "当前内核模块: ${GREEN}BBR v3${PLAIN}"
    elif [[ -n "$bbr_ver" ]]; then
        echo -e "当前内核模块: ${GREEN}BBR (标准版) - 版本 $bbr_ver${PLAIN}"
    else
        echo -e "当前内核模块: ${YELLOW}未检测到 BBR 模块 (将在配置后生效)${PLAIN}"
    fi

    # 检查当前运行状态
    local current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "none")
    echo -e "当前运行算法: ${GREEN}$current_cc${PLAIN}"
}

# --- 模块管理 ---
load_qdisc_module() {
    local qdisc=$1
    local module="sch_$qdisc"

    # fq 和 fq_codel 通常是内置的，但也尝试加载以防万一
    log "正在检查并加载模块: $module"
    
    if modprobe "$module" &>/dev/null; then
        log "✅ 模块 $module 加载成功"
    else
        # 并不是所有内核都编译了所有模块，失败不一定是错误
        log "⚠️ 模块 $module 加载尝试结束 (可能已内置或不支持)"
    fi

    # 持久化加载配置
    mkdir -p "$(dirname "$MODULES_CONF")"
    if [[ "$qdisc" != "fq" && "$qdisc" != "fq_codel" ]]; then
        if ! grep -q "^$module" "$MODULES_CONF" 2>/dev/null; then
            echo "$module" >> "$MODULES_CONF"
            log "已添加 $module 到自动加载列表"
        fi
    fi
}

# --- 极限优化 (文件描述符等) ---
apply_limits_optimization() {
    log "正在配置系统资源限制 (Limit Load)..."

    # 1. 用户级限制 (/etc/security/limits.conf)
    local limits_content="* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576"

    if ! grep -q "soft nofile 1048576" "$LIMITS_CONF"; then
        echo -e "\n$limits_content" >> "$LIMITS_CONF"
        log "✅ 已更新 $LIMITS_CONF"
    else
        log "ℹ️ $LIMITS_CONF 已包含优化限制"
    fi

    # 2. Systemd 全局限制 (/etc/systemd/system.conf)
    if [[ -f "$SYSTEMD_CONF" ]]; then
        if ! grep -q "^DefaultLimitNOFILE=1048576" "$SYSTEMD_CONF"; then
            sed -i 's/^#DefaultLimitNOFILE=.*/DefaultLimitNOFILE=1048576/' "$SYSTEMD_CONF"
            if ! grep -q "^DefaultLimitNOFILE=1048576" "$SYSTEMD_CONF"; then
                echo "DefaultLimitNOFILE=1048576" >> "$SYSTEMD_CONF"
            fi
            log "✅ 已更新 $SYSTEMD_CONF"
            systemctl daemon-reexec || true
        else
            log "ℹ️ $SYSTEMD_CONF 已包含优化限制"
        fi
    fi

    # 3. 检查 PAM 限制 (提示性质)
    if [[ -f /etc/pam.d/common-session ]]; then
        if ! grep -q "pam_limits.so" /etc/pam.d/common-session; then
            log "⚠️ 警告: 未在 /etc/pam.d/common-session 中检测到 pam_limits.so，限制可能无法在 SSH 登录时立即生效。"
        fi
    fi
}

# --- Sysctl 配置 ---
apply_optimization() {
    local qdisc=$1
    log "正在应用网络优化配置 (QDisc: $qdisc)..."

    # 1. 分层备份环境准备
    mkdir -p "$ORIGINAL_BACKUP_DIR" "$HISTORY_BACKUP_DIR"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    
    local files=("$SYSCTL_CONF" "$LIMITS_CONF" "$SYSTEMD_CONF")
    for file in "${files[@]}"; do
        if [[ -f "$file" ]]; then
            local base_name=$(basename "$file")
            # 原始备份 (仅在不存在时创建)
            if [[ ! -f "$ORIGINAL_BACKUP_DIR/$base_name.orig" ]]; then
                cp "$file" "$ORIGINAL_BACKUP_DIR/$base_name.orig"
                log "💾 已创建原始备份: $base_name.orig"
            fi
            # 历史备份 (每次运行都创建)
            cp "$file" "$HISTORY_BACKUP_DIR/$base_name.$timestamp.bak"
        fi
    done

    # 清理旧的历史备份，只保留最近 N 个
    find "$HISTORY_BACKUP_DIR" -name "*.bak" -type f 2>/dev/null | sort -r | tail -n +$((MAX_HISTORY_BACKUPS + 1)) | xargs rm -f 2>/dev/null || true

    # 2. 加载模块
    # 确保 BBR 模块加载
    if ! lsmod | grep -q tcp_bbr; then
        modprobe tcp_bbr &>/dev/null || true
        echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
    fi
    load_qdisc_module "$qdisc"

    # 3. 应用 Limits 优化
    apply_limits_optimization
    cat > "$SYSCTL_CONF" << EOF
# ==========================================
# BBR Network Optimization
# Generated by bbr.sh at $(date)
# Original backup at: $ORIGINAL_BACKUP_DIR
# ==========================================

# --- 核心网络参数 ---
net.core.default_qdisc = $qdisc
net.ipv4.tcp_congestion_control = bbr

# --- TCP 缓冲区优化 (基于通常建议值) ---
fs.file-max = 6815744
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# --- TCP 行为优化 ---
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_frto = 0
net.ipv4.tcp_mtu_probing = 0
net.ipv4.tcp_sack = 1
# net.ipv4.tcp_fack = 1  # 已在 Linux 4.15+ 移除
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_moderate_rcvbuf = 1

# --- 连接保持与安全性 ---
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fastopen = 3

# --- 转发开启 ---
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
EOF

    # 4. 应用 (使用 --system 加载所有 /etc/sysctl.d/ 配置)
    if sysctl --system &>/dev/null; then
        echo -e "${GREEN}✅ 优化配置已应用!${PLAIN}"
    else
        echo -e "${RED}⚠️  sysctl 应用失败，请检查配置文件${PLAIN}"
    fi
}

# --- Hysteria2 进程优先级配置 (官方推荐) ---
configure_hysteria2_priority() {
    local service_name="hysteria-server"
    local priority_conf="/etc/systemd/system/${service_name}.service.d/priority.conf"
    
    # 检查 Hysteria2 服务是否存在
    if ! systemctl list-unit-files | grep -q "$service_name"; then
        log "⚠️ 未检测到 Hysteria2 服务 ($service_name)，跳过优先级配置"
        return
    fi
    
    echo -e "\n${CYAN}--- Hysteria2 进程优先级 ---${PLAIN}"
    
    if [[ "$AUTO_YES" != true ]]; then
        read -p "是否设置 Hysteria2 进程优先级 (推荐、降低延迟抖动)? [y/N]: " choice
        [[ ! "$choice" =~ ^[Yy]$ ]] && return
    fi
    
    mkdir -p "$(dirname "$priority_conf")"
    cat > "$priority_conf" << 'EOF'
# Hysteria2 进程优先级配置 (官方推荐)
# 来源: https://v2.hysteria.network/zh/docs/advanced/Performance/
[Service]
CPUSchedulingPolicy=rr
CPUSchedulingPriority=99
EOF
    
    systemctl daemon-reload
    if systemctl restart "$service_name" 2>/dev/null; then
        log "✅ 已设置 Hysteria2 实时调度优先级 (rr:99)"
    else
        log "⚠️ Hysteria2 服务重启失败，请手动重启: systemctl restart $service_name"
    fi
}

# --- Hysteria2 QUIC 窗口配置提示 ---
show_hysteria2_quic_tips() {
    echo -e "\n${CYAN}--- 💡 Hysteria2 QUIC 窗口优化提示 ---${PLAIN}"
    echo -e "建议在 Hysteria2 配置文件中添加以下参数 (官方推荐):"
    echo -e "${GREEN}"
    cat << 'EOF'
quic:
  initStreamReceiveWindow: 26843545
  maxStreamReceiveWindow: 26843545
  initConnReceiveWindow: 67108864
  maxConnReceiveWindow: 67108864
EOF
    echo -e "${PLAIN}"
    echo -e "流/连接窗口比例应保持约 2:5，避免单流堵塞整个连接。"
    echo -e "更多详情: ${CYAN}https://v2.hysteria.network/zh/docs/advanced/Performance/${PLAIN}"
}

# --- Hysteria2 专用优化 (UDP/QUIC) ---
apply_hysteria2_optimization() {
    log "正在应用 Hysteria2 专用优化 (UDP/QUIC)..."

    # 备份环境准备
    mkdir -p "$ORIGINAL_BACKUP_DIR" "$HISTORY_BACKUP_DIR"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    
    local files=("$SYSCTL_CONF" "$LIMITS_CONF" "$SYSTEMD_CONF")
    for file in "${files[@]}"; do
        if [[ -f "$file" ]]; then
            local base_name=$(basename "$file")
            if [[ ! -f "$ORIGINAL_BACKUP_DIR/$base_name.orig" ]]; then
                cp "$file" "$ORIGINAL_BACKUP_DIR/$base_name.orig"
                log "💾 已创建原始备份: $base_name.orig"
            fi
            cp "$file" "$HISTORY_BACKUP_DIR/$base_name.$timestamp.bak"
        fi
    done

    find "$HISTORY_BACKUP_DIR" -name "*.bak" -type f 2>/dev/null | sort -r | tail -n +$((MAX_HISTORY_BACKUPS + 1)) | xargs rm -f 2>/dev/null || true

    apply_limits_optimization
    cat > "$SYSCTL_CONF" << EOF
# ==========================================
# Hysteria2 (UDP/QUIC) Optimization
# Generated by bbr.sh v7.2 at $(date)
# Original backup at: $ORIGINAL_BACKUP_DIR
# 参考: https://v2.hysteria.network/zh/docs/advanced/Performance/
# ==========================================

# --- 文件描述符限制 ---
fs.file-max = 6815744

# --- UDP 缓冲区优化 (QUIC 核心) ---
# 官方推荐 16MB，但高带宽场景可用 64MB
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 26214400
net.core.wmem_default = 26214400
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# --- UDP 连接追踪 ---
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 180

# --- 禁用反向路径过滤 (UDP 重要) ---
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0

# --- 转发开启 ---
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1

# --- 网络队列优化 ---
net.core.netdev_max_backlog = 65536
net.core.somaxconn = 65535

# --- 可选: BBR 对 TCP 回退连接有帮助 ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

    # 加载 nf_conntrack 模块
    modprobe nf_conntrack &>/dev/null || true

    if sysctl --system &>/dev/null; then
        echo -e "${GREEN}✅ Hysteria2 系统参数已优化!${PLAIN}"
    else
        echo -e "${RED}⚠️  sysctl 应用失败${PLAIN}"
    fi
    
    # 配置进程优先级 (官方推荐)
    configure_hysteria2_priority
    
    # 显示 QUIC 窗口配置提示
    show_hysteria2_quic_tips
}

# --- VLESS-WS 专用优化 (TCP/WebSocket) ---
apply_vless_ws_optimization() {
    log "正在应用 VLESS-WS 专用优化 (TCP/WebSocket)..."

    mkdir -p "$ORIGINAL_BACKUP_DIR" "$HISTORY_BACKUP_DIR"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    
    local files=("$SYSCTL_CONF" "$LIMITS_CONF" "$SYSTEMD_CONF")
    for file in "${files[@]}"; do
        if [[ -f "$file" ]]; then
            local base_name=$(basename "$file")
            if [[ ! -f "$ORIGINAL_BACKUP_DIR/$base_name.orig" ]]; then
                cp "$file" "$ORIGINAL_BACKUP_DIR/$base_name.orig"
                log "💾 已创建原始备份: $base_name.orig"
            fi
            cp "$file" "$HISTORY_BACKUP_DIR/$base_name.$timestamp.bak"
        fi
    done

    find "$HISTORY_BACKUP_DIR" -name "*.bak" -type f 2>/dev/null | sort -r | tail -n +$((MAX_HISTORY_BACKUPS + 1)) | xargs rm -f 2>/dev/null || true

    if ! lsmod | grep -q tcp_bbr; then
        modprobe tcp_bbr &>/dev/null || true
        echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
    fi
    load_qdisc_module "fq"

    apply_limits_optimization
    cat > "$SYSCTL_CONF" << EOF
# ==========================================
# VLESS-WS (TCP/WebSocket) Optimization
# Generated by bbr.sh at $(date)
# Original backup at: $ORIGINAL_BACKUP_DIR
# ==========================================

# --- 核心网络参数 (BBR + fq) ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- 文件描述符 ---
fs.file-max = 6815744

# --- TCP 缓冲区优化 ---
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432

# --- TCP 行为优化 ---
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_moderate_rcvbuf = 1

# --- WebSocket 长连接优化 ---
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 10

# --- 连接优化 ---
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fastopen = 3

# --- 转发开启 ---
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
EOF

    if sysctl --system &>/dev/null; then
        echo -e "${GREEN}✅ VLESS-WS 专用优化已应用!${PLAIN}"
    else
        echo -e "${RED}⚠️  sysctl 应用失败${PLAIN}"
    fi
}

# --- VLESS-WS (Cloudflare CDN) 专用优化 (TCP/WebSocket) ---
apply_vless_ws_cdn_optimization() {
    log "正在应用 VLESS-WS (Cloudflare CDN) 专用优化 (TCP/WebSocket)..."

    mkdir -p "$ORIGINAL_BACKUP_DIR" "$HISTORY_BACKUP_DIR"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    
    local files=("$SYSCTL_CONF" "$LIMITS_CONF" "$SYSTEMD_CONF")
    for file in "${files[@]}"; do
        if [[ -f "$file" ]]; then
            local base_name=$(basename "$file")
            if [[ ! -f "$ORIGINAL_BACKUP_DIR/$base_name.orig" ]]; then
                cp "$file" "$ORIGINAL_BACKUP_DIR/$base_name.orig"
                log "💾 已创建原始备份: $base_name.orig"
            fi
            cp "$file" "$HISTORY_BACKUP_DIR/$base_name.$timestamp.bak"
        fi
    done

    find "$HISTORY_BACKUP_DIR" -name "*.bak" -type f 2>/dev/null | sort -r | tail -n +$((MAX_HISTORY_BACKUPS + 1)) | xargs rm -f 2>/dev/null || true

    if ! lsmod | grep -q tcp_bbr; then
        modprobe tcp_bbr &>/dev/null || true
        echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
    fi
    load_qdisc_module "fq"

    apply_limits_optimization
    cat > "$SYSCTL_CONF" << EOF
# ==========================================
# VLESS-WS (Cloudflare CDN) Optimization
# Generated by bbr.sh at $(date)
# Original backup at: $ORIGINAL_BACKUP_DIR
# ==========================================

# --- 核心网络参数 (BBR + fq) ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- 文件描述符 ---
fs.file-max = 6815744

# --- TCP 缓冲区优化 ---
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432

# --- TCP 行为优化 ---
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_moderate_rcvbuf = 1

# --- WebSocket 长连接优化 (CDN 场景下 Keepalive 设短) ---
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 5

# --- 连接优化 ---
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fastopen = 3

# --- 转发开启 ---
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
EOF

    if sysctl --system &>/dev/null; then
        echo -e "${GREEN}✅ VLESS-WS (Cloudflare CDN) 专用优化已应用!${PLAIN}"
    else
        echo -e "${RED}⚠️  sysctl 应用失败${PLAIN}"
    fi
}

# --- 直播专用优化 (低延迟/抗抖动) ---
apply_streaming_optimization() {
    log "正在应用直播专用优化 (低延迟/抗抖动)..."
    log "策略: fq_codel + 大接收窗口 + 激进重传"

    mkdir -p "$ORIGINAL_BACKUP_DIR" "$HISTORY_BACKUP_DIR"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local files=("$SYSCTL_CONF" "$LIMITS_CONF" "$SYSTEMD_CONF")
    for file in "${files[@]}"; do
        if [[ -f "$file" ]]; then
            local base_name=$(basename "$file")
            [[ ! -f "$ORIGINAL_BACKUP_DIR/$base_name.orig" ]] && cp "$file" "$ORIGINAL_BACKUP_DIR/$base_name.orig"
            cp "$file" "$HISTORY_BACKUP_DIR/$base_name.$timestamp.bak"
        fi
    done
    find "$HISTORY_BACKUP_DIR" -name "*.bak" -type f 2>/dev/null | sort -r | tail -n +$((MAX_HISTORY_BACKUPS + 1)) | xargs rm -f 2>/dev/null || true

    if ! lsmod | grep -q tcp_bbr; then
        modprobe tcp_bbr &>/dev/null || true
        echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
    fi
    # 直播场景推荐 fq_codel (控制延迟)
    load_qdisc_module "fq_codel"

    apply_limits_optimization
    
    cat > "$SYSCTL_CONF" << EOF
# ==========================================
# Live Streaming Optimization
# Generated by bbr.sh v7.2 at $(date)
# 针对直播场景优化:
# - 使用 fq_codel 控制 Bufferbloat (降低延迟)
# - 增大接收缓冲区 (平滑播放)
# - 优化重传机制
# ==========================================

# --- 核心网络参数 ---
# fq_codel 对实时流媒体延迟控制更好
net.core.default_qdisc = fq_codel
net.ipv4.tcp_congestion_control = bbr

# --- 文件描述符 ---
fs.file-max = 6815744

# --- TCP 缓冲区优化 (观看端优化) ---
# 接收缓冲区(rmem) 设得比发送缓冲区(wmem) 稍大，利于吞吐和平滑
net.core.rmem_max = 67108864
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 131072 67108864
net.ipv4.tcp_wmem = 4096 65536 33554432

# --- 降低延迟优化 ---
# 尽可能推送数据，减少缓冲
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_sack = 1
# 开启低延迟模式 (如内核支持)
net.ipv4.tcp_low_latency = 1

# --- 连接与重传 ---
# 直播可容忍少量连接断开，但重传要快
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# --- 其他 ---
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 8192

# --- 转发 ---
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
EOF

    if sysctl --system &>/dev/null; then
        echo -e "${GREEN}✅ 直播专用优化已应用! (QDisc: fq_codel)${PLAIN}"
    else
        echo -e "${RED}⚠️  sysctl 应用失败${PLAIN}"
    fi
}

# --- VLESS-XTLS/Reality 专用优化 (TCP/TLS + UDP透传) ---
apply_vless_xtls_optimization() {
    log "正在应用 VLESS-XTLS/Reality 专用优化 (TCP/TLS + UDP透传)..."

    mkdir -p "$ORIGINAL_BACKUP_DIR" "$HISTORY_BACKUP_DIR"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    
    local files=("$SYSCTL_CONF" "$LIMITS_CONF" "$SYSTEMD_CONF")
    for file in "${files[@]}"; do
        if [[ -f "$file" ]]; then
            local base_name=$(basename "$file")
            if [[ ! -f "$ORIGINAL_BACKUP_DIR/$base_name.orig" ]]; then
                cp "$file" "$ORIGINAL_BACKUP_DIR/$base_name.orig"
                log "💾 已创建原始备份: $base_name.orig"
            fi
            cp "$file" "$HISTORY_BACKUP_DIR/$base_name.$timestamp.bak"
        fi
    done

    find "$HISTORY_BACKUP_DIR" -name "*.bak" -type f 2>/dev/null | sort -r | tail -n +$((MAX_HISTORY_BACKUPS + 1)) | xargs rm -f 2>/dev/null || true

    if ! lsmod | grep -q tcp_bbr; then
        modprobe tcp_bbr &>/dev/null || true
        echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
    fi
    load_qdisc_module "fq"
    modprobe nf_conntrack &>/dev/null || true

    apply_limits_optimization
    cat > "$SYSCTL_CONF" << EOF
# ==========================================
# VLESS-XTLS/Reality (TCP/TLS + UDP) Optimization
# Generated by bbr.sh at $(date)
# Original backup at: $ORIGINAL_BACKUP_DIR
# ==========================================

# --- 核心网络参数 (BBR + fq) ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- 文件描述符 ---
fs.file-max = 6815744

# --- TCP 缓冲区优化 (XTLS 零拷贝加速) ---
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432

# --- UDP 缓冲区优化 (UDP 透传支持) ---
net.core.rmem_default = 26214400
net.core.wmem_default = 26214400
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# --- TCP 行为优化 (XTLS 增强) ---
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_slow_start_after_idle = 0

# --- TLS/Reality 连接优化 ---
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# --- 连接优化 (更激进的回收) ---
net.ipv4.tcp_fin_timeout = 5
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = 65535
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fastopen = 3

# --- UDP 连接追踪 (UDP 透传) ---
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 180

# --- 网络队列优化 ---
net.core.netdev_max_backlog = 65536
net.core.somaxconn = 65535

# --- 转发开启 ---
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
EOF

    if sysctl --system &>/dev/null; then
        echo -e "${GREEN}✅ VLESS-XTLS/Reality 专用优化已应用!${PLAIN}"
    else
        echo -e "${RED}⚠️  sysctl 应用失败${PLAIN}"
    fi
}

# --- 混合模式 (Hysteria2 + VLESS) ---
apply_mixed_optimization() {
    log "正在应用混合模式优化 (Hysteria2 + VLESS)..."

    mkdir -p "$ORIGINAL_BACKUP_DIR" "$HISTORY_BACKUP_DIR"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    
    local files=("$SYSCTL_CONF" "$LIMITS_CONF" "$SYSTEMD_CONF")
    for file in "${files[@]}"; do
        if [[ -f "$file" ]]; then
            local base_name=$(basename "$file")
            if [[ ! -f "$ORIGINAL_BACKUP_DIR/$base_name.orig" ]]; then
                cp "$file" "$ORIGINAL_BACKUP_DIR/$base_name.orig"
                log "💾 已创建原始备份: $base_name.orig"
            fi
            cp "$file" "$HISTORY_BACKUP_DIR/$base_name.$timestamp.bak"
        fi
    done

    find "$HISTORY_BACKUP_DIR" -name "*.bak" -type f 2>/dev/null | sort -r | tail -n +$((MAX_HISTORY_BACKUPS + 1)) | xargs rm -f 2>/dev/null || true

    if ! lsmod | grep -q tcp_bbr; then
        modprobe tcp_bbr &>/dev/null || true
        echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
    fi
    load_qdisc_module "fq"
    modprobe nf_conntrack &>/dev/null || true

    apply_limits_optimization
    cat > "$SYSCTL_CONF" << EOF
# ==========================================
# Mixed Mode (Hysteria2 + VLESS) Optimization
# Generated by bbr.sh at $(date)
# Original backup at: $ORIGINAL_BACKUP_DIR
# ==========================================

# --- 核心网络参数 (BBR 对 TCP 和 QUIC 回退都有用) ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- 文件描述符 ---
fs.file-max = 6815744

# --- UDP 缓冲区优化 (Hysteria2/QUIC) ---
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 26214400
net.core.wmem_default = 26214400
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# --- TCP 缓冲区优化 (VLESS) ---
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432

# --- TCP 行为优化 ---
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_moderate_rcvbuf = 1

# --- WebSocket 长连接优化 ---
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 10

# --- 连接优化 ---
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fastopen = 3

# --- UDP 连接追踪 (Hysteria2) ---
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 180

# --- 禁用反向路径过滤 ---
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0

# --- 网络队列优化 ---
net.core.netdev_max_backlog = 65536
net.core.somaxconn = 65535

# --- 转发开启 ---
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
EOF

    if sysctl --system &>/dev/null; then
        echo -e "${GREEN}✅ 混合模式优化已应用!${PLAIN}"
    else
        echo -e "${RED}⚠️  sysctl 应用失败${PLAIN}"
    fi
}

# --- 恢复原始配置 ---
restore_original_config() {
    echo -e "\n${YELLOW}警告: 即将将系统网络与限制配置恢复为原始备份状态。${PLAIN}"
    if [[ "$AUTO_YES" != true ]]; then
        read -p "确定要继续吗? [y/N]: " choice
        [[ ! "$choice" =~ ^[Yy]$ ]] && return
    fi

    local files=("$SYSCTL_CONF" "$LIMITS_CONF" "$SYSTEMD_CONF")
    local restored=0

    for file in "${files[@]}"; do
        local base_name=$(basename "$file")
        local orig_file="$ORIGINAL_BACKUP_DIR/$base_name.orig"
        
        if [[ -f "$orig_file" ]]; then
            log "正在恢复: $base_name"
            cp "$orig_file" "$file"
            ((restored++))
        else
            log "⚠️ 未找到 $base_name 的原始备份，跳过恢复。"
        fi
    done

    if [[ $restored -gt 0 ]]; then
        log "正在应用恢复后的配置..."
        sysctl --system &>/dev/null || true
        systemctl daemon-reexec || true
        echo -e "${GREEN}✅ 系统配置已部分/全部恢复原始状态!${PLAIN}"
        echo -e "${YELLOW}提示: 为了确保完全生效，建议重启系统或重新登录 SSH。${PLAIN}"
    else
        echo -e "${RED}❌ 恢复失败: 未检测到任何可用的原始备份文件。${PLAIN}"
    fi
}

# --- 验证 ---
verify_status() {
    local mode="$1"
    echo -e "\n${CYAN}--- 状态验证 ---${PLAIN}"
    local cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    local qd=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
    local ul=$(ulimit -n)
    local rmem=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "unknown")
    
    echo -e "拥塞控制: ${GREEN}$cc${PLAIN}"
    echo -e "队列调度: ${GREEN}$qd${PLAIN}"
    echo -e "文件句柄: ${GREEN}$ul${PLAIN}"
    echo -e "rmem_max: ${GREEN}$rmem${PLAIN}"
    
    case "$mode" in
        hysteria2)
            if [[ "$rmem" -ge 67108864 && "$ul" -ge 1048576 ]]; then
                echo -e "${GREEN}✨ Hysteria2 优化成功生效!${PLAIN}"
            else
                echo -e "${YELLOW}⚠️  配置似乎未完全生效，建议重启系统。${PLAIN}"
            fi
            ;;
        vless-ws)
            if [[ "$cc" == "bbr" && "$qd" == "fq" && "$ul" -ge 1048576 ]]; then
                echo -e "${GREEN}✨ VLESS-WS 优化成功生效!${PLAIN}"
            else
                echo -e "${YELLOW}⚠️  配置似乎未完全生效，建议重启系统。${PLAIN}"
            fi
            ;;
        ws-cdn)
            local ka=$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null)
            if [[ "$ka" == "60" && "$ul" -ge 1048576 ]]; then
                echo -e "${GREEN}✨ VLESS-WS (CDN) 优化成功生效!${PLAIN}"
            else
                echo -e "${YELLOW}⚠️  配置未完全生效 (Keepalive: $ka/60)，建议重启。${PLAIN}"
            fi
            ;;
        streaming)
            if [[ "$cc" == "bbr" && "$qd" == "fq_codel" && "$rmem" -ge 33554432 ]]; then
                echo -e "${GREEN}✨ 直播专用优化成功生效!${PLAIN}"
            else
                echo -e "${YELLOW}⚠️  配置未完全生效，建议重启系统。${PLAIN}"
            fi
            ;;
        vless-xtls)
            if [[ "$cc" == "bbr" && "$qd" == "fq" && "$ul" -ge 1048576 ]]; then
                echo -e "${GREEN}✨ VLESS-XTLS/Reality 优化成功生效!${PLAIN}"
                echo -e "${CYAN}提示: 已启用 UDP 透传支持，适用于游戏/VoIP 等应用${PLAIN}"
            else
                echo -e "${YELLOW}⚠️  配置似乎未完全生效，建议重启系统。${PLAIN}"
            fi
            ;;
        mixed)
            if [[ "$cc" == "bbr" && "$rmem" -ge 67108864 && "$ul" -ge 1048576 ]]; then
                echo -e "${GREEN}✨ 混合模式优化成功生效!${PLAIN}"
            else
                echo -e "${YELLOW}⚠️  配置似乎未完全生效，建议重启系统。${PLAIN}"
            fi
            ;;
        *)
            # 通用模式
            if [[ "$cc" == "bbr" && "$qd" == "$mode" && "$ul" -ge 1048576 ]]; then
                echo -e "${GREEN}✨ 优化成功生效!${PLAIN}"
            else
                echo -e "${YELLOW}⚠️  配置似乎未完全生效，建议重启系统或重新登录 SSH。${PLAIN}"
                echo -e "${YELLOW}提示: 如果选择了 cake/fq_pie 但验证显示为 fq/pfifo_fast，说明当前内核不支持该算法。${PLAIN}"
            fi
            ;;
    esac
}

# --- 菜单逻辑 ---
show_menu() {
    clear
    echo "==========================================="
    echo "      BBR 网络优化脚本 (v7.2)"
    echo "==========================================="
    check_bbr_version
    echo "==========================================="
    echo -e "${CYAN}[通用优化]${PLAIN}"
    echo "1. 执行网络优化 (QDisc: fq)"
    echo "2. 执行网络优化 (QDisc: fq_codel)"
    echo "3. 执行网络优化 (QDisc: fq_pie)"
    echo "4. 执行网络优化 (QDisc: cake)"
    echo "-------------------------------------------"
    echo -e "${CYAN}[协议专用优化]${PLAIN}"
    echo "5. Hysteria2 专用优化 (UDP/QUIC)"
    echo "6. VLESS-WS 专用优化 (TCP/WebSocket)"
    echo "7. VLESS-XTLS/Reality 专用优化 (TCP/TLS + UDP透传)"
    echo "8. VLESS-WS (CDN) 专用优化 (针对 Cloudflare)"
    echo "9. 直播专用优化 (低延迟/抗抖动)"
    echo "10. 混合模式 (全协议兼容)"
    echo "-------------------------------------------"
    echo "11. 恢复原始系统配置"
    echo "0. 退出"
    echo "-------------------------------------------"
    echo "u. 检查并更新脚本"
    echo "==========================================="
    read -p "请输入选项 [u, 0-9]: " choice
    
    case "$choice" in
        u|U) QDISC="update" ;;
        1) QDISC="fq" ;;
        2) QDISC="fq_codel" ;;
        3) QDISC="fq_pie" ;;
        4) QDISC="cake" ;;
        5) QDISC="hysteria2" ;;
        6) QDISC="vless-ws" ;;
        7) QDISC="vless-xtls" ;;
        8) QDISC="ws-cdn" ;;
        9) QDISC="streaming" ;;
        10) QDISC="mixed" ;;
        11) QDISC="RESTORE" ;;
        0) exit 0 ;;
        *) echo "无效选项"; exit 1 ;;
    esac
}

# --- 主流程 ---
main() {
    # 解析选项参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y)
                AUTO_YES=true
                shift
                ;;
        -h|--help)
            show_help
            exit 0
            ;;
        fq|fq_codel|fq_pie|cake)
            QDISC="$1"
            shift
                ;;
            hysteria2|hy2)
                QDISC="hysteria2"
                shift
                ;;
            vless-ws|vless_ws)
                QDISC="vless-ws"
                shift
                ;;
            ws-cdn|cdn)
                QDISC="ws-cdn"
                shift
                ;;
            streaming|stream|live)
                QDISC="streaming"
                shift
                ;;
            vless-xtls|vless_xtls|vless-reality|xtls|reality)
                QDISC="vless-xtls"
                shift
                ;;
            vless)
                # 向后兼容，默认指向 vless-ws
                QDISC="vless-ws"
                shift
                ;;
            mixed)
                QDISC="mixed"
                shift
                ;;
            restore)
                QDISC="RESTORE"
                shift
                ;;
            *)
                echo -e "${RED}未知参数: $1${PLAIN}"
                show_help
                exit 1
                ;;
        esac
    done

    check_root
    check_kernel
    check_dependencies
    update_system
    install_shortcut
    
    # 如果未通过参数指定 QDISC，显示菜单
    if [[ -z "${QDISC:-}" ]]; then
        show_menu
    fi
    
    case "$QDISC" in
        RESTORE)
            restore_original_config
            ;;
        update)
            check_update
            show_menu
            ;;
        hysteria2)
            apply_hysteria2_optimization
            verify_status "hysteria2"
            ;;
        vless-ws)
            apply_vless_ws_optimization
            verify_status "vless-ws"
            ;;
        ws-cdn)
            apply_vless_ws_cdn_optimization
            verify_status "ws-cdn"
            ;;
        streaming)
            apply_streaming_optimization
            verify_status "streaming"
            ;;
        vless-xtls)
            apply_vless_xtls_optimization
            verify_status "vless-xtls"
            ;;
        mixed)
            apply_mixed_optimization
            verify_status "mixed"
            ;;
        *)
            apply_optimization "$QDISC"
            verify_status "$QDISC"
            ;;
    esac
}

main "$@"
