#!/bin/sh

echo "=============================="
echo " Alpine Linux BBR 自动开启脚本"
echo "=============================="

# 1. 检查内核版本
KERNEL=$(uname -r)
echo "当前内核版本: $KERNEL"
MAJOR=$(echo $KERNEL | cut -d. -f1)
MINOR=$(echo $KERNEL | cut -d. -f2)

if [ "$MAJOR" -lt 4 ] || { [ "$MAJOR" -eq 4 ] && [ "$MINOR" -lt 9 ]; }; then
    echo "错误: 内核版本低于 4.9，不支持 BBR"
    exit 1
fi

# 2. 检查容器环境
if grep -qa container=lxc /proc/1/environ 2>/dev/null; then
    echo "⚠️ 检测到 LXC/OpenVZ 容器环境，可能无法开启 BBR"
fi

# 3. 尝试加载 tcp_bbr 模块
echo "尝试加载 tcp_bbr 模块..."
modprobe tcp_bbr 2>/dev/null

# 4. 检查可用拥塞算法
AVAILABLE=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)
echo "当前可用拥塞算法: $AVAILABLE"

echo "$AVAILABLE" | grep -q bbr
if [ $? -ne 0 ]; then
    echo "⚠️ 内核尚未包含 BBR 模块或未加载成功"
    echo "请确保你使用的内核是 Alpine LTS 或支持 BBR 的内核"
fi

# 5. 写入 sysctl 配置
echo "写入 sysctl 配置..."
grep -q "net.core.default_qdisc" /etc/sysctl.conf || echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
grep -q "net.ipv4.tcp_congestion_control" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf

# 6. 应用配置
sysctl -p

# 7. 验证结果
CURRENT=$(sysctl -n net.ipv4.tcp_congestion_control)
echo "当前拥塞控制算法: $CURRENT"

echo "BBR 状态:"
lsmod | grep bbr

if [ "$CURRENT" = "bbr" ]; then
    echo "✅ BBR 已成功开启"
else
    echo "❌ BBR 未开启，可能内核不支持"
fi

echo "=============================="
