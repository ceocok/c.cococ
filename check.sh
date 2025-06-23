#!/bin/bash

BARK_KEY="KGn8NVG2PLv5LheiXpBwYP"
BARK_API="https://api.day.app"
CPU_THRESHOLD=95
DISK_THRESHOLD=70
DEVICE="vda"

# 获取CPU利用率
CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')

# 获取磁盘利用率（%util）
UTIL=$(iostat -dx 1 2 | grep "$DEVICE" | tail -1 | awk '{print $(NF)}')

# 检查CPU或磁盘是否超过阈值
if (( $(echo "$CPU_USAGE >= $CPU_THRESHOLD" | bc -l) )); then
    curl -X "POST" "$BARK_API/$BARK_KEY" \
         -H 'Content-Type: application/json; charset=utf-8' \
         -d '{
           "body": "阿里云CPU使用已超: '"$CPU_USAGE"'%",
           "title": "阿里云警告",
           "badge": 1,
           "level": "critical",
           "icon": "https://c.cococ.co/xlogo.png.pagespeed.ic.--54fD7p5L.png"
         }'
fi

if (( $(echo "$UTIL >= $DISK_THRESHOLD" | bc -l) )); then
    curl -X "POST" "$BARK_API/$BARK_KEY" \
         -H 'Content-Type: application/json; charset=utf-8' \
         -d '{
           "body": "'"$DEVICE"' IO利用率已超: '"$UTIL"'%",
           "title": "阿里云磁盘IO警告",
           "badge": 1,
           "level": "critical",
           "icon": "https://c.cococ.co/xlogo.png.pagespeed.ic.--54fD7p5L.png"
         }'
fi
