#!/bin/sh

# 脚本出现错误时立即退出
set -e

# --- 配置变量 ---
XRAY_VERSION="1.8.4"
CERT_DIR="/root/coca"
XRAY_BIN="/usr/local/bin/xray"
SYSTEMD_FILE="/etc/systemd/system/xray.service"
OPENRC_FILE="/etc/init.d/xray"
CONFIG_FILE="/etc/xray/config.json"
WS_PATH="/ws"

# --- 辅助函数 (无颜色) ---
green() { echo "$1"; }
red() { echo "$1"; }
yellow() { echo "$1"; }

# --- 核心辅助函数 ---
PKG_MANAGER=""
INSTALL_CMD=""
UPDATE_CMD=""
DEPS_UPDATED=""

is_systemd_system() {
    [ "$(ps -p 1 -o comm=)" = "systemd" ]
}

detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt"; INSTALL_CMD="apt-get install -y"; UPDATE_CMD="apt-get update"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"; INSTALL_CMD="yum install -y"; UPDATE_CMD="yum makecache"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"; INSTALL_CMD="dnf install -y"; UPDATE_CMD="dnf makecache"
    elif command -v apk >/dev/null 2>&1; then
        PKG_MANAGER="apk"; INSTALL_CMD="apk add"; UPDATE_CMD="apk update"
    fi
}

ensure_command() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 && return 0

    yellow "⏳ 命令 '$cmd' 未找到，正在尝试安装..."
    [ -z "$PKG_MANAGER" ] && red "❌ 无法检测到包管理器，请手动安装 '$cmd'。" && exit 1

    local pkg_name
    case "$cmd" in
        curl) pkg_name="curl" ;;
        unzip) pkg_name="unzip" ;;
        jq) pkg_name="jq" ;;
        openssl) pkg_name="openssl" ;;
        crontab) [ "$PKG_MANAGER" = "apk" ] && pkg_name="busybox-extras" || ([ "$PKG_MANAGER" = "apt" ] && pkg_name="cron" || pkg_name="cronie") ;;
        ps) [ "$PKG_MANAGER" = "apk" ] && pkg_name="procps" || ([ "$PKG_MANAGER" = "apt" ] && pkg_name="procps" || pkg_name="procps-ng") ;;
        *) red "❌ 内部错误：未知命令 '$cmd'" && exit 1 ;;
    esac

    [ -z "$DEPS_UPDATED" ] && echo "➡️ 首次安装依赖，更新软件包列表..." && $UPDATE_CMD >/dev/null 2>&1 && DEPS_UPDATED="true"
    [ "$pkg_name" = "jq" ] && { [ "$PKG_MANAGER" = "yum" ] || [ "$PKG_MANAGER" = "dnf" ]; } && $INSTALL_CMD epel-release >/dev/null 2>&1 || true
    $INSTALL_CMD "$pkg_name"
    command -v "$cmd" >/dev/null 2>&1 || (red "❌ 安装 '$pkg_name' 失败。" && exit 1)
    green "✅ 命令 '$cmd' 已安装。"
}

# --- 功能函数 ---

show_vmess_link() {
    [ ! -f "$CONFIG_FILE" ] && red "❌ 未找到 Xray 配置文件" && exit 1
    ensure_command "jq"
    UUID=$(jq -r '.inbounds[0].settings.clients[0].id' "$CONFIG_FILE")
    DOMAIN=$(jq -r '.inbounds[0].streamSettings.tlsSettings.serverName' "$CONFIG_FILE")
    PORT=$(jq -r '.inbounds[0].port' "$CONFIG_FILE")
    
    local vmess_json
    vmess_json=$(cat <<EOF
{
  "v": "2",
  "ps": "${DOMAIN}-vmess-self-signed",
  "add": "$DOMAIN",
  "port": "$PORT",
  "id": "$UUID",
  "aid": "0",
  "net": "ws",
  "type": "none",
  "host": "$DOMAIN",
  "path": "$WS_PATH",
  "tls": "tls"
}
EOF
)
    local vmess_link="vmess://$(echo "$vmess_json" | base64 -w 0)"
    echo
    green "🎉 VMess 配置信息如下 (使用自签名证书):"
    echo "======================================"
    echo " 地址 (Address): $DOMAIN (或服务器IP)"
    echo " 端口 (Port): $PORT"
    echo " 用户ID (UUID): $UUID"
    echo " WebSocket 路径 (Path): $WS_PATH"
    echo " SNI / 伪装域名 (Host): $DOMAIN"
    echo " 底层传输安全 (TLS): tls"
    yellow "🔴 重要: 客户端连接时，请务必开启'允许不安全连接'或'跳过证书验证'选项!"
    echo "======================================"
    green "VMess 链接 (复制并导入到客户端):"
    echo "$vmess_link"
    echo "======================================"
    exit 0
}

stop_xray() {
    yellow "➡️ 正在尝试停止 Xray 服务..."
    if is_systemd_system; then
        systemctl stop xray || true
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service xray stop || true
    else
        pkill -f "$XRAY_BIN run -c $CONFIG_FILE" || pkill xray || true
    fi
    green "✅ 停止命令已执行。"
}

uninstall_xray() {
    yellow "⚠️ 警告：此操作将彻底删除 Xray、其配置、证书和自启任务。"
    echo -n "您确定要卸载 Xray 吗? [Y/N]: "
    read -r confirm_uninstall
    if [ "$confirm_uninstall" != "y" ] && [ "$confirm_uninstall" != "Y" ]; then
        echo "操作已取消。"
        exit 0
    fi

    stop_xray
    
    if is_systemd_system && [ -f "$SYSTEMD_FILE" ]; then
        systemctl disable xray >/dev/null 2>&1 || true
        rm -f "$SYSTEMD_FILE"
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    if command -v rc-update >/dev/null 2>&1 && [ -f "$OPENRC_FILE" ]; then
        rc-update del xray default >/dev/null 2>&1 || true
        rm -f "$OPENRC_FILE"
    fi

    # 清理 crontab 自启任务
    if command -v crontab >/dev/null 2>&1; then
        (crontab -l 2>/dev/null | grep -Fv "$XRAY_BIN run -c $CONFIG_FILE") | crontab - >/dev/null 2>&1 || true
    fi

    rm -rf "$XRAY_BIN" /etc/xray "$CERT_DIR"
    green "🎉 Xray 已完全卸载。"
    exit 0
}

menu_if_installed() {
    green "❗ 检测到 Xray 已安装，请选择操作："
    echo "   1) 显示 VMess 配置和链接"
    echo "   2) 重新安装 Xray"
    echo "   3) 彻底卸载 Xray"
    echo -n "请输入选项 [1-3]，按 Enter 键: "
    read -r option
    case "$option" in
        1) show_vmess_link ;;
        2) 
            stop_xray
            rm -rf "$XRAY_BIN" /etc/xray
            green "✅ 旧版本已卸载，即将开始重新安装..."
            ;;
        3) uninstall_xray ;;
        *) red "❌ 无效选项" && exit 1 ;;
    esac
}

install_xray_core() {
    mkdir -p /etc/xray
    [ -f "$XRAY_BIN" ] && rm -f "$XRAY_BIN"

    ensure_command "curl"
    ensure_command "unzip"
    
    echo "➡️ 正在下载并安装 Xray v${XRAY_VERSION}..."
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) XRAY_ARCH="64" ;;
        aarch64) XRAY_ARCH="arm64-v8a" ;;
        *) red "❌ 不支持的系统架构: $ARCH"; exit 1 ;;
    esac
    
    curl -L -o xray.zip "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-${XRAY_ARCH}.zip"
    unzip -o xray.zip -d /tmp/xray
    mv -f /tmp/xray/xray "$XRAY_BIN"
    chmod +x "$XRAY_BIN"
    mv -f /tmp/xray/geo* /etc/xray/
    rm -rf xray.zip /tmp/xray
    green "✅ Xray 核心安装成功。"
}

get_user_input() {
    echo -n "请输入你的域名或 IP (将用于生成证书和SNI): "
    read -r DOMAIN
    [ -z "$DOMAIN" ] && red "❌ 域名或IP不能为空！" && exit 1
    echo -n "请输入监听端口 [默认: 443]: "
    read -r PORT
    [ -z "$PORT" ] && PORT=443
    UUID=$(cat /proc/sys/kernel/random/uuid)
}

generate_self_signed_cert() {
    yellow "➡️ 正在生成自签名证书..."
    ensure_command "openssl"
    mkdir -p "$CERT_DIR"
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$CERT_DIR/${DOMAIN}.key" -out "$CERT_DIR/${DOMAIN}.cer" \
        -subj "/CN=$DOMAIN"
    green "✅ 自签名证书已生成到 $CERT_DIR 目录。"
}

generate_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat > "$CONFIG_FILE" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "port": $PORT,
    "protocol": "vmess",
    "settings": {
      "clients": [{ "id": "$UUID" }]
    },
    "streamSettings": {
      "network": "ws",
      "security": "tls",
      "tlsSettings": {
        "serverName": "$DOMAIN",
        "certificates": [{
          "certificateFile": "$CERT_DIR/${DOMAIN}.cer",
          "keyFile": "$CERT_DIR/${DOMAIN}.key"
        }]
      },
      "wsSettings": { "path": "$WS_PATH" }
    }
  }],
  "outbounds": [{ "protocol": "freedom", "settings": {} }]
}
EOF
    green "✅ Xray 配置文件已生成。"
}

setup_and_start_xray() {
    if is_systemd_system; then
        echo "➡️ 检测到 systemd，正在创建服务..."
        cat > "$SYSTEMD_FILE" <<EOF
[Unit]
Description=Xray Service
After=network.target nss-lookup.target
[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=$XRAY_BIN run -c $CONFIG_FILE
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable xray
        systemctl start xray
        sleep 2
        systemctl is-active --quiet xray && green "✅ Xray (systemd) 启动成功。" || (red "❌ Xray (systemd) 启动失败。" && exit 1)

    elif command -v rc-update >/dev/null 2>&1; then
        echo "➡️ 检测到 OpenRC，正在创建服务..."
        cat > "$OPENRC_FILE" <<EOF
#!/sbin/openrc-run
description="Xray Service"
command="$XRAY_BIN"
command_args="run -c $CONFIG_FILE"
pidfile="/run/\${RC_SVCNAME}.pid"
depend() { need net; after net; }
EOF
        chmod +x "$OPENRC_FILE"
        rc-update add xray default
        rc-service xray start
        sleep 2
        rc-service xray status | grep -q "started" && green "✅ Xray (OpenRC) 启动成功。" || (red "❌ Xray (OpenRC) 启动失败。" && exit 1)

    else
        yellow "⚠️ 未检测到 systemd/OpenRC，使用 crontab @reboot + nohup 实现自启。"
        ensure_command "crontab"
        cron_job="@reboot $XRAY_BIN run -c $CONFIG_FILE >/dev/null 2>&1"
        (crontab -l 2>/dev/null | grep -Fv "$XRAY_BIN run -c $CONFIG_FILE"; echo "$cron_job") | crontab - >/dev/null 2>&1
        green "✅ 已添加 crontab @reboot 任务。"
        
        pkill -f "$XRAY_BIN run -c $CONFIG_FILE" || true; sleep 1
        nohup "$XRAY_BIN" run -c "$CONFIG_FILE" >/dev/null 2>&1 &
        sleep 2
        pgrep -f "$XRAY_BIN run -c $CONFIG_FILE" >/dev/null && green "✅ Xray (nohup) 启动成功。" || (red "❌ Xray (nohup) 启动失败。" && exit 1)
    fi
}

# --- 主函数 ---
main() {
    detect_pkg_manager
    ensure_command "ps"

    [ -f "$XRAY_BIN" ] && menu_if_installed

    get_user_input
    install_xray_core
    generate_self_signed_cert
    generate_config
    setup_and_start_xray
    show_vmess_link
}

# --- 脚本入口 ---
main "$@"
