#!/bin/sh

set -e

XRAY_VERSION="1.8.4"
CERT_DIR="/root/coca"
XRAY_BIN="/usr/local/bin/xray"
CONFIG_FILE="/etc/xray/config.json"
WS_PATH="/ws"

green() { echo "\033[32m$1\033[0m"; }
red() { echo "\033[31m$1\033[0m"; }

show_vmess_link() {
  [ ! -f "$CONFIG_FILE" ] && red "❌ 未找到配置文件" && exit 1
  UUID=$(jq -r '.inbounds[0].settings.clients[0].id' "$CONFIG_FILE")
  DOMAIN=$(jq -r '.inbounds[0].streamSettings.tlsSettings.certificates[0].certificateFile' "$CONFIG_FILE" | sed 's/.*\///;s/\.cer//')
  PORT=$(jq -r '.inbounds[0].port' "$CONFIG_FILE")
  local vmess_json=$(cat <<EOF
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
  local vmess_link="vmess://$(echo "$vmess_json" | base64 -w 0)"
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

delete_xray() {
  echo "⚠️ 正在删除 Xray..."
  pkill xray || true
  rm -rf "$XRAY_BIN" /etc/xray "$CERT_DIR"
  echo "✅ 删除完成，继续重新安装..."
}

menu_if_installed() {
  green "❗ 检测到 Xray 已安装，选择操作："
  echo "1) 显示 VMess 链接"
  echo "2) 删除并重新安装"
  echo -n "请输入选项 [1-2]: "
  read option
  case "$option" in
    1) show_vmess_link ;;
    2) delete_xray ;;
    *) red "无效选项" && exit 1 ;;
  esac
}

install_dependencies() {
  if command -v apk >/dev/null 2>&1; then
    apk update
    apk add curl unzip socat jq bash openssl busybox-extras
  else
    echo "不支持的系统，请手动安装依赖"
    exit 1
  fi
}

install_xray() {
  mkdir -p /etc/xray
  [ -d "$XRAY_BIN" ] && rm -rf "$XRAY_BIN"
  [ -f "$XRAY_BIN" ] && rm -f "$XRAY_BIN"

  curl -L -o xray.zip https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-64.zip
  unzip -o xray.zip xray geo* || { red "❌ 解压失败"; exit 1; }
  mv -f xray "$XRAY_BIN"
  chmod +x "$XRAY_BIN"
  rm -f xray.zip
}

get_user_input() {
  echo -n "请输入你的域名（必须已解析到本服务器 IP）: "
  read DOMAIN
  echo -n "请输入监听端口 [默认: 443]: "
  read PORT
  [ -z "$PORT" ] && PORT=443
  UUID=$(cat /proc/sys/kernel/random/uuid)
}

issue_cert() {
  mkdir -p "$CERT_DIR"
  curl https://get.acme.sh | sh
  . ~/.acme.sh/acme.sh.env

  ~/.acme.sh/acme.sh --register-account -m eflke1@gmail.com
  ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

  ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --keylength ec-256 || return 1
  ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
    --ecc \
    --key-file "$CERT_DIR/${DOMAIN}.key" \
    --fullchain-file "$CERT_DIR/${DOMAIN}.cer" \
    --reloadcmd "pkill -f xray && $XRAY_BIN run -c $CONFIG_FILE &"

  echo "0 3 * * * /root/.acme.sh/acme.sh --cron --home /root/.acme.sh > /dev/null 2>&1" >> /etc/crontabs/root
  crond
}

generate_self_signed_cert() {
  echo "⚠️ ACME 证书申请失败，使用自签证书..."
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "$CERT_DIR/${DOMAIN}.key" -out "$CERT_DIR/${DOMAIN}.cer" \
    -subj "/CN=$DOMAIN"
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
  nohup "$XRAY_BIN" run -c "$CONFIG_FILE" > /dev/null 2>&1 &
  sleep 2
  if pgrep -f "$XRAY_BIN" >/dev/null; then
    green "✅ Xray 启动成功"
  else
    red "❌ Xray 启动失败，请检查配置"
    exit 1
  fi
}

main() {
  if [ -f "$XRAY_BIN" ]; then
    menu_if_installed
  fi
  install_dependencies
  get_user_input
  install_xray

  if issue_cert; then
    green "✅ 证书申请成功"
  else
    generate_self_signed_cert
  fi

  generate_config
  start_xray
  show_vmess_link
}

main "$@"
