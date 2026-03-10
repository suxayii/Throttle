#!/bin/bash
echo "正在查找 s-ui 进程..."
PID=$(pgrep -f "/usr/local/s-ui/sui")
if [ -z "$PID" ]; then
    echo "未找到 s-ui 进程"
    exit 1
fi

echo "找到 s-ui PID: $PID"
echo "设置 Nice 为 -20..."
renice -n -20 -p $PID >/dev/null

echo "设置实时调度 FIFO 90..."
chrt -f -p 90 $PID >/dev/null

echo "当前优先级状态："
ps -o pid,ni,cmd -p $PID

echo "实时调度状态："
chrt -p $PID

echo "完成！（实时优先级已设置为 90）"