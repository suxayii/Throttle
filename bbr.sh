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

    echo "▶ 正在应用 激进优化配置（稳定/低延迟模式）..."

    # 备份已有配置
    if [[ -f "$CONF_FILE" ]]; then
        BACKUP_FILE="$BACKUP_DIR/99-proxy-tune.conf.bak.$(date +%Y%m%d_%H%M%S)"
        cp "$CONF_FILE" "$BACKUP_FILE"
        ok "已备份当前配置到：$BACKUP_FILE"
    fi

    # 写入激进优化参数
    cat > "$CONF_FILE" << 'EOF'
############################################################
# 激进优化配置（稳定/低延迟模式）
# 文件：/etc/sysctl.d/99-proxy-tune.conf
############################################################

########################
# 系统资源相关
########################
fs.file-max = 6815744

########################
# 队列与拥塞控制
########################

# 使用 fq：BBR 最佳搭档，支持 pacing（定速），减少抖动
net.core.default_qdisc = fq

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

########################
# 缓冲区配置（平衡模式）
########################

# 系统级最大缓冲区 (32MB) - 避免过大导致 bufferbloat
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432

# TCP 自动调节范围 (最大 32MB)
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 16384 33554432

# 默认缓冲区
net.core.rmem_default = 262144
net.core.wmem_default = 262144

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
# 优化模式特点：
# - fq 队列：配合 BBR 实现精准 pacing，平滑发送
# - 32MB 缓冲区：平衡吞吐量与延迟，防止缓冲区膨胀
# - tcp_fastopen：减少握手时间
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
    ok "激进优化已应用（已调整为更稳定的低抖动配置）"
    echo "特点："
    echo "  - fq 队列：BBR 最佳搭档，减少发包抖动"
    echo "  - 缓冲区 32MB：防止 bufferbloat 导致的延迟不稳"
    echo "  - initcwnd=32：保持快速起速特性"
    echo "========================================================="
}

# ---------------------------------------------------------
# 流媒体/极速起飞优化（解决 BBR 爬坡慢）
# ---------------------------------------------------------
do_streaming() {
    echo "▶ 开始预检查..."
    if ! do_precheck; then
        err "由于预检查失败，已中止优化操作"
        return 1
    fi

    echo "▶ 正在应用 流媒体/极速起飞优化（针对爬坡慢特殊调优）..."

    # 备份已有配置
    if [[ -f "$CONF_FILE" ]]; then
        BACKUP_FILE="$BACKUP_DIR/99-proxy-tune.conf.bak.$(date +%Y%m%d_%H%M%S)"
        cp "$CONF_FILE" "$BACKUP_FILE"
        ok "已备份当前配置到：$BACKUP_FILE"
    fi

    # 写入流媒体优化参数
    cat > "$CONF_FILE" << 'EOF'
############################################################
# 流媒体/极速起飞优化（Streaming/Fast Ramp-up Mode）
# 文件：/etc/sysctl.d/99-proxy-tune.conf
############################################################

########################
# 核心加速参数 (解决慢热)
########################

# 关键设置：限制 TCP 发送队列堆积
# 作用：大幅减少 bufferbloat，让 BBR 更快感知带宽并加速
# 对于 1Gbps+ 环境，16384 (16KB) 是推荐的起始值
net.ipv4.tcp_notsent_lowat = 16384

# 开启 BBR (配合 fq)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

########################
# 激进的 TCP 行为
########################

# 优先低延迟 (如果内核支持)
net.ipv4.tcp_low_latency = 1

# 空闲后立即恢复发送速度 (拒绝慢启动)
net.ipv4.tcp_slow_start_after_idle = 0

# 开启 MTU 探测 (寻找最佳包大小)
net.ipv4.tcp_mtu_probing = 1

# 禁用 ECN (防止丢包重传延迟)
net.ipv4.tcp_ecn = 0

# 快速打开 (减少握手延迟)
net.ipv4.tcp_fastopen = 3

# 更短的 Keepalive (快速释放死连接)
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3

########################
# 大缓冲区 (吞吐量保障)
########################

# 与 aggressive 模式保持一致，防止溢出但足够大
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 16384 33554432

########################
# 高并发基础
########################
fs.file-max = 6815744
net.core.somaxconn = 16384
net.ipv4.tcp_max_syn_backlog = 16384
net.core.netdev_max_backlog = 32768
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

############################################################
# 优化模式特点：
# - tcp_notsent_lowat：解决 BBR 爬坡慢的核心参数
# - initcwnd=64：起步速度翻倍
# - MTU Probing：自动适配网络环境
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

    echo "▶ 尝试设置超大初始窗口 (initcwnd=64, initrwnd=32)..."
    DEFAULT_ROUTE=$(ip route show default 2>/dev/null | head -n 1)
    if [[ "$DEFAULT_ROUTE" == *"via"* ]]; then
        # 64个包的初始窗口，相当于 90KB+ 的起始数据量
        if eval "ip route change $DEFAULT_ROUTE initcwnd 64 initrwnd 32" 2>/dev/null; then
            ok "已设置 initcwnd=64 initrwnd=32（极速起飞模式）"
        else
            warn "initcwnd 设置失败（可忽略）"
        fi
    else
        warn "未检测到标准默认路由，跳过 initcwnd 设置"
    fi

    echo "========================================================="
    ok "流媒体/极速起飞优化已应用！"
    echo "针对 BBR 爬坡慢问题已重点优化："
    echo "  - tcp_notsent_lowat=16384：减少积压，加速反馈"
    echo "  - initcwnd=64：起跑速度提升 2-4 倍"
    echo "  - MTU Probing：自动优化传输效率"
    echo "建议重新进行测速观察爬坡效果。"
    echo "========================================================="
}

# ---------------------------------------------------------
# 平衡网络优化 (net-tune.sh)
# ---------------------------------------------------------
do_net_tune_balanced() {
    echo "▶ 正在生成平衡网络优化脚本 (/root/net-tune.sh)..."
    cat > /root/net-tune.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SYSCTL_FILE="/etc/sysctl.d/99-network-tuning.conf"
BACKUP_DIR="/root/sysctl-backups"
mkdir -p "$BACKUP_DIR"

apply_tuning() {
  local ts
  ts=$(date +%F_%H%M%S)

  # 备份当前内核参数快照
  sysctl -a 2>/dev/null > "${BACKUP_DIR}/sysctl-all-${ts}.bak" || true
  # 备份旧配置文件（如果存在）
  if [[ -f "$SYSCTL_FILE" ]]; then
    cp -a "$SYSCTL_FILE" "${BACKUP_DIR}/99-network-tuning.conf.${ts}.bak"
  fi

  cat > "$SYSCTL_FILE" <<'CONF'
# ===== Network tuning (balanced for 4C/4G, proxy/web workloads) =====
# 网卡输入队列上限（先用平衡值，避免250000过激）
net.core.netdev_max_backlog = 65536

# TCP Fast Open（客户端+服务端）
net.ipv4.tcp_fastopen = 3

# MTU黑洞探测（公网复杂路径建议开启）
net.ipv4.tcp_mtu_probing = 1

# Socket缓冲区上限（64MB）
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864

# TCP 自动调优范围（先32MB上限，稳妥）
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432

# BBR + fq（现代内核常用组合）
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
CONF

  sysctl --system >/dev/null
  echo "✅ 已应用优化配置：$SYSCTL_FILE"
  echo "✅ 备份目录：$BACKUP_DIR"
  echo
  echo "当前关键参数："
  sysctl net.core.netdev_max_backlog \
         net.ipv4.tcp_fastopen \
         net.ipv4.tcp_mtu_probing \
         net.core.rmem_max \
         net.core.wmem_max \
         net.ipv4.tcp_rmem \
         net.ipv4.tcp_wmem \
         net.core.default_qdisc \
         net.ipv4.tcp_congestion_control
}

rollback_tuning() {
  if [[ -f "$SYSCTL_FILE" ]]; then
    rm -f "$SYSCTL_FILE"
    sysctl --system >/dev/null
    echo "✅ 已回滚：删除 $SYSCTL_FILE 并重新加载 sysctl"
  else
    echo "ℹ️ 未发现 $SYSCTL_FILE，无需回滚"
  fi
}

status_tuning() {
  echo "=== 当前关键参数 ==="
  sysctl net.core.netdev_max_backlog \
         net.ipv4.tcp_fastopen \
         net.ipv4.tcp_mtu_probing \
         net.core.rmem_max \
         net.core.wmem_max \
         net.ipv4.tcp_rmem \
         net.ipv4.tcp_wmem \
         net.core.default_qdisc \
         net.ipv4.tcp_congestion_control || true
  echo
  echo "=== 配置文件 ==="
  if [[ -f "$SYSCTL_FILE" ]]; then
    cat "$SYSCTL_FILE"
  else
    echo "未找到 $SYSCTL_FILE"
  fi
}

case "${1:-apply}" in
  apply) apply_tuning ;;
  rollback) rollback_tuning ;;
  status) status_tuning ;;
  *)
    echo "用法: $0 [apply|rollback|status]"
    exit 1
    ;;
esac
EOF

    chmod +x /root/net-tune.sh
    ok "脚本生成成功：/root/net-tune.sh"
    echo "▶ 正在应用平衡优化..."
    /root/net-tune.sh apply
}

# ---------------------------------------------------------
# 激进网络优化 (net-tune-aggressive.sh)
# ---------------------------------------------------------
do_net_tune_standalone_aggressive() {
    echo "▶ 正在生成激进网络优化脚本 (/root/net-tune-aggressive.sh)..."
    cat > /root/net-tune-aggressive.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SYSCTL_FILE="/etc/sysctl.d/99-network-tuning-aggressive.conf"
BACKUP_DIR="/root/sysctl-backups"
mkdir -p "$BACKUP_DIR"

apply_tuning() {
  local ts
  ts=$(date +%F_%H%M%S)

  # 备份当前参数快照
  sysctl -a 2>/dev/null > "${BACKUP_DIR}/sysctl-all-${ts}.bak" || true
  # 备份旧配置
  if [[ -f "$SYSCTL_FILE" ]]; then
    cp -a "$SYSCTL_FILE" "${BACKUP_DIR}/99-network-tuning-aggressive.conf.${ts}.bak"
  fi

  cat > "$SYSCTL_FILE" <<'CONF'
# ===== Network tuning (AGGRESSIVE) =====
# 适用：高并发/高PPS/大流量网关、代理、下载、视频等场景
# 注意：更高内存占用与更高softirq压力

# 网卡输入队列（激进）
net.core.netdev_max_backlog = 250000

# 套接字缓冲区上限（128MB）
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728

# TCP 自动调优范围（上限 64MB）
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864

# 连接队列相关（避免高并发下listen队列溢出）
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 262144

# TIME_WAIT 与端口范围（提升并发连接复用能力）
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1

# SYN 防护（抗突发半连接）
net.ipv4.tcp_syncookies = 1

# TCP Fast Open / MTU probing
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1

# 队列调度与拥塞控制
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 可选：提高UDP最小缓冲（对部分UDP代理/隧道有帮助）
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
CONF

  sysctl --system >/dev/null
  echo "✅ 已应用激进优化：$SYSCTL_FILE"
  echo "✅ 备份目录：$BACKUP_DIR"
  echo
  echo "当前关键参数："
  sysctl net.core.netdev_max_backlog \
         net.core.rmem_max \
         net.core.wmem_max \
         net.ipv4.tcp_rmem \
         net.ipv4.tcp_wmem \
         net.core.somaxconn \
         net.ipv4.tcp_max_syn_backlog \
         net.ipv4.ip_local_port_range \
         net.ipv4.tcp_fin_timeout \
         net.ipv4.tcp_tw_reuse \
         net.ipv4.tcp_syncookies \
         net.ipv4.tcp_fastopen \
         net.ipv4.tcp_mtu_probing \
         net.core.default_qdisc \
         net.ipv4.tcp_congestion_control
}

rollback_tuning() {
  if [[ -f "$SYSCTL_FILE" ]]; then
    rm -f "$SYSCTL_FILE"
    sysctl --system >/dev/null
    echo "✅ 已回滚：删除 $SYSCTL_FILE 并重新加载 sysctl"
  else
    echo "ℹ️ 未发现 $SYSCTL_FILE，无需回滚"
  fi
}

status_tuning() {
  echo "=== 当前关键参数 ==="
  sysctl net.core.netdev_max_backlog \
         net.core.rmem_max \
         net.core.wmem_max \
         net.ipv4.tcp_rmem \
         net.ipv4.tcp_wmem \
         net.core.somaxconn \
         net.ipv4.tcp_max_syn_backlog \
         net.ipv4.ip_local_port_range \
         net.ipv4.tcp_fin_timeout \
         net.ipv4.tcp_tw_reuse \
         net.ipv4.tcp_syncookies \
         net.ipv4.tcp_fastopen \
         net.ipv4.tcp_mtu_probing \
         net.core.default_qdisc \
         net.ipv4.tcp_congestion_control || true
  echo
  echo "=== 配置文件 ==="
  if [[ -f "$SYSCTL_FILE" ]]; then
    cat "$SYSCTL_FILE"
  else
    echo "未找到 $SYSCTL_FILE"
  fi
}

watch_metrics() {
  echo "每2秒刷新一次，按 Ctrl+C 退出"
  while true; do
    clear
    echo "===== $(date '+%F %T') ====="
    echo "[softnet_stat 丢包列(第2列) 前5行]"
    awk '{print NR ": " $2}' /proc/net/softnet_stat | head -n 5
    echo
    echo "[TCP摘要]"
    ss -s || true
    echo
    echo "[内存摘要]"
    free -h || true
    sleep 2
  done
}

case "${1:-apply}" in
  apply) apply_tuning ;;
  rollback) rollback_tuning ;;
  status) status_tuning ;;
  watch) watch_metrics ;;
  *)
    echo "用法: $0 [apply|rollback|status|watch]"
    exit 1
    ;;
esac
EOF

    chmod +x /root/net-tune-aggressive.sh
    ok "脚本生成成功：/root/net-tune-aggressive.sh"
    echo "▶ 正在应用激进优化..."
    /root/net-tune-aggressive.sh apply
}

# ---------------------------------------------------------
# 激进且安全网络优化 (net-tune-aggressive-safe.sh)
# ---------------------------------------------------------
do_net_tune_standalone_aggressive_safe() {
    echo "▶ 正在生成激进且安全网络优化脚本 (/root/net-tune-aggressive-safe.sh)..."
    cat > /root/net-tune-aggressive-safe.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SYSCTL_FILE="/etc/sysctl.d/99-network-tuning-aggressive-safe.conf"
BACKUP_DIR="/root/sysctl-backups"
mkdir -p "$BACKUP_DIR"

apply_tuning() {
  local ts
  ts=$(date +%F_%H%M%S)

  # 备份当前参数快照
  sysctl -a 2>/dev/null > "${BACKUP_DIR}/sysctl-all-${ts}.bak" || true
  # 备份旧配置
  if [[ -f "$SYSCTL_FILE" ]]; then
    cp -a "$SYSCTL_FILE" "${BACKUP_DIR}/99-network-tuning-aggressive-safe.conf.${ts}.bak"
  fi

  cat > "$SYSCTL_FILE" <<'CONF'
# ===== Network tuning (AGGRESSIVE but SAFER) =====
# 适用：4C4G~8C16G 代理/网关/高并发 Web 场景
# 特点：比普通版更激进；比250000 backlog版本更稳

# 1) 网卡输入队列：从 250000 下调到更稳的 131072
net.core.netdev_max_backlog = 131072

# 2) 连接队列上限
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 131072

# 3) 缓冲上限（保留高上限）
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728

# 4) TCP 自动调优（给到 64MB 上限，兼顾内存）
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864

# 5) 端口与连接回收
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_tw_reuse = 1

# 6) 基础防护与链路优化
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1

# 7) 拥塞控制
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 8) UDP 最小缓冲（对 UDP 隧道/代理更友好）
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
CONF

  sysctl --system >/dev/null
  echo "✅ 已应用：$SYSCTL_FILE"
  echo "✅ 备份目录：$BACKUP_DIR"
  echo
  sysctl net.core.netdev_max_backlog \
         net.core.somaxconn \
         net.ipv4.tcp_max_syn_backlog \
         net.core.rmem_max \
         net.core.wmem_max \
         net.ipv4.tcp_rmem \
         net.ipv4.tcp_wmem \
         net.ipv4.ip_local_port_range \
         net.ipv4.tcp_fin_timeout \
         net.ipv4.tcp_tw_reuse \
         net.ipv4.tcp_fastopen \
         net.ipv4.tcp_mtu_probing \
         net.core.default_qdisc \
         net.ipv4.tcp_congestion_control
}

rollback_tuning() {
  if [[ -f "$SYSCTL_FILE" ]]; then
    rm -f "$SYSCTL_FILE"
    sysctl --system >/dev/null
    echo "✅ 已回滚：删除 $SYSCTL_FILE 并重新加载 sysctl"
  else
    echo "ℹ️ 未发现 $SYSCTL_FILE，无需回滚"
  fi
}

status_tuning() {
  echo "=== 当前关键参数 ==="
  sysctl net.core.netdev_max_backlog \
         net.core.somaxconn \
         net.ipv4.tcp_max_syn_backlog \
         net.core.rmem_max \
         net.core.wmem_max \
         net.ipv4.tcp_rmem \
         net.ipv4.tcp_wmem \
         net.ipv4.ip_local_port_range \
         net.ipv4.tcp_fin_timeout \
         net.ipv4.tcp_tw_reuse \
         net.ipv4.tcp_fastopen \
         net.ipv4.tcp_mtu_probing \
         net.core.default_qdisc \
         net.ipv4.tcp_congestion_control || true
  echo
  echo "=== 配置文件 ==="
  [[ -f "$SYSCTL_FILE" ]] && cat "$SYSCTL_FILE" || echo "未找到 $SYSCTL_FILE"
}

watch_metrics() {
  echo "每2秒刷新，Ctrl+C退出"
  while true; do
    clear
    echo "===== $(date '+%F %T') ====="
    echo "[softnet_stat 丢包列(第2列) 前5行]"
    awk '{print NR ": " $2}' /proc/net/softnet_stat | head -n 5
    echo
    echo "[溢出/重传相关]"
    netstat -s 2>/dev/null | grep -Ei 'listen|overflow|drop|retrans' | head -n 20 || true
    echo
    echo "[连接概览]"
    ss -s || true
    echo
    echo "[内存]"
    free -h || true
    sleep 2
  done
}

case "${1:-apply}" in
  apply) apply_tuning ;;
  rollback) rollback_tuning ;;
  status) status_tuning ;;
  watch) watch_metrics ;;
  *)
    echo "用法: $0 [apply|rollback|status|watch]"
    exit 1
    ;;
esac
EOF

    chmod +x /root/net-tune-aggressive-safe.sh
    ok "脚本生成成功：/root/net-tune-aggressive-safe.sh"
    echo "▶ 正在应用激进且安全优化..."
    /root/net-tune-aggressive-safe.sh apply
}

# ---------------------------------------------------------
# Xray/Hysteria2 专项优化 (net-tune-xray-hy2.sh)
# ---------------------------------------------------------
do_net_tune_xray_hy2() {
    echo "▶ 正在生成 Xray/Hy2 专项优化脚本 (/root/net-tune-xray-hy2.sh)..."
    cat > /root/net-tune-xray-hy2.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SYSCTL_FILE="/etc/sysctl.d/99-xray-hy2-tuning.conf"
BACKUP_DIR="/root/sysctl-backups"
mkdir -p "$BACKUP_DIR"

apply_tuning() {
  local ts
  ts=$(date +%F_%H%M%S)

  # 备份当前参数快照
  sysctl -a 2>/dev/null > "${BACKUP_DIR}/sysctl-all-${ts}.bak" || true
  # 备份旧专项配置
  if [[ -f "$SYSCTL_FILE" ]]; then
    cp -a "$SYSCTL_FILE" "${BACKUP_DIR}/99-xray-hy2-tuning.conf.${ts}.bak"
  fi

  cat > "$SYSCTL_FILE" <<'CONF'
# ===== Xray / Hysteria2 专项调优 =====
# 目标：TCP/UDP混合代理场景（Xray + Hy2）
# 建议系统：Linux 5.10+，更推荐 6.x

###############
# 核心队列与并发
###############
# 网卡收包队列（高并发但不过分激进）
net.core.netdev_max_backlog = 131072
# listen 队列上限
net.core.somaxconn = 32768
# SYN 半连接队列
net.ipv4.tcp_max_syn_backlog = 131072

#########################
# Socket 缓冲区（TCP/UDP）
#########################
# 全局上限：128MB
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
# 默认值适度提高（防止小默认拖性能）
net.core.rmem_default = 262144
net.core.wmem_default = 262144

# TCP autotuning（上限64MB）
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864

# UDP 最小缓冲（Hy2/QUIC 更友好）
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

#####################
# TCP 连接行为优化
#####################
# Fast Open：客户端+服务端
net.ipv4.tcp_fastopen = 3
# MTU 黑洞探测（公网推荐）
net.ipv4.tcp_mtu_probing = 1
# 减少 TIME_WAIT 占用压力
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_tw_reuse = 1
# 临时端口范围扩大（高并发出站更稳）
net.ipv4.ip_local_port_range = 10240 65535
# SYN cookies 防护
net.ipv4.tcp_syncookies = 1

########################
# 拥塞控制（Xray TCP关键）
########################
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

########################
# 可选稳定性项（通常安全）
########################
# 避免队首阻塞导致的异常重试
net.ipv4.tcp_slow_start_after_idle = 0
CONF

  sysctl --system >/dev/null

  echo "✅ 已应用 Xray/Hy2 专项优化：$SYSCTL_FILE"
  echo "✅ 备份目录：$BACKUP_DIR"
  echo
  echo "=== 当前关键参数 ==="
  sysctl \
    net.core.netdev_max_backlog \
    net.core.somaxconn \
    net.ipv4.tcp_max_syn_backlog \
    net.core.rmem_max \
    net.core.wmem_max \
    net.core.rmem_default \
    net.core.wmem_default \
    net.ipv4.tcp_rmem \
    net.ipv4.tcp_wmem \
    net.ipv4.udp_rmem_min \
    net.ipv4.udp_wmem_min \
    net.ipv4.tcp_fastopen \
    net.ipv4.tcp_mtu_probing \
    net.ipv4.tcp_fin_timeout \
    net.ipv4.tcp_tw_reuse \
    net.ipv4.ip_local_port_range \
    net.ipv4.tcp_syncookies \
    net.core.default_qdisc \
    net.ipv4.tcp_congestion_control \
    net.ipv4.tcp_slow_start_after_idle
}

status_tuning() {
  echo "=== 当前关键参数 ==="
  sysctl \
    net.core.netdev_max_backlog \
    net.core.somaxconn \
    net.ipv4.tcp_max_syn_backlog \
    net.core.rmem_max \
    net.core.wmem_max \
    net.core.rmem_default \
    net.core.wmem_default \
    net.ipv4.tcp_rmem \
    net.ipv4.tcp_wmem \
    net.ipv4.udp_rmem_min \
    net.ipv4.udp_wmem_min \
    net.ipv4.tcp_fastopen \
    net.ipv4.tcp_mtu_probing \
    net.ipv4.tcp_fin_timeout \
    net.ipv4.tcp_tw_reuse \
    net.ipv4.ip_local_port_range \
    net.ipv4.tcp_syncookies \
    net.core.default_qdisc \
    net.ipv4.tcp_congestion_control \
    net.ipv4.tcp_slow_start_after_idle || true
  echo
  echo "=== 配置文件 ==="
  [[ -f "$SYSCTL_FILE" ]] && cat "$SYSCTL_FILE" || echo "未找到 $SYSCTL_FILE"
}

watch_metrics() {
  echo "每2秒刷新，Ctrl+C 退出"
  while true; do
    clear
    echo "===== $(date '+%F %T') ====="
    echo "[CPU softirq]"
    grep -E '^(cpu|NET_RX|NET_TX)' /proc/softirqs || true
    echo
    echo "[softnet_stat 丢包列(第2列) 前8行]"
    awk '{print NR ": " $2}' /proc/net/softnet_stat | head -n 8
    echo
    echo "[UDP/TCP 摘要]"
    ss -s || true
    echo
    echo "[重传/溢出关键字]"
    netstat -s 2>/dev/null | grep -Ei 'retrans|listen|overflow|drop|fail|prune' | head -n 30 || true
    echo
    echo "[内存]"
    free -h || true
    sleep 2
  done
}

rollback_tuning() {
  if [[ -f "$SYSCTL_FILE" ]]; then
    rm -f "$SYSCTL_FILE"
    sysctl --system >/dev/null
    echo "✅ 已回滚：删除 $SYSCTL_FILE 并重新加载 sysctl"
  else
    echo "ℹ️ 未发现 $SYSCTL_FILE，无需回滚"
  fi
}

case "${1:-apply}" in
  apply) apply_tuning ;;
  status) status_tuning ;;
  watch) watch_metrics ;;
  rollback) rollback_tuning ;;
  *)
    echo "用法: $0 [apply|status|watch|rollback]"
    exit 1
    ;;
esac
EOF

    chmod +x /root/net-tune-xray-hy2.sh
    ok "脚本生成成功：/root/net-tune-xray-hy2.sh"
    echo "▶ 正在应用 Xray/Hy2 专项优化..."
    /root/net-tune-xray-hy2.sh apply
}

# ---------------------------------------------------------
# 分级配置优化 (net-profile-tune.sh)
# ---------------------------------------------------------
do_net_profile_tune() {
    echo "▶ 正在生成分级配置优化脚本 (/root/net-profile-tune.sh)..."
    cat > /root/net-profile-tune.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

PROFILE="${2:-}"
ACTION="${1:-}"
SYSCTL_FILE="/etc/sysctl.d/99-net-profile-tuning.conf"
BACKUP_DIR="/root/sysctl-backups"
mkdir -p "$BACKUP_DIR"

backup_now() {
  local ts
  ts=$(date +%F_%H%M%S)
  sysctl -a 2>/dev/null > "${BACKUP_DIR}/sysctl-all-${ts}.bak" || true
  [[ -f "$SYSCTL_FILE" ]] && cp -a "$SYSCTL_FILE" "${BACKUP_DIR}/99-net-profile-tuning.conf.${ts}.bak"
}

write_common_header() {
  cat > "$SYSCTL_FILE" <<'CONF'
# ===== Net Profile Tuning =====
# Generated by /root/net-profile-tune.sh
# Profiles:
# - low_1c1g  : conservative for 1C/1G
# - low_2c2g  : conservative for 2C/2G
# - bw_1g     : high-throughput for 1G NIC
# - bw_10g    : high-throughput for 10G NIC

# ---- Common safe options ----
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 20
net.ipv4.ip_local_port_range = 10240 65535
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
CONF
}

append_profile_low_1c1g() {
  cat >> "$SYSCTL_FILE" <<'CONF'

# ---- Profile: low_1c1g ----
net.core.netdev_max_backlog = 8192
net.core.somaxconn = 2048
net.ipv4.tcp_max_syn_backlog = 8192

net.core.rmem_default = 131072
net.core.wmem_default = 131072
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216

net.ipv4.tcp_rmem = 4096 87380 8388608
net.ipv4.tcp_wmem = 4096 65536 8388608
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

net.ipv4.tcp_slow_start_after_idle = 0
CONF
}

append_profile_low_2c2g() {
  cat >> "$SYSCTL_FILE" <<'CONF'

# ---- Profile: low_2c2g ----
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 16384

net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432

net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

net.ipv4.tcp_slow_start_after_idle = 0
CONF
}

append_profile_bw_1g() {
  cat >> "$SYSCTL_FILE" <<'CONF'

# ---- Profile: bw_1g ----
net.core.netdev_max_backlog = 32768
net.core.somaxconn = 16384
net.ipv4.tcp_max_syn_backlog = 65536

net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864

net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

net.ipv4.tcp_slow_start_after_idle = 0
CONF
}

append_profile_bw_10g() {
  cat >> "$SYSCTL_FILE" <<'CONF'

# ---- Profile: bw_10g ----
net.core.netdev_max_backlog = 131072
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 131072

net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728

net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

net.ipv4.tcp_slow_start_after_idle = 0
CONF
}

apply_profile() {
  local p="$1"
  backup_now
  write_common_header
  case "$p" in
    low_1c1g) append_profile_low_1c1g ;;
    low_2c2g) append_profile_low_2c2g ;;
    bw_1g)    append_profile_bw_1g ;;
    bw_10g)   append_profile_bw_10g ;;
    *)
      echo "❌ 未知 profile: $p"
      echo "可用: low_1c1g | low_2c2g | bw_1g | bw_10g"
      exit 1
      ;;
  esac

  sysctl --system >/dev/null
  echo "✅ 已应用 profile: $p"
  echo "✅ 配置文件: $SYSCTL_FILE"
  echo "✅ 备份目录: $BACKUP_DIR"
  echo
  status_now
}

status_now() {
  sysctl \
    net.core.netdev_max_backlog \
    net.core.somaxconn \
    net.ipv4.tcp_max_syn_backlog \
    net.core.rmem_default \
    net.core.wmem_default \
    net.core.rmem_max \
    net.core.wmem_max \
    net.ipv4.tcp_rmem \
    net.ipv4.tcp_wmem \
    net.ipv4.udp_rmem_min \
    net.ipv4.udp_wmem_min \
    net.ipv4.tcp_fastopen \
    net.ipv4.tcp_mtu_probing \
    net.ipv4.tcp_fin_timeout \
    net.ipv4.tcp_tw_reuse \
    net.ipv4.ip_local_port_range \
    net.core.default_qdisc \
    net.ipv4.tcp_congestion_control \
    net.ipv4.tcp_slow_start_after_idle || true
  echo
  echo "--- $SYSCTL_FILE ---"
  [[ -f "$SYSCTL_FILE" ]] && cat "$SYSCTL_FILE" || echo "未找到配置文件"
}

rollback_now() {
  if [[ -f "$SYSCTL_FILE" ]]; then
    rm -f "$SYSCTL_FILE"
    sysctl --system >/dev/null
    echo "✅ 已回滚（删除 $SYSCTL_FILE 并重载）"
  else
    echo "ℹ️ 未发现 $SYSCTL_FILE，无需回滚"
  fi
}

watch_now() {
  echo "每2秒刷新，Ctrl+C退出"
  while true; do
    clear
    echo "===== $(date '+%F %T') ====="
    echo "[softnet_stat 丢包列(第2列) 前8行]"
    awk '{print NR ": " $2}' /proc/net/softnet_stat | head -n 8
    echo
    echo "[ss -s]"
    ss -s || true
    echo
    echo "[netstat关键统计]"
    netstat -s 2>/dev/null | grep -Ei 'listen|overflow|drop|retrans' | head -n 30 || true
    echo
    echo "[内存]"
    free -h || true
    sleep 2
  done
}

usage() {
  cat <<USAGE
用法:
  $0 apply <profile>
  $0 status
  $0 rollback
  $0 watch

profile:
  low_1c1g   低内存保守版（1C/1G）
  low_2c2g   低内存保守版（2C/2G）
  bw_1g      高带宽版（1G口）
  bw_10g     高带宽版（10G口）
USAGE
}

case "$ACTION" in
  apply)    [[ -n "$PROFILE" ]] || { usage; exit 1; }; apply_profile "$PROFILE" ;;
  status)   status_now ;;
  rollback) rollback_now ;;
  watch)    watch_now ;;
  *)        usage; exit 1 ;;
esac
EOF

    chmod +x /root/net-profile-tune.sh
    ok "脚本生成成功：/root/net-profile-tune.sh"
    
    echo "========================================================="
    echo "           分级配置优化 (Hardware Profile)"
    echo "========================================================="
    echo " 1. 低内存保守版 (1C/1G)"
    echo " 2. 低内存保守版 (2C/2G)"
    echo " 3. 高带宽版 (1G NIC)"
    echo " 4. 高带宽版 (10G NIC)"
    echo " 0. 返回主菜单"
    echo "========================================================="
    read -p "请选择硬件配置 [0-4]: " prof_choice
    
    case "$prof_choice" in
        1) /root/net-profile-tune.sh apply low_1c1g ;;
        2) /root/net-profile-tune.sh apply low_2c2g ;;
        3) /root/net-profile-tune.sh apply bw_1g ;;
        4) /root/net-profile-tune.sh apply bw_10g ;;
        0) return ;;
        *) echo "无效选择" ;;
    esac
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
    echo " 3. 备份原始系统配置（永不覆盖）"
    echo " 4. 还原到原始系统配置"
    echo " 5. 还原最近一次配置备份"
    echo " 6. 还原首次配置备份"
    echo " 7. 查看当前状态"
    echo " 8. 网络测试"
    echo " 9. BBR 版本检测"
    echo "10. 升级内核（支持 BBR）"
    echo "11. 应用平衡优化 (net-tune.sh)"
    echo "12. 应用激进优化 (net-tune-aggressive.sh)"
    echo "13. 应用激进且安全优化 (net-tune-aggressive-safe.sh)"
    echo "14. 应用 Xray/Hy2 专项优化 (net-tune-xray-hy2.sh)"
    echo "15. 应用分级配置优化 (net-profile-tune.sh)"
    echo " 0. 退出"
    echo "========================================================="
    read -p "请输入选项 [0-15]: " choice

    case "$choice" in
        1) do_precheck ;;
        2) do_optimize ;;
        3) do_pristine_backup ;;
        4) do_restore_pristine ;;
        5) do_restore_latest ;;
        6) do_restore_original ;;
        7) do_status ;;
        8) do_network_test ;;
        9) do_bbr_detect ;;
        10) do_kernel_upgrade ;;
        11) do_net_tune_balanced ;;
        12) do_net_tune_standalone_aggressive ;;
        13) do_net_tune_standalone_aggressive_safe ;;
        14) do_net_tune_xray_hy2 ;;
        15) do_net_profile_tune ;;
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
        pristine|backup)      do_pristine_backup ;;
        restore-pristine)     do_restore_pristine ;;
        restore|latest)       do_restore_latest ;;
        original)             do_restore_original ;;
        status)               do_status ;;
        test|speedtest)       do_network_test ;;
        bbr|detect)           do_bbr_detect ;;
        kernel|upgrade)       do_kernel_upgrade ;;
        balanced|tune)        do_net_tune_balanced ;;
        aggressive-standalone) do_net_tune_standalone_aggressive ;;
        aggressive-safe)      do_net_tune_standalone_aggressive_safe ;;
        xray-hy2)             do_net_tune_xray_hy2 ;;
        profile)              do_net_profile_tune ;;
        *)                    show_menu ;;
    esac
else
    show_menu
fi
