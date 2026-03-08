#!/bin/bash

# 使用cf代理
BASE_URL="https://gh-proxy.org/https://raw.githubusercontent.com/ceocok/c.cococ/main"

# 显示菜单中文名称
declare -A script_names=(
  ["1"]="安装 Snell"
  ["2"]="安装 Vmess"
  ["3"]="安装 Warp"
  ["4"]="安装 Hy2"
  ["5"]="安装 BBR"
  ["6"]="科技 lion"
  ["7"]="常用 tool"
  ["8"]="Docker安装"
  ["9"]="DNS 解锁"
  ["10"]="Alice 出口"
  ["11"]="安装 frp"
  ["12"]="安装 Socks5"
  ["13"]="安装证书"
  ["14"]="Alpine-vmess"
  ["15"]="Alpine-hy2"
  ["16"]="更新 box 工具箱"
  ["17"]="EasyTier组网"
  ["18"]="Docker迁移"
  ["19"]="修改SSH端口"
  ["20"]="Caddy管理"
  ["21"]="系统换源"
  ["22"]="哪吒换源"
  ["23"]="Singbox" 
  ["24"]="OpenClaw" 
  ["0"]="退出"
)

# 功能编号对应脚本名
declare -A scripts=(
  ["1"]="Snell.sh"
  ["2"]="vmess.sh"
  ["3"]="warp.sh"
  ["4"]="hy.sh"
  ["5"]="bbr.sh"
  ["6"]="kejilion.sh"
  ["7"]="tool.sh"
  ["8"]="docker.sh"
  ["9"]="dnsunlock.sh"
  ["10"]="unlock.sh"
  ["11"]="frp.sh"
  ["12"]="socks5.sh"
  ["13"]="acme.sh"
  ["14"]="Alpine-vmess.sh"
  ["15"]="Alpine-hy2.sh"
  ["17"]="easytier.sh"
  ["18"]="Docker_container_migration.sh"
  ["19"]="changessh.sh"
  ["20"]="caddyman.sh"
  ["21"]="yuan.sh"
  ["22"]="editnz.sh"
  ["23"]="singbox.sh"  
  ["24"]="ocm.sh"
)

# 显示菜单
show_menu() {
  echo "========== 🧰 工具合集 =========="
  for key in "${!script_names[@]}"; do
    echo "$key. ${script_names[$key]}"
  done | sort -n
  echo "=================================="
}

# 下载并执行脚本，支持 curl 或 wget
run_script() {
  local script_name="$1"
  local url="$BASE_URL/$script_name"
  echo "📥 正在下载并执行 $script_name ..."

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o /tmp/$script_name
  elif command -v wget >/dev/null 2>&1; then
    wget -qO /tmp/$script_name "$url"
  else
    echo "❌ 未找到 curl 或 wget，无法下载脚本。请先安装其中一个工具。"
    return 1
  fi

  if [ $? -ne 0 ]; then
    echo "❌ 下载失败，请检查网络或脚本路径：$url"
    return 1
  fi

  chmod +x /tmp/$script_name
  bash /tmp/$script_name
}


# 设置 box 快捷命令
setup_shortcut() {
  if [ ! -f "/usr/local/bin/box" ]; then
    cp "$(realpath "$0")" /usr/local/bin/box
    chmod +x /usr/local/bin/box
    echo "✅ 已创建快捷命令：输入 box 可随时启动工具箱。"
  fi
}



# 自我更新
update_self() {
  local update_url="$BASE_URL/box.sh"
  echo "🔄 正在更新 box 工具箱脚本..."

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$update_url" -o "$0.tmp"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$0.tmp" "$update_url"
  else
    echo "❌ 未找到 curl 或 wget，无法更新脚本。"
    return 1
  fi

  if [ $? -ne 0 ]; then
    echo "❌ 更新失败，无法从：$update_url 下载"
    return 1
  fi

  mv "$0.tmp" "$0"
  chmod +x "$0"
  echo "✅ box 工具箱已成功更新！请重新运行。"
  exit 0
}

# 主逻辑
main() {
  setup_shortcut
  while true; do
    show_menu
    read -p "请输入功能序号: " choice
    if [[ "$choice" == "0" ]]; then
      echo "👋 再见，已退出工具箱！"
      exit 0
    elif [[ "$choice" == "16" ]]; then
      update_self
    elif [[ -n "${scripts[$choice]}" ]]; then
      # 所有脚本都通过这里执行，包括 vmess.sh
      run_script "${scripts[$choice]}"
    else
      echo "⚠️ 无效输入，请重新选择。"
    fi
  done
}


main
