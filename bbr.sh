#!/bin/bash
# =========================================================
# BBR + Xray + Hysteria2 网络优化脚本（生产安全版）
# - 不覆盖 /etc/sysctl.conf
# - 使用 /etc/sysctl.d/99-proxy-tune.conf
# - 支持自动备份 / 还原（最近备份 / 原始备份）
# - 支持状态检查（status）
# - 新增预检查阶段（precheck）
# =========================================================

CONF_FILE="/etc/sysctl.d/99-proxy-tune.conf"
BACKUP_DIR="/etc/sysctl.d/backup-proxy-tune"

# ---------------------------------------------------------
# Root 权限检查
# ---------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "❌ 错误：必须使用 root 权限运行此脚本"
    exit 1
fi

mkdir -p "$BACKUP_DIR"

# ---------------------------------------------------------
# 工具函数：输出格式
# ---------------------------------------------------------
ok()   { echo "✅ $*"; }
warn() { echo "⚠️ $*"; }
err()  { echo "❌ $*"; }

# ---------------------------------------------------------
# 预检查阶段
# 返回值：
#   0 = 通过
#   1 = 存在致命问题，不建议继续 optimize
# ---------------------------------------------------------
do_precheck() {
    echo "========================================================="
    echo "                 预检查（Precheck）"
    echo "========================================================="

    local fatal=0

    # 1) 必要命令检查
    local cmds=(sysctl ip grep awk sort head ls uname)
    for c in "${cmds[@]}"; do
        if command -v "$c" >/dev/null 2>&1; then
            ok "命令存在: $c"
        else
            err "缺少必要命令: $c"
            fatal=1
        fi
    done

    # 2) 目录可写性检查
    if [[ -d /etc/sysctl.d && -w /etc/sysctl.d ]]; then
        ok "/etc/sysctl.d 可写"
    else
        err "/etc/sysctl.d 不可写或不存在"
        fatal=1
    fi

    # 3) 内核与 BBR 支持检查
    local kernel
    kernel=$(uname -r 2>/dev/null)
    echo "内核版本: ${kernel:-N/A}"

    # 尝试加载模块
    modprobe tcp_bbr >/dev/null 2>&1 || true

    local avail_cc
    avail_cc=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
    if [[ -n "$avail_cc" ]]; then
        echo "可用拥塞控制: $avail_cc"
        if echo "$avail_cc" | grep -qw bbr; then
            ok "内核支持 BBR"
        else
            err "内核不支持 BBR（可用: $avail_cc）"
            fatal=1
        fi
    else
        err "无法读取 net.ipv4.tcp_available_congestion_control"
        fatal=1
    fi

    # 4) 当前 sysctl systemd 加载能力检查（只检查，不改值）
    if sysctl --system >/dev/null 2>&1; then
        ok "sysctl --system 可正常执行"
    else
        err "sysctl --system 执行失败（系统现有配置可能有语法/冲突问题）"
        fatal=1
    fi

    # 5) 默认路由检查（非致命）
    local default_route
    default_route=$(ip route show default 2>/dev/null | head -n 1 || true)
    if [[ -n "$default_route" ]]; then
        ok "检测到默认路由: $default_route"
        if [[ "$default_route" == *"via"* ]]; then
            ok "默认路由支持尝试设置 initcwnd/initrwnd"
        else
            warn "默认路由不含 via，后续将跳过 initcwnd 设置"
        fi
    else
        warn "未检测到默认路由，后续将跳过 initcwnd 设置"
    fi

    # 6) 备份目录检查
    if [[ -d "$BACKUP_DIR" && -w "$BACKUP_DIR" ]]; then
        ok "备份目录可用: $BACKUP_DIR"
    else
        err "备份目录不可用: $BACKUP_DIR"
        fatal=1
    fi

    echo "---------------------------------------------------------"
    if [[ $fatal -eq 0 ]]; then
        ok "预检查通过，可执行 optimize"
        echo "========================================================="
        return 0
    else
        err "预检查未通过，请先修复上述问题"
        echo "========================================================="
        return 1
    fi
}

# ---------------------------------------------------------
# 应用优化配置
# ---------------------------------------------------------
do_optimize() {
    echo "▶ 开始预检查..."
    if ! do_precheck; then
        err "由于预检查失败，已中止优化操作"
        return 1
    fi

    echo "▶ 正在应用 Xray + Hysteria2 网络优化配置..."

    # 备份已有配置（每次应用都生成一个时间戳备份）
    if [[ -f "$CONF_FILE" ]]; then
        BACKUP_FILE="$BACKUP_DIR/99-proxy-tune.conf.bak.$(date +%Y%m%d_%H%M%S)"
        cp "$CONF_FILE" "$BACKUP_FILE"
        ok "已备份当前配置到：$BACKUP_FILE"
    else
        warn "未检测到现有 $CONF_FILE，首次应用将直接写入新配置。"
    fi

    # 写入优化参数
    cat > "$CONF_FILE" << 'EOF'
############################################################
# Xray + Hysteria2 (HY2) 网络优化参数说明
# 文件：/etc/sysctl.d/99-proxy-tune.conf
############################################################

########################
# 系统资源相关
########################

# 系统允许的最大文件句柄数（高并发连接必备）
fs.file-max = 6815744


########################
# 队列与拥塞控制（BBR 必须）
########################

# 默认队列算法 fq（BBR 必须，降低排队延迟）
net.core.default_qdisc = fq

# TCP 拥塞控制算法使用 BBR（对 Xray TCP 代理收益明显）
net.ipv4.tcp_congestion_control = bbr


########################
# TCP 行为优化（主要服务 Xray）
########################

# 禁止保存旧连接的网络路径参数，避免跨网络环境性能异常
net.ipv4.tcp_no_metrics_save = 1

# 连接空闲后不重新进入慢启动（长连接/间歇代理更快）
net.ipv4.tcp_slow_start_after_idle = 0

# 关闭 ECN，避免部分链路兼容问题
net.ipv4.tcp_ecn = 0

# 关闭 MTU 探测，防止部分网络下频繁调整
net.ipv4.tcp_mtu_probing = 0

# 启用 TCP SACK（选择性确认，提高丢包恢复能力）
net.ipv4.tcp_sack = 1

# 启用 FACK（增强快速重传，部分内核中仍有效）
net.ipv4.tcp_fack = 1

# 启用 TCP 窗口缩放（高带宽高延迟链路必备）
net.ipv4.tcp_window_scaling = 1

# TCP 接收窗口自动调节策略
net.ipv4.tcp_adv_win_scale = 1

# 自动调整 TCP 接收缓冲区
net.ipv4.tcp_moderate_rcvbuf = 1


########################
# TCP 缓冲区大小（Xray 跨境/高 RTT 优化）
########################

# 系统级 TCP 接收/发送缓冲最大值（32MB）
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432

# TCP 自动缓冲区范围：最小 / 默认 / 最大
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 16384 33554432

# 系统默认 socket 缓冲区（未手动设置时使用）
net.core.rmem_default = 262144
net.core.wmem_default = 262144


########################
# 连接队列优化（高并发 Xray 必备）
########################

# TCP listen 队列长度（高并发连接防止拒绝）
net.core.somaxconn = 8192

# TCP 半连接队列（防 SYN 高峰）
net.ipv4.tcp_max_syn_backlog = 8192

# 网卡接收数据包队列（高 PPS 场景防丢包）
net.core.netdev_max_backlog = 16384


########################
# UDP / QUIC 优化（主要服务 Hysteria2）
########################

# UDP 最小接收缓冲区（防止过小导致丢包）
net.ipv4.udp_rmem_min = 8192

# UDP 最小发送缓冲区
net.ipv4.udp_wmem_min = 8192

############################################################
# 注意：
# - 本配置适用于代理服务端（Xray + HY2）
# - 不包含 IP 转发 / NAT / 透明代理参数
############################################################
EOF

    # 确保模块在重启后能自动加载
    if ! grep -q "tcp_bbr" /etc/modules-load.d/*.conf 2>/dev/null; then
        echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
        ok "已添加 tcp_bbr 到自动加载列表 (/etc/modules-load.d/bbr.conf)"
    fi

    echo "▶ 正在加载 sysctl 参数..."
    if sysctl --system >/dev/null; then
        ok "sysctl 参数加载成功"
    else
        err "sysctl 参数加载失败，请检查配置文件语法"
        return 1
    fi

    # TCP 初始窗口优化（尽力而为）
    echo "▶ 尝试优化 TCP 初始窗口 (initcwnd/initrwnd)..."
    DEFAULT_ROUTE=$(ip route show default 2>/dev/null | head -n 1)
    if [[ "$DEFAULT_ROUTE" == *"via"* ]]; then
        if ip route change $DEFAULT_ROUTE initcwnd 10 initrwnd 10 2>/dev/null; then
            ok "已设置默认路由 initcwnd=10 initrwnd=10（临时生效）"
        else
            warn "initcwnd 设置失败（云厂商限制或不支持，可忽略）"
        fi
    else
        warn "未检测到标准默认路由，跳过 initcwnd 设置"
    fi

    echo "========================================================="
    ok "Xray + Hysteria2 网络优化已完成"
    echo "========================================================="
}

# ---------------------------------------------------------
# 还原最近一次备份
# ---------------------------------------------------------
do_restore_latest() {
    echo "▶ 正在查找最近一次备份..."
    LATEST_BAK=$(ls "$BACKUP_DIR"/99-proxy-tune.conf.bak.* 2>/dev/null | sort -r | head -n 1)

    if [[ -z "$LATEST_BAK" ]]; then
        err "未找到任何备份文件"
        return 1
    fi

    echo "发现最近备份：$LATEST_BAK"
    read -p "是否确认还原该备份？[y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        cp "$LATEST_BAK" "$CONF_FILE"
        if sysctl --system >/dev/null; then
            ok "已成功还原最近备份"
        else
            err "还原后加载失败，请检查文件内容"
            return 1
        fi
    else
        echo "已取消还原操作"
    fi
}

# ---------------------------------------------------------
# 还原原始（最早）备份
# ---------------------------------------------------------
do_restore_original() {
    echo "▶ 正在查找原始（最早）备份..."
    ORIGINAL_BAK=$(ls "$BACKUP_DIR"/99-proxy-tune.conf.bak.* 2>/dev/null | sort | head -n 1)

    if [[ -z "$ORIGINAL_BAK" ]]; then
        err "未找到任何备份文件"
        return 1
    fi

    echo "发现原始备份：$ORIGINAL_BAK"
    read -p "是否确认还原“原始备份”？[y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        cp "$ORIGINAL_BAK" "$CONF_FILE"
        if sysctl --system >/dev/null; then
            ok "已成功还原原始备份"
        else
            err "还原后加载失败，请检查文件内容"
            return 1
        fi
    else
        echo "已取消还原操作"
    fi
}

# ---------------------------------------------------------
# 显示备份信息
# ---------------------------------------------------------
show_backup_info() {
    LATEST_BAK=$(ls "$BACKUP_DIR"/99-proxy-tune.conf.bak.* 2>/dev/null | sort -r | head -n 1)
    ORIGINAL_BAK=$(ls "$BACKUP_DIR"/99-proxy-tune.conf.bak.* 2>/dev/null | sort | head -n 1)

    echo "---------------- 备份信息 ----------------"
    [[ -n "$LATEST_BAK" ]] && echo "最近备份: $LATEST_BAK" || echo "最近备份: 无"
    [[ -n "$ORIGINAL_BAK" ]] && echo "原始备份: $ORIGINAL_BAK" || echo "原始备份: 无"
    echo "------------------------------------------"
}

# ---------------------------------------------------------
# 状态检查
# ---------------------------------------------------------
do_status() {
    echo "========================================================="
    echo "                当前网络优化状态检查"
    echo "========================================================="

    if [[ -f "$CONF_FILE" ]]; then
        echo "配置文件: $CONF_FILE  (存在)"
    else
        echo "配置文件: $CONF_FILE  (不存在)"
    fi

    echo
    echo "【内核与拥塞控制】"
    KERNEL_VER=$(uname -r)
    AVAIL_CC=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)
    CUR_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null)

    echo "内核版本: $KERNEL_VER"
    echo "可用拥塞控制: ${AVAIL_CC:-N/A}"
    echo "当前拥塞控制: ${CUR_CC:-N/A}"
    echo "默认队列算法: ${QDISC:-N/A}"

    [[ "$CUR_CC" == "bbr" ]] && ok "BBR状态: 已启用" || err "BBR状态: 未启用"
    [[ "$QDISC" == "fq" ]] && ok "fq状态 : 已启用" || err "fq状态 : 未启用"

    echo
    echo "【慢启动相关】"
    SLOW_IDLE=$(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null)
    echo "tcp_slow_start_after_idle = ${SLOW_IDLE:-N/A}"
    [[ "$SLOW_IDLE" == "0" ]] && ok "空闲后慢启动: 已优化" || warn "空闲后慢启动: 未优化"

    echo
    echo "【默认路由 initcwnd / initrwnd】"
    DEFAULT_ROUTE=$(ip route show default 2>/dev/null | head -n 1)
    if [[ -n "$DEFAULT_ROUTE" ]]; then
        echo "默认路由: $DEFAULT_ROUTE"
        echo "$DEFAULT_ROUTE" | grep -q "initcwnd" && ok "initcwnd: 已设置" || warn "initcwnd: 未显示（可能未设置或重启失效）"
        echo "$DEFAULT_ROUTE" | grep -q "initrwnd" && ok "initrwnd: 已设置" || warn "initrwnd: 未显示（可能未设置或重启失效）"
    else
        warn "默认路由: N/A"
    fi

    echo
    echo "【关键参数快照】"
    for key in \
        net.core.rmem_max \
        net.core.wmem_max \
        net.core.rmem_default \
        net.core.wmem_default \
        net.ipv4.tcp_rmem \
        net.ipv4.tcp_wmem \
        net.core.somaxconn \
        net.ipv4.tcp_max_syn_backlog \
        net.core.netdev_max_backlog \
        net.ipv4.udp_rmem_min \
        net.ipv4.udp_wmem_min \
        fs.file-max
    do
        val=$(sysctl -n "$key" 2>/dev/null)
        printf "%-35s = %s\n" "$key" "${val:-N/A}"
    done

    echo
    show_backup_info
    echo "========================================================="
}

# ---------------------------------------------------------
# 主菜单
# ---------------------------------------------------------
show_menu() {
    echo "========================================================="
    echo "  Xray + Hysteria2 网络优化脚本"
    echo "========================================================="
    show_backup_info
    echo " 1. 预检查（不修改）"
    echo " 2. 应用优化配置（先自动预检查）"
    echo " 3. 还原最近一次备份"
    echo " 4. 还原原始备份（最早备份）"
    echo " 5. 查看当前状态"
    echo " 6. 退出"
    echo "========================================================="
    read -p "请输入选项 [1-6]: " choice

    case "$choice" in
        1) do_precheck ;;
        2) do_optimize ;;
        3) do_restore_latest ;;
        4) do_restore_original ;;
        5) do_status ;;
        6) exit 0 ;;
        *) echo "无效选项"; exit 1 ;;
    esac
}

# ---------------------------------------------------------
# 参数模式
# ---------------------------------------------------------
if [[ $# -gt 0 ]]; then
    case "$1" in
        precheck|check)    do_precheck ;;
        optimize)          do_optimize ;;
        restore|latest)    do_restore_latest ;;
        original)          do_restore_original ;;
        status)            do_status ;;
        *)                 show_menu ;;
    esac
else
    show_menu
fi
