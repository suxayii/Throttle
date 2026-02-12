#!/bin/bash
# ==========================================================
# 中国大陆晚高峰网络质量增强诊断工具 (CN Peak Pro Edition)
# 专用于检测 VPS 在中国大陆晚高峰的真实使用情况
# ==========================================================

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[36m'
PLAIN='\033[0m'

LOG_FILE="/root/peak_test.log"

log() {
    echo -e "[$(date '+%F %T')] $1"
    echo "[$(date '+%F %T')] $1" >> "$LOG_FILE"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}必须使用 Root 运行${PLAIN}"
        exit 1
    fi
}

install_if_missing() {
    for cmd in mtr bc curl; do
        if ! command -v $cmd >/dev/null 2>&1; then
            if command -v apt >/dev/null; then
                apt update && apt install -y $cmd
            elif command -v yum >/dev/null; then
                yum install -y $cmd
            fi
        fi
    done
}

get_nic() {
    ip route show default 2>/dev/null | awk '/default/ {print $5; exit}'
}

bandwidth_check() {
    local nic=$1
    local rx1=$(cat /sys/class/net/$nic/statistics/rx_bytes)
    local tx1=$(cat /sys/class/net/$nic/statistics/tx_bytes)
    local drop1=$(cat /sys/class/net/$nic/statistics/rx_dropped 2>/dev/null || echo 0)
    sleep 1
    local rx2=$(cat /sys/class/net/$nic/statistics/rx_bytes)
    local tx2=$(cat /sys/class/net/$nic/statistics/tx_bytes)
    local drop2=$(cat /sys/class/net/$nic/statistics/rx_dropped 2>/dev/null || echo 0)

    local rx_speed=$(( (rx2 - rx1) / 1024 ))
    local tx_speed=$(( (tx2 - tx1) / 1024 ))
    local drop_diff=$(( drop2 - drop1 ))

    log "实时流量: RX=${rx_speed}KB/s TX=${tx_speed}KB/s"
    if (( drop_diff > 0 )); then
        echo -e "${RED}严重警告: 检测到网卡丢包增长 (RX_dropped +${drop_diff}/s)${PLAIN}"
        log "WARNING: RX_dropped increased by ${drop_diff}"
        echo -e "${YELLOW}建议运行 install.sh -> 12) 网卡/系统级深度优化 以增加 Ring Buffer${PLAIN}"
    else
        echo -e "${GREEN}丢包监控: 正常 (无新增丢包)${PLAIN}"
    fi
}

ping_test() {
    local ip=$1
    local desc=$2

    local res=$(ping -c 20 -i 0.2 -q "$ip" 2>/dev/null)
    # 退出码非0 或 找不到 rtt 行（说明100%丢失）
    if [ $? -ne 0 ] || ! echo "$res" | grep -q "rtt"; then
        echo "100 999 999"
        return
    fi

    # 使用 awk 提取丢包率，兼容性更好
    local loss=$(echo "$res" | awk -F', ' '/packet loss/ {print $3}' | awk '{print $1}' | tr -d '%')
    # 备用提取逻辑
    if [[ -z "$loss" ]]; then
       loss=$(echo "$res" | grep -oE '[0-9]+% packet loss' | awk '{print $1}' | tr -d '%')
    fi

    local rtt=$(echo "$res" | grep "rtt")
    local avg=$(echo "$rtt" | awk -F'/' '{print $5}')
    local mdev=$(echo "$rtt" | awk -F'/' '{print $7}' | awk '{print $1}')
    
    # 防止空值导致后续计算报错
    [[ -z "$loss" ]] && loss=100
    [[ -z "$avg" ]] && avg=999
    [[ -z "$mdev" ]] && mdev=999

    echo "$loss $avg $mdev"
}

tcp_test() {
    local ip=$1
    curl -o /dev/null -s -w "%{time_connect}\n" http://$ip 2>/dev/null
}

bufferbloat_test() {
    log "开始 Bufferbloat 测试..."
    local idle=$(ping -c 10 -q 223.5.5.5 | grep rtt | awk -F'/' '{print $5}')
    wget -O /dev/null http://speedtest.tele2.net/10MB.zip >/dev/null 2>&1 &
    sleep 2
    local load=$(ping -c 10 -q 223.5.5.5 | grep rtt | awk -F'/' '{print $5}')
    killall wget >/dev/null 2>&1

    log "空闲延迟: ${idle}ms"
    log "满载延迟: ${load}ms"

    diff=$(echo "$load - $idle" | bc)
    if (( $(echo "$diff > 100" | bc -l) )); then
        echo -e "${RED}严重 Bufferbloat (${diff}ms)${PLAIN}"
    elif (( $(echo "$diff > 30" | bc -l) )); then
        echo -e "${YELLOW}中度 Bufferbloat (${diff}ms)${PLAIN}"
    else
        echo -e "${GREEN}Bufferbloat 正常${PLAIN}"
    fi
}

score_calc() {
    local loss=$1
    local jitter=$2
    score=10

    if (( loss > 5 )); then score=$((score-3)); fi
    if (( $(echo "$jitter > 30" | bc -l) )); then score=$((score-2)); fi
    if (( loss > 20 )); then score=2; fi

    echo $score
}

start_test() {
    clear
    echo -e "${BLUE}====== 中国大陆晚高峰增强诊断 ======${PLAIN}"
    log "开始测试"

    local nic=$(get_nic)
    [ -z "$nic" ] && nic="eth0"

    echo -e "\n${YELLOW}[1/6] 系统资源检查${PLAIN}"
    load=$(awk '{print $1}' /proc/loadavg)
    mem=$(free -m | awk '/Mem:/ {print $3"/"$2"MB"}')
    tcp=$(ss -tun state established | wc -l)

    log "负载: $load"
    log "内存: $mem"
    log "TCP连接: $tcp"

    rx_drop=$(cat /sys/class/net/$nic/statistics/rx_dropped)
    tx_drop=$(cat /sys/class/net/$nic/statistics/tx_dropped)
    log "网卡丢包: RX=$rx_drop TX=$tx_drop"

    bandwidth_check $nic

    # 检查 TC 规则 (新增)
    if command -v tc >/dev/null; then
        local tc_qdisc=$(tc qdisc show dev $nic 2>/dev/null | head -n 1)
        if [[ -n "$tc_qdisc" ]]; then
            log "当前流量控制 (TC): $tc_qdisc"
            if echo "$tc_qdisc" | grep -qE "htb|tbf|prio"; then
                echo -e "${RED}警告: 检测到活跃的限速规则 (htb/tbf)，这可能是速度异常的原因！${PLAIN}"
                log "警告: 检测到限速规则"
            fi
        fi
    fi

    echo -e "\n${YELLOW}[2/6] 三网 Ping 测试${PLAIN}"

    targets=(
    "202.96.134.133 电信"
    "210.21.196.6 联通"
    "221.179.155.161 移动"
    )

    printf "%-15s %-8s %-8s %-8s %-8s\n" "IP" "运营商" "丢包" "延迟" "评分"

    for item in "${targets[@]}"; do
        ip=$(echo $item | awk '{print $1}')
        isp=$(echo $item | awk '{print $2}')
        read loss avg jitter <<< $(ping_test $ip $isp)
        score=$(score_calc $loss $jitter)

        printf "%-15s %-8s %-8s %-8s %-8s\n" "$ip" "$isp" "${loss}%" "${avg}ms" "$score/10"
    done

    echo -e "\n${YELLOW}[3/6] TCP 连接延迟测试${PLAIN}"
    tcp_time=$(tcp_test 223.5.5.5)
    log "TCP建连时间: ${tcp_time}s"

    echo -e "\n${YELLOW}[4/6] MTR 路由检测${PLAIN}"
    mtr -r -c 20 223.5.5.5 | head -n 15

    echo -e "\n${YELLOW}[5/6] Bufferbloat 检测${PLAIN}"
    bufferbloat_test

    echo -e "\n${YELLOW}[6/6] 综合诊断${PLAIN}"
    echo "--------------------------------------------------"
    echo "如果移动评分低，晚高峰不适合移动用户"
    echo "如果三网都低，说明 VPS 出口拥塞"
    echo "如果 TCP 高但 ICMP 正常，可能 QoS 限速"
    echo "--------------------------------------------------"

    log "测试结束"
    echo -e "${GREEN}测试完成，日志: $LOG_FILE${PLAIN}"
}

install_if_missing
check_root
start_test
