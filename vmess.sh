#!/bin/sh

# 脚本出现错误时立即退出
set -e

# --- 配置变量 ---
XRAY_VERSION="1.8.4"
CERT_DIR="/root/coca"
XRAY_BIN="/usr/local/bin/xray"
SYSTEMD_FILE="/etc/systemd/system/xray.service"
CONFIG_FILE="/etc/xray/config.json"
WS_PATH="/ws"

# --- 辅助函数 (已移除颜色代码) ---
green() { echo "$1"; }
red() { echo "$1"; }
yellow() { echo "$1"; }

# --- 按需安装依赖的核心函数 ---

# 定义全局变量用于存储包管理器信息
PKG_MANAGER=""
INSTALL_CMD=""
UPDATE_CMD=""
DEPS_UPDATED="" # 标志位，防止重复更新

# 检测包管理器
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

# 确保命令可用，如果不可用则尝试安装
ensure_command() {
    local cmd="$1"
    if command -v "$cmd" >/dev/null 2>&1; then
        return 0 # 命令已存在，直接返回
    fi

    yellow "⏳ 命令 '$cmd' 未找到，正在尝试安装..."
    
    if [ -z "$PKG_MANAGER" ]; then
        red "❌ 无法检测到有效的包管理器 (apt, yum, dnf, apk)。"
        red "❌ 请手动安装 '$cmd' 后再重新运行脚本。"
        exit 1
    fi

    local pkg_name
    case "$cmd" in
        curl) pkg_name="curl" ;;
        unzip) pkg_name="unzip" ;;
        jq) pkg_name="jq" ;;
        socat) pkg_name="socat" ;;
        openssl) pkg_name="openssl" ;;
        crontab) [ "$PKG_MANAGER" = "apk" ] && pkg_name="busybox-extras" || ([ "$PKG_MANAGER" = "apt" ] && pkg_name="cron" || pkg_name="cronie") ;;
        fuser) pkg_name="psmisc" ;;
        *)
            red "❌ 内部错误：无法确定命令 '$cmd' 对应的软件包名。"
            exit 1
            ;;
    esac

    if [ -z "$DEPS_UPDATED" ]; then
        echo "➡️ 首次安装依赖，正在更新软件包列表..."
        $UPDATE_CMD >/dev/null 2>&1
        DEPS_UPDATED="true"
    fi

    if [ "$pkg_name" = "jq" ] && { [ "$PKG_MANAGER" = "yum" ] || [ "$PKG_MANAGER" = "dnf" ]; }; then
         $INSTALL_CMD epel-release >/dev/null 2>&1 || true
    fi

    $INSTALL_CMD "$pkg_name"

    if ! command -v "$cmd" >/dev/null 2>&1; then
        red "❌ 安装软件包 '$pkg_name' 失败，或安装后 '$cmd' 命令依然不可用。"
        red "❌ 请检查以上错误信息并手动安装后重试。"
        exit 1
    fi
    green "✅ 命令 '$cmd' 已成功安装。"
}


# --- 功能函数 ---

# 显示 VMess 配置信息和链接
show_vmess_link() {
  [ ! -f "$CONFIG_FILE" ] && red "❌ 未找到 Xray 配置文件" && exit 1
  ensure_command "jq"
  UUID=$(jq -r '.inbounds[0].settings.clients[0].id' "$CONFIG_FILE")
  DOMAIN=$(jq -r '.inbounds[0].streamSettings.tlsSettings.certificates[0].certificateFile' "$CONFIG_FILE" | sed 's/.*\///;s/\.cer//')
  PORT=$(jq -r '.inbounds[0].port' "$CONFIG_FILE")
  local vmess_json=$(cat <<EOF
{
  "v": "2",
  "ps": "${DOMAIN}-vmess",
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
  echo " 地址 (Address): $DOMAIN"
  echo " 端口 (Port): $PORT"
  echo " 用户ID (UUID): $UUID"
  echo " 额外ID (AlterId): 0"
  echo " 加密方式 (Security): auto"
  echo " 传输协议 (Network): ws"
  echo " WebSocket 路径 (Path): $WS_PATH"
  echo " SNI / 伪装域名 (Host): $DOMAIN"
  echo " 底层传输安全 (TLS): tls"
  echo " 证书路径 (服务器端): $CERT_DIR/${DOMAIN}.cer"
  echo "======================================"
  green "VMess 链接 (复制并导入到客户端):"
  echo "$vmess_link"
  echo "======================================"
  exit 0
}

# 停止 Xray
stop_xray() {
    if [ -f "$SYSTEMD_FILE" ]; then
        systemctl stop xray || true
    else
        pkill xray || true
    fi
}

# 核心卸载逻辑（用于重新安装），保留证书和crontab
uninstall_for_reinstall() {
  echo "➡️ 正在停止并删除 Xray 程序及配置..."
  stop_xray
  if [ -f "$SYSTEMD_FILE" ]; then
    systemctl disable xray >/dev/null 2>&1 || true
    rm -f "$SYSTEMD_FILE"
  fi
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

    echo "➡️ 正在停止并卸载 Xray..."
    stop_xray
    if [ -f "$SYSTEMD_FILE" ]; then
        echo "➡️ 正在禁用并删除 systemd 服务..."
        systemctl disable xray >/dev/null 2>&1 || true
        rm -f "$SYSTEMD_FILE"
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    echo "➡️ 正在删除 Xray 程序及配置目录..."
    rm -rf "$XRAY_BIN" /etc/xray

    echo "➡️ 正在删除证书目录 $CERT_DIR..."
    rm -rf "$CERT_DIR"

    echo "➡️ 正在从 crontab 中删除续期任务..."
    ensure_command "crontab"
    (crontab -l 2>/dev/null | grep -Fv "acme.sh --cron") | crontab - >/dev/null 2>&1

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

# 安装 Xray 核心文件
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
  green "✅ Xray 安装成功。"
}

# 获取用户输入
get_user_input() {
  echo -n "请输入你的域名（必须已解析到本服务器 IP）: "
  read -r DOMAIN
  [ -z "$DOMAIN" ] && red "❌ 域名不能为空！" && exit 1
  echo -n "请输入监听端口 [默认: 443]: "
  read -r PORT
  [ -z "$PORT" ] && PORT=443
  UUID=$(cat /proc/sys/kernel/random/uuid)
}

# 申请证书
issue_cert() {
  ensure_command "curl"
  ensure_command "socat"
  
  if [ ! -f /root/.acme.sh/acme.sh ]; then
    echo "➡️ 正在安装 acme.sh..."
    curl https://get.acme.sh | sh
  fi
  # shellcheck source=/root/.acme.sh/acme.sh.env
  . ~/.acme.sh/acme.sh.env

  # ---
  # *** 关键修正 ***
  # 必须先设置默认 CA 为 Let's Encrypt，然后再注册账户，否则会因无法连接默认的 ZeroSSL 而失败
  # ---
  echo "➡️ 正在设置默认 CA 为 Let's Encrypt 以提高兼容性..."
  ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

  echo "➡️ 正在基于 Let's Encrypt 注册 ACME 账户..."
  ~/.acme.sh/acme.sh --register-account -m "myemail@${DOMAIN}"

  ACME_LISTEN_PARAM=""
  if curl -s -6 -m 10 "ifconfig.co" >/dev/null 2>&1; then
    green "✅ 检测到 IPv6 网络，将优先使用 IPv6 进行证书申请"
    ACME_LISTEN_PARAM="--listen-v6"
  elif curl -s -4 -m 10 "ifconfig.co" >/dev/null 2>&1; then
    green "✅ 检测到 IPv4 网络，将使用 IPv4 进行证书申请"
    ACME_LISTEN_PARAM="--listen-v4"
  else
    red "❌ 无法检测到有效的公网 IP (IPv4 或 IPv6)，请检查网络连接。证书申请无法继续。"
    exit 1
  fi
  
  echo "➡️ 正在停止 80 端口服务，以确保证书申请成功..."
  ensure_command "fuser"
  fuser -k 80/tcp >/dev/null 2>&1 || true
  sleep 1

  echo "➡️ 正在为 $DOMAIN 申请 Let's Encrypt 证书..."
  ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone $ACME_LISTEN_PARAM --keylength ec-256 || return 1
  
  ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
    --ecc \
    --key-file "$CERT_DIR/${DOMAIN}.key" \
    --fullchain-file "$CERT_DIR/${DOMAIN}.cer" \
    --reloadcmd "systemctl restart xray >/dev/null 2>&1 || pkill -f xray"
  
  echo "➡️ 正在设置证书自动续期任务..."
  ensure_command "crontab"
  (crontab -l 2>/dev/null | grep -Fv "acme.sh --cron") | crontab - >/dev/null 2>&1
  (crontab -l 2>/dev/null; echo "0 3 * * * /root/.acme.sh/acme.sh --cron --home /root/.acme.sh > /dev/null 2>&1") | crontab - >/dev/null 2>&1

  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now cron >/dev/null 2>&1 || systemctl enable --now cronie >/dev/null 2>&1
  else
    # 对于非 systemd 系统，确保 crond 正在运行
    # 不同系统的启动方式可能不同，这里是一个通用尝试
    if ! pgrep -x "crond" > /dev/null; then
        crond || (echo "Warning: could not start crond. Auto-renewal may not work." >&2)
    fi
  fi
}

# 生成自签名证书（备用方案）
generate_self_signed_cert() {
  red "⚠️ ACME 证书申请失败，将使用自签证书..."
  ensure_command "openssl"
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout "$CERT_DIR/${DOMAIN}.key" -out "$CERT_DIR/${DOMAIN}.cer" \
    -subj "/CN=$DOMAIN"
  green "✅ 自签证书已生成。"
}

# 生成 Xray 配置文件
generate_config() {
  cat > "$CONFIG_FILE" <<EOF
{
  "log": {
      "loglevel": "warning"
  },
  "inbounds": [{
    "port": $PORT,
    "protocol": "vmess",
    "settings": {
      "clients": [{
        "id": "$UUID"
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

# 创建并启动 systemd 服务
setup_and_start_xray() {
  if command -v systemctl >/dev/null 2>&1; then
      echo "➡️ 正在创建并启动 systemd 服务..."
      cat > "$SYSTEMD_FILE" <<EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=$XRAY_BIN run -c $CONFIG_FILE
Restart=on-failure
RestartPreventExitStatus=23

[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload
      systemctl enable xray
      systemctl start xray
      sleep 2
      if systemctl is-active --quiet xray; then
          green "✅ Xray (systemd) 启动成功！"
      else
          red "❌ Xray (systemd) 启动失败，请运行 'journalctl -u xray --no-pager -l' 查看日志。"
          exit 1
      fi
  else
      echo "➡️ 正在使用 nohup 启动 Xray (非 systemd 系统)..."
      nohup "$XRAY_BIN" run -c "$CONFIG_FILE" > /dev/null 2>&1 &
      sleep 2
      if pgrep -f "$XRAY_BIN" >/dev/null; then
          green "✅ Xray (nohup) 启动成功！"
      else
          red "❌ Xray (nohup) 启动失败，请检查配置。"
          exit 1
      fi
  fi
}

# --- 主函数 ---
main() {
  detect_pkg_manager

  if [ -f "$XRAY_BIN" ]; then
    menu_if_installed
  fi

  get_user_input
  install_xray_core

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
  setup_and_start_xray
  show_vmess_link
}

# --- 脚本入口 ---
main "$@"
