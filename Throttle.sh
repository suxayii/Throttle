#!/bin/bash

# 固定网卡名称
INTERFACE="eth0"

# 检查并安装必要的软件包
if ! command -v tc &> /dev/null; then
    echo "tc 命令未找到，请安装 iproute2 包。"
    exit 1
fi

if ! command -v iptables &> /dev/null; then
    echo "iptables 命令未找到，请安装 iptables 包。"
    exit 1
fi

# 固定 MARK 值
MARK=10

# 提示用户选择操作
echo "请选择操作："
echo "1. 设置端口限速"
echo "2. 清除限速规则"
echo "3. 查看当前配置"
read -p "请输入选项 (1、2 或 3): " CHOICE

if [ "$CHOICE" -eq 1 ]; then
    # 设置限速
    read -p "请输入目标端口(用逗号分隔，如 443,80,22): " PORTS
    read -p "请输入总带宽 (单位 KBps，只输入数值): " TOTAL_BANDWIDTH
    read -p "请输入单个 IP 的限速 (单位 KBps，只输入数值): " RATE
    read -p "请输入允许的最大速率 (单位 KBps，只输入数值): " CEIL

    echo -e "\n您已设置以下参数："
    echo "目标端口: $PORTS"
    echo "总带宽: ${TOTAL_BANDWIDTH}KBps"
    echo "单个 IP 的限速: ${RATE}KBps"
    echo "允许的最大速率: ${CEIL}KBps"
    read -p "确认限速请回车，取消请按 Ctrl+C..."

    # 清除已有的队列规则
    sudo tc qdisc del dev $INTERFACE root 2>/dev/null
    sudo iptables -t mangle -F

    # 添加根队列规则（HTB调度器）
    sudo tc qdisc add dev $INTERFACE root handle 1: htb default 30
    sudo tc class add dev $INTERFACE parent 1: classid 1:1 htb rate "${TOTAL_BANDWIDTH}KBps"
    sudo tc class add dev $INTERFACE parent 1:1 classid 1:10 htb rate "${RATE}KBps" ceil "${CEIL}KBps"

    # 添加 iptables 规则
    IFS=',' read -ra PORT_ARRAY <<< "$PORTS"
    for PORT in "${PORT_ARRAY[@]}"; do
        sudo iptables -t mangle -A PREROUTING -i $INTERFACE -p tcp --dport "$PORT" -j MARK --set-mark $MARK
        sudo iptables -t mangle -A PREROUTING -i $INTERFACE -p udp --dport "$PORT" -j MARK --set-mark $MARK
        sudo iptables -t mangle -A OUTPUT -o $INTERFACE -p tcp --sport "$PORT" -j MARK --set-mark $MARK
        sudo iptables -t mangle -A OUTPUT -o $INTERFACE -p udp --sport "$PORT" -j MARK --set-mark $MARK
    done

    # 设置过滤规则
    sudo tc filter add dev $INTERFACE protocol ip parent 1:0 prio 1 handle $MARK fw flowid 1:10

    # 保存配置信息到文件
    echo "${PORTS}" > /tmp/traffic_ports
    echo "${TOTAL_BANDWIDTH},${RATE},${CEIL}" > /tmp/traffic_config
    echo "限速规则已设置。"

elif [ "$CHOICE" -eq 2 ]; then
    # 清除限速规则
    echo "请选择清除规则的方式："
    echo "1. 清除所有限速规则"
    echo "2. 输入端口清除指定规则"
    read -p "请输入选项 (1 或 2): " CLEAR_CHOICE

    if [ "$CLEAR_CHOICE" -eq 1 ]; then
        # 清除所有规则
        sudo tc qdisc del dev $INTERFACE root 2>/dev/null
        sudo iptables -t mangle -F
        sudo rm -f /tmp/traffic_ports /tmp/traffic_config
        echo "已清除所有限速规则。"

    elif [ "$CLEAR_CHOICE" -eq 2 ]; then
        # 清除指定端口规则
        echo "当前限速端口："
        iptables -t mangle -L PREROUTING -v -n | grep "MARK set 0x$MARK" | awk '{print $13}' | sort -u
        read -p "请输入要解除限速的端口(用逗号分隔): " REMOVE_PORTS

        IFS=',' read -ra REMOVE_PORT_ARRAY <<< "$REMOVE_PORTS"
        for PORT in "${REMOVE_PORT_ARRAY[@]}"; do
            sudo iptables -t mangle -D PREROUTING -i $INTERFACE -p tcp --dport "$PORT" -j MARK --set-mark $MARK
            sudo iptables -t mangle -D PREROUTING -i $INTERFACE -p udp --dport "$PORT" -j MARK --set-mark $MARK
            sudo iptables -t mangle -D OUTPUT -o $INTERFACE -p tcp --sport "$PORT" -j MARK --set-mark $MARK
            sudo iptables -t mangle -D OUTPUT -o $INTERFACE -p udp --sport "$PORT" -j MARK --set-mark $MARK
        done

        echo "已解除端口 $REMOVE_PORTS 的限速规则。"
    else
        echo "无效选项，请输入 1 或 2"
    fi

elif [ "$CHOICE" -eq 3 ]; then
    # 查看当前配置
    if [ -f /tmp/traffic_config ] && [ -f /tmp/traffic_ports ]; then
        CONFIG=$(cat /tmp/traffic_config)
        PORTS=$(cat /tmp/traffic_ports)
        IFS=',' read -r TOTAL_BANDWIDTH RATE CEIL <<< "$CONFIG"
        echo "当前限速配置："
        echo "目标端口: $PORTS"
        echo "总带宽: ${TOTAL_BANDWIDTH}KBps"
        echo "单个 IP 限速: ${RATE}KBps"
        echo "允许的最大速率: ${CEIL}KBps"
    else
        echo "没有找到有效的限速配置文件。"
    fi

    echo "限速端口:"
    iptables -t mangle -L PREROUTING -v -n | grep "MARK set 0x$MARK" | awk '{print $13}' | sort -u

else
    echo "无效选项，请输入 1、2 或 3"
    exit 1
fi
