#!/bin/bash
# ==========================================
# SSH 端口一键修改脚本
# 支持 Debian / Ubuntu / CentOS / Rocky / AlmaLinux
#
# 主要改进：
#   1. SELinux ssh_port_t 标签
#   2. systemd socket 激活 (Ubuntu 22.10+ / Debian 13+)
#   3. /etc/ssh/sshd_config.d drop-in，避免直接改主配置被覆盖
#   4. 可选双端口过渡，降低锁死风险
#   5. UFW / firewalld / iptables / nft 基础放行
#   6. 重启失败自动回滚
# ==========================================
set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()      { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()     { echo -e "${RED}[ERROR]${NC} $*" >&2; }

echo
echo -e "${BLUE}==========================================${NC}"
echo -e "${BLUE}        VPS SSH 端口一键修改工具${NC}"
echo -e "${BLUE}==========================================${NC}"
echo

if [ "$(id -u)" -ne 0 ]; then
    err "请使用 root 运行：sudo bash $0"
    exit 1
fi

if ! command -v sshd >/dev/null 2>&1; then
    err "未找到 sshd，请先安装 OpenSSH 服务端"
    exit 1
fi

SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
SSHD_DROPIN="${SSHD_DROPIN_DIR}/99-custom-port.conf"
STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="/etc/ssh/backup-${STAMP}"

if [ ! -f "$SSHD_CONFIG" ]; then
    err "找不到 $SSHD_CONFIG"
    exit 1
fi

# ------------------------------------------
# 探测发行版 / 服务名 / socket 激活
# ------------------------------------------
OS_ID=""
OS_VERSION_ID=""
if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_VERSION_ID="${VERSION_ID:-}"
fi

detect_ssh_units() {
    SSH_SERVICE=""
    SSH_SOCKET=""
    if systemctl list-unit-files --type=service 2>/dev/null | grep -qE '^ssh\.service'; then
        SSH_SERVICE="ssh"
    elif systemctl list-unit-files --type=service 2>/dev/null | grep -qE '^sshd\.service'; then
        SSH_SERVICE="sshd"
    fi
    if systemctl list-unit-files --type=socket 2>/dev/null | grep -qE '^ssh\.socket'; then
        SSH_SOCKET="ssh.socket"
    elif systemctl list-unit-files --type=socket 2>/dev/null | grep -qE '^sshd\.socket'; then
        SSH_SOCKET="sshd.socket"
    fi
}

detect_ssh_units

SOCKET_ACTIVE=0
if [ -n "$SSH_SOCKET" ] && systemctl is-active --quiet "$SSH_SOCKET" 2>/dev/null; then
    SOCKET_ACTIVE=1
fi

# ------------------------------------------
# 当前有效端口（可能多个）
# ------------------------------------------
mapfile -t CURRENT_PORTS < <(sshd -T 2>/dev/null | awk '/^port / {print $2}' | sort -n -u)

if [ "${#CURRENT_PORTS[@]}" -eq 0 ]; then
    # socket 激活时 sshd -T 仍可能给出 Port，但实际监听以 socket 为准
    mapfile -t CURRENT_PORTS < <(
        ss -lntH 2>/dev/null \
            | awk '{print $4}' \
            | grep -oE '[0-9]+$' \
            | sort -n -u
    )
    # 上面会混入非 SSH 端口，再按进程收窄
    mapfile -t CURRENT_PORTS < <(
        ss -lntpH 2>/dev/null \
            | awk '/sshd|systemd/ && /:22 |:[0-9]+/ {print $4}' \
            | grep -oE '[0-9]+$' \
            | sort -n -u
    )
fi

if [ "${#CURRENT_PORTS[@]}" -eq 0 ]; then
    CURRENT_PORTS=(22)
fi

CURRENT_PORT="${CURRENT_PORTS[0]}"
echo -e "${GREEN}当前 SSH 有效端口：${CURRENT_PORTS[*]}${NC}"
[ "$SOCKET_ACTIVE" -eq 1 ] && warn "检测到 systemd socket 激活（$SSH_SOCKET），只改 sshd_config 不会生效"
echo

# ------------------------------------------
# 输入新端口
# ------------------------------------------
RESERVED_WARN="80 443 3306 5432 6379 8080 8443 27017"

is_port_in_use() {
    local p="$1"
    ss -lntH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"
}

while true; do
    read -rp "请输入新的 SSH 端口 [1024-65535]：" NEW_PORT
    if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]]; then
        err "请输入纯数字端口"
        continue
    fi
    # 10# 避免 08 被当成八进制
    if [ "$((10#$NEW_PORT))" -lt 1024 ] || [ "$((10#$NEW_PORT))" -gt 65535 ]; then
        err "端口必须在 1024-65535 之间（避免特权端口）"
        continue
    fi
    NEW_PORT="$((10#$NEW_PORT))"

    already=0
    for p in "${CURRENT_PORTS[@]}"; do
        [ "$p" = "$NEW_PORT" ] && already=1
    done
    if [ "$already" -eq 1 ] && [ "${#CURRENT_PORTS[@]}" -eq 1 ]; then
        warn "新端口与当前端口相同，无需修改"
        exit 0
    fi

    if is_port_in_use "$NEW_PORT"; then
        # 若占用者就是 sshd，允许作为“已在听、只需收敛配置”
        if ss -lntpH 2>/dev/null | grep -E "[:.]${NEW_PORT}([[:space:]]|$)" | grep -q sshd; then
            warn "端口 $NEW_PORT 已由 sshd 监听，将把配置收敛到该端口"
        else
            err "端口 $NEW_PORT 已被其他程序占用："
            ss -lntpH 2>/dev/null | grep -E "[:.]${NEW_PORT}([[:space:]]|$)" || true
            continue
        fi
    fi

    for w in $RESERVED_WARN; do
        if [ "$NEW_PORT" = "$w" ]; then
            warn "端口 $NEW_PORT 是常见服务端口，容易冲突或被扫描"
        fi
    done
    break
done

echo
echo -e "${YELLOW}准备将 SSH 端口：${CURRENT_PORTS[*]} → ${NEW_PORT}${NC}"
echo
warn "云厂商安全组 / 面板防火墙 不会被本脚本修改。"
warn "若使用阿里云/腾讯云/AWS Security Group，请先在控制台放行 ${NEW_PORT}/tcp。"
echo
read -rp "确认后先双端口过渡（旧端口+新端口同时监听，更安全）？[Y/n]：" DUAL
DUAL="${DUAL:-Y}"
echo
read -rp "确认修改？[y/N]：" CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "已取消"
    exit 0
fi

mkdir -p "$BACKUP_DIR"
cp -a "$SSHD_CONFIG" "$BACKUP_DIR/sshd_config"
if [ -d "$SSHD_DROPIN_DIR" ]; then
    cp -a "$SSHD_DROPIN_DIR" "$BACKUP_DIR/sshd_config.d" 2>/dev/null || true
fi
ok "配置已备份到 $BACKUP_DIR"

# ------------------------------------------
# SELinux
# ------------------------------------------
selinux_enforcing() {
    if command -v getenforce >/dev/null 2>&1; then
        [ "$(getenforce 2>/dev/null)" = "Enforcing" ]
        return
    fi
    return 1
}

ensure_selinux_port() {
    local port="$1"
    if ! selinux_enforcing; then
        return 0
    fi
    info "SELinux Enforcing：为 ${port}/tcp 添加 ssh_port_t"
    if ! command -v semanage >/dev/null 2>&1; then
        if command -v dnf >/dev/null 2>&1; then
            dnf -y install policycoreutils-python-utils >/dev/null
        elif command -v yum >/dev/null 2>&1; then
            yum -y install policycoreutils-python-utils >/dev/null
        else
            err "SELinux 已启用但找不到 semanage，无法安全改端口"
            return 1
        fi
    fi
    if semanage port -l | awk '/^ssh_port_t/ {print}' | grep -qw "$port"; then
        ok "SELinux 已允许 ${port}/tcp"
        return 0
    fi
    if semanage port -a -t ssh_port_t -p tcp "$port" 2>/dev/null; then
        ok "已添加 SELinux 端口标签 ${port}/tcp"
        return 0
    fi
    if semanage port -m -t ssh_port_t -p tcp "$port" 2>/dev/null; then
        ok "已修改 SELinux 端口标签 ${port}/tcp"
        return 0
    fi
    err "SELinux 端口标签设置失败"
    return 1
}

if ! ensure_selinux_port "$NEW_PORT"; then
    exit 1
fi

# ------------------------------------------
# 写端口配置
#   优先 drop-in；否则改主文件
#   Port 是可重复指令：drop-in 若在 Include 之后，
#   会“追加监听”而不是覆盖。因此同时清理已有 Port 行。
# ------------------------------------------
strip_port_directives() {
    local file="$1"
    [ -f "$file" ] || return 0
    # 注释掉已有 Port，避免多端口残留
    sed -i -E 's/^[[:space:]]*Port[[:space:]]+.*/# &/' "$file"
}

clean_all_port_lines() {
    strip_port_directives "$SSHD_CONFIG"
    if [ -d "$SSHD_DROPIN_DIR" ]; then
        shopt -s nullglob
        for f in "$SSHD_DROPIN_DIR"/*.conf; do
            [ "$f" = "$SSHD_DROPIN" ] && continue
            if grep -Eq '^[[:space:]]*Port[[:space:]]+' "$f"; then
                cp -a "$f" "$BACKUP_DIR/$(basename "$f")"
                strip_port_directives "$f"
                warn "已注释 $f 中的 Port 指令"
            fi
        done
        shopt -u nullglob
    fi
}

write_port_config() {
    local ports=("$@")
    clean_all_port_lines

    local body="# Generated by ssh-port.sh ${STAMP}"$'\n'
    local p
    for p in "${ports[@]}"; do
        body+="Port ${p}"$'\n'
    done

    if grep -Eq '^[[:space:]]*Include[[:space:]]+.*/sshd_config\.d/' "$SSHD_CONFIG" \
        || [ -d "$SSHD_DROPIN_DIR" ]; then
        mkdir -p "$SSHD_DROPIN_DIR"
        printf '%s' "$body" > "$SSHD_DROPIN"
        # Include 一般在文件头部，drop-in 会先被读取。
        # 为避免“先读到 Port 22 默认 + 后又追加”，主文件 Port 已全部注释。
        ok "已写入 $SSHD_DROPIN ：${ports[*]}"
    else
        {
            echo ""
            printf '%s' "$body"
        } >> "$SSHD_CONFIG"
        ok "已写入 $SSHD_CONFIG ：${ports[*]}"
    fi
}

DESIRED_PORTS=("$NEW_PORT")
if [[ "$DUAL" =~ ^[Yy]$ ]]; then
    DESIRED_PORTS=()
    for p in "${CURRENT_PORTS[@]}"; do
        DESIRED_PORTS+=("$p")
    done
    found=0
    for p in "${DESIRED_PORTS[@]}"; do
        [ "$p" = "$NEW_PORT" ] && found=1
    done
    [ "$found" -eq 0 ] && DESIRED_PORTS+=("$NEW_PORT")
fi

write_port_config "${DESIRED_PORTS[@]}"

# ------------------------------------------
# systemd socket 激活
# Ubuntu 22.10+ / 部分 Debian：ListenStream 由 ssh.socket 决定
# ------------------------------------------
SOCKET_DROPIN=""
configure_socket() {
    [ "$SOCKET_ACTIVE" -eq 1 ] || return 0
    local unit="$SSH_SOCKET"
    local dir="/etc/systemd/system/${unit}.d"
    SOCKET_DROPIN="${dir}/listen.conf"
    mkdir -p "$dir"
    {
        echo "[Socket]"
        echo "ListenStream="
        local p
        for p in "${DESIRED_PORTS[@]}"; do
            echo "ListenStream=${p}"
        done
        echo "FreeBind=true"
    } > "$SOCKET_DROPIN"
    systemctl daemon-reload
    ok "已配置 $SOCKET_DROPIN"
}

configure_socket

# ------------------------------------------
# 语法检查
# ------------------------------------------
info "检查 SSH 配置语法..."
if ! sshd -t; then
    err "SSH 配置检查失败，正在回滚..."
    cp -a "$BACKUP_DIR/sshd_config" "$SSHD_CONFIG"
    if [ -d "$BACKUP_DIR/sshd_config.d" ]; then
        rm -rf "$SSHD_DROPIN_DIR"
        cp -a "$BACKUP_DIR/sshd_config.d" "$SSHD_DROPIN_DIR"
    else
        rm -f "$SSHD_DROPIN"
    fi
    [ -n "$SOCKET_DROPIN" ] && rm -f "$SOCKET_DROPIN"
    systemctl daemon-reload 2>/dev/null || true
    exit 1
fi
ok "语法检查通过"

# ------------------------------------------
# 防火墙：只放行，不关闭旧端口
# ------------------------------------------
info "检查防火墙（只放行新端口，不关闭旧端口）..."

allow_ufw() {
    command -v ufw >/dev/null 2>&1 || return 0
    local st
    st="$(ufw status 2>/dev/null | head -1 || true)"
    echo "$st" | grep -qi "active" || return 0
    info "检测到 UFW"
    if ufw status 2>/dev/null | grep -qE "^${NEW_PORT}/tcp"; then
        ok "UFW 已放行 ${NEW_PORT}/tcp"
    else
        ufw allow "${NEW_PORT}/tcp" comment "SSH custom port"
        ok "UFW 已放行 ${NEW_PORT}/tcp"
    fi
}

allow_firewalld() {
    command -v firewall-cmd >/dev/null 2>&1 || return 0
    firewall-cmd --state >/dev/null 2>&1 || return 0
    info "检测到 firewalld"
    firewall-cmd --permanent --add-port="${NEW_PORT}/tcp" >/dev/null
    firewall-cmd --reload >/dev/null
    ok "firewalld 已放行 ${NEW_PORT}/tcp"
}

allow_iptables() {
    # 仅在没有 ufw/firewalld 管理时，给 filter INPUT 插一条
    if command -v ufw >/dev/null 2>&1; then
        ufw status 2>/dev/null | grep -qi "active" && return 0
    fi
    if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --state >/dev/null 2>&1 && return 0
    fi
    if command -v iptables >/dev/null 2>&1; then
        if iptables -C INPUT -p tcp --dport "$NEW_PORT" -j ACCEPT 2>/dev/null; then
            ok "iptables 已放行 ${NEW_PORT}/tcp"
        else
            # 有规则链才插入，避免空表机器误加
            if iptables -L INPUT -n >/dev/null 2>&1; then
                local policy
                policy="$(iptables -L INPUT -n 2>/dev/null | awk '/Chain INPUT/ {print $4}' | tr -d ')' )"
                if [ "$policy" = "DROP" ] || [ "$policy" = "REJECT" ] \
                    || iptables -L INPUT -n | grep -qE 'DROP|REJECT'; then
                    iptables -I INPUT -p tcp --dport "$NEW_PORT" -j ACCEPT
                    warn "已在 iptables INPUT 插入放行（未持久化，重启可能丢失）"
                    if command -v netfilter-persistent >/dev/null 2>&1; then
                        netfilter-persistent save >/dev/null 2>&1 || true
                    elif command -v service >/dev/null 2>&1 && [ -x /etc/init.d/iptables ]; then
                        service iptables save >/dev/null 2>&1 || true
                    fi
                fi
            fi
        fi
    fi
}

allow_ufw
allow_firewalld
allow_iptables

if command -v fail2ban-client >/dev/null 2>&1; then
    warn "检测到 fail2ban。若 jail 写死了 port=22，请改成新端口后 reload fail2ban"
fi

# ------------------------------------------
# 重启 / 重载
# ------------------------------------------
apply_ssh_service() {
    if [ -z "$SSH_SERVICE" ]; then
        return 1
    fi
    if [ "$SOCKET_ACTIVE" -eq 1 ]; then
        systemctl daemon-reload 2>/dev/null || true
        systemctl restart "$SSH_SOCKET" && systemctl restart "$SSH_SERVICE"
        return
    fi
    systemctl reload "$SSH_SERVICE" 2>/dev/null || systemctl restart "$SSH_SERVICE"
}

rollback() {
    err "正在恢复备份配置..."
    cp -a "$BACKUP_DIR/sshd_config" "$SSHD_CONFIG"
    if [ -d "$BACKUP_DIR/sshd_config.d" ]; then
        rm -rf "$SSHD_DROPIN_DIR"
        cp -a "$BACKUP_DIR/sshd_config.d" "$SSHD_DROPIN_DIR"
    else
        rm -f "$SSHD_DROPIN"
    fi
    [ -n "$SOCKET_DROPIN" ] && rm -f "$SOCKET_DROPIN"
    systemctl daemon-reload 2>/dev/null || true
    if [ "$SOCKET_ACTIVE" -eq 1 ]; then
        systemctl restart "$SSH_SOCKET" 2>/dev/null || true
        systemctl restart "$SSH_SERVICE" 2>/dev/null || true
    elif [ -n "$SSH_SERVICE" ]; then
        systemctl restart "$SSH_SERVICE" 2>/dev/null || true
    fi
    ok "已恢复原配置"
}

info "应用 SSH 服务..."
if [ -z "$SSH_SERVICE" ]; then
    err "无法确定 SSH 服务名。配置已改，请手动重启"
    exit 1
fi

if ! apply_ssh_service; then
    err "SSH 重启失败"
    rollback
    exit 1
fi

sleep 2

listening_on() {
    local p="$1"
    ss -lntH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"
}

close_firewall_22() {
    local changed=0

    if command -v ufw >/dev/null 2>&1; then
        local st
        st="$(ufw status 2>/dev/null | head -1 || true)"
        if echo "$st" | grep -qi "active"; then
            info "从 UFW 移除 22/tcp"
            # 可能同时存在 22/tcp 与 OpenSSH 应用规则
            ufw delete allow 22/tcp >/dev/null 2>&1 && changed=1 || true
            ufw delete allow OpenSSH >/dev/null 2>&1 && changed=1 || true
            ufw --force delete allow 22 >/dev/null 2>&1 && changed=1 || true
            ok "UFW 已尝试关闭 22"
        fi
    fi

    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        info "从 firewalld 移除 22/tcp 与 ssh 服务"
        firewall-cmd --permanent --remove-port=22/tcp >/dev/null 2>&1 && changed=1 || true
        firewall-cmd --permanent --remove-service=ssh >/dev/null 2>&1 && changed=1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        ok "firewalld 已尝试关闭 22"
    fi

    if command -v ufw >/dev/null 2>&1; then
        ufw status 2>/dev/null | grep -qi "active" && return 0
    fi
    if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --state >/dev/null 2>&1 && return 0
    fi

    if command -v iptables >/dev/null 2>&1; then
        while iptables -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null; do
            iptables -D INPUT -p tcp --dport 22 -j ACCEPT
            changed=1
        done
        if [ "$changed" -eq 1 ]; then
            warn "已删除 iptables 中 22/tcp ACCEPT（若规则带网卡/源地址限制，请手动核对）"
            if command -v netfilter-persistent >/dev/null 2>&1; then
                netfilter-persistent save >/dev/null 2>&1 || true
            elif command -v service >/dev/null 2>&1 && [ -x /etc/init.d/iptables ]; then
                service iptables save >/dev/null 2>&1 || true
            fi
        fi
    fi
}

close_listen_22() {
    info "将 SSH 监听收敛为仅 ${NEW_PORT}"
    DESIRED_PORTS=("$NEW_PORT")
    write_port_config "${DESIRED_PORTS[@]}"
    configure_socket

    if ! sshd -t; then
        err "去掉 22 后配置检查失败，已中止（未重启服务）"
        return 1
    fi
    if ! apply_ssh_service; then
        err "去掉 22 后 SSH 重启失败"
        rollback
        return 1
    fi
    sleep 2
    if ! listening_on "$NEW_PORT"; then
        err "新端口 ${NEW_PORT} 未在监听，正在回滚"
        rollback
        return 1
    fi
    if listening_on 22; then
        warn "本机仍有进程监听 22，请手动检查：ss -lntp | grep ':22'"
        ss -lntpH 2>/dev/null | grep -E '[:.]22([[:space:]]|$)' || true
    else
        ok "SSH 已不再监听 22"
    fi
    return 0
}

if listening_on "$NEW_PORT"; then
    echo
    echo -e "${GREEN}==========================================${NC}"
    echo -e "${GREEN}        SSH 端口修改成功${NC}"
    echo -e "${GREEN}==========================================${NC}"
    echo
    echo -e "旧端口：${YELLOW}${CURRENT_PORTS[*]}${NC}"
    echo -e "新端口：${GREEN}${NEW_PORT}${NC}"
    if [[ "$DUAL" =~ ^[Yy]$ ]]; then
        echo -e "当前监听：${GREEN}${DESIRED_PORTS[*]}${NC}（双端口过渡）"
    fi
    echo -e "服务：${GREEN}${SSH_SERVICE}${NC}"
    [ "$SOCKET_ACTIVE" -eq 1 ] && echo -e "Socket：${GREEN}${SSH_SOCKET}${NC}"
    echo -e "备份：${GREEN}${BACKUP_DIR}${NC}"
    echo
    echo -e "${BLUE}请先新开一个终端测试：${NC}"
    echo
    echo "    ssh -p ${NEW_PORT} root@你的服务器IP"
    echo
    echo -e "${YELLOW}不要在未验证前关闭当前会话。云安全组请自行放行 ${NEW_PORT}/tcp。${NC}"
    echo

    if [ "$NEW_PORT" != "22" ]; then
        echo -e "${BLUE}------------------------------------------${NC}"
        echo -e "${BLUE}关闭 22 端口（可选）${NC}"
        echo -e "${BLUE}------------------------------------------${NC}"
        echo
        warn "只有在新窗口已经用 ${NEW_PORT} 登录成功后再做这一步。"
        warn "本脚本不能改云厂商安全组；安全组里的 22 需要你自己删。"
        echo
        read -rp "是否已用新端口从另一个窗口成功登录？[y/N]：" TESTED_OK
        if [[ "$TESTED_OK" =~ ^[Yy]$ ]]; then
            read -rp "停止 SSH 监听 22 端口？[y/N]：" CLOSE_LISTEN
            if [[ "$CLOSE_LISTEN" =~ ^[Yy]$ ]]; then
                if close_listen_22; then
                    ok "SSH 配置已去掉 22"
                else
                    err "关闭 SSH 的 22 监听失败，请检查备份：$BACKUP_DIR"
                fi
            else
                info "保留 SSH 监听 22"
            fi

            read -rp "同时关闭本机防火墙中的 22/tcp？[y/N]：" CLOSE_FW
            if [[ "$CLOSE_FW" =~ ^[Yy]$ ]]; then
                if ! listening_on "$NEW_PORT"; then
                    err "新端口未监听，拒绝关闭防火墙 22"
                else
                    close_firewall_22
                    ok "本机防火墙 22 处理完毕"
                fi
            else
                info "本机防火墙 22 保持不变"
            fi
        else
            info "跳过关闭 22。验证新端口后可重新运行脚本再关。"
        fi
        echo
    fi
else
    err "未检测到 SSH 监听 ${NEW_PORT}"
    ss -lntpH 2>/dev/null | grep -E 'sshd|ssh' || true
    rollback
    exit 1
fi
