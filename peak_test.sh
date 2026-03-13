#!/bin/bash
# ==========================================================
# 中国大陆晚高峰网络质量增强诊断工具 (CN Peak Pro v2.2)
# 优化版：修复TCP测试 + 增强评分算法 + 修复Locale + 新增路由推断
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
    for cmd in mtr bc curl wget; do
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
        echo -e "${YELLOW}建议运行 ethtool 或调整 netdev_max_backlog 增加 Ring Buffer${PLAIN}"
    else
        echo -e "${GREEN}丢包监控: 正常 (无新增丢包)${PLAIN}"
    fi
}

ping_test() {
    local ip=$1
    local desc=$2

    # 使用 LC_ALL=C 强制标准 POSIX 英文输出，杜绝多语言环境导致的 grep 失效
    local res=$(LC_ALL=C ping -c 20 -i 0.2 -q "$ip" 2>/dev/null)
    
    if [ $? -ne 0 ] || ! echo "$res" | grep -qi "rtt"; then
        echo "100 999 999"
        return
    fi

    # 提取丢包率：精准匹配并提取数字
    local loss=$(echo "$res" | grep -i "packet loss" | awk -F'%' '{print $1}' | awk '{print $NF}')
    
    # 提取 RTT 延迟：提取 avg 和 mdev(抖动)
    local rtt_vals=$(echo "$res" | grep -i "rtt" | awk -F'=' '{print $2}')
    local avg=$(echo "$rtt_vals" | awk -F'/' '{print $2}')
    local mdev=$(echo "$rtt_vals" | awk -F'/' '{print $4}' | awk '{print $1}')
    
    # 兜底机制
    [[ -z "$loss" ]] && loss=100
    [[ -z "$avg" ]] && avg=999
    [[ -z "$mdev" ]] && mdev=999

    echo "$loss $avg $mdev"
}

tcp_test() {
    local target=$1
    # 修复版：使用 baidu.com + 超时保护 + 强制IPv4
    curl -o /dev/null -s -w "%{time_connect}\n" --max-time 3 -4 "http://$target" 2>/dev/null || echo "超时"
}

# ==================== 增强版评分算法 ====================
score_calc() {
    local loss=$1
    local avg=$2      # 平均延迟权重
    local jitter=$3
    local score=10

    # 原有逻辑
    if (( loss > 5 )); then score=$((score-3)); fi
    if (( $(echo "$jitter > 30" | bc -l) )); then score=$((score-2)); fi
    if (( loss > 20 )); then score=2; fi

    # 新增：平均延迟惩罚（晚高峰核心体验）
    if (( $(echo "$avg > 200" | bc -l) )); then 
        score=$((score-4))
    elif (( $(echo "$avg > 150" | bc -l) )); then 
        score=$((score-2))
    fi

    # 防止负分
    (( score < 0 )) && score=0
    echo $score
}

# ==================== 回程路由智能推断 ====================
route_analysis() {
    local ip=$1
    local isp=$2
    # 运行 MTR 提取 IP 路径 (只发2个包加快探测速度)
    local trace=$(mtr -4 -n -c 2 -r "$ip" 2>/dev/null)
    local route_type="${RED}未知 / 疑似绕路${PLAIN}"

    case "$isp" in
        "电信")
            if echo "$trace" | grep -q "59.43."; then
                route_type="${GREEN}CN2 优质直连 (特征: 59.43.*)${PLAIN}"
            elif echo "$trace" | grep -q "202.97."; then
                route_type="${YELLOW}163 骨干直连 (特征: 202.97.*)${PLAIN}"
            fi
            ;;
        "联通")
            if echo "$trace" | grep -qE "218.105.|210.51."; then
                route_type="${GREEN}AS9929 优质直连 (CUPM)${PLAIN}"
            elif echo "$trace" | grep -q "219.158."; then
                route_type="${YELLOW}AS4837 骨干直连${PLAIN}"
            fi
            ;;
        "移动")
            if echo "$trace" | grep -q "58.253."; then
                route_type="${GREEN}CMIN2 优质直连 (AS58453)${PLAIN}"
            elif echo "$trace" | grep -q "223.120."; then
                route_type="${YELLOW}CMI 骨干直连 (特征: 223.120.*)${PLAIN}"
            fi
            ;;
    esac

    # 兜底检测：如果跳数异常多，大概率是绕路
    local hops=$(echo "$trace" | grep -v "Start" | grep -v "HOST" | wc -l)
    if (( hops > 22 )); then
        route_type="${RED}严重绕路 (跳数 $hops > 22)${PLAIN}"
    fi
    
    # 如果没匹配到高端特征，但跳数在正常范围内
    if [[ "$route_type" == "${RED}未知 / 疑似绕路${PLAIN}" && $hops -le 22 ]]; then
        route_type="${YELLOW}普通直连 / 动态中转线路${PLAIN}"
    fi

    echo "$route_type"
}

bufferbloat_test() {
    log "开始 Bufferbloat 测试..."
    
    # 测量空闲延迟
    local idle=$(LC_ALL=C ping -c 10 -q 223.5.5.5 | grep -i rtt | awk -F'=' '{print $2}' | awk -F'/' '{print $2}')
    
    # 使用 1GB 测速文件确保大带宽也能被占满
    wget -O /dev/null http://speedtest.tele2.net/1GB.zip >/dev/null 2>&1 &
    local wget_pid=$!
    
    # 给 TCP 拥塞控制算法提速预留 3 秒
    sleep 3 
    
    # 测量满载延迟
    local load=$(LC_ALL=C ping -c 10 -q 223.5.5.5 | grep -i rtt | awk -F'=' '{print $2}' | awk -F'/' '{print $2}')
    
    # 精准结束后台的 wget 测试进程
    kill $wget_pid >/dev/null 2>&1

    # 兜底防止空值运算报错
    [[ -z "$idle" ]] && idle=0
    [[ -z "$load" ]] && load=0

    log "空闲延迟: ${idle}ms"
    log "满载延迟: ${load}ms"

    local diff=$(echo "$load - $idle" | bc)
    if (( $(echo "$diff > 100" | bc -l) )); then
        echo -e "${RED}严重 Bufferbloat (${diff}ms) -> 建议开启 BBR 或 SQM${PLAIN}"
    elif (( $(echo "$diff > 30" | bc -l) )); then
        echo -e "${YELLOW}中度 Bufferbloat (${diff}ms)${PLAIN}"
    else
        echo -e "${GREEN}Bufferbloat 正常 (${diff}ms)${PLAIN}"
    fi
}

start_test() {
    clear
    echo -e "${BLUE}====== 中国大陆晚高峰增强诊断 (v2.2) ======${PLAIN}"
    log "开始测试（优化版）"

    local nic=$(get_nic)
    [ -z "$nic" ] && nic="eth0"

    echo -e "\n${YELLOW}[1/7] 系统资源检查${PLAIN}"
    local load=$(awk '{print $1}' /proc/loadavg)
    local mem=$(free -m | awk '/Mem:/ {print $3"/"$2"MB"}')
    local tcp=$(ss -tun state established | wc -l)

    log "负载: $load"
    log "内存: $mem"
    log "TCP连接: $tcp"

    local rx_drop=$(cat /sys/class/net/$nic/statistics/rx_dropped)
    local tx_drop=$(cat /sys/class/net/$nic/statistics/tx_dropped)
    log "网卡丢包: RX=$rx_drop TX=$tx_drop"

    bandwidth_check $nic

    if command -v tc >/dev/null; then
        local tc_qdisc=$(tc qdisc show dev $nic 2>/dev/null | head -n 1)
        if [[ -n "$tc_qdisc" && "$tc_qdisc" =~ htb|tbf|prio ]]; then
            echo -e "${RED}警告: 检测到活跃的限速规则 (htb/tbf)，可能是速度异常主因！${PLAIN}"
            log "警告: 检测到限速规则"
        fi
    fi

    echo -e "\n${YELLOW}[2/7] 三网 Ping 测试${PLAIN}"

    local targets=(
    "223.215.161.220 电信"
    "211.91.88.175 联通"
    "221.179.155.161 移动"
    )

    printf "%-15s %-8s %-8s %-8s %-8s %-8s\n" "IP" "运营商" "丢包" "延迟" "抖动" "评分"

    local ip isp loss avg jitter score
    for item in "${targets[@]}"; do
        ip=$(echo $item | awk '{print $1}')
        isp=$(echo $item | awk '{print $2}')
        read loss avg jitter <<< $(ping_test $ip $isp)
        score=$(score_calc $loss $avg $jitter)   # ← 增强版调用

        printf "%-15s %-8s %-8s %-8s %-8s %-8s\n" "$ip" "$isp" "${loss}%" "${avg}ms" "${jitter}ms" "$score/10"
    done

    echo -e "\n${YELLOW}[3/7] TCP 连接延迟测试${PLAIN}"
    local tcp_time=$(tcp_test www.baidu.com)   # ← 已修复
    log "TCP建连时间: ${tcp_time}s"
    if [[ "$tcp_time" == "超时" ]]; then
        echo -e "${RED}TCP建连超时（可能出口限制）${PLAIN}"
    else
        echo -e "TCP建连时间: ${tcp_time}s"
    fi

    echo -e "\n${YELLOW}[4/7] 基础 MTR 路由检测 (原始数据)${PLAIN}"
    mtr -r -c 10 223.5.5.5 | head -n 20

    echo -e "\n${YELLOW}[5/7] 三网回程路由智能分析 (核心指标)${PLAIN}"
    printf "%-6s %-16s %s\n" "运营商" "目标测试IP" "推测线路类型"
    echo "--------------------------------------------------"
    local route_res
    for item in "${targets[@]}"; do
        ip=$(echo $item | awk '{print $1}')
        isp=$(echo $item | awk '{print $2}')
        route_res=$(route_analysis "$ip" "$isp")
        printf "%-9s %-16s %b\n" "$isp" "$ip" "$route_res"
    done
    echo "--------------------------------------------------"

    echo -e "\n${YELLOW}[6/7] Bufferbloat 检测${PLAIN}"
    bufferbloat_test

    echo -e "\n${YELLOW}[7/7] 综合诊断${PLAIN}"
    echo "--------------------------------------------------"
    echo "移动评分低  → 晚高峰不适合移动用户"
    echo "线路遇绕路  → 建议更换 CN2 GIA/AS9929 等优质线路"
    echo "TCP高但ICMP正常 → 可能是QoS/限速"
    echo "评分<5分    → 晚高峰体验较差"
    echo "--------------------------------------------------"

    log "测试结束（v2.2）"
    echo -e "${GREEN}测试完成！日志: $LOG_FILE${PLAIN}"
    echo -e "${YELLOW}建议：晚高峰 20:00-22:00 运行效果最佳${PLAIN}"
}

install_if_missing
check_root
start_test