#!/bin/bash

BASE_URL="https://raw.githubusercontent.com/ceocok/c.cococ/main"

# 有序功能菜单
declare -A scripts=(
  ["1"]="Snell.sh"
  ["2"]="v2ray.sh"
  ["3"]="warp.sh"
  ["4"]="hy.sh"
  ["5"]="bbr.sh"
  ["6"]="kejilion.sh"
  ["7"]="tool.sh"
  ["8"]="docker.sh"
  ["9"]="yuan.sh"
  ["10"]="dnsunlock.sh"
  ["11"]="unlock.sh"
  ["12"]="frps.sh"
  ["13"]="socks5.sh"
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

# v2ray 安装检测函数
check_v2ray() {
  if command -v v2ray >/dev/null 2>&1 || [ -f "/usr/bin/v2ray/v2ray" ]; then
    echo "检测到 V2Ray 已安装。"
    read -p "是否重新安装？[y/N]: " re
    if [[ "$re" =~ ^[Yy]$ ]]; then
      run_script "v2ray.sh"
    else
      echo "跳过安装 V2Ray。"
    fi
  else
    echo "未检测到 V2Ray，准备安装..."
    run_script "v2ray.sh"
  fi
}

# 主逻辑
while true; do
  show_menu
  read -p "请输入对应的数字选择功能: " choice
  if [[ "$choice" == "0" ]]; then
    echo "退出工具箱，再见！"
    exit 0
  elif [[ -n "${scripts[$choice]}" ]]; then
    if [[ "$choice" == "2" ]]; then
      check_v2ray
    else
      run_script "${scripts[$choice]}"
    fi
  else
    echo "无效的选项，请重新输入。"
  fi
done
