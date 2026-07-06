#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

Green="\033[32m"Red="\033[31m"Yellow="\033[33m"Blue="\033[36m"Font="\033[0m"BOLD="\033[1m"
FRP_VERSION="0.63.0"
PLUGIN_VERSION="0.0.2"

# 1. 自动检测操作系统和硬件架构
OS_TYPE=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH_TYPE=$(uname -m)

case "$ARCH_TYPE" in
    x86_64|amd64)  FRP_ARCH="amd64" ;;
    arm64|aarch64) FRP_ARCH="arm64" ;;
    *)             FRP_ARCH="amd64" ;;
esac

# 2. 根据系统类型初始化不同的路径与服务模式
if [[ "$OS_TYPE" == "darwin" ]]; then
    OS_NAME="darwin"
    SERVICE_MODE="launchd"
    FRP_DIR="$HOME/.local/share/frp"
    CONFIG_DIR="$HOME/.config/frp"
    BIN_DIR="/usr/local/bin"
    LAUNCHD_DIR="$HOME/Library/LaunchAgents"
    mkdir -p "$FRP_DIR" "$CONFIG_DIR" "$LAUNCHD_DIR" "$BIN_DIR" >/dev/null 2>&1
else
    OS_NAME="linux"
    if command -v systemctl >/dev/null 2>&1; then 
        SERVICE_MODE="systemd"
    else 
        SERVICE_MODE="openrc"
    fi
    FRP_DIR="/usr/local/frp"
    CONFIG_DIR="/etc/frp"
    BIN_DIR="/usr/local/bin"
    mkdir -p "$FRP_DIR" "$CONFIG_DIR" >/dev/null 2>&1
    
    if command -v apk >/dev/null 2>&1; then 
        apk add --no-cache bash curl wget tar gzip gcompat libc6-compat >/dev/null 2>&1 || true
    fi
fi

svc_enable() {
    local name="$1"
    if [[ "$SERVICE_MODE" == "launchd" ]]; then
        launchctl load "$LAUNCHD_DIR/${name}.plist" >/dev/null 2>&1 || true
    elif [[ "$SERVICE_MODE" == "systemd" ]]; then
        systemctl enable "${name}.service" >/dev/null 2>&1 || true
    else
        rc-update add "$name" default >/dev/null 2>&1 || true
    fi
}

svc_restart() {
    local name="$1"
    if [[ "$SERVICE_MODE" == "launchd" ]]; then
        launchctl unload "$LAUNCHD_DIR/${name}.plist" >/dev/null 2>&1 || true
        launchctl load "$LAUNCHD_DIR/${name}.plist" >/dev/null 2>&1 || true
    elif [[ "$SERVICE_MODE" == "systemd" ]]; then
        systemctl restart "${name}.service"
    else
        rc-service "$name" restart || rc-service "$name" start
    fi
}

svc_stop() {
    local name="$1"
    if [[ "$SERVICE_MODE" == "launchd" ]]; then
        launchctl unload "$LAUNCHD_DIR/${name}.plist" >/dev/null 2>&1 || true
    elif [[ "$SERVICE_MODE" == "systemd" ]]; then
        systemctl stop "${name}.service" >/dev/null 2>&1 || true
    else
        rc-service "$name" stop >/dev/null 2>&1 || true
    fi
}

svc_disable() {
    local name="$1"
    if [[ "$SERVICE_MODE" == "launchd" ]]; then
        launchctl unload "$LAUNCHD_DIR/${name}.plist" >/dev/null 2>&1 || true
        rm -f "$LAUNCHD_DIR/${name}.plist" >/dev/null 2>&1 || true
    elif [[ "$SERVICE_MODE" == "systemd" ]]; then
        systemctl disable "${name}.service" >/dev/null 2>&1 || true
    else
        rc-update del "$name" default >/dev/null 2>&1 || true
    fi
}

svc_status() {
    local name="$1"
    if [[ "$SERVICE_MODE" == "launchd" ]]; then
        if launchctl list | grep -q "$name"; then
            echo -e "${Green}服务 ${name} 正在运行 (Launchd)${Font}"
        else
            echo -e "${Red}服务 ${name} 未运行或未加载${Font}"
        fi
    elif [[ "$SERVICE_MODE" == "systemd" ]]; then
        systemctl status "${name}.service" --no-pager
    else
        rc-service "$name" status
    fi
}

svc_logs() {
    local name="$1"
    if [[ "$SERVICE_MODE" == "launchd" ]]; then
        echo "展示最近的日志内容 (/tmp/${name}.log):"
        tail -n 50 "/tmp/${name}.log" 2>/dev/null || echo "(暂无常规输出日志)"
        tail -n 50 "/tmp/${name}_err.log" 2>/dev/null || echo "(暂无错误输出日志)"
    elif [[ "$SERVICE_MODE" == "systemd" ]]; then
        journalctl -u "${name}.service" -e --no-pager
    else
        echo "OpenRC 环境无 journald，展示最近系统日志："
        tail -n 120 /var/log/messages 2>/dev/null || dmesg | tail -n 120
    fi
}

write_openrc_service() {
    local name="$1"
    local bin="$2"
    local args="$3"
    cat > "$OPENRC_INIT_DIR/$name" <<EOF
#!/sbin/openrc-run
name="$name"
command="$bin"
command_args="$args"
command_background=true
pidfile="/run/$name.pid"
respawn_delay=2

depend() {
    need net
}
EOF
    chmod +x "$OPENRC_INIT_DIR/$name"
}

write_launchd_plist() {
    local name="$1"
    local bin="$2"
    local conf="$3"
    cat > "$LAUNCHD_DIR/${name}.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${name}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${bin}</string>
        <string>-c</string>
        <string>${conf}</string>
    </array>
    <key>KeepAlive</key>
    <true/>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/${name}.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/${name}_err.log</string>
</dict>
</plist>
EOF
}

DOWNLOAD_UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
DOWNLOAD_REF="https://github.com/"

download_file() {
    local out="$1"
    shift
    local urls=("$@")
    for url in "${urls[@]}"; do
        echo -e "${Yellow}尝试下载: $url${Font}"
        if command -v curl >/dev/null 2>&1; then
            local code
            code=$(curl -L --http1.1 --connect-timeout 10 --max-time 60 \
                --retry 2 --retry-delay 1 --retry-all-errors \
                -A "$DOWNLOAD_UA" -e "$DOWNLOAD_REF" \
                -o "$out" -w "%{http_code}" "$url" 2>/dev/null || echo "000")
            [[ "$code" == "200" ]] || continue
        elif command -v wget >/dev/null 2>&1; then
            wget -q --timeout=60 --tries=2 \
                --user-agent="$DOWNLOAD_UA" --referer="$DOWNLOAD_REF" \
                -O "$out" "$url" || continue
        else
            echo -e "${Red}未找到 curl/wget${Font}"
            return 1
        fi
        return 0
    done
    return 1
}

download_frp_package() {
    local out="/tmp/frp.tar.gz"
    local pkg="frp_${FRP_VERSION}_${OS_NAME}_${FRP_ARCH}.tar.gz"
    
    download_file "$out" \
        "https://gh-proxy.org/https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${pkg}" \
        "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${pkg}" \
        "https://ghproxy.com/https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${pkg}" || return 1
        
    if ! gzip -t "$out" >/dev/null 2>&1; then
        echo -e "${Red}下载内容不是有效 gzip${Font}"
        return 1
    fi
    if ! tar -tzf "$out" >/dev/null 2>&1; then
        echo -e "${Red}压缩包目录结构校验失败${Font}"
        return 1
    fi
    tar -zxf "$out" -C /tmp/ || return 1
    return 0
}

create_frp_command() {
    cat > "$BIN_DIR/frp" <<EOF
#!/usr/bin/env bash
bash $FRP_DIR/frp-menu.sh
EOF
    chmod +x "$BIN_DIR/frp"
}

frp_install_core() {
    local type="$1"
    echo -e "${Yellow}正在下载并安装 ${type}...${Font}"
    download_frp_package || return 1
    
    local extracted_dir=$(find /tmp -maxdepth 1 -type d -name "frp_${FRP_VERSION}_*")
    if [ -z "$extracted_dir" ]; then
        echo -e "${Red}未找到解压目录${Font}"
        return 1
    fi
    
    cp "$extracted_dir/$type" "$BIN_DIR/$type" || return 1
    chmod +x "$BIN_DIR/$type"
    
    if [ ! -f "$CONFIG_DIR/$type.toml" ]; then
        cp "$extracted_dir/${type}.toml" "$CONFIG_DIR/$type.toml" 2>/dev/null || {
            if [[ "$type" == "frps" ]]; then
                echo -e "bindPort = 7000" > "$CONFIG_DIR/$type.toml"
            else
                echo -e "serverAddr = \"127.0.0.1\"\nserverPort = 7000" > "$CONFIG_DIR/$type.toml"
            fi
        }
    fi
    
    if [[ "$SERVICE_MODE" == "launchd" ]]; then
        write_launchd_plist "$type" "$BIN_DIR/$type" "$CONFIG_DIR/$type.toml"
    elif [[ "$SERVICE_MODE" == "systemd" ]]; then
        cat > "/etc/systemd/system/${type}.service" <<EOF
[Unit]
Description=FRP ${type} Service
After=network.target

[Service]
Type=simple
ExecStart=$BIN_DIR/$type -c $CONFIG_DIR/$type.toml
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    else
        write_openrc_service "$type" "$BIN_DIR/$type" "-c $CONFIG_DIR/$type.toml"
    fi
    
    svc_enable "$type"
    svc_restart "$type"
    echo -e "${Green}${type} 安装配置完成并已启动！${Font}"
    rm -rf "$extracted_dir" "/tmp/frp.tar.gz"
}

frp_uninstall_core() {
    local type="$1"
    svc_stop "$type"
    svc_disable "$type"
    rm -f "$BIN_DIR/$type"
    rm -f "$CONFIG_DIR/$type.toml"
    echo -e "${Green}${type} 已彻底卸载。${Font}"
}

pause() {
    read -rp $'\n按回车键返回...' _
}

check_installed() {
    local svc=$1
    if [ ! -f "$BIN_DIR/$svc" ]; then
        echo -e "${Red}[$svc 未安装]${Font}"
        echo -e "${Yellow}1) 安装 $svc\n0) 返回上级菜单${Font}"
        read -p "请输入选项: " opt
        case "$opt" in
            1) frp_install_core "$svc" ;;
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
        echo -e "${Green}6.${Font} 修改配置"
        echo -e "${Green}7.${Font} 重新安装"
        echo -e "${Green}8.${Font} 卸载"
        echo -e "${Green}0.${Font} 返回主菜单"
        read -p "请输入选项: " choice
        case "$choice" in
            1) check_installed "$svc" && svc_status "$svc"; pause ;;
            2) check_installed "$svc" && svc_logs "$svc"; pause ;;
            3) check_installed "$svc" && svc_restart "$svc" && echo -e "${Green}服务已重启${Font}"; pause ;;
            4) check_installed "$svc" && svc_stop "$svc" && echo -e "${Green}服务已停止${Font}"; pause ;;
            5) check_installed "$svc" && cat "$CONFIG_DIR/$svc.toml"; pause ;;
            6) check_installed "$svc" && ${EDITOR:-vi} "$CONFIG_DIR/$svc.toml"; pause ;;
            7) frp_install_core "$svc"; pause ;;
            8) frp_uninstall_core "$svc"; pause ;;
            0) break ;;
            *) echo -e "${Red}无效输入${Font}" ;;
        esac
    done
}

main_menu() {
    mkdir -p "$FRP_DIR" "$CONFIG_DIR" >/dev/null 2>&1
    create_frp_command
    while true; do
        echo -e "\n${Blue}===== FRP 跨平台管理脚本 (支持 Mac/Linux) =====${Font}"
        echo -e "${Green}1.${Font} 管理 FRPS (服务端)"
        echo -e "${Green}2.${Font} 管理 FRPC (客户端)"
        echo -e "${Green}0.${Font} 退出脚本"
        read -p "请输入选项: " main_choice
        case "$main_choice" in
            1) manage_service_menu "frps" "FRPS 服务端" ;;
            2) manage_service_menu "frpc" "FRPC 客户端" ;;
            0) exit 0 ;;
            *) echo -e "${Red}无效输入${Font}" ;;
        esac
    done
}

main_menu
