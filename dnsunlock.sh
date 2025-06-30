#!/bin/bash

# 仅 root 可执行
if [[ $EUID -ne 0 ]]; then
   echo "❌ 请以 root 权限运行此脚本"
   exit 1
fi

# 要写入的 DNS 配置
DNS_CONTENT="nameserver 144.24.24.42
nameserver 137.131.50.50
nameserver 1.1.1.1
nameserver 8.8.8.8"

# 检查是否为 Alpine
if grep -qi "alpine" /etc/os-release; then
    echo "🔧 检测到 Alpine 系统，正在配置 /etc/resolv.conf ..."
else
    # 非 Alpine 再判断是否有 systemd-resolved
    if [ -f /etc/systemd/resolved.conf ] && command -v systemctl &>/dev/null; then
        echo "🔧 检测到 systemd-resolved，正在配置..."

        RESOLVED_CONF="/etc/systemd/resolved.conf"
        cp "$RESOLVED_CONF" "${RESOLVED_CONF}.bak.$(date +%F-%H%M%S)"

        sed -i '/^\[Resolve\]/,/^\[.*\]/s/^DNS=.*$/DNS=144.24.24.42 137.131.50.50/' "$RESOLVED_CONF"
        sed -i '/^\[Resolve\]/,/^\[.*\]/s/^FallbackDNS=.*$/FallbackDNS=1.1.1.1 8.8.8.8/' "$RESOLVED_CONF"
        grep -q "^DNS=" "$RESOLVED_CONF" || sed -i '/^\[Resolve\]/a DNS=144.24.24.42 137.131.50.50' "$RESOLVED_CONF"
        grep -q "^FallbackDNS=" "$RESOLVED_CONF" || sed -i '/^\[Resolve\]/a FallbackDNS=1.1.1.1 8.8.8.8' "$RESOLVED_CONF"
        sed -i 's/^#*DNSStubListener=.*/DNSStubListener=no/' "$RESOLVED_CONF"

        ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
        systemctl restart systemd-resolved

        echo "✅ DNS 设置完成。当前状态如下："
        command -v resolvectl &>/dev/null && resolvectl status | grep 'DNS Servers\|Fallback DNS Servers'
        exit 0
    fi
fi

# 通用 fallback 逻辑（直接写入 /etc/resolv.conf）

echo "⚠️ 未检测到 systemd-resolved，直接配置 /etc/resolv.conf ..."

# 处理不存在的 /etc/resolv.conf
if [ ! -e /etc/resolv.conf ]; then
    echo "⛑️ /etc/resolv.conf 不存在，正在创建..."
    touch /etc/resolv.conf
fi

# 如果是损坏的符号链接，移除重建
if [ -L /etc/resolv.conf ] && [ ! -e "$(readlink -f /etc/resolv.conf)" ]; then
    echo "🔧 检测到无效的符号链接，正在修复..."
    rm -f /etc/resolv.conf
    touch /etc/resolv.conf
fi

# 备份旧文件
cp /etc/resolv.conf "/etc/resolv.conf.bak.$(date +%F-%H%M%S)"

# 写入 DNS 内容
echo "$DNS_CONTENT" > /etc/resolv.conf

echo "✅ DNS 设置完成。当前内容如下："
cat /etc/resolv.conf
