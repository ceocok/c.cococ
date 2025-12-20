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

# --- 辅助函数 ---
green() { echo -e "\033[32m$1\033[0m"; }
red() { echo -e "\033[31m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }

# --- 检测包管理器 ---
PKG_MANAGER=""
INSTALL_CMD=""
UPDATE_CMD=""
DEPS_UPDATED=""

detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt"
        INSTALL_CMD="apt-get install -y"
        UPDATE_CMD="apt-get update"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
        INSTALL_CMD="yum install -y"
        UPDATE_CMD="yum makecache"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
        INSTALL_CMD="dnf install -y"
        UPDATE_CMD="dnf makecache"
    elif command -v apk >/dev/null 2>&1;then
        PKG_MANAGER="apk"
        INSTALL_CMD="apk add"
        UPDATE_CMD="apk update"
    fi
}

ensure_command() {
    local cmd="$1"
    if command -v "$cmd" >/dev/null 2>&1; then return 0; fi
    yellow "⏳ 命令 '$cmd' 未找到，正在尝试安装..."
    if [ -z "$PKG_MANAGER" ]; then red "❌ 无法检测到包管理器"; exit 1; fi

    local pkg_name
    case "$cmd" in
        curl) pkg_name="curl" ;;
        unzip) pkg_name="unzip" ;;
        jq) pkg_name="jq" ;;
        socat) pkg_name="socat" ;;
        openssl) pkg_name="openssl" ;;
        crontab) [ "$PKG_MANAGER" = "apk" ] && pkg_name="busybox-extras" || ([ "$PKG_MANAGER" = "apt" ] && pkg_name="cron" || pkg_name="cronie") ;;
        fuser) pkg_name="psmisc" ;;
        *) red "❌ 未知命令 '$cmd'"; exit 1 ;;
    esac

    if [ -z "$DEPS_UPDATED" ]; then $UPDATE_CMD >/dev/null 2>&1; DEPS_UPDATED="true"; fi
    if [ "$pkg_name" = "jq" ] && { [ "$PKG_MANAGER" = "yum" ] || [ "$PKG_MANAGER" = "dnf" ]; }; then $INSTALL_CMD epel-release >/dev/null 2>&1 || true; fi
    $INSTALL_CMD "$pkg_name"
}

# --- 功能函数 ---

# 1. 查看运行状态 (新增)
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

# 2. 重启 Xray (优化原有并整合)
restart_xray() {
    echo "➡️ 正在重启 Xray 服务..."
    if systemctl --version >/dev/null 2>&1; then
        systemctl restart xray
        sleep 2
        systemctl is-active --quiet xray && green "✅ 重启成功" || red "❌ 重启失败"
    elif rc-service --version >/dev/null 2>&1; then
        rc-service xray restart
        sleep 2
        rc-service -e xray && green "✅ 重启成功" || red "❌ 重启失败"
    else
        pkill -f "$XRAY_BIN" || true
        sleep 1
        nohup "$XRAY_BIN" run -c "$CONFIG_FILE" > /dev/null 2>&1 &
        sleep 2
        pgrep -f "$XRAY_BIN" >/dev/null && green "✅ 重启成功" || red "❌ 重启失败"
    fi
}

# 3. 显示链接
show_vmess_link() {
  [ ! -f "$CONFIG_FILE" ] && red "❌ 未找到 Xray 配置文件" && exit 1
  ensure_command "jq"
  UUID=$(jq -r '.inbounds[0].settings.clients[0].id' "$CONFIG_FILE")
  DOMAIN=$(jq -r '.inbounds[0].streamSettings.tlsSettings.certificates[0].certificateFile' "$CONFIG_FILE" | sed 's/.*\///;s/\.cer//')
  PORT=$(jq -r '.inbounds[0].port' "$CONFIG_FILE")
  local vmess_json=$(cat <<EOF
{ "v": "2", "ps": "${DOMAIN}-vmess", "add": "$DOMAIN", "port": "$PORT", "id": "$UUID", "aid": "0", "net": "ws", "type": "none", "host": "$DOMAIN", "path": "$WS_PATH", "tls": "tls" }
EOF
)
  local vmess_link="vmess://$(echo "$vmess_json" | base64 -w 0)"
  echo ""
  green "🎉 VMess 配置信息如下："
  echo " 地址: $DOMAIN | 端口: $PORT | UUID: $UUID"
  green "VMess 链接:"
  echo "$vmess_link"
}

# 4. 修改端口
modify_port() {
    ensure_command "jq"
    local current_port=$(jq -r '.inbounds[0].port' "$CONFIG_FILE")
    echo -n "当前端口 $current_port，请输入新端口: "
    read -r new_port
    if ! echo "$new_port" | grep -Eq '^[0-9]+$' || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        red "❌ 无效端口"; exit 1
    fi
    jq --argjson newport "$new_port" '.inbounds[0].port = $newport' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    restart_xray
    show_vmess_link
}

# 5. 卸载相关
stop_xray() {
    if systemctl --version >/dev/null 2>&1; then systemctl stop xray || true
    elif rc-service --version >/dev/null 2>&1; then rc-service xray stop || true
    else pkill -f "$XRAY_BIN" || true; fi
}

uninstall_xray() {
    yellow "⚠️ 确认卸载 Xray 及其所有配置？ [y/N]"; read -r confirm
    [ "$confirm" != "y" ] && exit 0
    stop_xray
    [ -f "$SYSTEMD_FILE" ] && (systemctl disable xray; rm -f "$SYSTEMD_FILE")
    [ -f "$OPENRC_FILE" ] && (rc-update del xray; rm -f "$OPENRC_FILE")
    rm -rf "$XRAY_BIN" /etc/xray "$CERT_DIR"
    green "✅ 已彻底卸载"
    exit 0
}

# --- 菜单控制 ---
menu_if_installed() {
  check_status
  green "请选择操作："
  echo "   1) 显示 VMess 配置和链接"
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
    4) stop_xray; rm -rf "$XRAY_BIN" /etc/xray; echo "➡️ 准备重新安装..."; return 0 ;;
    5) uninstall_xray ;;
    0) exit 0 ;;
    *) red "❌ 无效选项" && exit 1 ;;
  esac
  exit 0
}

# --- 核心安装逻辑 ---
install_xray_core() {
  mkdir -p /etc/xray
  ensure_command "curl"; ensure_command "unzip"
  ARCH=$(uname -m); [ "$ARCH" = "x86_64" ] && XRAY_ARCH="64" || XRAY_ARCH="arm64-v8a"
  curl -L -o xray.zip "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-${XRAY_ARCH}.zip"
  unzip -o xray.zip -d /tmp/xray && mv -f /tmp/xray/xray "$XRAY_BIN" && chmod +x "$XRAY_BIN"
  mv -f /tmp/xray/geo* /etc/xray/ && rm -rf xray.zip /tmp/xray
}

issue_cert() {
  ensure_command "curl"; ensure_command "socat"; ensure_command "crontab"
  [ ! -f /root/.acme.sh/acme.sh ] && curl https://get.acme.sh | sh
  . ~/.acme.sh/acme.sh.env
  ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
  ~/.acme.sh/acme.sh --register-account -m "admin@${DOMAIN}"
  ensure_command "fuser"; fuser -k 80/tcp >/dev/null 2>&1 || true
  ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --keylength ec-256 || return 1
  ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
    --key-file "$CERT_DIR/${DOMAIN}.key" --fullchain-file "$CERT_DIR/${DOMAIN}.cer" \
    --reloadcmd "rc-service xray restart >/dev/null 2>&1 || systemctl restart xray >/dev/null 2>&1 || pkill -f xray"
}

setup_and_start_xray() {
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
  green "✅ 启动指令已发出"
}

main() {
  detect_pkg_manager
  [ -f "$XRAY_BIN" ] && menu_if_installed

  echo -n "请输入你的域名: "; read -r DOMAIN
  echo -n "请输入监听端口 [默认443]: "; read -r PORT; [ -z "$PORT" ] && PORT=443
  UUID=$(cat /proc/sys/kernel/random/uuid)

  install_xray_core
  mkdir -p "$CERT_DIR"
  if [ ! -f "$CERT_DIR/${DOMAIN}.cer" ]; then
    issue_cert || (red "⚠️ 申请失败，生成自签证书"; ensure_command "openssl"; openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -keyout "$CERT_DIR/${DOMAIN}.key" -out "$CERT_DIR/${DOMAIN}.cer" -subj "/CN=$DOMAIN")
  fi

  cat > "$CONFIG_FILE" <<EOF
{ "log": {"loglevel": "warning"}, "inbounds": [{ "port": $PORT, "protocol": "vmess", "settings": { "clients": [{ "id": "$UUID" }] }, "streamSettings": { "network": "ws", "security": "tls", "tlsSettings": { "certificates": [{ "certificateFile": "$CERT_DIR/${DOMAIN}.cer", "keyFile": "$CERT_DIR/${DOMAIN}.key" }] }, "wsSettings": { "path": "$WS_PATH" } } }], "outbounds": [{ "protocol": "freedom", "settings": {} }] }
EOF
  setup_and_start_xray
  show_vmess_link
}

main "$@"
