#!/usr/bin/env bash

# 使用cf代理
BASE_URL="https://ghfast.top/https://raw.githubusercontent.com/ceocok/c.cococ/main"
USER_SHORTCUT="$HOME/bin/box"
SYSTEM_SHORTCUT="/usr/local/bin/box"

if [ -z "${BASH_VERSION:-}" ] || (( BASH_VERSINFO[0] < 4 )); then
  echo "❌ 当前 Bash 版本过旧：${BASH_VERSION:-未知}"
  echo "请使用 Bash 4+ 运行，例如：/opt/homebrew/bin/bash $0"
  exit 1
fi

# 显示菜单中文名称
declare -A script_names=(
  ["1"]="安装 Snell"
  ["2"]="安装 Vmess"
  ["3"]="安装 Warp-go"
  ["4"]="安装 Hy2"
  ["5"]="安装 BBR"
  ["6"]="科技 lion"
  ["7"]="安装 Warp"
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
  ["25"]="系统清理"
  ["26"]="爱马仕"  
  ["0"]="退出"
)

# 功能编号对应脚本名
declare -A scripts=(
  ["1"]="https://git.io/Snell.sh"
  ["2"]="vmess.sh"
  ["3"]="https://gitlab.com/fscarmen/warp/-/raw/main/warp-go.sh"
  ["4"]="hy.sh"
  ["5"]="bbr.sh"
  ["6"]="https://gh-proxy.com/https://github.com/kejilion/sh/blob/main/kejilion.sh"
  ["7"]="https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh"
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
  ["25"]="clear.sh"
  ["26"]="hms.sh"  
)

# 显示菜单
show_menu() {
  echo "========== 🧰 工具合集 =========="
  for key in "${!script_names[@]}"; do
    echo "$key. ${script_names[$key]}"
  done | sort -n
  echo "=================================="
}

path_contains() {
  case ":$PATH:" in
    *":$1:"*) return 0 ;;
    *) return 1 ;;
  esac
}

get_self_path() {
  local src="${BASH_SOURCE[0]:-$0}"
  local dir

  if [[ "$src" != /* ]]; then
    dir="$(cd "$(dirname "$src")" && pwd -P)" || return 1
    src="$dir/$(basename "$src")"
  fi

  printf '%s\n' "$src"
}

download_file() {
  local url="$1"
  local output="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$output"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$output" "$url"
  else
    echo "❌ 未找到 curl 或 wget"
    return 1
  fi
}

normalize_downloaded_script() {
  local file="$1"
  local sed_expr='1s|^#!/bin/bash$|#!/usr/bin/env bash|'

  if sed --version >/dev/null 2>&1; then
    sed -i "$sed_expr" "$file"
  else
    sed -i '' "$sed_expr" "$file"
  fi
}

needs_root() {
  local file="$1"

  grep -Eq '(^|[^[:alnum:]_])(sudo|EUID|id[[:space:]]+-u)([^[:alnum:]_]|$)|root 或 sudo|root权限|sudo 权限|必须以 root' "$file"
}

# 下载并执行脚本，支持 curl 或 wget
run_script() {
  local input_path="$1"
  local url
  local save_name
  local tmp_dir
  local script_path
  local run_status

  # 1. 提取文件名（处理 URL 里的文件名）
  # 比如从 http://.../warp.sh 提取出 warp.sh
  save_name=$(basename "$input_path")

  # 2. 判断输入的是否是完整 URL
  if [[ "$input_path" == http* ]]; then
    url="$input_path"
  else
    url="$BASE_URL/$input_path"
  fi

  echo "📥 正在从 $url 下载并执行..."

  # 3. 下载到独立临时目录，避免同名文件冲突
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/box.XXXXXX" 2>/dev/null || mktemp -d -t box)" || {
    echo "❌ 创建临时目录失败"
    return 1
  }
  script_path="$tmp_dir/$save_name"

  if ! download_file "$url" "$script_path"; then
    echo "❌ 下载失败，请检查链接：$url"
    rm -rf "$tmp_dir"
    return 1
  fi

  # 4. 执行
  chmod +x "$script_path"
  if needs_root "$script_path" && [ "$(id -u)" -ne 0 ]; then
    echo "🔐 正在请求管理员权限..."
    sudo -p "请输入密码: " env "PATH=$PATH" "$BASH" "$script_path"
    run_status=$?
    rm -rf "$tmp_dir"
    return "$run_status"
  fi
  bash "$script_path"
  run_status=$?
  rm -rf "$tmp_dir"
  return "$run_status"
}


# 设置 box 快捷命令
setup_shortcut() {
  local source_path
  local shortcut_dir
  local shortcut_path

  source_path="$(get_self_path)" || {
    echo "⚠️ 无法识别当前脚本路径，跳过快捷命令创建。"
    return 1
  }

  if path_contains "$HOME/bin"; then
    shortcut_path="$USER_SHORTCUT"
  elif [ -w "$(dirname "$SYSTEM_SHORTCUT")" ]; then
    shortcut_path="$SYSTEM_SHORTCUT"
  else
    shortcut_path="$USER_SHORTCUT"
  fi

  shortcut_dir="$(dirname "$shortcut_path")"
  mkdir -p "$shortcut_dir" || {
    echo "⚠️ 无法创建快捷命令目录：$shortcut_dir"
    return 1
  }

  if [ "$source_path" != "$shortcut_path" ] && { [ ! -f "$shortcut_path" ] || ! cmp -s "$source_path" "$shortcut_path"; }; then
    if ! cp "$source_path" "$shortcut_path"; then
      echo "⚠️ 创建快捷命令失败：$shortcut_path"
      return 1
    fi
    chmod +x "$shortcut_path"
    echo "✅ 已同步快捷命令：$shortcut_path"
  fi

  if ! path_contains "$shortcut_dir"; then
    echo "⚠️ $shortcut_dir 不在 PATH 中，如无法直接输入 box，请加入："
    echo "export PATH=\"$shortcut_dir:\$PATH\""
  fi
}



# 自我更新
update_self() {
  local update_url="$BASE_URL/box.sh"
  local self_path
  local tmp_file
  echo "🔄 正在更新 box 工具箱脚本..."

  self_path="$(get_self_path)"
  tmp_file="$(mktemp 2>/dev/null || mktemp -t box)"

  if ! download_file "$update_url" "$tmp_file"; then
    echo "❌ 更新失败，无法从：$update_url 下载"
    rm -f "$tmp_file"
    return 1
  fi

  normalize_downloaded_script "$tmp_file"

  if ! bash -n "$tmp_file"; then
    echo "❌ 更新失败：下载的新脚本语法检查未通过。"
    rm -f "$tmp_file"
    return 1
  fi

  if ! cp "$tmp_file" "$self_path"; then
    echo "❌ 更新失败，无法写入：$self_path"
    rm -f "$tmp_file"
    return 1
  fi

  chmod +x "$self_path"

  if [ "$self_path" != "$USER_SHORTCUT" ] && [ -w "$(dirname "$USER_SHORTCUT")" ]; then
    cp "$tmp_file" "$USER_SHORTCUT" && chmod +x "$USER_SHORTCUT"
  fi

  if [ "$self_path" != "$SYSTEM_SHORTCUT" ] && [ -w "$(dirname "$SYSTEM_SHORTCUT")" ] && [ -f "$SYSTEM_SHORTCUT" ]; then
    cp "$tmp_file" "$SYSTEM_SHORTCUT" && chmod +x "$SYSTEM_SHORTCUT"
  fi

  rm -f "$tmp_file"
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
