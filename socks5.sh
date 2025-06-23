#!/bin/bash
# SOCKS5代理服务器自动部署脚本

# 检测root权限
if [ "$EUID" -ne 0 ]; then
    echo "❌ 请使用sudo或root用户运行脚本" >&2
    exit 1
fi

# 安装依赖
echo "🔧 安装必要组件..."
apt update &> /dev/null
apt install -y dante-server netcat-openbsd &> /dev/null

# 配置参数
read -p "🛡️ 输入代理端口 (默认1080): " PORT
PORT=${PORT:-1080}

read -p "👤 输入认证用户名: " USERNAME
while [[ -z "$USERNAME" ]]; do
    read -p "❌ 用户名不能为空，请重新输入: " USERNAME
done

read -sp "🔑 输入认证密码: " PASSWORD
echo
while [[ -z "$PASSWORD" ]]; do
    read -sp "❌ 密码不能为空，请重新输入: " PASSWORD
    echo
done

# 生成配置文件
echo "📝 生成Dante配置文件..."
INTERFACE=$(ip route | awk '/default/ {print $5}')
cat > /etc/danted.conf <<EOF
logoutput: syslog
internal: 0.0.0.0 port = $PORT
external: $INTERFACE
method: username
user.privileged: root
user.unprivileged: nobody
client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect disconnect
}
socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect disconnect
}
EOF

# 创建认证用户
echo "👥 创建系统用户..."
useradd -r -s /bin/false $USERNAME
echo "$USERNAME:$PASSWORD" | chpasswd

# 防火墙配置
echo "🔥 配置防火墙..."
if command -v ufw &> /dev/null; then
    ufw allow $PORT/tcp &> /dev/null
elif command -v firewall-cmd &> /dev/null; then
    firewall-cmd --permanent --add-port=$PORT/tcp &> /dev/null
    firewall-cmd --reload &> /dev/null
fi

# 启动服务
echo "🚀 启动Dante服务..."
systemctl restart danted
systemctl enable danted &> /dev/null

# 验证安装
echo "✅ 安装完成，测试连接..."
if nc -zv localhost $PORT &> /dev/null; then
    echo "================================"
    echo "SOCKS5代理服务器已就绪"
    echo "地址: $(curl -s ifconfig.me)"
    echo "端口: $PORT"
    echo "认证: $USERNAME:$PASSWORD"
    echo "================================"
else
    echo "❌ 服务启动失败，请检查配置" >&2
    exit 1
fi

