#!/bin/bash
# ============================================================
# 服务器安全加固一键脚本 v1.2
# 基于官方指南 + 代理/VPN服务器实战优化
# 改进：移除 set -e + 增加 ufw 检查 + 优化日常放行体验
# ============================================================

SUDO=""
if [ "$EUID" -ne 0 ]; then
    SUDO="sudo"
fi

# ------------------ 辅助函数 ------------------

check_ufw_installed() {
    if ! command -v ufw &> /dev/null; then
        echo "❌ 未检测到 ufw 命令！"
        echo "请先安装：sudo apt install ufw -y"
        return 1
    fi
    return 0
}

show_listening_ports() {
    echo ""
    echo "【当前系统监听端口】（TCP + UDP）"
    echo "TCP 监听："
    $SUDO ss -tuln | grep LISTEN || true
    echo ""
    echo "UDP 监听："
    $SUDO ss -uln || true
    echo ""
}

show_ufw_status() {
    echo ""
    echo "【当前 ufw 防火墙已允许的规则】"
    $SUDO ufw status numbered || true
    echo ""
}

add_ports_interactive() {
    show_listening_ports
    show_ufw_status

    echo "现在添加/放行新端口（支持 tcp 和 udp）"
    echo "格式示例：443/tcp   或   8443/udp"
    echo "可一次性输入多个，用逗号分隔，例如：80/tcp,443/tcp,8443/udp"
    echo "输入 'done' 结束"
    echo ""

    while true; do
        read -p "要放行的端口/协议 (或 done): " port_input
        [[ "$port_input" == "done" || "$port_input" == "DONE" ]] && break

        # 支持逗号分隔 + 过滤空项
        IFS=',' read -ra ports <<< "$port_input"
        for raw in "${ports[@]}"; do
            p=$(echo "$raw" | xargs)
            [[ -z "$p" ]] && continue
            if [[ "$p" =~ ^[0-9]+/(tcp|udp)$ ]]; then
                comment="Proxy-Node-$(date +%F)"
                $SUDO ufw allow "$p" comment "$comment"
                echo "  ✅ 已放行: $p  (注释: $comment)"
            else
                echo "  ❌ 格式错误，跳过: $p"
            fi
        done
    done

    echo ""
    echo "放行操作完成，当前防火墙规则："
    $SUDO ufw status numbered
}

# ------------------ 主菜单 ------------------

echo "=============================================="
echo "🚀 服务器安全加固脚本 v1.2（稳定版）"
echo "=============================================="
echo ""
echo "请选择要执行的操作："
echo "  1) 执行完整安全加固（首次部署服务器时推荐）"
echo "  2) 仅添加/放行新端口（日常维护加节点时推荐）"
echo "  3) 查看当前监听端口 + 防火墙规则"
echo "  4) 删除某个已放行的端口"
echo "  5) 退出"
echo ""
read -p "请输入选项 [1-5]: " choice

case "$choice" in
    1)
        # ==================== 完整安全加固模式 ====================
        echo ""
        echo "【完整安全加固模式】即将执行所有安全加固步骤..."
        read -p "确认继续？(y/N): " confirm
        [[ ! "$confirm" =~ ^[Yy]$ ]] && { echo "已取消。"; exit 0; }

        echo ""
        echo "【步骤 1/7】 系统更新与安全补丁安装"
        $SUDO apt update -y
        $SUDO apt upgrade -y
        echo "✅ 系统已更新"

        echo ""
        echo "安装安全工具 (ufw / fail2ban / unattended-upgrades)..."
        $SUDO apt install -y ufw fail2ban unattended-upgrades
        echo "✅ 安全工具安装完成"

        show_listening_ports

        echo ""
        echo "【步骤 2/7】 SSH 远程访问安全加固"
        $SUDO cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%F_%T) 2>/dev/null || true

        ORIGINAL_SSH_PORT=$($SUDO grep -E '^\s*Port\s+' /etc/ssh/sshd_config | head -1 | awk '{print $2}' || echo "22")
        echo "当前 SSH 端口: $ORIGINAL_SSH_PORT"

        NEW_SSH_PORT=""
        read -p "是否修改默认 SSH 端口？(强烈推荐) (y/N): " change_port
        if [[ "$change_port" =~ ^[Yy]$ ]]; then
            while true; do
                read -p "请输入新的 SSH 端口 (1024-65535): " NEW_SSH_PORT
                if [[ "$NEW_SSH_PORT" =~ ^[0-9]+$ ]] && [ "$NEW_SSH_PORT" -ge 1024 ] && [ "$NEW_SSH_PORT" -le 65535 ] && [ "$NEW_SSH_PORT" -ne 22 ]; then
                    break
                else
                    echo "端口无效，请重新输入。"
                fi
            done
            $SUDO sed -i "s/^\s*#*\s*Port\s\+.*/Port ${NEW_SSH_PORT}/" /etc/ssh/sshd_config
            echo "✅ SSH 端口已修改为 $NEW_SSH_PORT"
        fi

        echo "禁用 root SSH 登录..."
        $SUDO sed -i 's/^\s*#*\s*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config

        read -p "是否已配置 SSH 密钥并确认可用？(y/N) [将禁用密码认证]: " has_key
        if [[ "$has_key" =~ ^[Yy]$ ]]; then
            $SUDO sed -i 's/^\s*#*\s*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
            $SUDO sed -i 's/^\s*#*\s*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
            echo "✅ 已禁用密码认证"
        fi

        EFFECTIVE_SSH_PORT=${NEW_SSH_PORT:-$ORIGINAL_SSH_PORT}

        echo ""
        echo "【步骤 3/7】 配置防火墙 (ufw)"
        $SUDO ufw default deny incoming
        $SUDO ufw default allow outgoing
        $SUDO ufw allow ${EFFECTIVE_SSH_PORT}/tcp comment 'SSH access'
        if [ -n "$NEW_SSH_PORT" ] && [ "$NEW_SSH_PORT" != "$ORIGINAL_SSH_PORT" ]; then
            $SUDO ufw allow ${ORIGINAL_SSH_PORT}/tcp comment 'SSH old port (temp)'
        fi

        echo ""
        echo "现在添加你服务需要的端口..."
        add_ports_interactive

        echo ""
        echo "启用防火墙..."
        read -p "确认启用 ufw？(y/N): " en
        if [[ "$en" =~ ^[Yy]$ ]]; then
            $SUDO ufw --force enable
            $SUDO ufw status verbose
        fi

        echo ""
        echo "【步骤 4/7】 配置 fail2ban"
        $SUDO tee /etc/fail2ban/jail.d/sshd-custom.conf > /dev/null <<EOF
[sshd]
enabled = true
port = __PORT_PLACEHOLDER__
maxretry = 4
bantime = 7200
findtime = 600
backend = systemd
EOF
        if [ "$EFFECTIVE_SSH_PORT" != "22" ]; then
            $SUDO sed -i "s/__PORT_PLACEHOLDER__/${EFFECTIVE_SSH_PORT}/" /etc/fail2ban/jail.d/sshd-custom.conf
        else
            $SUDO sed -i "s/__PORT_PLACEHOLDER__/ssh,22/" /etc/fail2ban/jail.d/sshd-custom.conf
        fi
        $SUDO systemctl enable fail2ban --now >/dev/null 2>&1 || true
        echo "✅ fail2ban 已配置并启动"

        echo ""
        echo "【步骤 5/7】 启用自动安全更新"
        cat <<EOF | $SUDO tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
        echo "✅ 自动安全更新已启用"

        echo ""
        echo "【步骤 6/7】 应用网络安全内核参数"
        $SUDO tee /etc/sysctl.d/99-server-security.conf > /dev/null << 'EOF'
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.log_martians = 1
EOF
        $SUDO sysctl -p /etc/sysctl.d/99-server-security.conf >/dev/null 2>&1 || true
        echo "✅ sysctl 安全参数已应用"

        echo ""
        echo "【步骤 7/7】 重启服务"
        $SUDO systemctl restart ssh || $SUDO systemctl restart sshd || true
        $SUDO systemctl restart fail2ban 2>/dev/null || true
        echo "✅ 服务已重启"

        echo ""
        echo "🎉 完整安全加固已完成！请立即用新终端测试 SSH 连接。"
        ;;

    2)
        # ==================== 仅放行端口模式 ====================
        echo ""
        echo "【仅添加/放行新端口模式】"
        if ! check_ufw_installed; then exit 1; fi

        add_ports_interactive

        # 如果 ufw 未启用，询问是否启用
        if ! $SUDO ufw status | grep -q "Status: active"; then
            echo ""
            read -p "检测到 ufw 当前未启用，是否现在启用？(y/N): " enable_now
            if [[ "$enable_now" =~ ^[Yy]$ ]]; then
                $SUDO ufw --force enable
                echo "✅ ufw 已启用"
            fi
        fi
        echo "✅ 端口放行操作完成。"
        ;;

    3)
        if ! check_ufw_installed; then exit 1; fi
        show_listening_ports
        show_ufw_status
        ;;

    4)
        if ! check_ufw_installed; then exit 1; fi
        echo ""
        echo "【删除已放行的端口】"
        show_ufw_status
        read -p "请输入要删除的规则编号: " rule_num
        if [[ "$rule_num" =~ ^[0-9]+$ ]]; then
            $SUDO ufw delete "$rule_num"
            echo "✅ 已尝试删除规则 #$rule_num"
            $SUDO ufw status numbered
        else
            echo "无效的规则编号。"
        fi
        ;;

    5)
        echo "已退出。"
        exit 0
        ;;

    *)
        echo "无效选项，请重新运行脚本。"
        exit 1
        ;;
esac

echo ""
echo "=============================================="
echo "脚本执行完毕。"
echo "日常维护推荐直接选择选项 2（仅放行端口）。"
echo "=============================================="
