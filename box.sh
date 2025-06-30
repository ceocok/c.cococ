#!/bin/bash

BASE_URL="https://raw.githubusercontent.com/ceocok/c.cococ/main"

# 显示菜单中文名称
declare -A script_names=(
  ["1"]="安装 Snell"
  ["2"]="安装 V2Ray"
  ["3"]="安装 Warp"
  ["4"]="安装 Hy2"
  ["5"]="安装 BBR"
  ["6"]="科技 lion"
  ["7"]="常用 tool"
  ["8"]="Docker安装"
  ["9"]="系统换源"
  ["10"]="DNS 解锁"
  ["11"]="Alice 出口"
  ["12"]="安装 frps"
  ["13"]="安装 Socks5"
  ["0"]="退出"
)

# 脚本名与编号映射
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
)

# 展示菜单
show_menu() {
  echo "========== 🧰 ceocok工具合集 =========="
  for key in "${!script_names[@]}"; do
    echo "$key. ${script_names[$key]}"
  done | sort -n
  echo "=================================="
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
    echo "✅ 检测到 V2Ray 已安装。"
    read -p "是否重新安装？[y/N]: " re
    if [[ "$re" =~ ^[Yy]$ ]]; then
      run_script "v2ray.sh"
    else
      echo "跳过安装 V2Ray。"
    fi
  else
    echo "❌ 未检测到 V2Ray，准备安装..."
    run_script "v2ray.sh"
  fi
}

# 主逻辑
while true; do
  show_menu
  read -p "请输入序号选择功能: " choice
  if [[ "$choice" == "0" ]]; then
    echo "👋 再见，退出工具箱！"
    exit 0
  elif [[ -n "${scripts[$choice]}" ]]; then
    if [[ "$choice" == "2" ]]; then
      check_v2ray
    else
      run_script "${scripts[$choice]}"
    fi
  else
    echo "⚠️ 无效选项，请重新输入。"
  fi
done
# 自动设置快捷命令
if [ ! -f "/usr/local/bin/box" ]; then
  cp "$(realpath "$0")" /usr/local/bin/box
  chmod +x /usr/local/bin/box
  echo "✅ 工具箱已设置为快捷命令，输入 box 即可快速打开。"
fi
