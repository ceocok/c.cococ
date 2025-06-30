#!/bin/bash

# 仅 root 可执行
if [[ $EUID -ne 0 ]]; then
    echo "❌ 请以 root 权限运行此脚本"
    exit 1
fi

DNS_CONTENT="nameserver 144.24.24.42
nameserver 137.131.50.50
nameserver 1.1.1.1
nameserver 8.8.8.8"

RESOLVED_CONF="/etc/systemd/resolved.conf"
RESOLV_CONF="/etc/resolv.conf"
BACKUP_RESOLVED="${RESOLVED_CONF}.bak"
BACKUP_RESOLV="${RESOLV_CONF}.bak"

echo "🛠️ 请选择操作："
echo "1) 🔓 启用 DNS 解锁（修改 DNS）"
echo "2) 🔁 恢复默认 DNS 配置"
echo "3) 🔍 查询当前 DNS 配置"
read -rp "请输入选项编号 [1-3]: " choice

if [[ "$choice" == "1" ]]; then
    echo "🔧 正在设置 DNS 解锁配置..."

    if grep -qi "alpine" /etc/os-release; then
        echo "🔧 检测到 Alpine 系统，正在配置 /etc/resolv.conf ..."
    else
        if [ -f "$RESOLVED_CONF" ] && command -v systemctl &>/dev/null; then
            echo "🔧 检测到 systemd-resolved，正在配置..."
            # 备份配置（覆盖旧备份）
            cp "$RESOLVED_CONF" "$BACKUP_RESOLVED"

            sed -i '/^\[Resolve\]/,/^\[.*\]/s/^DNS=.*$/DNS=144.24.24.42 137.131.50.50/' "$RESOLVED_CONF"
            sed -i '/^\[Resolve\]/,/^\[.*\]/s/^FallbackDNS=.*$/FallbackDNS=1.1.1.1 8.8.8.8/' "$RESOLVED_CONF"
            grep -q "^DNS=" "$RESOLVED_CONF" || sed -i '/^\[Resolve\]/a DNS=144.24.24.42 137.131.50.50' "$RESOLVED_CONF"
            grep -q "^FallbackDNS=" "$RESOLVED_CONF" || sed -i '/^\[Resolve\]/a FallbackDNS=1.1.1.1 8.8.8.8' "$RESOLVED_CONF"
            sed -i 's/^#*DNSStubListener=.*/DNSStubListener=no/' "$RESOLVED_CONF"

            ln -sf /run/systemd/resolve/resolv.conf "$RESOLV_CONF"
            systemctl restart systemd-resolved
        fi
    fi

    if [ ! -e "$RESOLV_CONF" ]; then
        echo "⛑️ /etc/resolv.conf 不存在，正在创建..."
        touch "$RESOLV_CONF"
    fi

    if [ -L "$RESOLV_CONF" ] && [ ! -e "$(readlink -f $RESOLV_CONF)" ]; then
        echo "🔧 检测到无效符号链接，正在修复..."
        rm -f "$RESOLV_CONF"
        touch "$RESOLV_CONF"
    fi

    # 备份 resolv.conf
    cp "$RESOLV_CONF" "$BACKUP_RESOLV"
    echo "$DNS_CONTENT" > "$RESOLV_CONF"

    echo "✅ DNS 设置完成。当前内容如下："
    cat "$RESOLV_CONF"

    echo -e "\n🌐 测试 DNS 查询 google.com ："
    dig +short google.com || nslookup google.com

elif [[ "$choice" == "2" ]]; then
    echo "🔁 正在恢复默认 DNS 设置..."

    # 恢复 /etc/systemd/resolved.conf
    if [ -f "$BACKUP_RESOLVED" ]; then
        echo "✅ 正在恢复 $RESOLVED_CONF"
        cp "$BACKUP_RESOLVED" "$RESOLVED_CONF"
    else
        echo "⚠️ 未找到 $BACKUP_RESOLVED，使用默认空配置恢复"
        echo -e "[Resolve]\nDNS=\nFallbackDNS=\nDNSStubListener=yes" > "$RESOLVED_CONF"
    fi

    # 恢复 /etc/resolv.conf 为 systemd 默认 stub 链接
    echo "🔄 正在恢复 /etc/resolv.conf 为默认符号链接..."
    rm -f "$RESOLV_CONF"
    ln -s /run/systemd/resolve/stub-resolv.conf "$RESOLV_CONF"

    # 重启服务
    systemctl restart systemd-resolved

    echo "🎉 DNS 配置已恢复为 systemd 默认状态"
    echo -e "\n📄 当前 resolv.conf 内容："
    cat "$RESOLV_CONF"

elif [[ "$choice" == "3" ]]; then
    echo "🔍 当前系统 DNS 配置如下："
    echo "----------------------------"
    if command -v systemd-resolve &>/dev/null; then
        systemd-resolve --status | grep -A2 'DNS Servers'
    elif command -v resolvectl &>/dev/null; then
        resolvectl status | grep 'DNS Servers\|Fallback DNS Servers'
    else
        echo "📄 /etc/resolv.conf 内容："
        cat "$RESOLV_CONF"
    fi
    echo -e "\n🌐 测试 DNS 查询 google.com ："
    dig +short google.com || nslookup google.com

else
    echo "❌ 无效输入，请输入 1-3"
    exit 1
fi
