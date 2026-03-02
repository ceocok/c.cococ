#!/bin/sh

echo "=============================="
echo " Alpine Linux BBR 启用脚本"
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

# 2. 检查是否为容器
if grep -qa container=lxc /proc/1/environ 2>/dev/null; then
    echo "检测到 LXC/OpenVZ 容器环境，可能无法开启 BBR"
fi

# 3. 检查是否已有 bbr
AVAILABLE=$(sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null)

echo "当前可用拥塞算法: $AVAILABLE"

echo "$AVAILABLE" | grep -q bbr

if [ $? -ne 0 ]; then
    echo "当前内核未包含 BBR 模块"
    echo "尝试安装 linux-lts 内核..."

    apk update
    apk add linux-lts

    echo "已安装 linux-lts，请重启后重新运行此脚本"
    exit 0
fi

# 4. 写入 sysctl
echo "写入 sysctl 配置..."

if ! grep -q "net.core.default_qdisc" /etc/sysctl.conf; then
    echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
fi

if ! grep -q "net.ipv4.tcp_congestion_control" /etc/sysctl.conf; then
    echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
fi

# 5. 应用配置
sysctl -p

# 6. 验证
echo "当前拥塞控制算法:"
sysctl net.ipv4.tcp_congestion_control

echo "BBR 状态:"
lsmod | grep bbr

echo "=============================="
echo "如果显示 bbr，说明开启成功"
echo "=============================="
