#!/bin/sh
set -e

XRAY_VERSION="1.8.4"
CERT_DIR="/root/coca"
XRAY_BIN="/usr/local/bin/xray"
CONFIG_FILE="/etc/xray/config.json"
WS_PATH="/ws"

green() { echo "\033[32m$1\033[0m"; }
red() { echo "\033[31m$1\033[0m"; }
yellow() { echo "\033[33m$1\033[0m"; }

create_openrc_service() {
cat > /etc/init.d/xray <<'EOF'
#!/sbin/openrc-run
description="Xray Service"
command="/usr/local/bin/xray"
command_args="run -c /etc/xray/config.json"
command_background="yes"
pidfile="/run/xray.pid"
respawn_delay=5
respawn_max=10
depend() {
    need net
}
EOF

chmod +x /etc/init.d/xray
rc-update add xray default >/dev/null 2>&1 || true
}

show_vmess_link() {
  [ ! -f "$CONFIG_FILE" ] && red "❌ 未找到配置文件" && exit 1
  UUID=$(jq -r '.inbounds[0].settings.clients[0].id' "$CONFIG_FILE")
  DOMAIN=$(jq -r '.inbounds[0].streamSettings.tlsSettings.certificates[0].certificateFile' "$CONFIG_FILE" | sed 's/.*\///;s/\.cer//')
  PORT=$(jq -r '.inbounds[0].port' "$CONFIG_FILE")

  vmess_json=$(cat <<EOF
{
  "v": "2",
  "ps": "$DOMAIN",
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

  vmess_link="vmess://$(echo "$vmess_json" | base64 -w 0)"

  echo
  green "🎉 VMess 配置信息如下："
  echo "======================================"
  echo "地址: $DOMAIN"
  echo "端口: $PORT"
  echo "UUID: $UUID"
  echo "WS路径: $WS_PATH"
  echo "TLS证书: 已启用"
  echo "VMess链接:"
  echo "$vmess_link"
  echo "======================================"
  exit 0
}

install_dependencies() {
  apk update
  apk add curl unzip socat jq bash openssl busybox-extras
}

install_xray_core() {
  mkdir -p /etc/xray
  rm -f "$XRAY_BIN"

  echo "➡️ 正在下载并安装 Xray v${XRAY_VERSION}..."
  curl -L -o xray.zip "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-64.zip"
  unzip -o xray.zip xray geo* >/dev/null
  mv -f xray "$XRAY_BIN"
  chmod +x "$XRAY_BIN"
  rm -f xray.zip

  create_openrc_service
  green "✅ Xray 安装成功。"
}

get_user_input() {
  echo -n "请输入你的域名（必须已解析到本服务器 IP）: "
  read -r DOMAIN
  echo -n "请输入监听端口 [默认: 443]: "
  read -r PORT
  [ -z "$PORT" ] && PORT=443
  UUID=$(cat /proc/sys/kernel/random/uuid)
}

issue_cert() {
  if [ ! -f /root/.acme.sh/acme.sh ]; then
    curl https://get.acme.sh | sh
  fi
  . ~/.acme.sh/acme.sh.env

  ~/.acme.sh/acme.sh --register-account -m test@example.com >/dev/null 2>&1
  ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

  fuser -k 80/tcp >/dev/null 2>&1 || true
  sleep 1

  ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --keylength ec-256

  ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
    --ecc \
    --key-file "$CERT_DIR/${DOMAIN}.key" \
    --fullchain-file "$CERT_DIR/${DOMAIN}.cer" \
    --reloadcmd "rc-service xray restart"

  if ! grep -q "acme.sh --cron" /etc/crontabs/root 2>/dev/null; then
    echo "0 3 * * * /root/.acme.sh/acme.sh --cron --home /root/.acme.sh > /dev/null 2>&1" >> /etc/crontabs/root
  fi
  crond
}

generate_config() {
cat > "$CONFIG_FILE" <<EOF
{
  "inbounds": [{
    "port": $PORT,
    "protocol": "vmess",
    "settings": {
      "clients": [{
        "id": "$UUID",
        "alterId": 0
      }]
    },
    "streamSettings": {
      "network": "ws",
      "security": "tls",
      "tlsSettings": {
        "certificates": [{
          "certificateFile": "$CERT_DIR/${DOMAIN}.cer",
          "keyFile": "$CERT_DIR/${DOMAIN}.key"
        }]
      },
      "wsSettings": {
        "path": "$WS_PATH"
      }
    }
  }],
  "outbounds": [{
    "protocol": "freedom",
    "settings": {}
  }]
}
EOF
}

start_xray() {
  rc-service xray stop >/dev/null 2>&1 || true
  rc-service xray start
  sleep 2
  if rc-service xray status | grep -q started; then
    green "✅ Xray 服务启动成功！"
  else
    red "❌ Xray 启动失败"
    exit 1
  fi
}

main() {
  if [ -f "$XRAY_BIN" ]; then
    green "❗ 检测到已安装，将重新安装并覆盖"
    rc-service xray stop >/dev/null 2>&1 || true
  fi

  install_dependencies
  get_user_input
  install_xray_core

  mkdir -p "$CERT_DIR"
  issue_cert

  generate_config
  start_xray
  show_vmess_link
}

main "$@"
