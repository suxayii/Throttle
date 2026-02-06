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
PRISTINE_BACKUP="$BACKUP_DIR/pristine-system-sysctl.conf"
LOCK_FILE="/tmp/bbr-tune.lock"

# ---------------------------------------------------------
# Root 权限检查
# ---------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "❌ 错误：必须使用 root 权限运行此脚本"
    exit 1
fi

# ---------------------------------------------------------
# 锁文件机制（防止重复运行）
# ---------------------------------------------------------
acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid
        pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            echo "❌ 错误：脚本已在运行中 (PID: $pid)"
            echo "如果确认没有其他实例运行，请删除锁文件: rm -f $LOCK_FILE"
            exit 1
        fi
    fi
    echo $$ > "$LOCK_FILE"
}

release_lock() {
    rm -f "$LOCK_FILE" 2>/dev/null
}

# 脚本退出时自动释放锁
trap release_lock EXIT

# 获取锁
acquire_lock

mkdir -p "$BACKUP_DIR"

# ---------------------------------------------------------
# 工具函数：输出格式
# ---------------------------------------------------------
ok()   { echo "✅ $*"; }
warn() { echo "⚠️ $*"; }
err()  { echo "❌ $*"; }

# ---------------------------------------------------------
# 检测系统类型
# ---------------------------------------------------------
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="$ID"
        OS_VERSION="$VERSION_ID"
    elif [[ -f /etc/redhat-release ]]; then
        OS_ID="centos"
        OS_VERSION=$(grep -oE '[0-9]+' /etc/redhat-release | head -1)
    else
        OS_ID="unknown"
        OS_VERSION="unknown"
    fi
}

# ---------------------------------------------------------
# 升级内核以支持 BBR
# ---------------------------------------------------------
do_kernel_upgrade() {
    echo "========================================================="
    echo "              升级内核以支持 BBR"
    echo "========================================================="

    detect_os
    echo "检测到系统: $OS_ID $OS_VERSION"
    echo

    case "$OS_ID" in
        debian|ubuntu)
            echo "【Debian/Ubuntu 内核升级】"
            echo "将安装最新的云优化内核 (linux-image-cloud-amd64)"
            echo
            warn "升级内核后需要重启系统！"
            read -p "是否继续升级内核？[y/N]: " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                echo "▶ 更新软件包列表..."
                apt update

                echo "▶ 安装云优化内核..."
                if apt install -y linux-image-cloud-amd64; then
                    ok "内核安装成功！"
                    echo
                    echo "▶ 配置 BBR 模块自动加载..."
                    echo "tcp_bbr" > /etc/modules-load.d/bbr.conf

                    echo
                    ok "内核升级完成！"
                    warn "请执行 'reboot' 重启系统以使用新内核"
                    echo "重启后再次运行此脚本应用 BBR 优化"
                else
                    err "内核安装失败，请检查网络或手动安装"
                    return 1
                fi
            else
                echo "已取消内核升级"
            fi
            ;;

        centos|rhel|rocky|almalinux|fedora)
            echo "【CentOS/RHEL 内核升级】"
            echo "将使用 ELRepo 安装最新主线内核 (kernel-ml)"
            echo
            warn "升级内核后需要重启系统！"
            read -p "是否继续升级内核？[y/N]: " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                local major_ver
                major_ver=$(echo "$OS_VERSION" | cut -d. -f1)

                if [[ "$major_ver" -ge 8 ]]; then
                    # CentOS 8+ / Rocky / AlmaLinux
                    echo "▶ 安装 ELRepo..."
                    dnf install -y https://www.elrepo.org/elrepo-release-8.el8.elrepo.noarch.rpm 2>/dev/null || \
                    dnf install -y https://www.elrepo.org/elrepo-release-9.el9.elrepo.noarch.rpm 2>/dev/null || true

                    echo "▶ 安装主线内核..."
                    if dnf --enablerepo=elrepo-kernel install -y kernel-ml; then
                        ok "内核安装成功！"
                    else
                        err "内核安装失败"
                        return 1
                    fi
                else
                    # CentOS 7
                    echo "▶ 导入 ELRepo GPG 密钥..."
                    rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org

                    echo "▶ 安装 ELRepo..."
                    rpm -Uvh https://www.elrepo.org/elrepo-release-7.el7.elrepo.noarch.rpm 2>/dev/null || true

                    echo "▶ 安装主线内核..."
                    if yum --enablerepo=elrepo-kernel install -y kernel-ml; then
                        ok "内核安装成功！"

                        echo "▶ 设置默认启动内核..."
                        grub2-set-default 0
                    else
                        err "内核安装失败"
                        return 1
                    fi
                fi

                echo
                echo "▶ 配置 BBR 模块自动加载..."
                echo "tcp_bbr" > /etc/modules-load.d/bbr.conf

                echo
                ok "内核升级完成！"
                warn "请执行 'reboot' 重启系统以使用新内核"
                echo "重启后再次运行此脚本应用 BBR 优化"
            else
                echo "已取消内核升级"
            fi
            ;;

        *)
            err "不支持的系统: $OS_ID"
            echo "请手动升级内核到 4.9+ 版本以支持 BBR"
            echo
            echo "常见发行版升级方法："
            echo "  Debian/Ubuntu: apt install linux-image-cloud-amd64"
            echo "  CentOS 7:      使用 ELRepo 安装 kernel-ml"
            echo "  CentOS 8+:     dnf install kernel-ml"
            return 1
            ;;
    esac

    echo "========================================================="
}

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
            echo
            echo "您的内核版本过低，不支持 BBR 拥塞控制算法。"
            read -p "是否升级内核以支持 BBR？[y/N]: " upgrade_confirm
            if [[ "$upgrade_confirm" =~ ^[Yy]$ ]]; then
                do_kernel_upgrade
                return 1  # 需要重启后再次运行
            else
                fatal=1
            fi
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

# 注意：tcp_fack 在 Linux 4.15+ 已移除，不再设置

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
        # 使用 eval 确保路由参数正确解析
        if eval "ip route change $DEFAULT_ROUTE initcwnd 10 initrwnd 10" 2>/dev/null; then
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
# 一键备份原始系统配置（永不覆盖）
# ---------------------------------------------------------
do_pristine_backup() {
    echo "========================================================="
    echo "         一键备份原始系统配置"
    echo "========================================================="

    if [[ -f "$PRISTINE_BACKUP" ]]; then
        echo "原始系统配置备份已存在：$PRISTINE_BACKUP"
        echo "创建时间：$(stat -c '%y' "$PRISTINE_BACKUP" 2>/dev/null || stat -f '%Sm' "$PRISTINE_BACKUP" 2>/dev/null)"
        warn "此备份永远不会被修改或覆盖！"
        echo
        read -p "是否查看备份内容？[y/N]: " view_confirm
        if [[ "$view_confirm" =~ ^[Yy]$ ]]; then
            echo "---------------- 备份内容 ----------------"
            cat "$PRISTINE_BACKUP"
            echo "------------------------------------------"
        fi
        return 0
    fi

    echo "▶ 正在收集当前系统 sysctl 配置..."

    # 创建原始系统配置快照
    cat > "$PRISTINE_BACKUP" << HEADER
############################################################
# 原始系统配置备份（Pristine System Backup）
# 创建时间：$(date '+%Y-%m-%d %H:%M:%S')
# 此文件永远不会被修改或覆盖
############################################################

HEADER

    # 备份所有当前 sysctl 值
    sysctl -a 2>/dev/null | grep -E '^(net\.|fs\.file-max)' >> "$PRISTINE_BACKUP"

    # 设置只读属性（防止意外修改）
    chmod 444 "$PRISTINE_BACKUP"

    ok "原始系统配置已备份到：$PRISTINE_BACKUP"
    ok "此备份已设为只读，永远不会被修改或覆盖！"
    echo "========================================================="
}

# ---------------------------------------------------------
# 还原到原始系统配置
# ---------------------------------------------------------
do_restore_pristine() {
    echo "========================================================="
    echo "         还原到原始系统配置"
    echo "========================================================="

    if [[ ! -f "$PRISTINE_BACKUP" ]]; then
        err "未找到原始系统配置备份！"
        echo "请先运行 '备份原始系统配置' 选项创建备份。"
        return 1
    fi

    echo "发现原始系统备份：$PRISTINE_BACKUP"
    echo "创建时间：$(stat -c '%y' "$PRISTINE_BACKUP" 2>/dev/null || stat -f '%Sm' "$PRISTINE_BACKUP" 2>/dev/null)"
    echo
    warn "此操作将删除当前优化配置，恢复到系统原始状态！"
    read -p "是否确认还原？[y/N]: " confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        # 删除优化配置文件
        if [[ -f "$CONF_FILE" ]]; then
            rm -f "$CONF_FILE"
            ok "已删除优化配置文件：$CONF_FILE"
        fi

        # 重新加载系统默认配置
        if sysctl --system >/dev/null 2>&1; then
            ok "系统配置已重新加载"
        else
            warn "sysctl --system 执行时有警告（可忽略）"
        fi

        ok "已还原到原始系统配置！"
        echo "========================================================="
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
    if [[ -f "$PRISTINE_BACKUP" ]]; then
        echo "🔒 原始系统备份: $PRISTINE_BACKUP (永不覆盖)"
    else
        echo "🔒 原始系统备份: 未创建"
    fi
    [[ -n "$LATEST_BAK" ]] && echo "📁 最近配置备份: $LATEST_BAK" || echo "📁 最近配置备份: 无"
    [[ -n "$ORIGINAL_BAK" ]] && echo "📁 首次配置备份: $ORIGINAL_BAK" || echo "📁 首次配置备份: 无"
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
# 激进优化模式（晚高峰/抗抖动/快速起速）
# ---------------------------------------------------------
do_aggressive() {
    echo "▶ 开始预检查..."
    if ! do_precheck; then
        err "由于预检查失败，已中止优化操作"
        return 1
    fi

    echo "▶ 正在应用 激进优化配置（晚高峰/抗抖动模式）..."

    # 备份已有配置
    if [[ -f "$CONF_FILE" ]]; then
        BACKUP_FILE="$BACKUP_DIR/99-proxy-tune.conf.bak.$(date +%Y%m%d_%H%M%S)"
        cp "$CONF_FILE" "$BACKUP_FILE"
        ok "已备份当前配置到：$BACKUP_FILE"
    fi

    # 写入激进优化参数
    cat > "$CONF_FILE" << 'EOF'
############################################################
# 激进优化配置（晚高峰/抗抖动/快速起速）
# 文件：/etc/sysctl.d/99-proxy-tune.conf
############################################################

########################
# 系统资源相关
########################
fs.file-max = 6815744

########################
# 队列与拥塞控制
########################

# 使用 fq_codel：更好的抗缓冲膨胀（bufferbloat）能力
# 相比 fq，能更智能地管理队列延迟
net.core.default_qdisc = fq_codel

# BBR 拥塞控制
net.ipv4.tcp_congestion_control = bbr

########################
# TCP 低延迟优化
########################

# 禁止保存旧连接参数
net.ipv4.tcp_no_metrics_save = 1

# 连接空闲后不重新慢启动（关键！加快恢复速度）
net.ipv4.tcp_slow_start_after_idle = 0

# 关闭 ECN（部分链路不兼容）
net.ipv4.tcp_ecn = 0

# 关闭 MTU 探测
net.ipv4.tcp_mtu_probing = 0

# 启用 TCP SACK
net.ipv4.tcp_sack = 1

# 启用窗口缩放
net.ipv4.tcp_window_scaling = 1

# 降低 TCP FIN 超时时间（加快连接释放）
net.ipv4.tcp_fin_timeout = 15

# 启用 TCP 快速打开（减少握手延迟）
net.ipv4.tcp_fastopen = 3

# 缩短 keepalive 检测间隔（更快发现死连接）
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3

# 启用 TCP 时间戳（RTT 测量更精确）
net.ipv4.tcp_timestamps = 1

# 降低重传超时的最小值（更快重传）
net.ipv4.tcp_retries1 = 3
net.ipv4.tcp_retries2 = 8

########################
# 缓冲区配置（中等偏激进）
########################

# 系统级最大缓冲区
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864

# TCP 自动调节范围
net.ipv4.tcp_rmem = 4096 131072 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864

# 默认缓冲区
net.core.rmem_default = 524288
net.core.wmem_default = 524288

########################
# 高并发优化
########################

net.core.somaxconn = 16384
net.ipv4.tcp_max_syn_backlog = 16384
net.core.netdev_max_backlog = 32768

# TIME_WAIT 优化
net.ipv4.tcp_max_tw_buckets = 65536
net.ipv4.tcp_tw_reuse = 1

# 本地端口范围扩大
net.ipv4.ip_local_port_range = 1024 65535

########################
# UDP / QUIC 优化
########################
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

############################################################
# 激进模式特点：
# - fq_codel 队列：智能抗抖动、降低延迟
# - tcp_fastopen：减少握手时间
# - 更大初始窗口：加速起速
# - 更短超时时间：快速回收资源
############################################################
EOF

    # 确保 BBR 模块自动加载
    if ! grep -q "tcp_bbr" /etc/modules-load.d/*.conf 2>/dev/null; then
        echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
        ok "已添加 tcp_bbr 到自动加载列表"
    fi

    echo "▶ 正在加载 sysctl 参数..."
    if sysctl --system >/dev/null; then
        ok "sysctl 参数加载成功"
    else
        err "sysctl 参数加载失败"
        return 1
    fi

    # 设置更大的初始窗口（initcwnd=32 加速起速）
    echo "▶ 尝试设置大初始窗口 (initcwnd=32, initrwnd=32)..."
    DEFAULT_ROUTE=$(ip route show default 2>/dev/null | head -n 1)
    if [[ "$DEFAULT_ROUTE" == *"via"* ]]; then
        if eval "ip route change $DEFAULT_ROUTE initcwnd 32 initrwnd 32" 2>/dev/null; then
            ok "已设置 initcwnd=32 initrwnd=32（大窗口快速起速）"
        else
            warn "initcwnd 设置失败（可忽略）"
        fi
    else
        warn "未检测到标准默认路由，跳过 initcwnd 设置"
    fi

    echo "========================================================="
    ok "激进优化已完成（晚高峰/抗抖动模式）"
    echo "特点："
    echo "  - fq_codel 队列：智能抗缓冲膨胀、降低延迟抖动"
    echo "  - initcwnd=32：更大初始窗口，测速秒起速"
    echo "  - tcp_fastopen：减少握手延迟"
    echo "  - 更短超时时间：快速回收连接资源"
    echo "========================================================="
}

# ---------------------------------------------------------
# BBRv3 支持检测
# ---------------------------------------------------------
do_bbr_detect() {
    echo "========================================================="
    echo "              BBR 版本检测"
    echo "========================================================="

    local kernel_ver avail_cc cur_cc
    kernel_ver=$(uname -r)
    echo "内核版本: $kernel_ver"
    echo

    # 尝试加载 BBR 模块
    modprobe tcp_bbr 2>/dev/null || true

    avail_cc=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)
    cur_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)

    echo "可用拥塞控制算法: ${avail_cc:-N/A}"
    echo "当前拥塞控制算法: ${cur_cc:-N/A}"
    echo

    # 检测 BBR 版本
    echo "【BBR 版本检测】"

    # 检查 BBRv3 特征（内核 6.x+ 且有 bbr 的 ecn_* 参数）
    local bbr_ver="v1"
    local kernel_major
    kernel_major=$(echo "$kernel_ver" | cut -d. -f1)

    if [[ "$kernel_major" -ge 6 ]]; then
        # BBRv3 在 6.x 内核中可用
        if sysctl net.ipv4.tcp_ecn_fallback 2>/dev/null | grep -q "tcp_ecn_fallback"; then
            bbr_ver="v3 (推测)"
        elif [[ -f /sys/module/tcp_bbr/parameters/ecn_enable ]] 2>/dev/null; then
            bbr_ver="v3"
        else
            bbr_ver="v2/v3 (内核 6.x)"
        fi
    elif [[ "$kernel_major" -ge 5 ]]; then
        local kernel_minor
        kernel_minor=$(echo "$kernel_ver" | cut -d. -f2)
        if [[ "$kernel_minor" -ge 13 ]]; then
            bbr_ver="v2 (内核 5.13+)"
        else
            bbr_ver="v1"
        fi
    fi

    if echo "$avail_cc" | grep -qw bbr; then
        ok "BBR 支持: ✅ 可用"
        echo "BBR 版本: $bbr_ver"

        if [[ "$cur_cc" == "bbr" ]]; then
            ok "BBR 状态: 已启用"
        else
            warn "BBR 状态: 未启用（当前使用 $cur_cc）"
        fi
    else
        err "BBR 支持: ❌ 不可用"
        echo "请升级内核到 4.9+ 或安装支持 BBR 的内核"
    fi

    echo
    echo "【内核版本与 BBR 版本对应】"
    echo "  • Linux 4.9+   : BBRv1"
    echo "  • Linux 5.13+  : BBRv2 (改进的带宽探测)"
    echo "  • Linux 6.x+   : BBRv3 (更好的 ECN 支持)"
    echo "========================================================="
}

# ---------------------------------------------------------
# 网络测试功能
# ---------------------------------------------------------
do_network_test() {
    echo "========================================================="
    echo "              网络连接测试"
    echo "========================================================="

    local test_targets=(
        "8.8.8.8:Google DNS"
        "1.1.1.1:Cloudflare DNS"
        "223.5.5.5:阿里 DNS"
    )

    echo "【延迟测试 (Ping)】"
    for target in "${test_targets[@]}"; do
        local ip name
        ip=$(echo "$target" | cut -d: -f1)
        name=$(echo "$target" | cut -d: -f2)

        if command -v ping >/dev/null 2>&1; then
            local result
            result=$(ping -c 3 -W 2 "$ip" 2>/dev/null | tail -1)
            if [[ -n "$result" && "$result" == *"avg"* ]]; then
                local avg
                avg=$(echo "$result" | awk -F'/' '{print $5}')
                printf "  %-15s (%s): %.2f ms\n" "$ip" "$name" "$avg"
            else
                printf "  %-15s (%s): 超时/不可达\n" "$ip" "$name"
            fi
        fi
    done

    echo
    echo "【下载速度测试】"

    # 测试地址列表
    local speed_tests=(
        "https://speed.cloudflare.com/__down?bytes=10000000:Cloudflare (10MB)"
        "http://cachefly.cachefly.net/10mb.test:CacheFly (10MB)"
    )

    for test_url in "${speed_tests[@]}"; do
        local url name
        url=$(echo "$test_url" | cut -d'|' -f1 | cut -d: -f1-2)
        name=$(echo "$test_url" | cut -d: -f3)

        if command -v curl >/dev/null 2>&1; then
            echo "  测试 $name ..."
            local speed
            speed=$(curl -o /dev/null -w '%{speed_download}' -m 10 -s "$url" 2>/dev/null)
            if [[ -n "$speed" && "$speed" != "0" ]]; then
                # 转换为 MB/s
                local mbps
                mbps=$(echo "scale=2; $speed / 1048576" | bc 2>/dev/null || echo "N/A")
                echo "    → 速度: ${mbps} MB/s"
            else
                echo "    → 测试失败或超时"
            fi
        else
            warn "curl 未安装，跳过速度测试"
            break
        fi
    done

    echo
    echo "【当前 TCP 连接统计】"
    if command -v ss >/dev/null 2>&1; then
        local established listen time_wait
        established=$(ss -t state established 2>/dev/null | wc -l)
        listen=$(ss -t state listening 2>/dev/null | wc -l)
        time_wait=$(ss -t state time-wait 2>/dev/null | wc -l)
        echo "  ESTABLISHED: $((established - 1))"
        echo "  LISTENING:   $((listen - 1))"
        echo "  TIME_WAIT:   $((time_wait - 1))"
    else
        warn "ss 命令不可用"
    fi

    echo
    echo "【当前拥塞控制状态】"
    local cur_cc qdisc
    cur_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    echo "  拥塞控制: ${cur_cc:-N/A}"
    echo "  队列算法: ${qdisc:-N/A}"

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
    echo " 2. 应用标准优化配置"
    echo " 3. 应用激进优化（晚高峰/抗抖动/快速起速）"
    echo " 4. 🔒 备份原始系统配置（永不覆盖）"
    echo " 5. 还原到原始系统配置"
    echo " 6. 还原最近一次配置备份"
    echo " 7. 还原首次配置备份"
    echo " 8. 查看当前状态"
    echo " 9. 🌐 网络测试"
    echo "10. 🔍 BBR 版本检测"
    echo "11. ⬆️  升级内核（支持 BBR）"
    echo " 0. 退出"
    echo "========================================================="
    read -p "请输入选项 [0-11]: " choice

    case "$choice" in
        1) do_precheck ;;
        2) do_optimize ;;
        3) do_aggressive ;;
        4) do_pristine_backup ;;
        5) do_restore_pristine ;;
        6) do_restore_latest ;;
        7) do_restore_original ;;
        8) do_status ;;
        9) do_network_test ;;
        10) do_bbr_detect ;;
        11) do_kernel_upgrade ;;
        0) exit 0 ;;
        *) echo "无效选项"; exit 1 ;;
    esac
}

# ---------------------------------------------------------
# 参数模式
# ---------------------------------------------------------
if [[ $# -gt 0 ]]; then
    case "$1" in
        precheck|check)       do_precheck ;;
        optimize)             do_optimize ;;
        aggressive|fast)      do_aggressive ;;
        pristine|backup)      do_pristine_backup ;;
        restore-pristine)     do_restore_pristine ;;
        restore|latest)       do_restore_latest ;;
        original)             do_restore_original ;;
        status)               do_status ;;
        test|speedtest)       do_network_test ;;
        bbr|detect)           do_bbr_detect ;;
        kernel|upgrade)       do_kernel_upgrade ;;
        *)                    show_menu ;;
    esac
else
    show_menu
fi
