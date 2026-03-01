#!/usr/bin/env bash

# ========= 可调配置 =========
REPO_RAW_BASE="https://raw.githubusercontent.com/ceocok/c.cococ/main"
GH_PROXY_BASE="https://ghproxy.com/https://raw.githubusercontent.com/ceocok/c.cococ/main"
CF_PROXY_BASE="https://feria.eu.org/https://raw.githubusercontent.com/ceocok/c.cococ/main"

UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
REFERER="https://github.com/"
TMP_DIR="/tmp"

# ========= 菜单名称 =========
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
["0"]="退出"
)

# ========= 功能编号 -> 脚本名 =========
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
)

show_menu() {
echo "========== 🧰 工具合集 =========="
for key in $(printf "%s\n" "${!script_names[@]}" | sort -n); do
printf "%-3s. %s\n" "$key" "${script_names[$key]}"
done
echo "=================================="
}

download_file() {
local remote="$1"
local out="$2"

if command -v curl >/dev/null 2>&1; then
local code
code=$(curl -L --http1.1 \
--connect-timeout 10 --max-time 40 \
--retry 2 --retry-delay 1 --retry-all-errors \
-A "$UA" -e "$REFERER" \
-o "$out" -w "%{http_code}" \
"$remote" 2>/dev/null || echo "000")
[[ "$code" == "200" ]]
return
elif command -v wget >/dev/null 2>&1; then
wget -q --timeout=40 --tries=2 \
--user-agent="$UA" --referer="$REFERER" \
-O "$out" "$remote"
return
else
return 127
fi
}

looks_like_html_challenge() {
local f="$1"
grep -qiE '<html|<!doctype html|cloudflare|attention required|just a moment' "$f"
}

run_script() {
local script_name="$1"
local out="${TMP_DIR}/${script_name}"
local -a urls=(
"${CF_PROXY_BASE}/${script_name}"
"${REPO_RAW_BASE}/${script_name}"
"${GH_PROXY_BASE}/${script_name}"
)

echo "📥 正在下载并执行 ${script_name} ..."
local ok=0

for url in "${urls[@]}"; do
echo "→ 尝试: $url"
if download_file "$url" "$out"; then
# 防止拿到挑战页/错误页
if looks_like_html_challenge "$out"; then
echo " ⚠️ 命中挑战页/HTML，继续尝试下一个源"
continue
fi
# 至少要像 shell 脚本
if ! head -n 1 "$out" | grep -qiE '^#!|bash|sh'; then
echo " ⚠️ 文件不像脚本，继续尝试下一个源"
continue
fi
ok=1
break
else
echo " ❌ 失败"
fi
done

if [[ $ok -ne 1 ]]; then
echo "❌ 下载失败（HTTP 403/风控/网络问题）。"
return 1
fi

chmod +x "$out"
bash "$out"
}

setup_shortcut() {
if [[ "$0" != "/usr/local/bin/box" ]]; then
cp "$0" /usr/local/bin/box 2>/dev/null
chmod +x /usr/local/bin/box 2>/dev/null
if [[ $? -eq 0 ]]; then
echo "✅ 已创建快捷命令：输入 box 可随时启动工具箱。"
fi
fi
}

update_self() {
local self_tmp="$0.tmp"
local -a urls=(
"${CF_PROXY_BASE}/box.sh"
"${REPO_RAW_BASE}/box.sh"
"${GH_PROXY_BASE}/box.sh"
)

echo "🔄 正在更新 box 工具箱脚本..."
local ok=0
for url in "${urls[@]}"; do
echo "→ 尝试: $url"
if download_file "$url" "$self_tmp"; then
if looks_like_html_challenge "$self_tmp"; then
echo " ⚠️ 挑战页，换源"
continue
fi
ok=1
break
fi
done

if [[ $ok -ne 1 ]]; then
echo "❌ 更新失败。"
rm -f "$self_tmp"
return 1
fi

mv "$self_tmp" "$0"
chmod +x "$0"
echo "✅ box 工具箱已成功更新！请重新运行。"
exit 0
}

main() {
setup_shortcut
while true; do
show_menu
read -r -p "请输入功能序号: " choice
if [[ "$choice" == "0" ]]; then
echo "👋 再见！"
exit 0
elif [[ "$choice" == "16" ]]; then
update_self
elif [[ -n "${scripts[$choice]}" ]]; then
run_script "${scripts[$choice]}"
else
echo "⚠️ 无效输入。"
fi
done
}

main
