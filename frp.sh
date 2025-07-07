#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

Green="\033[32m"
Red="\033[31m"
Yellow="\033[33m"
Blue="\033[36m"
Font="\033[0m"
BOLD="\033[1m"

FRP_VERSION="0.63.0"
PLUGIN_VERSION="0.0.2"
FRP_DIR="/usr/local/frp"
CONFIG_DIR="/etc/frp"
BIN_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"

mkdir -p "$FRP_DIR" "$CONFIG_DIR" >/dev/null 2>&1

create_frp_command() {
    cat > "$BIN_DIR/frp" <<'EOF'
#!/usr/bin/env bash
bash /usr/local/frp/frp-menu.sh
EOF
    chmod +x "$BIN_DIR/frp"
}

create_menu_script() {
    cat > "$FRP_DIR/frp-menu.sh" <<'EOF'
#!/usr/bin/env bash
Green="\033[32m"
Red="\033[31m"
Yellow="\033[33m"
Blue="\033[36m"
Font="\033[0m"
CONFIG_DIR="/etc/frp"
BIN_DIR="/usr/local/bin"

pause() {
    read -rp $'\n按回车键返回...' _
}

check_installed() {
    local svc=$1
    if [ ! -f "$BIN_DIR/$svc" ]; then
        echo -e "${Red}[$svc 未安装]${Font}"
        echo -e "${Yellow}1) 安装 $svc\n2) 返回上级菜单${Font}"
        read -p "请输入选项: " opt
        case "$opt" in
            1) bash /usr/local/frp/frp-install.sh "$svc" ;;
            2) return 1 ;;
            *) echo -e "${Red}无效输入，返回上级菜单${Font}"; return 1 ;;
        esac
        return 1
    fi
    return 0
}

manage_service_menu() {
    local svc=$1
    local desc=$2
    while true; do
        echo -e "\n${Blue}===== ${desc} 管理菜单 =====${Font}"
        echo -e "${Green}1.${Font} 查看状态"
        echo -e "${Green}2.${Font} 查看日志"
        echo -e "${Green}3.${Font} 重启服务"
        echo -e "${Green}4.${Font} 停止服务"
        echo -e "${Green}5.${Font} 查看配置"
        echo -e "${Green}6.${Font} 修改配置文件"
        echo -e "${Green}7.${Font} 重新安装"
        echo -e "${Green}8.${Font} 卸载"
        [[ "$svc" == "frps" ]] && echo -e "${Green}9.${Font} tokens 配置"
        echo -e "${Green}0.${Font} 返回主菜单"
        read -p "请输入选项: " choice
        case "$choice" in
            1) check_installed "$svc" && systemctl status "$svc" --no-pager; pause ;;
            2) check_installed "$svc" && journalctl -u "$svc" -e; pause ;;
            3) check_installed "$svc" && systemctl restart "$svc"; echo -e "${Green}服务已重启${Font}"; pause ;;
            4) check_installed "$svc" && systemctl stop "$svc"; echo -e "${Green}服务已停止${Font}"; pause ;;
            5) check_installed "$svc" && cat "$CONFIG_DIR/$svc.toml"; pause ;;
            6) check_installed "$svc" && ${EDITOR:-nano} "$CONFIG_DIR/$svc.toml"; pause ;;
            7) bash /usr/local/frp/frp-install.sh "$svc"; pause ;;
            8) bash /usr/local/frp/frp-install.sh "uninstall_$svc"; pause ;;
            9) [[ "$svc" == "frps" ]] && tokens_menu ;;
            0) break ;;
            *) echo -e "${Red}无效输入${Font}" ;;
        esac
    done
}

tokens_menu() {
    while true; do
        echo -e "\n${Blue}===== tokens 配置 =====${Font}"
        echo -e "${Green}1.${Font} 查看当前 tokens"
        echo -e "${Green}2.${Font} 添加用户和 token"
        echo -e "${Green}3.${Font} 删除用户"
        echo -e "${Green}0.${Font} 返回"
        read -p "请输入选项: " TK
        case "$TK" in
            1) cat "$CONFIG_DIR/tokens" 2>/dev/null || echo "(无 tokens 文件)"; pause ;;
            2)
                while true; do
                    read -p "用户名: " U
                    [ -z "$U" ] && break
                    read -p "Token: " T
                    echo "${U}=${T}" >> "$CONFIG_DIR/tokens"
                done
                systemctl restart fp-multiuser.service frps.service
                echo -e "${Green}已添加并重启服务${Font}"; pause ;;
            3)
                cut -d= -f1 "$CONFIG_DIR/tokens" 2>/dev/null || echo "(无)"
                read -p "要删除的用户名: " D
                sed -i "/^$D=/d" "$CONFIG_DIR/tokens"
                systemctl restart fp-multiuser.service frps.service
                echo -e "${Green}已删除并重启服务${Font}"; pause ;;
            0) break ;;
            *) echo -e "${Red}无效输入${Font}" ;;
        esac
    done
}

main_menu() {
    while true; do
        echo -e "\n${Blue}========== FRP 管理主菜单 ==========${Font}"
        echo -e "${Green}1.${Font} frps 管理"
        echo -e "${Green}2.${Font} frpc 管理"
        echo -e "${Green}0.${Font} 退出"
        read -p "请输入选项: " main
        case "$main" in
            1) manage_service_menu "frps" "frps" ;;
            2) manage_service_menu "frpc" "frpc" ;;
            0) exit 0 ;;
            *) echo -e "${Red}无效输入${Font}" ;;
        esac
    done
}

main_menu
EOF
    chmod +x "$FRP_DIR/frp-menu.sh"
}

install_frpc() {
    if [ -f "$BIN_DIR/frpc" ]; then
        echo -e "${Yellow}frpc 已安装。${Font}"
        echo -e "1) 显示配置文件  2) 重新安装  0) 返回"
        read -p "请选择: " C
        case "$C" in
            1) cat "$CONFIG_DIR/frpc.toml"; return ;;
            0) return ;;
        esac
    fi

    wget -qO /tmp/frp.tar.gz "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_amd64.tar.gz"
    tar -zxf /tmp/frp.tar.gz -C /tmp/
    cp /tmp/frp_${FRP_VERSION}_linux_amd64/frpc "$BIN_DIR/" && chmod +x "$BIN_DIR/frpc"

    read -p "服务端地址: " SERVER_ADDR
    read -p "用户名 (可留空跳过鉴权): " USERNAME
    read -p "Token (可留空跳过鉴权): " TOKEN
    read -p "代理名称: " PROXY_NAME
    read -p "代理类型 (tcp/udp/http/https) 默认tcp: " PROXY_TYPE
    PROXY_TYPE=${PROXY_TYPE:-tcp}
    read -p "本地端口: " LOCAL_PORT
    read -p "远程端口: " REMOTE_PORT

    cat > "$CONFIG_DIR/frpc.toml" <<EOF
serverAddr = "$SERVER_ADDR"
serverPort = 7000
EOF

    if [[ -n "$USERNAME" && -n "$TOKEN" ]]; then
        cat >> "$CONFIG_DIR/frpc.toml" <<EOF
user = "$USERNAME"
metadatas.token = "$TOKEN"
EOF
    fi

    cat >> "$CONFIG_DIR/frpc.toml" <<EOF

[[proxies]]
name = "$PROXY_NAME"
type = "$PROXY_TYPE"
localIP = "127.0.0.1"
localPort = $LOCAL_PORT
remotePort = $REMOTE_PORT
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
    systemctl enable frpc.service >/dev/null
    systemctl restart frpc.service

    create_frp_command
    create_menu_script
    echo -e "${Green}frpc 安装完成，可使用 frp 命令管理${Font}"
}

install_frps() {
    :
}

uninstall_frps() {
    systemctl stop frps.service fp-multiuser.service >/dev/null 2>&1
    systemctl disable frps.service fp-multiuser.service >/dev/null 2>&1
    rm -f "$BIN_DIR/frps"
    rm -f "$SYSTEMD_DIR/frps.service" "$SYSTEMD_DIR/fp-multiuser.service"
    rm -f "$CONFIG_DIR/frps.toml" "$CONFIG_DIR/tokens"
    rm -f "$FRP_DIR/fp-multiuser"
    systemctl daemon-reload
    echo -e "${Green}frps 已卸载${Font}"
}

uninstall_frpc() {
    systemctl stop frpc.service >/dev/null 2>&1
    systemctl disable frpc.service >/dev/null 2>&1
    rm -f "$BIN_DIR/frpc"
    rm -f "$CONFIG_DIR/frpc.toml"
    rm -f "$SYSTEMD_DIR/frpc.service"
    systemctl daemon-reload
    echo -e "${Green}frpc 已卸载${Font}"
}

cp "$0" "$FRP_DIR/frp-install.sh" >/dev/null 2>&1

if [[ "$1" == "frps" ]]; then install_frps; exit 0; fi
if [[ "$1" == "frpc" ]]; then install_frpc; exit 0; fi
if [[ "$1" == "uninstall_frps" ]]; then uninstall_frps; exit 0; fi
if [[ "$1" == "uninstall_frpc" ]]; then uninstall_frpc; exit 0; fi

echo -e "${Blue}========== FRP 安装管理脚本 ==========${Font}"
echo -e "${Green}1.${Font} 安装 frps"
echo -e "${Green}2.${Font} 安装 frpc"
echo -e "${Green}3.${Font} 卸载 frps"
echo -e "${Green}4.${Font} 卸载 frpc"
echo -e "${Green}0.${Font} 退出"
read -p "请输入编号 [0-4]: " CHOICE

case "$CHOICE" in
    1) install_frps ;;
    2) install_frpc ;;
    3) uninstall_frps ;;
    4) uninstall_frpc ;;
    0) echo -e "${Green}已退出${Font}" ;;
    *) echo -e "${Red}无效输入${Font}" ;;
esac
