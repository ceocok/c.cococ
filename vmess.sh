#!/bin/sh

# 脚本出现错误时立即退出
set -e

# --- 配置变量 ---
XRAY_VERSION="25.12.2"
CERT_DIR="/root/coca"
XRAY_BIN="/usr/local/bin/xray"
SYSTEMD_FILE="/etc/systemd/system/xray.service"
OPENRC_FILE="/etc/init.d/xray"
CONFIG_FILE="/etc/xray/config.json"
WS_PATH="/ws"

# --- 辅助函数 (修正颜色显示) ---
green() { printf "\033[32m%s\033[0m\n" "$1"; }
red() { printf "\033[31m%s\033[0m\n" "$1"; }
yellow() { printf "\033[33m%s\033[0m\n" "$1"; }

# --- 环境检测 ---
PKG_MANAGER=""
INSTALL_CMD=""
UPDATE_CMD=""
DEPS_UPDATED=""

detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt"; INSTALL_CMD="apt-get install -y"; UPDATE_CMD="apt-get update"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"; INSTALL_CMD="yum install -y"; UPDATE_CMD="yum makecache"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"; INSTALL_CMD="dnf install -y"; UPDATE_CMD="dnf makecache"
    elif command -v apk >/dev/null 2>&1;then
        PKG_MANAGER="apk"; INSTALL_CMD="apk add"; UPDATE_CMD="apk update"
    fi
}

ensure_command() {
    local cmd="$1"
    if command -v "$cmd" >/dev/null 2>&1; then return 0; fi
    yellow "⏳ 正在安装缺失组件: $cmd ..."
    [ -z "$PKG_MANAGER" ] && detect_pkg_manager
    local pkg_name="$cmd"
    [ "$cmd" = "jq" ] && { [ "$PKG_MANAGER" = "yum" ] || [ "$PKG_MANAGER" = "dnf" ]; } && $INSTALL_CMD epel-release >/dev/null 2>&1 || true
    [ "$cmd" = "crontab" ] && { [ "$PKG_MANAGER" = "apk" ] && pkg_name="busybox-extras" || ([ "$PKG_MANAGER" = "apt" ] && pkg_name="cron" || pkg_name="cronie"); }
    [ "$cmd" = "fuser" ] && pkg_name="psmisc"
    [ -z "$DEPS_UPDATED" ] && { $UPDATE_CMD >/dev/null 2>&1; DEPS_UPDATED="true"; }
    $INSTALL_CMD "$pkg_name"
}

# --- 功能函数 ---

check_status() {
    echo "--------------------------------------"
    if systemctl --version >/dev/null 2>&1; then
        if systemctl is-active --quiet xray; then
            green "● Xray 运行状态: 正在运行 (systemd)"
        else
            red "● Xray 运行状态: 已停止 (systemd)"
        fi
        systemctl status xray --no-pager | grep -E "Active:|Main PID:" || true
    elif rc-service --version >/dev/null 2>&1; then
        if rc-service -e xray; then
            green "● Xray 运行状态: 正在运行 (OpenRC)"
        else
            red "● Xray 运行状态: 已停止 (OpenRC)"
        fi
    else
        if pgrep -f "$XRAY_BIN" >/dev/null; then
            green "● Xray 运行状态: 正在运行 (PID: $(pgrep -f "$XRAY_BIN"))"
        else
            red "● Xray 运行状态: 未运行 (nohup)"
        fi
    fi
    echo "--------------------------------------"
}

restart_xray() {
    echo "➡️ 正在重启 Xray 服务..."
    if systemctl --version >/dev/null 2>&1; then
        systemctl restart xray && sleep 2
        systemctl is-active --quiet xray && green "✅ 重启成功" || red "❌ 重启失败"
    elif rc-service --version >/dev/null 2>&1; then
        rc-service xray restart && sleep 2
        rc-service -e xray && green "✅ 重启成功" || red "❌ 重启失败"
    else
        pkill -f "$XRAY_BIN" || true && sleep 1
        nohup "$XRAY_BIN" run -c "$CONFIG_FILE" > /dev/null 2>&1 &
        sleep 2
        pgrep -f "$XRAY_BIN" >/dev/null && green "✅ 重启成功" || red "❌ 重启失败"
    fi
}

show_vmess_link() {
    [ ! -f "$CONFIG_FILE" ] && { red "❌ 未找到配置文件"; return; }
    ensure_command "jq"
    UUID=$(jq -r '.inbounds[0].settings.clients[0].id' "$CONFIG_FILE")
    PORT=$(jq -r '.inbounds[0].port' "$CONFIG_FILE")
    CERT_PATH=$(jq -r '.inbounds[0].streamSettings.tlsSettings.certificates[0].certificateFile' "$CONFIG_FILE")
    DOMAIN=$(basename "$CERT_PATH" .cer)
    
    local vmess_json=$(cat <<EOF
{ "v": "2", "ps": "${DOMAIN}-vmess", "add": "$DOMAIN", "port": "$PORT", "id": "$UUID", "aid": "0", "net": "ws", "type": "none", "host": "$DOMAIN", "path": "$WS_PATH", "tls": "tls" }
EOF
)
    local vmess_link="vmess://$(printf '%s' "$vmess_json" | base64 | tr -d '\n')"

    echo ""
    green "======================================"
    green "       VMess 详细配置信息"
    green "======================================"
    echo " 地址 (Address)   : $DOMAIN"
    echo " 端口 (Port)      : $PORT"
    echo " 用户ID (UUID)    : $UUID"
    echo " 传输协议 (Net)   : ws"
    echo " 伪装类型 (Type)  : none"
    echo " 伪装域名 (Host)  : $DOMAIN"
    echo " 路径 (Path)      : $WS_PATH"
    echo " 安全传输 (TLS)   : tls"
    green "======================================"
    green " VMess 链接 (直接导入客户端):"
    echo "$vmess_link"
    green "======================================"
}

modify_port() {
    ensure_command "jq"
    local current_port=$(jq -r '.inbounds[0].port' "$CONFIG_FILE")
    echo -n "当前端口 $current_port，请输入新端口 (1-65535): "
    read -r new_port
    if ! echo "$new_port" | grep -Eq '^[0-9]+$' || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        red "❌ 无效端口"; return
    fi
    jq --argjson newport "$new_port" '.inbounds[0].port = $newport' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    restart_xray
    show_vmess_link
}

uninstall_xray() {
    yellow "⚠️ 确认卸载 Xray 及其所有配置与证书？ [y/N]"; read -r confirm
    [ "$confirm" != "y" ] && return
    if systemctl --version >/dev/null 2>&1; then systemctl stop xray || true; systemctl disable xray || true; rm -f "$SYSTEMD_FILE"
    elif rc-service --version >/dev/null 2>&1; then rc-service xray stop || true; rc-update del xray || true; rm -f "$OPENRC_FILE"
    else pkill -f "$XRAY_BIN" || true; fi
    rm -rf "$XRAY_BIN" /etc/xray "$CERT_DIR"
    green "✅ 已彻底卸载"
    exit 0
}

menu_if_installed() {
    check_status
    green "请选择操作："
    echo "   1) 显示 VMess 详细配置与链接"
    echo "   2) 重启 Xray 服务"
    echo "   3) 修改监听端口"
    echo "   4) 重新安装 Xray (保留证书)"
    echo "   5) 彻底卸载 Xray"
    echo "   0) 退出脚本"
    echo -n "请输入选项 [0-5]: "
    read -r option
    case "$option" in
        1) show_vmess_link ;;
        2) restart_xray ;;
        3) modify_port ;;
        4) pkill -f "$XRAY_BIN" || true; rm -rf "$XRAY_BIN" /etc/xray; return 0 ;;
        5) uninstall_xray ;;
        0) exit 0 ;;
        *) red "❌ 无效选项"; menu_if_installed ;;
    esac
    exit 0
}

# --- 安装逻辑 ---
main() {
    detect_pkg_manager
    [ -f "$XRAY_BIN" ] && menu_if_installed

    echo -n "请输入域名 (需提前解析): "; read -r DOMAIN
    [ -z "$DOMAIN" ] && { red "❌ 域名不能为空"; exit 1; }
    echo -n "请输入端口 [默认443]: "; read -r PORT; [ -z "$PORT" ] && PORT=443
    UUID=$(cat /proc/sys/kernel/random/uuid)

    ensure_command "curl"; ensure_command "unzip"; ensure_command "socat"
    
    # 安装核心
    ARCH=$(uname -m); [ "$ARCH" = "x86_64" ] && XRAY_ARCH="64" || XRAY_ARCH="arm64-v8a"
    curl -L -o xray.zip "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-${XRAY_ARCH}.zip"
    mkdir -p /etc/xray /tmp/xray && unzip -o xray.zip -d /tmp/xray
    mv -f /tmp/xray/xray "$XRAY_BIN" && chmod +x "$XRAY_BIN"
    mv -f /tmp/xray/geo* /etc/xray/ && rm -rf xray.zip /tmp/xray

    # 证书处理
    mkdir -p "$CERT_DIR"
    if [ ! -f "$CERT_DIR/${DOMAIN}.cer" ]; then
        [ ! -f /root/.acme.sh/acme.sh ] && curl https://get.acme.sh | sh
        . ~/.acme.sh/acme.sh.env
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        ensure_command "fuser"; fuser -k 80/tcp >/dev/null 2>&1 || true
        ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --keylength ec-256 || \
        { yellow "⚠️ ACME 失败，生成自签证书"; ensure_command "openssl"; openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -keyout "$CERT_DIR/${DOMAIN}.key" -out "$CERT_DIR/${DOMAIN}.cer" -subj "/CN=$DOMAIN"; }
        [ -f /root/.acme.sh/acme.sh ] && ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc --key-file "$CERT_DIR/${DOMAIN}.key" --fullchain-file "$CERT_DIR/${DOMAIN}.cer" || true
    fi

    # 配置文件
    cat > "$CONFIG_FILE" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "port": $PORT,
    "protocol": "vmess",
    "settings": {"clients": [{"id": "$UUID"}]},
    "streamSettings": {
      "network": "ws",
      "security": "tls",
      "tlsSettings": {
        "certificates": [{"certificateFile": "$CERT_DIR/${DOMAIN}.cer", "keyFile": "$CERT_DIR/${DOMAIN}.key"}]
      },
      "wsSettings": {"path": "$WS_PATH"}
    }
  }],
  "outbounds": [{"protocol": "freedom", "settings": {}}]
}
EOF

    # 启动服务
    if command -v systemctl >/dev/null 2>&1; then
        cat > "$SYSTEMD_FILE" <<EOF
[Unit]
Description=Xray Service
After=network.target
[Service]
ExecStart=$XRAY_BIN run -c $CONFIG_FILE
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload && systemctl enable xray && systemctl start xray
    elif command -v rc-update >/dev/null 2>&1; then
        cat > "$OPENRC_FILE" <<EOF
#!/sbin/openrc-run
supervisor=supervise-daemon
command="$XRAY_BIN"
command_args="run -c $CONFIG_FILE"
EOF
        chmod +x "$OPENRC_FILE" && rc-update add xray default && rc-service xray start
    else
        nohup "$XRAY_BIN" run -c "$CONFIG_FILE" > /dev/null 2>&1 &
    fi

    show_vmess_link
}

main "$@"
