#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

# 字体颜色
Green="\033[32m"
Red="\033[31m"
Yellow="\033[33m"
Font="\033[0m"

# 变量
FRP_VERSION="0.63.0"
PLUGIN_VERSION="0.0.2"
FRP_DIR="/usr/local/frp"
CONFIG_DIR="/etc/frp"
BIN_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"

mkdir -p "$FRP_DIR" "$CONFIG_DIR"

# 安装依赖
if command -v apk >/dev/null 2>&1; then
    apk update
    apk add --no-cache wget curl jq tar bash
elif command -v apt >/dev/null 2>&1; then
    apt update && apt install -y wget curl jq tar
else
    echo "不支持的系统，请手动安装必要工具"
    exit 1
fi

echo -e "${Yellow}请选择操作：${Font}"
echo "1) 安装 frps（服务端 + 用户鉴权插件）"
echo "2) 安装 frpc（客户端）"
echo "3) 卸载 frps"
echo "4) 卸载 frpc"
echo "0) 退出"
read -p "输入编号 [0-4]: " CHOICE

install_frps() {
    echo -e "${Green}开始安装 frps + 鉴权插件${Font}"

    wget -qO /tmp/frp.tar.gz "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_amd64.tar.gz"
    tar -zxf /tmp/frp.tar.gz -C /tmp/
    cp /tmp/frp_${FRP_VERSION}_linux_amd64/frps "$BIN_DIR/"
    chmod +x "$BIN_DIR/frps"

    wget -qO "$FRP_DIR/fp-multiuser" "https://github.com/gofrp/fp-multiuser/releases/download/v${PLUGIN_VERSION}/fp-multiuser-linux-amd64"
    chmod +x "$FRP_DIR/fp-multiuser"

    echo -e "${Yellow}请输入用户 = token（直接回车结束）：${Font}"
    > "$CONFIG_DIR/tokens"
    while true; do
        read -p "用户名: " U
        [ -z "$U" ] && break
        read -p "Token: " T
        echo "${U}=${T}" >> "$CONFIG_DIR/tokens"
    done

    read -p "请输入 webServer 用户名(默认: admin): " WEB_USER
    WEB_USER=${WEB_USER:-admin}
    read -sp "请输入 webServer 密码: " WEB_PASS
    echo

    cat > "$CONFIG_DIR/frps.toml" <<EOF
bindAddr = "0.0.0.0"
bindPort = 7000

webServer.addr = "0.0.0.0"
webServer.port = 7500
webServer.user = "${WEB_USER}"
webServer.password = "${WEB_PASS}"

[[httpPlugins]]
name = "multiuser"
addr = "127.0.0.1:7200"
path = "/handler"
ops = ["Login"]
EOF

    cat > "$SYSTEMD_DIR/fp-multiuser.service" <<EOF
[Unit]
Description=FRP 用户鉴权插件
After=network.target

[Service]
ExecStart=$FRP_DIR/fp-multiuser -l 127.0.0.1:7200 -f $CONFIG_DIR/tokens
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    cat > "$SYSTEMD_DIR/frps.service" <<EOF
[Unit]
Description=FRP 服务端
After=network.target

[Service]
ExecStart=$BIN_DIR/frps -c $CONFIG_DIR/frps.toml
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable fp-multiuser.service frps.service
    systemctl start fp-multiuser.service frps.service

    echo -e "${Green}frps 安装并已启动${Font}"
}

install_frpc() {
    echo -e "${Green}开始安装 frpc 客户端${Font}"

    wget -qO /tmp/frp.tar.gz "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_amd64.tar.gz"
    tar -zxf /tmp/frp.tar.gz -C /tmp/
    cp /tmp/frp_${FRP_VERSION}_linux_amd64/frpc "$BIN_DIR/"
    chmod +x "$BIN_DIR/frpc"

    read -p "请输入服务端地址 (serverAddr): " SERVER_ADDR
    read -p "请输入用户名 (user): " USERNAME
    read -p "请输入 token (meta_token): " TOKEN

    cat > "$CONFIG_DIR/frpc.toml" <<EOF
serverAddr = "$SERVER_ADDR"
serverPort = 7000
user = "$USERNAME"
meta_token = "$TOKEN"

[[proxies]]
name = "ssh"
type = "tcp"
localPort = 22
remotePort = 6000
EOF

    cat > "$SYSTEMD_DIR/frpc.service" <<EOF
[Unit]
Description=FRP 客户端
After=network.target

[Service]
ExecStart=$BIN_DIR/frpc -c $CONFIG_DIR/frpc.toml
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable frpc.service
    systemctl start frpc.service

    echo -e "${Green}frpc 安装并已启动${Font}"
}

uninstall_frps() {
    systemctl stop fp-multiuser.service frps.service >/dev/null 2>&1
    systemctl disable fp-multiuser.service frps.service >/dev/null 2>&1
    rm -rf "$FRP_DIR"
    rm -f "$CONFIG_DIR/frps.toml" "$CONFIG_DIR/tokens"
    rm -f "$SYSTEMD_DIR/frps.service" "$SYSTEMD_DIR/fp-multiuser.service"
    systemctl daemon-reload
    echo -e "${Green}frps 已卸载${Font}"
}

uninstall_frpc() {
    systemctl stop frpc.service >/dev/null 2>&1
    systemctl disable frpc.service >/dev/null 2>&1
    rm -f "$CONFIG_DIR/frpc.toml"
    rm -f "$SYSTEMD_DIR/frpc.service"
    rm -f "$BIN_DIR/frpc"
    systemctl daemon-reload
    echo -e "${Green}frpc 已卸载${Font}"
}

case "$CHOICE" in
    1) install_frps ;;
    2) install_frpc ;;
    3) uninstall_frps ;;
    4) uninstall_frpc ;;
    0) echo -e "${Green}已退出${Font}"; exit 0 ;;
    *) echo -e "${Red}无效输入${Font}" ;;
esac
