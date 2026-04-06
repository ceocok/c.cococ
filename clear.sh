#!/bin/sh

# ==========================================
# 全系统兼容智能极限清理脚本
# 支持 Alpine / Debian / Ubuntu / Fedora /
# CentOS / Arch / openSUSE 等主流 Linux
# 并附带 Docker / Podman / npm / pip /
# conda / cargo / go 缓存清理
# ==========================================

if [ "$(id -u)" -ne 0 ]; then
    echo "错误: 请使用 root 权限运行此脚本 (例如: sudo ./cleanup.sh)"
    exit 1
fi

print_line() {
    printf '%s\n' "====================================="
}

get_root_disk_info() {
    df -k / 2>/dev/null | awk 'NR==2 {
        gsub(/%/, "", $5)
        printf "%s %s %s %s\n", $2, $3, $4, $5
    }'
}

kb_to_human() {
    awk -v kb="$1" '
    BEGIN {
        if (kb >= 1073741824)
            printf "%.2f TB", kb/1073741824
        else if (kb >= 1048576)
            printf "%.2f GB", kb/1048576
        else if (kb >= 1024)
            printf "%.2f MB", kb/1024
        else
            printf "%d KB", kb
    }'
}

print_disk_summary() {
    info=$(get_root_disk_info)
    total_kb=$(echo "$info" | awk '{print $1}')
    used_kb=$(echo "$info"  | awk '{print $2}')
    avail_kb=$(echo "$info" | awk '{print $3}')
    usep=$(echo "$info"     | awk '{print $4}')

    printf "总空间: %s\n" "$(kb_to_human "$total_kb")"
    printf "已使用: %s\n" "$(kb_to_human "$used_kb")"
    printf "剩余:   %s\n" "$(kb_to_human "$avail_kb")"
    printf "使用率: %s%%\n" "$usep"
}

safe_truncate_file() {
    file="$1"
    if [ -f "$file" ] && [ -w "$file" ]; then
        : > "$file" 2>/dev/null
    fi
}

truncate_logs_in_dir() {
    dir="$1"
    [ -d "$dir" ] || return 0

    find "$dir" -type f \( -name '*.log' -o -name '*.out' \) 2>/dev/null | while IFS= read -r f; do
        safe_truncate_file "$f"
    done
}

delete_rotated_logs_in_dir() {
    dir="$1"
    [ -d "$dir" ] || return 0

    find "$dir" -type f \( \
        -name '*.1' -o -name '*.2' -o -name '*.3' -o -name '*.4' -o -name '*.5' -o \
        -name '*.old' -o \
        -name '*.gz' -o -name '*.xz' -o -name '*.bz2' -o -name '*.zst' \
    \) -exec rm -f {} \; 2>/dev/null
}

run_if_exists() {
    cmd="$1"
    shift
    if command -v "$cmd" >/dev/null 2>&1; then
        "$cmd" "$@" 2>/dev/null
    fi
}

echo "===== 系统智能极限清理开始 ====="
print_line
echo "清理前磁盘状态（根分区 /）："
print_disk_summary
print_line

BEFORE_INFO=$(get_root_disk_info)
BEFORE_TOTAL_KB=$(echo "$BEFORE_INFO" | awk '{print $1}')
BEFORE_USED_KB=$(echo "$BEFORE_INFO"  | awk '{print $2}')
BEFORE_AVAIL_KB=$(echo "$BEFORE_INFO" | awk '{print $3}')
BEFORE_USEP=$(echo "$BEFORE_INFO"     | awk '{print $4}')

printf "\n[1/9] 清理包管理器缓存与无用依赖...\n"
if command -v apk >/dev/null 2>&1; then
    echo " -> 检测到 APK (Alpine Linux)"
    rm -rf /var/cache/apk/* 2>/dev/null
    echo " -> APK 缓存已清理。"

elif command -v apt-get >/dev/null 2>&1; then
    echo " -> 检测到 APT (Debian/Ubuntu/Mint)"
    apt-get clean
    apt-get autoclean -y
    apt-get autoremove --purge -y
    rm -rf /var/lib/apt/lists/* 2>/dev/null
    echo " -> APT 缓存与无用依赖已清理。"

elif command -v dnf >/dev/null 2>&1; then
    echo " -> 检测到 DNF (Fedora/RHEL/CentOS 8+)"
    dnf clean all
    dnf autoremove -y
    echo " -> DNF 缓存与无用依赖已清理。"

elif command -v yum >/dev/null 2>&1; then
    echo " -> 检测到 YUM (CentOS 7 及更早)"
    yum clean all
    echo " -> YUM 缓存已清理。"

elif command -v pacman >/dev/null 2>&1; then
    echo " -> 检测到 Pacman (Arch/Manjaro)"
    pacman -Sc --noconfirm
    orphans=$(pacman -Qdtq 2>/dev/null)
    if [ -n "$orphans" ]; then
        pacman -Rs $orphans --noconfirm
    fi
    echo " -> Pacman 缓存与孤儿包已清理。"

elif command -v zypper >/dev/null 2>&1; then
    echo " -> 检测到 Zypper (openSUSE)"
    zypper clean -a
    echo " -> Zypper 缓存已清理。"

else
    echo " -> 未检测到支持的包管理器，跳过包清理。"
fi

printf "\n[2/9] 清理 systemd / 系统日志...\n"
if command -v journalctl >/dev/null 2>&1; then
    journalctl --vacuum-time=3d 2>/dev/null
    journalctl --vacuum-size=100M 2>/dev/null
    echo " -> systemd 日志已压缩。"
else
    echo " -> 未找到 journalctl，跳过 journal 清理。"
fi

printf "\n[3/9] 智能清理普通日志文件...\n"
delete_rotated_logs_in_dir /var/log
truncate_logs_in_dir /var/log
truncate_logs_in_dir /var/log/nginx
truncate_logs_in_dir /var/log/apache2
truncate_logs_in_dir /var/log/httpd
truncate_logs_in_dir /var/log/caddy
truncate_logs_in_dir /var/log/mysql
truncate_logs_in_dir /var/log/mariadb
truncate_logs_in_dir /var/log/redis
truncate_logs_in_dir /var/log/postgresql
truncate_logs_in_dir /var/log/sing-box
truncate_logs_in_dir /var/log/xray
truncate_logs_in_dir /var/log/haproxy
echo " -> 常见日志已智能清理。"

printf "\n[4/9] 清理临时文件...\n"
find /tmp -type f -mtime +3 -exec rm -f {} \; 2>/dev/null
find /var/tmp -type f -mtime +3 -exec rm -f {} \; 2>/dev/null
echo " -> 临时文件清理完成。"

printf "\n[5/9] 清理崩溃文件与 core dump...\n"
rm -rf /var/crash/* 2>/dev/null
rm -rf /var/lib/systemd/coredump/* 2>/dev/null
echo " -> 崩溃文件清理完成。"

printf "\n[6/9] 清理用户缩略图缓存...\n"
for user_dir in /home/*; do
    if [ -d "$user_dir/.cache/thumbnails" ]; then
        rm -rf "$user_dir/.cache/thumbnails/"* 2>/dev/null
    fi
done
if [ -d /root/.cache/thumbnails ]; then
    rm -rf /root/.cache/thumbnails/* 2>/dev/null
fi
echo " -> 用户缩略图缓存清理完成。"

printf "\n[7/9] 清理开发工具缓存...\n"

if command -v npm >/dev/null 2>&1; then
    echo " -> 清理 npm 缓存"
    npm cache clean --force 2>/dev/null
fi

if command -v pip >/dev/null 2>&1; then
    echo " -> 清理 pip 缓存"
    pip cache purge 2>/dev/null
fi

if command -v pip3 >/dev/null 2>&1; then
    echo " -> 清理 pip3 缓存"
    pip3 cache purge 2>/dev/null
fi

if command -v conda >/dev/null 2>&1; then
    echo " -> 清理 conda 缓存"
    conda clean -y --index-cache --tarballs --packages --logfiles 2>/dev/null
fi

if command -v cargo >/dev/null 2>&1; then
    if command -v cargo-cache >/dev/null 2>&1; then
        echo " -> 清理 cargo 缓存"
        cargo cache -a 2>/dev/null
    else
        echo " -> 检测到 cargo，但未安装 cargo-cache，跳过 cargo 缓存清理"
    fi
fi

if command -v go >/dev/null 2>&1; then
    echo " -> 清理 go build/module 缓存"
    go clean -cache -modcache -testcache -fuzzcache 2>/dev/null
fi

echo " -> 开发工具缓存清理完成。"

printf "\n[8/9] 清理 Docker / Podman 缓存...\n"

if command -v docker >/dev/null 2>&1; then
    echo " -> 检测到 Docker，执行保守清理"
    docker container prune -f 2>/dev/null
    docker image prune -f 2>/dev/null
    docker builder prune -f 2>/dev/null
    docker network prune -f 2>/dev/null
    echo " -> Docker 保守清理完成。"
fi

if command -v podman >/dev/null 2>&1; then
    echo " -> 检测到 Podman，执行保守清理"
    podman container prune -f 2>/dev/null
    podman image prune -f 2>/dev/null
    podman builder prune -f 2>/dev/null
    podman network prune -f 2>/dev/null
    echo " -> Podman 保守清理完成。"
fi

printf "\n[9/9] 清理常见残留缓存...\n"
rm -rf /var/cache/man/* 2>/dev/null
rm -rf /var/cache/fontconfig/* 2>/dev/null

if command -v snap >/dev/null 2>&1; then
    echo " -> 检测到 Snap，尝试清理已禁用旧版本..."
    snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}' | while read -r snapname revision; do
        if [ -n "$snapname" ] && [ -n "$revision" ]; then
            snap remove "$snapname" --revision="$revision" 2>/dev/null
        fi
    done
fi

echo " -> 常见残留清理完成。"

AFTER_INFO=$(get_root_disk_info)
AFTER_TOTAL_KB=$(echo "$AFTER_INFO" | awk '{print $1}')
AFTER_USED_KB=$(echo "$AFTER_INFO"  | awk '{print $2}')
AFTER_AVAIL_KB=$(echo "$AFTER_INFO" | awk '{print $3}')
AFTER_USEP=$(echo "$AFTER_INFO"     | awk '{print $4}')

FREED_KB=$((BEFORE_USED_KB - AFTER_USED_KB))
if [ "$FREED_KB" -lt 0 ]; then
    FREED_KB=0
fi

printf "\n"
print_line
echo "清理完成"
print_line

printf "清理前:\n"
printf "  总空间: %s\n" "$(kb_to_human "$BEFORE_TOTAL_KB")"
printf "  已使用: %s\n" "$(kb_to_human "$BEFORE_USED_KB")"
printf "  剩余:   %s\n" "$(kb_to_human "$BEFORE_AVAIL_KB")"
printf "  使用率: %s%%\n" "$BEFORE_USEP"

printf "\n清理后:\n"
printf "  总空间: %s\n" "$(kb_to_human "$AFTER_TOTAL_KB")"
printf "  已使用: %s\n" "$(kb_to_human "$AFTER_USED_KB")"
printf "  剩余:   %s\n" "$(kb_to_human "$AFTER_AVAIL_KB")"
printf "  使用率: %s%%\n" "$AFTER_USEP"

printf "\n本次释放空间: %s\n" "$(kb_to_human "$FREED_KB")"

printf "\n===== 脚本执行完毕 =====\n"
