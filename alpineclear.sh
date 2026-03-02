#!/usr/bin/env sh
# Alpine Smart Cleaner (for tiny VPS, e.g. 1G disk)
# Author: TARS
# Usage:
# chmod +x alpine-cleaner.sh
# sudo ./alpine-cleaner.sh

set -eu

# ---------- UI ----------
C_RESET='\033[0m'
C_RED='\033[31m'
C_GREEN='\033[32m'
C_YELLOW='\033[33m'
C_BLUE='\033[34m'
C_CYAN='\033[36m'
C_BOLD='\033[1m'

say() { printf "%b\n" "$*"; }
ok() { say "${C_GREEN}✅ $*${C_RESET}"; }
warn() { say "${C_YELLOW}⚠️ $*${C_RESET}"; }
err() { say "${C_RED}❌ $*${C_RESET}"; }
info() { say "${C_CYAN}ℹ️ $*${C_RESET}"; }
headl(){ say "\n${C_BOLD}${C_BLUE}== $* ==${C_RESET}"; }

need_root() {
if [ "$(id -u)" -ne 0 ]; then
err "请用 root/sudo 运行。"
exit 1
fi
}

pause() {
printf "\n按回车继续..."
read -r _
}

ask_yes_no() {
# $1 prompt
printf "%b [y/N]: " "$1"
read -r ans || true
case "${ans:-}" in
y|Y|yes|YES) return 0 ;;
*) return 1 ;;
esac
}

disk_report() {
headl "磁盘状态"
df -h /
echo
df -i /
}

quick_health() {
headl "系统概览"
uname -a || true
echo
cat /etc/alpine-release 2>/dev/null || true
echo
info "顶层目录占用（/ 下）"
du -xhd1 / 2>/dev/null | sort -h | tail -n 20 || true
echo
info "大文件（>20MB，Top 30）"
find / -xdev -type f -size +20M 2>/dev/null \
-exec ls -lh {} + | sort -k5 -h | tail -n 30 || true
}

refresh_apk_index() {
headl "刷新 APK 索引"
if apk update >/dev/null 2>&1; then
ok "apk 索引已刷新。"
else
warn "apk update 失败（可能网络问题），继续执行本地清理。"
fi
}

clean_basic() {
headl "基础清理（安全）"
info "清理 apk 缓存 / tmp / 日志轮转..."
apk cache clean >/dev/null 2>&1 || true
rm -rf /var/cache/apk/* 2>/dev/null || true
rm -rf /var/cache/* 2>/dev/null || true
mkdir -p /var/cache/apk 2>/dev/null || true

find /tmp -mindepth 1 -xdev -exec rm -rf {} + 2>/dev/null || true
find /var/tmp -mindepth 1 -xdev -exec rm -rf {} + 2>/dev/null || true

find /var/log -type f -name "*.gz" -delete 2>/dev/null || true
find /var/log -type f -name "*.1" -delete 2>/dev/null || true
find /var/log -type f -name "*.old" -delete 2>/dev/null || true
# 清空过大日志
find /var/log -type f -size +5M -exec sh -c ': > "$1"' _ {} \; 2>/dev/null || true

# core dump
find / -xdev -type f \( -name "core" -o -name "core.*" \) -delete 2>/dev/null || true

sync
ok "基础清理完成。"
}

clean_docker() {
if ! command -v docker >/dev/null 2>&1; then
warn "未检测到 docker，跳过。"
return 0
fi
headl "Docker 清理"
info "将执行: docker system prune -af --volumes"
if ask_yes_no "确认清理 Docker 未使用镜像/容器/网络/卷？"; then
docker system prune -af --volumes || true
ok "Docker 清理完成。"
else
warn "已跳过 Docker 清理。"
fi
}

slim_python() {
headl "Python 精简"
info "将删除 python3 / pip / setuptools / packaging / parsing 及依赖"
info "如果你有依赖 Python 的业务，请不要执行。"
if ! ask_yes_no "确认执行 Python 精简？"; then
warn "已跳过。"
return 0
fi

apk del python3 py3-pip py3-setuptools py3-packaging py3-parsing >/dev/null 2>&1 || true
rm -rf /root/.cache/* /home/*/.cache/* 2>/dev/null || true
find /usr/lib -type d -name "__pycache__" -prune -exec rm -rf {} + 2>/dev/null || true
ok "Python 精简完成。"
}

slim_docs_locales() {
headl "文档/语言包瘦身（激进）"
info "将删除 man/doc/info，并仅保留 zh*/en* locale"
if ! ask_yes_no "确认执行文档/locale 瘦身？"; then
warn "已跳过。"
return 0
fi

rm -rf /usr/share/man/* /usr/share/doc/* /usr/share/info/* 2>/dev/null || true
if [ -d /usr/share/locale ]; then
find /usr/share/locale -mindepth 1 -maxdepth 1 \
! -name "zh*" ! -name "en*" -exec rm -rf {} + 2>/dev/null || true
fi
ok "文档/语言包瘦身完成。"
}

remove_old_modules() {
headl "旧内核模块清理"
if [ ! -d /lib/modules ]; then
warn "/lib/modules 不存在，跳过。"
return 0
fi
cur="$(uname -r || true)"
info "当前内核: ${cur:-unknown}"

old_count=0
for d in /lib/modules/*; do
[ -d "$d" ] || continue
b="$(basename "$d")"
if [ "$b" != "$cur" ]; then
old_count=$((old_count+1))
echo "旧模块候选: $d"
fi
done

if [ "$old_count" -eq 0 ]; then
ok "未发现旧模块。"
return 0
fi

if ask_yes_no "确认删除以上旧模块目录？"; then
for d in /lib/modules/*; do
[ -d "$d" ] || continue
b="$(basename "$d")"
[ "$b" = "$cur" ] && continue
rm -rf "$d" || true
done
ok "旧模块清理完成。"
else
warn "已跳过旧模块清理。"
fi
}
recommendations() {
headl "后续建议"
cat <<'EOF'
1) 安装软件一律用:
apk add --no-cache <pkg>

2) 若后续某些二进制程序报缺库，可按需装回:
apk add --no-cache libgcc libstdc++

3) 定期执行基础清理（每周一次）:
apk cache clean && rm -rf /var/cache/apk/* /tmp/* /var/tmp/*
EOF
}

full_guided() {
before_kb="$(df -k / | awk 'NR==2{print $4}')"

disk_report
quick_health
pause

refresh_apk_index
clean_basic
clean_docker
slim_python
slim_docs_locales
remove_old_modules

sync

after_kb="$(df -k / | awk 'NR==2{print $4}')"
freed_kb=$((after_kb - before_kb))
freed_mb=$((freed_kb / 1024))

headl "清理结果"
disk_report
ok "本次预计释放: ${freed_mb} MB"
recommendations
}

menu() {
while true; do
say "\n${C_BOLD}🧰 Alpine Smart Cleaner${C_RESET}"
say "1) 一键引导清理（推荐）"
say "2) 仅基础清理（安全）"
say "3) 仅 Docker 清理"
say "4) 仅 Python 精简"
say "5) 仅文档/locale 瘦身（激进）"
say "6) 仅查看占用分析"
say "0) 退出"
printf "请选择: "
read -r ch || true
case "${ch:-}" in
1) full_guided ;;
2) clean_basic; disk_report ;;
3) clean_docker; disk_report ;;
4) slim_python; disk_report ;;
5) slim_docs_locales; disk_report ;;
6) disk_report; quick_health ;;
0) exit 0 ;;
*) warn "无效选项" ;;
esac
done
}

main() {
need_root
menu
}

main "$@"
