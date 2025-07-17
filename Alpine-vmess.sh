#!/bin/sh

# 脚本出现错误时立即退出
set -e

# --- 配置变量 ---
XRAY_VERSION="1.8.4"
CERT_DIR="/root/coca"
XRAY_BIN="/usr/local/bin/xray"
CONFIG_FILE="/etc/xray/config.json"
WS_PATH="/ws"

# --- 辅助函数 ---
green() { echo "\033[32m$1\033[0m"; }
red() { echo "\033[31m$1\033[0m"; }
yellow() { echo "\033[33m$1\033[0m"; }


# --- 功能函数 ---

# 显示 VMess 配置信息和链接
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

# 核心卸载逻辑（用于重新安装），保留证书和crontab
uninstall_for_reinstall() {
  echo "➡️ 正在停止并删除 Xray 程序及配置..."
  pkill xray || true
  rm -rf "$XRAY_BIN" /etc/xray
  green "✅ Xray 程序和配置已删除，证书和续期任务已保留。"
}

# 完整卸载功能（菜单选项3），删除所有相关文件
uninstall_xray() {
    yellow "⚠️ 警告：此操作将彻底删除 Xray 及其配置文件、证书和定时任务。"
    echo -n "您确定要卸载 Xray 吗? [y/N]: "
    read -r confirm_uninstall
    if [ "$confirm_uninstall" != "y" ] && [ "$confirm_uninstall" != "Y" ]; then
        echo "操作已取消。"
        exit 0
    fi

    echo "➡️ 正在停止并删除 Xray 程序及配置..."
    pkill xray || true
    rm -rf "$XRAY_BIN" /etc/xray

    echo "➡️ 正在删除证书目录 $CERT_DIR..."
    rm -rf "$CERT_DIR"

    echo "➡️ 正在从 crontab 中删除续期任务..."
    if [ -f "/etc/crontabs/root" ]; then
        sed -i '/acme.sh --cron/d' /etc/crontabs/root >/dev/null 2>&1 || true
    fi
    green "✅ Xray 核心组件、证书及续期任务已删除。"

    echo -n "❓ 是否要同时卸载 acme.sh 证书申请工具? (这将删除 /root/.acme.sh) [y/N]: "
    read -r confirm_acme
    if [ "$confirm_acme" = "y" ] || [ "$confirm_acme" = "Y" ]; then
        echo "➡️ 正在卸载 acme.sh..."
        /root/.acme.sh/acme.sh --uninstall >/dev/null 2>&1 || true
        rm -rf /root/.acme.sh
        green "✅ acme.sh 已卸载。"
    fi
    green "🎉 卸载完成。"
    exit 0
}

# 如果已安装 Xray，显示此菜单
menu_if_installed() {
  green "❗ 检测到 Xray 已安装，请选择操作："
  echo "   1) 显示 VMess 配置和链接"
  echo "   2) 重新安装 Xray (保留证书)"
  echo "   3) 彻底卸载 Xray (删除证书)"
  echo -n "请输入选项 [1-3]，按 Enter 键: "
  read -r option
  case "$option" in
    1) show_vmess_link ;;
    2)
      uninstall_for_reinstall
      echo "✅ 旧版本已卸载，即将开始重新安装..."
      ;;
    3)
      uninstall_xray
      ;;
    *) red "❌ 无效选项" && exit 1 ;;
  esac
}

# 安装依赖
install_dependencies() {
  if command -v apk >/dev/null 2>&1; then
    apk update
    apk add curl unzip socat jq bash openssl busybox-extras
  else
    echo "不支持的系统，请手动安装依赖"
    exit 1
  fi
}

# 安装 Xray 核心文件
install_xray_core() {
  mkdir -p /etc/xray
  [ -d "$XRAY_BIN" ] && rm -rf "$XRAY_BIN"
  [ -f "$XRAY_BIN" ] && rm -f "$XRAY_BIN"

  echo "➡️ 正在下载并安装 Xray v${XRAY_VERSION}..."
  curl -L -o xray.zip "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-64.zip"
  unzip -o xray.zip xray geo* || { red "❌ 解压失败"; exit 1; }
  mv -f xray "$XRAY_BIN"
  chmod +x "$XRAY_BIN"
  rm -f xray.zip
  green "✅ Xray 安装成功。"
}

# 获取用户输入
get_user_input() {
  echo -n "请输入你的域名（必须已解析到本服务器 IP）: "
  read -r DOMAIN
  echo -n "请输入监听端口 [默认: 443]: "
  read -r PORT
  [ -z "$PORT" ] && PORT=443
  UUID=$(cat /proc/sys/kernel/random/uuid)
}

# 申请证书
issue_cert() {
  # 确保acme.sh已安装
  if [ ! -f /root/.acme.sh/acme.sh ]; then
    curl https://get.acme.sh | sh
  fi
  . ~/.acme.sh/acme.sh.env

  ~/.acme.sh/acme.sh --register-account -m eflke1@gmail.com
  ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

  # 自动检测 IP 版本并设置 acme.sh 监听参数
  ACME_LISTEN_PARAM=""
  if curl -s -6 -m 10 "ifconfig.co" >/dev/null 2>&1; then
    green "✅ 检测到 IPv6 网络，将优先使用 IPv6 进行证书申请"
    ACME_LISTEN_PARAM="--listen-v6"
  elif curl -s -4 -m 10 "ifconfig.co" >/dev/null 2>&1; then
    green "✅ 检测到 IPv4 网络，将使用 IPv4 进行证书申请"
    ACME_LISTEN_PARAM="--listen-v4"
  else
    red "❌ 无法检测到有效的公网 IP (IPv4 或 IPv6)，请检查网络连接。"
    red "   证书申请无法继续。"
    exit 1
  fi

  # 停止可能占用 80 端口的服务
  echo "➡️ 正在停止 80 端口服务，以确保证书申请成功..."
  fuser -k 80/tcp || true
  sleep 1

  # 使用动态检测到的参数来申请证书
  echo "➡️ 正在为 $DOMAIN 申请 Let's Encrypt 证书..."
  ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone $ACME_LISTEN_PARAM --keylength ec-256 || return 1

  # 安装证书并设置定时任务
  ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
    --ecc \
    --key-file "$CERT_DIR/${DOMAIN}.key" \
    --fullchain-file "$CERT_DIR/${DOMAIN}.cer" \
    --reloadcmd "pkill -f xray && $XRAY_BIN run -c $CONFIG_FILE &"
  
  # 确保cron任务不重复添加
  if ! grep -q "acme.sh --cron" /etc/crontabs/root 2>/dev/null; then
    echo "0 3 * * * /root/.acme.sh/acme.sh --cron --home /root/.acme.sh > /dev/null 2>&1" >> /etc/crontabs/root
  fi
  crond
}

# 生成自签名证书（备用方案）
generate_self_signed_cert() {
  red "⚠️ ACME 证书申请失败，将使用自签证书..."
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "$CERT_DIR/${DOMAIN}.key" -out "$CERT_DIR/${DOMAIN}.cer" \
    -subj="/CN=$DOMAIN"
  green "✅ 自签证书已生成。"
}

# 生成 Xray 配置文件
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
  green "✅ 配置文件已生成。"
}

# 启动 Xray
start_xray() {
  nohup "$XRAY_BIN" run -c "$CONFIG_FILE" > /dev/null 2>&1 &
  sleep 2
  if pgrep -f "$XRAY_BIN" >/dev/null; then
    green "✅ Xray 启动成功！"
  else
    red "❌ Xray 启动失败，请检查日志或配置。"
    exit 1
  fi
}

# --- 主函数 ---
main() {
  # 如果 Xray 已安装，显示管理菜单
  if [ -f "$XRAY_BIN" ]; then
    menu_if_installed
  fi

  # 执行安装流程
  install_dependencies
  get_user_input
  install_xray_core

  # 检查证书是否存在，不存在则申请
  mkdir -p "$CERT_DIR"
  if [ -f "$CERT_DIR/${DOMAIN}.key" ] && [ -f "$CERT_DIR/${DOMAIN}.cer" ]; then
      green "✅ 检测到域名 $DOMAIN 的现有证书，将直接使用。"
  else
      yellow "⚠️ 未找到 $DOMAIN 的证书，开始申请新证书..."
      if issue_cert; then
          green "✅ 证书申请及安装成功。"
      else
          generate_self_signed_cert
      fi
  fi

  generate_config
  start_xray
  show_vmess_link
}

# --- 脚本入口 ---
main "$@"
