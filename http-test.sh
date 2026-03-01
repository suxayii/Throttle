#!/bin/bash

# ====== 颜色定义 ======
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ====== 获取代理 ======
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
echo "     HTTP/SOCKS5 代理测速工具 v2.2（最终稳定版）"
echo -e "     目标代理: $PROXY"
echo -e "==============================${NC}\n"

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

# 使用临时文件捕获速度（最稳定方式）
speed_file=$(mktemp)
trap 'rm -f "$speed_file"' EXIT   # 自动清理

curl -x "$PROXY" -o /dev/null --progress-bar \
     --connect-timeout 10 -m 60 \
     -w "%{speed_download}" "$TEST_URL" > "$speed_file"

curl_status=$?
speed_bps=$(tr -d '\r\n ' < "$speed_file")

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