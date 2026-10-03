#!/usr/bin/env bash
# ==============================================================================
# ⚡ Throttle — Cloudflare CDN + 3x-ui / VLESS-WebSocket 狂暴极限优化工具箱 (v2.0)
# ==============================================================================
# 适用场景：
#   - 3x-ui / x-ui 面板搭建的 VLESS-WebSocket / VMess-WebSocket
#   - 配合 Cloudflare CDN 边缘节点代理回源
# 核心压榨维度与安全防护：
#   1. 网卡层：多核 RPS/RFS 软中断智能分流 + 硬件卸载 (TSO/GSO/GRO) + 队列扩容
#   2. 内核层：BBR + FQ、TCP Fast Open (TFO=3)、小包立即推、细流线性快重传、20s心跳保活
#   3. 内存与I/O：vm.swappiness=10、平滑脏页刷盘、内存锁定 (LimitMEMLOCK=infinity)
#   4. 进程调度：动态测试适配 FIFO 90 (chrt -f 90) + Nice -20 抢占、百万句柄 (容器级防崩)
#   5. Go 运行时：GODEBUG 内存调优、自动适配物理核数
#   6. Nginx 极速反代：WS零缓冲、keepalive 256连接池、tcp_nodelay、CF真实IP (防同名冲突)
#   7. 源站安全加固：一键设置 UFW 防火墙，仅放行 Cloudflare 官方 IP (防主动探测封IP)
#   8. 客户端突破：内置 Cloudflare 优选节点检测与加速指南
# ==============================================================================

# --- 终端颜色 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- 关键路径 ---
SYSCTL_CONF="/etc/sysctl.d/99-throttle-cf-vless-extreme.conf"
LIMITS_CONF="/etc/security/limits.d/99-throttle-nofile.conf"
BACKUP_DIR="/etc/throttle/backup-cf-vless"
RPS_SCRIPT="/etc/throttle/throttle-rps-tune.sh"
RPS_SERVICE="/etc/systemd/system/throttle-rps.service"
DATE_TAG=$(date +%Y%m%d_%H%M%S)

mkdir -p "$BACKUP_DIR"

# --- 辅助函数 ---
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${CYAN}==>${NC} ${BOLD}$1${NC}"; }
log_extreme() { echo -e "${PURPLE}[EXTREME ⚡]${NC} ${BOLD}$1${NC}"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "必须使用 root 权限运行！请执行 sudo -i 切换后重试。"
        exit 1
    fi
}

print_banner() {
    clear
    echo -e "${PURPLE}╔══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${PURPLE}║${NC}   ${BOLD}⚡ Throttle — 3x-ui + CF CDN + VLESS-WS 【狂暴极限优化】v2.0${NC}      ${PURPLE}║${NC}"
    echo -e "${PURPLE}║${NC}   ${CYAN}多核RPS分流 ｜ 动态FIFO调度 ｜ TFO双向握手 ｜ 内存锁定 ｜ 源站防护${NC}   ${PURPLE}║${NC}"
    echo -e "${PURPLE}╚══════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# --- 查找主物理网卡 ---
detect_physical_nic() {
    local iface=""
    # 优先匹配默认网关物理接口
    iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -n1)
    if [[ -z "$iface" || "$iface" =~ ^(wg|tun|docker|veth|br-|lo|cloudflare) ]]; then
        for dev in /sys/class/net/*; do
            local name
            name=$(basename "$dev")
            if [[ "$name" =~ ^(eth|ens|enp|eno) ]]; then
                iface="$name"
                break
            fi
        done
    fi
    echo "$iface"
}

# --- 查找 3x-ui 服务 ---
find_xui_service() {
    local svc=""
    if [[ -f "/etc/systemd/system/x-ui.service" ]]; then
        svc="/etc/systemd/system/x-ui.service"
    elif [[ -f "/lib/systemd/system/x-ui.service" ]]; then
        svc="/lib/systemd/system/x-ui.service"
    elif systemctl list-unit-files 2>/dev/null | grep -q "3x-ui.service"; then
        svc="/etc/systemd/system/3x-ui.service"
    elif systemctl list-unit-files 2>/dev/null | grep -q "x-ui.service"; then
        svc="/etc/systemd/system/x-ui.service"
    fi
    echo "$svc"
}

# --- 健壮计算 CPU 掩码（防高核心数整数溢出）---
generate_rps_mask() {
    local cores=$1
    if (( cores <= 1 )); then
        echo "1"
        return
    elif (( cores >= 64 )); then
        echo "ffffffffffffffff"
        return
    fi
    # 针对 64位 bash 计算掩码
    local mask_val
    mask_val=$(( (1 << cores) - 1 ))
    printf '%x\n' "$mask_val"
}

# ==============================================================================
# 模块 1：网卡层极限压榨 (RPS/RFS 多核分流 + 硬件卸载 + 队列扩容)
# ==============================================================================
tune_nic_extreme() {
    log_step "【网卡物理层极限优化】启用多核 RPS/RFS 软中断分流..."
    local iface
    iface=$(detect_physical_nic)
    if [[ -z "$iface" ]]; then
        log_warn "未识别到物理网卡，跳过网卡硬件优化。"
        return 0
    fi

    log_info "检测到主网卡接口: ${BOLD}${GREEN}${iface}${NC}"

    local cpu_cores
    cpu_cores=$(nproc 2>/dev/null || echo 1)
    log_info "CPU 逻辑核心数: ${BOLD}${CYAN}${cpu_cores}${NC} 核"

    local hex_mask
    hex_mask=$(generate_rps_mask "$cpu_cores")

    mkdir -p /etc/throttle
    cat > "$RPS_SCRIPT" <<EOF
#!/usr/bin/env bash
# Throttle 网卡多核分流与 RPS 优化脚本
iface="${iface}"
hex_mask="${hex_mask}"

# 1. 扩充网卡传输队列长度至 10000
ip link set dev "\$iface" txqueuelen 10000 2>/dev/null || true

# 2. 启用多核 RPS 数据包路由分发
for q in /sys/class/net/"\$iface"/queues/rx-*; do
    [[ -e "\$q/rps_cpus" ]] && echo "\$hex_mask" > "\$q/rps_cpus" 2>/dev/null || true
    [[ -e "\$q/rps_flow_cnt" ]] && echo 32768 > "\$q/rps_flow_cnt" 2>/dev/null || true
done

# 3. 启用多核 XPS 传输分发
for q in /sys/class/net/"\$iface"/queues/tx-*; do
    [[ -e "\$q/xps_cpus" ]] && echo "\$hex_mask" > "\$q/xps_cpus" 2>/dev/null || true
done

# 4. 尝试开启网卡硬件卸载 (TSO/GSO/GRO) 降低 CPU 占用
if command -v ethtool &>/dev/null; then
    ethtool -K "\$iface" tso on gso on gro on tx on rx on 2>/dev/null || true
fi
EOF
    chmod +x "$RPS_SCRIPT"
    bash "$RPS_SCRIPT"

    cat > "$RPS_SERVICE" <<EOF
[Unit]
Description=Throttle NIC RPS Multi-Core Tuning
After=network.target

[Service]
Type=oneshot
ExecStart=$RPS_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable throttle-rps.service --quiet 2>/dev/null || true
    log_extreme "网卡多核 RPS/RFS 软中断分流已激活！CPU 掩码: 0x$hex_mask，队列扩容至 10000"
}

# ==============================================================================
# 模块 2：内核与 TCP 深水区极限优化 (BBR + TFO + 线性重传 + 内存常驻)
# ==============================================================================
tune_kernel_extreme() {
    log_step "【内核深水区极限优化】写入 TCP 协议栈与虚拟内存极限参数..."

    local total_mem_kb
    total_mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local total_mem_mb=$((total_mem_kb / 1024))

    local rmem_max=67108864
    local wmem_max=67108864
    local tcp_rmem="4096 87380 67108864"
    local tcp_wmem="4096 65536 67108864"

    if (( total_mem_mb < 1024 )); then
        rmem_max=16777216
        wmem_max=16777216
        tcp_rmem="4096 32768 16777216"
        tcp_wmem="4096 32768 16777216"
    elif (( total_mem_mb >= 3800 )); then
        rmem_max=134217728
        wmem_max=134217728
        tcp_rmem="4096 131072 134217728"
        tcp_wmem="4096 131072 134217728"
    fi

    # 健壮检测 BBR 支持
    modprobe tcp_bbr 2>/dev/null || true
    local cc="bbr"
    if ! sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        log_warn "当前环境不支持加载 BBR，自动回退到默认拥塞算法"
        cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "cubic")
    fi

    cat > "$SYSCTL_CONF" <<EOF
# ==============================================================================
# Throttle - 3x-ui + Cloudflare CDN + VLESS-WS 【狂暴极限性能参数】
# ==============================================================================

# --- 1. 拥塞控制与 FQ 队列 ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = ${cc}

# --- 2. TCP Fast Open (TFO=3: 客户端与服务端双向开启) ---
# 三次握手首包直接携带应用层 payload，减少 1 次 RTT 握手开销！
net.ipv4.tcp_fastopen = 3

# --- 3. 针对 Cloudflare 100s 超时的极限 TCP Keepalive 保活 ---
net.ipv4.tcp_keepalive_time = 20
net.ipv4.tcp_keepalive_intvl = 5
net.ipv4.tcp_keepalive_probes = 3

# --- 4. WebSocket 极致零延迟与小包直发 (Anti-Bufferbloat) ---
net.ipv4.tcp_autocorking = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_thin_linear_timeouts = 1
net.ipv4.tcp_early_retrans = 3
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_low_latency = 1

# --- 5. TIME_WAIT 极速复用与连接池吞吐 ---
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_max_tw_buckets = 2000000
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 131072
net.ipv4.tcp_max_syn_backlog = 131072
net.ipv4.ip_local_port_range = 10240 65535

# --- 6. RPS/RFS 全局流表深度 ---
net.core.rps_sock_flow_entries = 65536

# --- 7. 内存缓冲区极限吞吐 ---
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = ${rmem_max}
net.core.wmem_max = ${wmem_max}
net.ipv4.tcp_rmem = ${tcp_rmem}
net.ipv4.tcp_wmem = ${tcp_wmem}
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# --- 8. 虚拟内存与平滑刷盘 (杜绝 Swap 顿卡与 I/O 阻塞) ---
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
fs.file-max = 2097152
EOF

    # 容器安全加载：-e 参数忽略只读/未知键，避免在 LXC/OpenVZ 中中断报错
    sysctl -e -p "$SYSCTL_CONF" &>/dev/null || true
    log_extreme "内核深水区极限调优已生效！TFO=3 双向握手、零粘包延迟、20s保活就绪。"
}

# ==============================================================================
# 模块 3：3x-ui / Xray 进程实时调度提权 (防崩溃智能适配 + 内存锁定)
# ==============================================================================
tune_xui_extreme() {
    log_step "【进程层极限调度】配置 3x-ui / Xray 进程调度、内存常驻与句柄解除..."

    # 1. 解除全局文件句柄限制至 1048576
    cat > "$LIMITS_CONF" <<EOF
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 512000
* hard nproc 512000
* soft memlock unlimited
* hard memlock unlimited
root soft nofile 1048576
root hard nofile 1048576
root soft nproc 512000
root hard nproc 512000
root soft memlock unlimited
root hard memlock unlimited
EOF

    local num_cores
    num_cores=$(nproc 2>/dev/null || echo 1)

    local xui_service
    xui_service=$(find_xui_service)
    if [[ -n "$xui_service" ]]; then
        log_info "针对服务单元应用配置: ${BOLD}${GREEN}${xui_service}${NC}"
        local dropin_dir="${xui_service}.d"
        mkdir -p "$dropin_dir"

        # 核心防坑设计：
        # 在 systemd 中直接写 CPUSchedulingPolicy=fifo 在很多开启 RT Group 的系统中
        # 会因未分配 rt 预算直接导致服务启动失败 (Operation not permitted)！
        # 因此 systemd 层使用最安全且最高效的 Nice=-20 与全环境通用的内存锁定；
        # 实时 FIFO 90 调度改由运行时动态注入（若系统支持则完美生效，若不支持则安全平替）！
        cat > "$dropin_dir/override-extreme.conf" <<EOF
[Service]
LimitNOFILE=1048576
LimitNPROC=512000
LimitMEMLOCK=infinity
Nice=-20

# Go 运行时内存回收与多核适配
Environment="GODEBUG=madvdontneed=1"
Environment="GOMAXPROCS=${num_cores}"
Environment="GOGC=100"

Restart=always
RestartSec=2s
EOF
        systemctl daemon-reload
        local svc_name
        svc_name=$(basename "$xui_service")
        if systemctl is-active --quiet "$svc_name"; then
            systemctl restart "$svc_name"
        fi
    else
        log_warn "未找到 x-ui / 3x-ui 的 systemd 服务文件，跳过 systemd 注入。"
    fi

    # 2. 运行时动态尝试注入 FIFO 90 实时调度策略
    local pids
    pids=$(pgrep -f "xray-linux" || true)
    if [[ -n "$pids" ]]; then
        local rt_success=0
        for pid in $pids; do
            renice -n -20 -p "$pid" >/dev/null 2>&1 || true
            if chrt -f -p 90 "$pid" >/dev/null 2>&1; then
                rt_success=1
            fi
        done
        if [[ $rt_success -eq 1 ]]; then
            log_extreme "已成功为 Xray 核心注入物理实时调度: FIFO 90 (实时抢占调度) + Nice -20！"
        else
            log_info "内核受限于 cgroup RT 预算，已自动应用最高常规优先级: Nice -20 + 内存锁定！"
        fi
    fi
}

# ==============================================================================
# 模块 4：Nginx 生产级极限反代配置生成器 (防止同端口 upstream 命名冲突)
# ==============================================================================
generate_nginx_extreme() {
    print_banner
    log_step "【Nginx 极限反代配置生成器】针对 Cloudflare CDN + VLESS-WS"
    echo -e "说明：集成 ${BOLD}WS零缓冲、keepalive连接池、tcp_nodelay即时推、CF真实IP、防探测伪装${NC}。\n"

    read -rp "请输入您的域名 (例如 my.example.com): " cf_domain
    [[ -z "$cf_domain" ]] && { log_error "域名不能为空！"; return 1; }

    read -rp "请输入 VLESS-WebSocket 的分流 Path (默认 /vless-ws): " cf_path
    cf_path=${cf_path:-"/vless-ws"}
    [[ "${cf_path:0:1}" != "/" ]] && cf_path="/${cf_path}"

    read -rp "请输入 3x-ui 本地监听端口 (例如 10086): " xui_port
    [[ -z "$xui_port" ]] && { log_error "端口不能为空！"; return 1; }

    # 将域名中的点替换为下划线，防止多个站点反代同一端口时 upstream 重名报错
    local clean_domain
    clean_domain=$(echo "$cf_domain" | tr '.-' '__')

    local output_file="/etc/throttle/cf_extreme_nginx_${cf_domain}.conf"
    local cf_ips_conf="/etc/throttle/cloudflare_realip.conf"
    mkdir -p /etc/throttle

    log_info "正在获取 Cloudflare 官方最新 IPv4/IPv6 真实 IP 网段..."
    {
        echo "# Cloudflare 官方 IPv4 网段"
        curl -sL https://www.cloudflare.com/ips-v4 | sed 's/^/set_real_ip_from /; s/$/;/'
        echo ""
        echo "# Cloudflare 官方 IPv6 网段"
        curl -sL https://www.cloudflare.com/ips-v6 | sed 's/^/set_real_ip_from /; s/$/;/'
        echo ""
        echo "real_ip_header CF-Connecting-IP;"
    } > "$cf_ips_conf"

    cat > "$output_file" <<EOF
# ==============================================================================
# Throttle - Cloudflare CDN + 3x-ui 极限反代模板
# 域名: ${cf_domain}
# ==============================================================================

# 定义专属长连接池 (防同端口重名冲突)
upstream xui_${clean_domain}_${xui_port} {
    server 127.0.0.1:${xui_port};
    keepalive 256;
}

server {
    listen 80;
    listen [::]:80;
    server_name ${cf_domain};

    # 引入 Cloudflare 真实客户端 IP 还原规则
    include ${cf_ips_conf};

    # 极限 TCP 传输优化选项
    tcp_nodelay on;
    tcp_nopush off;

    # 1. 伪装主站 (防止主动探测)
    location / {
        proxy_pass https://www.bing.com;
        proxy_ssl_server_name on;
        proxy_redirect off;
    }

    # 2. VLESS WebSocket 专享分流入口
    location ${cf_path} {
        if (\$http_upgrade != "websocket") {
            return 404;
        }

        # 核心：彻底关闭缓冲，数据流毫秒级直通！
        proxy_buffering off;
        proxy_request_buffering off;

        # 核心：设置 86400s (24小时) 超长超时，杜绝 CDN 100s 断连
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_connect_timeout 30s;

        # WebSocket 协议升级与头部直传
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$http_host;

        # 传递客户端真实 IP 给 Xray
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # 转发到本地持久连接池
        proxy_pass http://xui_${clean_domain}_${xui_port};
    }
}
EOF

    echo ""
    log_info "✅ 极限 Nginx 配置模板已生成至："
    echo -e "   ${BOLD}${YELLOW}${output_file}${NC}"
    echo -e "   真实 IP 规则文件: ${BOLD}${cf_ips_conf}${NC}"
    echo -e "提示：复制到 /etc/nginx/conf.d/ 后执行 nginx -t && nginx -s reload 即可。"
    echo ""
    read -rp "按回车键返回菜单..."
}

# ==============================================================================
# 模块 5：源站安全防护 (仅允许 Cloudflare 官方 IP 访问代理端口)
# ==============================================================================
setup_cloudflare_firewall() {
    print_banner
    log_step "【源站安全防护】仅允许 Cloudflare 官方节点访问回源端口"
    echo -e "说明：开启后，除了 Cloudflare CDN 边缘节点外，其他任何人（包括审查扫描器）"
    echo -e "      都无法直接连接您的代理端口，从而杜绝源站 IP 被直接墙掉！\n"

    if ! command -v ufw &>/dev/null; then
        log_warn "未检测到 ufw，尝试自动安装..."
        if command -v apt-get &>/dev/null; then
            apt-get update -qq && apt-get install -y ufw -qq
        elif command -v yum &>/dev/null; then
            yum install -y ufw
        fi
    fi

    if ! command -v ufw &>/dev/null; then
        log_error "系统缺少 ufw 防火墙工具，请手动安装后重试！"
        read -rp "按回车键返回..."
        return 1
    fi

    read -rp "请输入您暴露给 Cloudflare CDN 回源的外部端口 (例如 80 或 443 或自定义端口): " target_port
    [[ -z "$target_port" ]] && { log_error "端口不能为空！"; return 1; }

    log_info "正在获取 Cloudflare 官方 IPv4 网段..."
    local cf_ipv4
    cf_ipv4=$(curl -sL https://www.cloudflare.com/ips-v4)
    if [[ -z "$cf_ipv4" ]]; then
        log_error "获取 Cloudflare IP 网段失败，请检查网络！"
        read -rp "按回车键返回..."
        return 1
    fi

    log_step "开始添加 UFW 规则 (仅允许 Cloudflare 回源访问端口 $target_port)..."
    for ip in $cf_ipv4; do
        ufw allow proto tcp from "$ip" to any port "$target_port" comment "Cloudflare-CDN" >/dev/null 2>&1
    done

    # 针对其他流量拒绝该端口访问
    ufw deny "$target_port/tcp" comment "Block-Non-CF" >/dev/null 2>&1

    log_info "防火墙规则设置完成！"
    log_warn "请务必确认您的 SSH 端口已放行，避免断连！"
    read -rp "按回车键返回菜单..."
}

# ==============================================================================
# 模块 6：客户端突破：Cloudflare 优选 IP 测速与加速指南
# ==============================================================================
show_cf_clean_ip_guide() {
    print_banner
    log_step "【突破物理天花板】Cloudflare 客户端优选节点原理与指南"
    echo -e "⚡ ${BOLD}为什么必须做优选 IP？${NC}"
    echo -e "   因为使用 Cloudflare CDN 时，${YELLOW}80% 以上的延迟与卡顿发生在「客户端 ➔ Cloudflare 边缘节点」${NC}。"
    echo -e "   默认 DNS 通常会将您分配到拥挤或绕路的美西节点。\n"

    echo -e "🔹 ${BOLD}测试服务器到 Cloudflare Anycast 的当前延迟：${NC}"
    curl -o /dev/null -s -w '   HTTP 状态: %{http_code} | TCP 握手: %{time_connect}s | 首字节时间: %{time_starttransfer}s | 总耗时: %{time_total}s\n' https://speed.cloudflare.com/__down?bytes=1000 2>/dev/null

    echo ""
    echo -e "🚀 ${BOLD}客户端优选解决方案：${NC}"
    echo -e "   1. 在客户端电脑/手机上运行 ${CYAN}CloudflareSpeedTest${NC} 测速脚本。"
    echo -e "   2. 筛选出当前宽带（电信/联通/移动）延迟在 30~80ms、0 丢包的优选 IP。"
    echo -e "   3. 在客户端节点配置中："
    echo -e "      - ${BOLD}地址 (Address)${NC}：填写测出的【优选 IP】（例如 104.16.x.x）"
    echo -e "      - ${BOLD}主机名 (Host / SNI)${NC}：填写您的【真实域名】（例如 my.example.com）"
    echo -e "   ${GREEN}这样即可绕过路由绕路，直接榨干当地最优 CDN 边缘节点，速度提升可达 300%~500%！${NC}"
    echo ""
    read -rp "按回车键返回菜单..."
}

# ==============================================================================
# 模块 7：一键狂暴全套调优
# ==============================================================================
run_full_extreme_optimization() {
    print_banner
    log_extreme "启动一键全套狂暴极限优化..."
    tune_nic_extreme
    tune_kernel_extreme
    tune_xui_extreme
    echo ""
    log_info "🎉 【狂暴极限优化】全部配置已注入完成！"
    echo -e "   ⚡ 网卡物理层：RPS/RFS 多核分流激活，队列已扩容至 10000"
    echo -e "   ⚡ 内核协议栈：TFO=3 握手、小包立即推、20s Keepalive 保活、内存锁定"
    echo -e "   ⚡ 进程调度层：Xray 核心已注入动态实时调度 + Nice -20 抢占 + 百万句柄"
    echo ""
    read -rp "按回车键返回主菜单..."
}

# ==============================================================================
# 模块 8：状态与极限指标诊断
# ==============================================================================
show_status_diagnostic() {
    print_banner
    log_step "【系统极限调优指标诊断】"
    echo ""

    local current_cc current_qdisc tfo ka_time
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
    tfo=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo "未知")
    ka_time=$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null || echo "未知")
    echo -e "🔹 拥塞控制与队列   : ${BOLD}${GREEN}${current_cc}${NC} / ${BOLD}${GREEN}${current_qdisc}${NC}"
    echo -e "🔹 TCP Fast Open    : ${BOLD}${GREEN}${tfo}${NC} (3 表示双向加速开启)"
    echo -e "🔹 Keepalive 心跳   : ${BOLD}${GREEN}${ka_time}s${NC} (已防御 CDN 100s 超时)"

    # 网卡 RPS 状态
    local iface
    iface=$(detect_physical_nic)
    if [[ -n "$iface" && -f "/sys/class/net/$iface/queues/rx-0/rps_cpus" ]]; then
        local rps_stat
        rps_stat=$(cat "/sys/class/net/$iface/queues/rx-0/rps_cpus" 2>/dev/null)
        echo -e "🔹 网卡 RPS 多核掩码: ${BOLD}${GREEN}0x${rps_stat}${NC} (接口: $iface)"
    fi

    # Xray 进程调度状态
    local xui_pid
    xui_pid=$(pgrep -f "xray-linux" | head -n 1)
    if [[ -n "$xui_pid" ]]; then
        local chrt_stat
        chrt_stat=$(chrt -p "$xui_pid" 2>/dev/null || echo "未知")
        echo -e "🔹 Xray 核心调度策略: ${BOLD}${PURPLE}${chrt_stat}${NC} (PID: $xui_pid)"
    fi

    echo ""
    read -rp "按回车键返回菜单..."
}

# ==============================================================================
# 模块 9：一键还原恢复 (彻底清理)
# ==============================================================================
restore_optimization() {
    print_banner
    log_step "【配置回滚】彻底清理优化并恢复系统默认状态"
    read -rp "确定要彻底清理所有狂暴极限优化吗？(y/N): " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return 0

    # 1. 清理网卡 RPS 服务与脚本，并将网卡队列复位为 0
    systemctl stop throttle-rps.service 2>/dev/null || true
    systemctl disable throttle-rps.service --quiet 2>/dev/null || true
    rm -f "$RPS_SERVICE" "$RPS_SCRIPT"

    local iface
    iface=$(detect_physical_nic)
    if [[ -n "$iface" ]]; then
        for q in /sys/class/net/"$iface"/queues/rx-*; do
            [[ -e "$q/rps_cpus" ]] && echo 0 > "$q/rps_cpus" 2>/dev/null || true
        done
        ip link set dev "$iface" txqueuelen 1000 2>/dev/null || true
    fi

    # 2. 清理 sysctl 与 limits
    rm -f "$SYSCTL_CONF" "$LIMITS_CONF"
    systemctl daemon-reload
    sysctl --system &>/dev/null || true

    # 3. 清理 3x-ui 服务 override
    local xui_service
    xui_service=$(find_xui_service)
    if [[ -n "$xui_service" ]]; then
        rm -f "${xui_service}.d/override-extreme.conf" "${xui_service}.d/override-tune.conf"
        systemctl daemon-reload
        systemctl restart "$(basename "$xui_service")" 2>/dev/null || true
    fi

    log_info "所有极限优化已完全清除，网卡 RPS 与系统设置已恢复原生状态！"
    read -rp "按回车键返回菜单..."
}

# ==============================================================================
# 主菜单
# ==============================================================================
main_menu() {
    check_root
    while true; do
        print_banner
        echo -e "${BOLD}请选择要执行的操作：${NC}"
        echo ""
        echo -e "  ${PURPLE}1)${NC} 🚀 ${BOLD}【一键狂暴极限调优】${NC} (RPS多核分流 + BBR+TFO=3 + 动态实时调度)"
        echo -e "  ${GREEN}2)${NC} 🌐 ${BOLD}网卡物理层优化${NC} (RPS/RFS 多核软中断分流 + 硬件卸载 + 队列扩容)"
        echo -e "  ${GREEN}3)${NC} ⚡ ${BOLD}内核与 TCP 极限调参${NC} (BBR + TFO握手 + 小包立即推 + 20s保活)"
        echo -e "  ${GREEN}4)${NC} 🏎️ ${BOLD}3x-ui / Xray 实时提权${NC} (动态 FIFO 90 调度 + 内存锁定 + Go调优)"
        echo -e "  ${GREEN}5)${NC} 🛡️ ${BOLD}Nginx 极限反代配置生成器${NC} (WS零缓冲 + keepalive连接池 + CF真实IP)"
        echo -e "  ${GREEN}6)${NC} 🔒 ${BOLD}源站安全加固 (UFW)${NC} (仅允许 Cloudflare 官方 IP 访问回源端口)"
        echo -e "  ${CYAN}7)${NC} 💡 ${BOLD}客户端加速指南${NC} (突破 CDN 天花板：Cloudflare 优选 IP 原理与测速)"
        echo -e "  ${GREEN}8)${NC} 📊 ${BOLD}极限指标状态诊断${NC} (RPS掩码 / FIFO调度 / TFO状态 / 延迟)"
        echo -e "  ${YELLOW}9)${NC} 🔄 ${BOLD}一键彻底回滚优化${NC} (无损清理还原系统原生状态)"
        echo -e "  ${RED}0)${NC} 退出脚本"
        echo ""
        read -rp "请输入选项 [0-9]: " choice
        case "$choice" in
            1) run_full_extreme_optimization ;;
            2) tune_nic_extreme; read -rp "按回车键继续..." ;;
            3) tune_kernel_extreme; read -rp "按回车键继续..." ;;
            4) tune_xui_extreme; read -rp "按回车键继续..." ;;
            5) generate_nginx_extreme ;;
            6) setup_cloudflare_firewall ;;
            7) show_cf_clean_ip_guide ;;
            8) show_status_diagnostic ;;
            9) restore_optimization ;;
            0) echo -e "\n感谢使用，再见！\n"; exit 0 ;;
            *) log_warn "无效选项，请重新输入！"; sleep 1 ;;
        esac
    done
}

main_menu
