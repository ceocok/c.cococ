#!/bin/bash

# 定义脚本来源地址前缀（raw.githubusercontent 的 CDN 地址）
BASE_URL="https://raw.githubusercontent.com/ceocok/c.cococ/main"

# 功能列表
declare -A scripts=(
  ["1"]="Snell.sh"
  ["2"]="bbr.sh"
  ["3"]="dnsunlock.sh"
  ["4"]="docker.sh"
  ["5"]="frps.sh"
  ["6"]="hy.sh"
  ["7"]="kejilion.sh"
  ["8"]="socks5.sh"
  ["9"]="tool.sh"
  ["10"]="unlock.sh"
  ["11"]="v2ray.sh"
  ["12"]="warp.sh"
  ["13"]="yuan.sh"
  ["0"]="退出"
)

# 展示菜单
show_menu() {
  echo "========= 工具合集 ========="
  for key in "${!scripts[@]}"; do
    echo "$key. ${scripts[$key]%.*}"
  done | sort -n
  echo "============================"
}

# 下载并执行脚本
run_script() {
  local script_name="$1"
  local url="$BASE_URL/$script_name"
  echo "正在下载并执行 $script_name ..."
  curl -fsSL "$url" -o /tmp/$script_name && chmod +x /tmp/$script_name && bash /tmp/$script_name
}

# 主逻辑
while true; do
  show_menu
  read -p "请输入对应的数字选择功能: " choice
  if [[ "$choice" == "0" ]]; then
    echo "退出工具箱，再见！"
    exit 0
  elif [[ -n "${scripts[$choice]}" ]]; then
    run_script "${scripts[$choice]}"
  else
    echo "无效的选项，请重新输入。"
  fi
done
