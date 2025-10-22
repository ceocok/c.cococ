#!/bin/bash

# 安全交互式修改 SSH 端口脚本
# 支持 Debian / Ubuntu / Alpine
# 会在修改前尝试临时监听新端口，失败自动回滚

# 检查是否以 root 运行
if [[ $EUID -ne 0 ]]; then
   echo "请使用 root 或 sudo 运行此脚本"
   exit 1
fi

SSH_CONFIG="/etc/ssh/sshd_config"
if [[ ! -f "$SSH_CONFIG" ]]; then
    echo "未找到 sshd 配置文件，脚本终止"
    exit 1
fi

# 备份配置文件
BACKUP_FILE="${SSH_CONFIG}.bak_$(date +%F_%T)"
cp "$SSH_CONFIG" "$BACKUP_FILE"
echo "已备份原配置文件到 $BACKUP_FILE"

# 获取当前 SSH 端口
CURRENT_PORT=$(grep "^Port" $SSH_CONFIG | awk '{print $2}')
if [[ -z "$CURRENT_PORT" ]]; then
    CURRENT_PORT=22
fi
echo "当前 SSH 端口: $CURRENT_PORT"

# 输入新端口
while true; do
    read -p "请输入新的 SSH 端口 (1024-65535): " NEW_PORT
    if [[ "$NEW_PORT" =~ ^[0-9]+$ ]] && [ "$NEW_PORT" -ge 22 ] && [ "$NEW_PORT" -le 65535 ]; then
        # 检查端口是否被占用
        if command -v ss >/dev/null 2>&1; then
            ss -tuln | grep -q ":$NEW_PORT " && echo "端口 $NEW_PORT 已被占用，请选择其他端口" && continue
        elif command -v netstat >/dev/null 2>&1; then
            netstat -tuln | grep -q ":$NEW_PORT " && echo "端口 $NEW_PORT 已被占用，请选择其他端口" && continue
        fi
        break
    else
        echo "端口号无效，请输入 22-65535 之间的数字"
    fi
done

# 修改配置文件
if grep -q "^Port " $SSH_CONFIG; then
    sed -i "s/^Port .*/Port $NEW_PORT/" $SSH_CONFIG
else
    echo "Port $NEW_PORT" >> $SSH_CONFIG
fi

# 放行防火墙端口
if command -v ufw >/dev/null 2>&1; then
    ufw allow $NEW_PORT/tcp
elif command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport $NEW_PORT -j ACCEPT 2>/dev/null || \
    iptables -I INPUT -p tcp --dport $NEW_PORT -j ACCEPT
fi

# 临时测试 SSH 新端口
echo "正在临时测试新端口 $NEW_PORT 可用性..."
if command -v systemctl >/dev/null 2>&1; then
    systemctl restart ssh || systemctl restart sshd
else
    service ssh restart || service sshd restart
fi

sleep 2

# 测试端口是否能监听
if command -v ss >/dev/null 2>&1; then
    if ! ss -tuln | grep -q ":$NEW_PORT "; then
        echo "新端口启动失败，回滚到原端口 $CURRENT_PORT"
        sed -i "s/^Port .*/Port $CURRENT_PORT/" $SSH_CONFIG
        if command -v systemctl >/dev/null 2>&1; then
            systemctl restart ssh || systemctl restart sshd
        else
            service ssh restart || service sshd restart
        fi
        exit 1
    fi
elif command -v netstat >/dev/null 2>&1; then
    if ! netstat -tuln | grep -q ":$NEW_PORT "; then
        echo "新端口启动失败，回滚到原端口 $CURRENT_PORT"
        sed -i "s/^Port .*/Port $CURRENT_PORT/" $SSH_CONFIG
        if command -v systemctl >/dev/null 2>&1; then
            systemctl restart ssh || systemctl restart sshd
        else
            service ssh restart || service sshd restart
        fi
        exit 1
    fi
fi

echo "SSH 端口已成功修改为 $NEW_PORT"
echo "请使用新的端口连接，例如：ssh -p $NEW_PORT user@host"
