#!/bin/bash

# 安装依赖
apt update && apt install -y wget tar curl jq

# 获取最新frp版本号
FRP_VERSION=$(curl -s https://api.github.com/repos/fatedier/frp/releases/latest | jq -r .tag_name | sed 's/v//')
FRP_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_amd64.tar.gz"
FRP_DIR="/usr/local/frp"
BIN_DIR="/usr/local/bin"
CONFIG_DIR="/etc/frp"
SYSTEMD_DIR="/etc/systemd/system"

if [ "$(id -u)" -ne 0 ]; then
    echo "请使用root用户执行此脚本！"
    exit 1
fi

# 下载frp
echo "正在下载frp ${FRP_VERSION}..."
wget -O /tmp/frp.tar.gz "${FRP_URL}"

# 解压
echo "正在解压..."
mkdir -p ${FRP_DIR}
tar -zxvf /tmp/frp.tar.gz -C /tmp/
cp -r /tmp/frp_${FRP_VERSION}_linux_amd64/* ${FRP_DIR}/

# 安装frps
echo "正在安装frps..."
cp ${FRP_DIR}/frps ${BIN_DIR}/
chmod +x ${BIN_DIR}/frps

# 提示用户输入webServer.user和webServer.password
read -p "请输入webServer用户名(默认: admin): " WEB_USER
WEB_USER=${WEB_USER:-admin}
read -sp "请输入webServer密码: " WEB_PASS
echo

# 创建配置目录和配置文件
echo "正在配置frps..."
mkdir -p ${CONFIG_DIR}
cat > ${CONFIG_DIR}/frps.toml <<EOF
bindAddr = "0.0.0.0"
bindPort = 7000
webServer.addr = "0.0.0.0"
webServer.port = 7500
webServer.user = "${WEB_USER}"
webServer.password = "${WEB_PASS}"
EOF

# 创建systemd服务文件
echo "正在配置systemd服务..."
cat > ${SYSTEMD_DIR}/frps.service <<EOF
[Unit]
Description=frp server
After=network.target

[Service]
Type=simple
Restart=on-failure
RestartSec=5s
ExecStart=${BIN_DIR}/frps -c ${CONFIG_DIR}/frps.toml

[Install]
WantedBy=multi-user.target
EOF

# 重载systemd
systemctl daemon-reload

# 启动并设置开机自启
systemctl start frps
systemctl enable frps

# 检查服务状态
systemctl status frps

echo "frps部署完成！"

