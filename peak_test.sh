#!/bin/bash
# ==========================================
# 晚高峰网络状况诊断工具 (Peak Test)
# 用于诊断网络拥塞、丢包和延迟抖动
# ==========================================

# 颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[36m'
PLAIN='\033[0m'

LOG_FILE="/root/peak_test.log"

log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误: 必须使用 Root 权限运行${PLAIN}"
        exit 1
    fi
}

start_test() {
    clear
    echo -e "${BLUE}=======================================${PLAIN}"
    echo -e "${BLUE}    晚高峰网络诊断工具 (Peak Test)    ${PLAIN}"
    echo -e "${BLUE}=======================================${PLAIN}"
    log "开始新一轮测试..."

    # 1. 系统负载检查
    echo -e "\n${YELLOW}[1/4] 系统资源检查...${PLAIN}"
    local load=$(awk '{print $1}' /proc/loadavg)
    local mem_used=$(free -m | awk '/Mem:/ {print $3}')
    local mem_total=$(free -m | awk '/Mem:/ {print $2}')
    local tcp_est=$(ss -tun state established | wc -l)
    local tcp_tw=$(ss -tun state time-wait | wc -l)

    log "系统负载 (1min): $load"
    log "内存使用: ${mem_used}MB / ${mem_total}MB"
    log "TCP连接数: ESTABLISHED=$tcp_est, TIME-WAIT=$tcp_tw"

    # 网卡丢包检查
    local nic=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    [ -z "$nic" ] && nic="eth0"
    if [ -d "/sys/class/net/$nic/statistics" ]; then
        local rx_dropped=$(cat /sys/class/net/$nic/statistics/rx_dropped)
        local tx_dropped=$(cat /sys/class/net/$nic/statistics/tx_dropped)
        log "网卡 ($nic) 丢包统计: RX_dropped=$rx_dropped, TX_dropped=$tx_dropped"
    fi

    # 2. 关键目标 Ping 测试
    echo -e "\n${YELLOW}[2/4] 关键节点延迟/丢包测试... (每个目标 Ping 20 次)${PLAIN}"
    
    # 定义测试目标 (CN 优化 + 国际通用)
    local targets=("223.5.5.5:阿里云DNS" "119.29.29.29:腾讯云DNS" "1.1.1.1:Cloudflare" "8.8.8.8:Google")
    
    printf "%-15s %-12s %-10s %-10s %-10s\n" "目标" "备注" "丢包率" "平均延迟" "抖动"
    echo "-------------------------------------------------------------"
    
    for item in "${targets[@]}"; do
        local ip=${item%%:*}
        local desc=${item##*:}
        
        # 使用 ping -c 20 -i 0.2 快速发送20个包
        local res=$(ping -c 20 -i 0.2 -q "$ip" 2>/dev/null)
        
        if [ $? -eq 0 ]; then
            local loss=$(echo "$res" | grep -oP '\d+(?=% packet loss)')
            local rtt_line=$(echo "$res" | grep "rtt min/avg/max/mdev")
            # 提取 avg 和 mdev
            local avg=$(echo "$rtt_line" | awk -F'/' '{print $5}')
            local mdev=$(echo "$rtt_line" | awk -F'/' '{print $7}' | awk '{print $1}')
            
            printf "%-15s %-12s %-10s %-10s %-10s\n" "$ip" "$desc" "${loss}%" "${avg}ms" "${mdev}ms"
            log "Ping $ip ($desc): Loss=${loss}%, Avg=${avg}ms, Jitter=${mdev}ms"
        else
            printf "%-15s %-12s %-10s %-10s %-10s\n" "$ip" "$desc" "100%" "N/A" "N/A"
            log "Ping $ip ($desc): 100% Loss (不可达)"
        fi
    done

    # 3. 简单的回程路由测试 (可选，仅测一跳)
    echo -e "\n${YELLOW}[3/4] 简易路由跳数测试 (Trace)...${PLAIN}"
    # 这里的思路是看第一跳是否超时，判断是否本地网络问题
    local trace_res=$(traceroute -n -w 1 -q 1 -m 5 223.5.5.5 2>/dev/null | tail -n+2 | head -n 3)
    echo "$trace_res"
    log "Traceroute (前3跳):\n$trace_res"

    echo -e "\n${YELLOW}[4/4] 诊断建议${PLAIN}"
    echo "-------------------------------------------------------------"
    echo "1. 如果 '丢包率' > 5% 或 '抖动' > 30ms，说明当前网络拥塞严重。"
    echo "2. 如果 '抖动' 很大但没有丢包，可能是缓冲区过大 (Bufferbloat)。"
    echo "3. 建议在 install.sh 中切换到 'UDP 专项版' 或 '低内存版' 减少缓冲区。"
    echo "-------------------------------------------------------------"
    log "测试结束。"
    echo -e "${GREEN}测试完成！日志已保存至: $LOG_FILE${PLAIN}"
}

# 检查依赖
command -v ping >/dev/null 2>&1 || { echo "缺少 ping 命令"; exit 1; }
command -v ss >/dev/null 2>&1 || { echo "缺少 ss 命令"; exit 1; }
command -v traceroute >/dev/null 2>&1 || { 
    if [ -x "$(command -v apt)" ]; then apt update && apt install -y traceroute; 
    elif [ -x "$(command -v yum)" ]; then yum install -y traceroute;
    else echo "建议安装 traceroute 获取更详细信息"; fi 
}

check_root
start_test
