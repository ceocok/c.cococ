#!/bin/sh

# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 用户执行此脚本！"
    exit 1
fi

# 检测包管理器
if command -v apk >/dev/null 2>&1; then
    OS="alpine"
    echo "检测到 Alpine 系统"
    apk update
    apk add --no-cache wget curl jq tar bash
elif command -v apt >/dev/null 2>&1; then
    OS="debian"
    echo "检测到 Debian/Ubuntu 系统"
    apt update && apt install -y wget curl jq tar
else
    echo "不支持的系统，请手动安装 wget、curl、jq、tar"
    exit 1
fi

# 获取最新版 frp
FRP_VERSION=$(curl -s https://api.github.com/repos/fatedier/frp/releases/latest | jq -r .tag_name | sed 's/v//')
FRP_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_amd64.tar.gz"
FRP_DIR="/usr/local/frp"
BIN_DIR="/usr/local/bin"
CONFIG_DIR="/etc/frp"

# 下载并解压
wget -O /tmp/frp.tar.gz "${FRP_URL}" >/dev/null 2>&1
mkdir -p ${FRP_DIR}
tar -zxf /tmp/frp.tar.gz -C /tmp/
cp -r /tmp/frp_${FRP_VERSION}_linux_amd64/* ${FRP_DIR}/
cp ${FRP_DIR}/frps ${BIN_DIR}/
chmod +x ${BIN_DIR}/frps

# 用户输入
read -p "请输入webServer用户名(默认: admin): " WEB_USER
WEB_USER=${WEB_USER:-admin}
read -sp "请输入webServer密码: " WEB_PASS
echo

# 写配置
mkdir -p ${CONFIG_DIR}
cat > ${CONFIG_DIR}/frps.toml <<EOF
bindAddr = "0.0.0.0"
bindPort = 7000
webServer.addr = "0.0.0.0"
webServer.port = 7500
webServer.user = "${WEB_USER}"
webServer.password = "${WEB_PASS}"
EOF

# 创建服务
if [ "$OS" = "debian" ]; then
    cat > /etc/systemd/system/frps.service <<EOF
[Unit]
Description=frp server
After=network.target

[Service]
Type=simple
ExecStart=${BIN_DIR}/frps -c ${CONFIG_DIR}/frps.toml
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable frps >/dev/null 2>&1
    systemctl start frps >/dev/null 2>&1
else
    cat > /etc/init.d/frps <<EOF
#!/sbin/openrc-run

name="frps"
description="FRP Server"
command="/sbin/start-stop-daemon"
command_args="--start --background --make-pidfile --pidfile /run/frps.pid --exec ${BIN_DIR}/frps -- -c ${CONFIG_DIR}/frps.toml"
pidfile="/run/frps.pid"
EOF
    chmod +x /etc/init.d/frps
    rc-update add frps default >/dev/null 2>&1
    rc-service frps start >/dev/null 2>&1
fi

echo "✅ frps 安装成功并已在后台运行"
