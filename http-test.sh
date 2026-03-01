#!/bin/bash

# ====== 颜色定义 ======
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ====== 获取代理 ======
# 支持命令行参数：./te.sh http://user:pass@ip:port
PROXY=${1:-}
if [ -z "$PROXY" ]; then
    echo -e "${YELLOW}请输入代理地址 (例如 http://user:pass@ip:port 或 socks5://user:pass@ip:port):${NC}"
    read -p "> " PROXY
fi

if [ -z "$PROXY" ]; then
    echo -e "${RED}❌ 错误: 代理地址不能为空${NC}"
    exit 1
fi

# 500MB 测速文件
TEST_URL="https://speed.cloudflare.com/__down?bytes=524288000"

echo -e "\n${YELLOW}=============================="
echo "     HTTP/SOCKS5 代理测速工具 v2.1"
echo -e "     目标代理: $PROXY"
echo -e "==============================${NC}\n"

# 默认回车直接开始
read -p "确认开始测试吗? [Y/n]: " confirm
if [[ -n "$confirm" && ! "$confirm" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}已取消测试${NC}"
    exit 0
fi

echo -e "\n${GREEN}1️⃣ 测试连通性与延迟...${NC}"
latency_info=$(curl -x "$PROXY" -o /dev/null -s --connect-timeout 10 -m 15 -w \
"DNS解析: %{time_namelookup}s\n连接建立: %{time_connect}s\n首字节延迟: %{time_starttransfer}s\n总时间: %{time_total}s" \
https://speed.cloudflare.com)

if [ $? -ne 0 ]; then
    echo -e "${RED}❌ 代理连接失败${NC}"
    exit 1
fi

echo -e "${GREEN}✅ 代理连接成功！${NC}"
echo -e "$latency_info\n"

echo -e "${GREEN}2️⃣ 测试下载速度（500MB，限时60秒）...${NC}"

# 【核心修复】用 2>&1 + tail 可靠捕获速度，解决进度条干扰
speed_output=$(curl -x "$PROXY" -o /dev/null --progress-bar \
  --connect-timeout 10 -m 60 \
  -w "%{speed_download}\n" "$TEST_URL" 2>&1)

curl_status=$?
speed_bps=$(echo "$speed_output" | tail -n 1 | tr -d '\r\n ')

if [[ $curl_status -ne 0 && $curl_status -ne 28 ]]; then
    echo -e "\n${YELLOW}⚠️  下载过程异常 (curl退出码: $curl_status)${NC}"
fi

if [[ -z "$speed_bps" || "$speed_bps" == "0.000" ]]; then
    echo -e "\n${RED}❌ 测速失败：未获取到下载数据${NC}"
    exit 1
fi

speed_mbs=$(awk "BEGIN {printf \"%.2f\", $speed_bps / 1024 / 1024}")

echo -e "\n${GREEN}✅ 测速完成！平均下载速度: ${speed_mbs} MB/s${NC}"

# 保存日志
log_file="proxy_speed.log"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] $PROXY → ${speed_mbs} MB/s" >> "$log_file"
echo -e "${YELLOW}📝 测试结果已保存到 $log_file${NC}"