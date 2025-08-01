#!/bin/bash

# --- 定义颜色输出 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
Blue="\033[36m"
YELLOW='\033[1;33m'
Font="\033[0m"
NC='\033[0m'

# --- 全局变量和系统检测 ---
OS_TYPE=""
NGINX_CONF_DIR=""
NGINX_WEB_ROOT=""

detect_os() {
  case "$(uname -s)" in
    Linux*) OS_TYPE="linux"; NGINX_CONF_DIR="/etc/nginx"; NGINX_WEB_ROOT="/var/www/html";;
    Darwin*)
      OS_TYPE="macos"
      if [ -d "/opt/homebrew" ]; then NGINX_CONF_DIR="/opt/homebrew/etc/nginx"; NGINX_WEB_ROOT="/opt/homebrew/var/www";
      else NGINX_CONF_DIR="/usr/local/etc/nginx"; NGINX_WEB_ROOT="/usr/local/var/www"; fi
      ;;
    *) echo -e "${RED}不支持的操作系统: $(uname -s)${NC}" >&2; exit 1;;
  esac
  echo -e "${GREEN}检测到操作系统: $OS_TYPE${NC}"
}

check_privileges() {
  if [[ "$OS_TYPE" == "linux" && "$(id -u)" -ne 0 ]]; then
    echo -e "${RED}错误: 在 Linux 上，此脚本必须以 root 权限运行。${NC}" >&2
    echo -e "${YELLOW}请尝试使用 'sudo ./docker_manager.sh'${NC}"; exit 1
  elif [[ "$OS_TYPE" == "macos" ]]; then
    echo -e "${YELLOW}在 macOS 上运行。需要 sudo 的操作会提示您输入密码。${NC}"
  fi
}

ensure_packages() {
  local pkgs_to_install=()
  for pkg in "$@"; do
      if ! command -v "$pkg" &> /dev/null; then
          if [[ "$OS_TYPE" == "macos" && "$pkg" == "docker" ]]; then
              echo -e "${RED}错误: Docker Desktop for Mac 未安装。请先从官网安装。${NC}" >&2; return 1
          fi
          pkgs_to_install+=("$pkg")
      else
          echo -e "${GREEN}依赖 $pkg 已就绪。${NC}"
      fi
  done

  if [ ${#pkgs_to_install[@]} -eq 0 ]; then return 0; fi
  echo -e "${YELLOW}以下依赖需要安装: ${pkgs_to_install[*]}${NC}"

  if [[ "$OS_TYPE" == "linux" ]]; then
    local PKG_MANAGER=""
    if [ -f /etc/os-release ]; then . /etc/os-release; OS_ID=$ID; else echo -e "${RED}无法检测 OS。${NC}" >&2; return 1; fi
    if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then PKG_MANAGER="apt-get"; elif [[ "$OS_ID" == "centos" || "$OS_ID" == "rhel" || "$OS_ID" == "fedora" ]]; then PKG_MANAGER="yum"; if ! command -v yum &> /dev/null; then PKG_MANAGER="dnf"; fi; else echo -e "${RED}不支持的 OS: $OS_ID ${NC}" >&2; return 1; fi
    if [[ $PKG_MANAGER == "apt-get" ]]; then echo "正在更新..."; sudo $PKG_MANAGER update > /dev/null; fi
    for pkg in "${pkgs_to_install[@]}"; do sudo $PKG_MANAGER install -y "$pkg" || { echo -e "${RED}依赖 $pkg 安装失败。${NC}" >&2; return 1; }; done
  elif [[ "$OS_TYPE" == "macos" ]]; then
    if ! command -v brew &> /dev/null; then echo -e "${RED}错误: Homebrew 未安装 (brew.sh)。${NC}" >&2; return 1; fi
    for pkg in "${pkgs_to_install[@]}"; do brew install "$pkg" || { echo -e "${RED}依赖 $pkg 安装失败。${NC}" >&2; return 1; }; done
  fi
}

### ========================================================= ###
###            ★ 安全的 Nginx 操作 ★
### ========================================================= ###
NGINX_TEMP_CONF_NAME="docker_migration_server.conf"

get_server_ip() {
    local ip_addr
    if command -v ip >/dev/null; then ip_addr=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v 127.0.0.1 | head -n 1); fi
    if [ -z "$ip_addr" ]; then ip_addr=$(ifconfig | grep "inet " | grep -v 127.0.0.1 | awk '{print $2}' | head -n 1); fi
    echo "$ip_addr"
}

setup_nginx_for_download() {
  local conf_path=""
  if [[ "$OS_TYPE" == "linux" ]]; then conf_path="${NGINX_CONF_DIR}/sites-available/${NGINX_TEMP_CONF_NAME}";
  else mkdir -p "${NGINX_CONF_DIR}/servers"; conf_path="${NGINX_CONF_DIR}/servers/${NGINX_TEMP_CONF_NAME}"; fi
  if [ -f "$conf_path" ]; then echo -e "${GREEN}Nginx 临时下载服务器已配置。${NC}"; return 0; fi
  echo -e "${GREEN}打包完成，正在配置 Nginx...${NC}"; sudo mkdir -p "${NGINX_WEB_ROOT}"
  echo "server { listen 8889; server_name _; root ${NGINX_WEB_ROOT}; autoindex on; access_log off; }" | sudo tee "$conf_path" > /dev/null
  if [[ "$OS_TYPE" == "linux" ]]; then sudo ln -sf "$conf_path" "${NGINX_CONF_DIR}/sites-enabled/${NGINX_TEMP_CONF_NAME}" 2>/dev/null; fi
  echo "正在重载 Nginx..."; sudo nginx -t || { echo -e "${RED}Nginx 配置测试失败！${NC}"; sudo rm -f "$conf_path"; return 1; }
  if [[ "$OS_TYPE" == "linux" ]]; then sudo systemctl reload nginx; else brew services reload nginx >/dev/null 2>&1 || brew services restart nginx >/dev/null 2>&1; fi
  if [ $? -ne 0 ]; then echo -e "${RED}重载 Nginx 失败，请检查端口 8889。${NC}"; sudo rm -f "$conf_path"; return 1; fi
  echo -e "${GREEN}临时下载服务器已搭建就绪。${NC}"; return 0
}

restore_nginx_config() {
    local conf_path=""
    if [[ "$OS_TYPE" == "linux" ]]; then conf_path="${NGINX_CONF_DIR}/sites-available/${NGINX_TEMP_CONF_NAME}";
    else conf_path="${NGINX_CONF_DIR}/servers/${NGINX_TEMP_CONF_NAME}"; fi
    if [ ! -f "$conf_path" ]; then echo -e "${YELLOW}未找到 Nginx 临时配置文件。${NC}"; return; fi
    echo -e "${YELLOW}正在移除 Nginx 临时配置...${NC}"; sudo rm -f "$conf_path"
    if [[ "$OS_TYPE" == "linux" ]]; then sudo rm -f "${NGINX_CONF_DIR}/sites-enabled/${NGINX_TEMP_CONF_NAME}" 2>/dev/null; fi
    if sudo nginx -t; then
        if [[ "$OS_TYPE" == "linux" ]]; then sudo systemctl reload nginx; else brew services reload nginx >/dev/null 2>&1 || brew services restart nginx >/dev/null 2>&1; fi
        echo -e "${GREEN}Nginx 临时配置已移除。${NC}"
    else echo -e "${RED}恢复 Nginx 配置失败。${NC}"; fi
}

check_runlike() {
    echo "检查 runlike 工具..."
    if ! docker image inspect assaflavie/runlike:latest >/dev/null 2>&1; then
        echo -e "${YELLOW}正在拉取 runlike 镜像...${NC}"
        docker pull assaflavie/runlike:latest || { echo -e "${RED}拉取 runlike 镜像失败。${NC}"; return 1; }
    fi; echo -e "${GREEN}runlike 镜像已就绪。${NC}"; return 0
}

### ========================================================= ###
###        ★ 功能1: 完整迁移 - 备份 ★
### ========================================================= ###
full_docker_backup() {
    echo -e "\n${YELLOW}--- 1. 完整迁移: 备份容器 (源服务器) ---${NC}"
    ensure_packages "docker" "tar" "nginx" || return 1
    check_runlike || return 1

    local ALL_CONTAINERS=$(docker ps --format '{{.Names}}')
    if [ -z "$ALL_CONTAINERS" ]; then echo -e "${RED}错误: 未找到任何正在运行的容器。${NC}"; return 1; fi

    local TARGET_CONTAINERS=()
    local RESTORE_SCRIPT="restore_containers.sh"
    local ARCHIVE_NAME="docker_migration_backup.tar.gz"

    while true; do
        echo "当前正在运行的容器:"; echo -e "${GREEN}$ALL_CONTAINERS${NC}"
        echo -e "\n请选择备份范围:\n 1. 备份所有容器\n 2. 备份指定容器\n 3. 返回主菜单"
        read -p "请选择 (1-3): " bk_choice
        case $bk_choice in
            1) TARGET_CONTAINERS=($ALL_CONTAINERS); break ;;
            2)
                read -p "请输入要备份的容器名称 (用空格分隔): " -r user_input; read -ra selected_containers <<< "$user_input"
                local valid_containers=(); local invalid_found=0
                for c in "${selected_containers[@]}"; do
                    if ! echo "$ALL_CONTAINERS" | grep -wq "$c"; then echo -e "${RED}错误: 找不到容器 '$c'。${NC}"; invalid_found=1; break; fi
                    valid_containers+=("$c")
                done
                if [ $invalid_found -eq 1 ]; then continue; fi
                TARGET_CONTAINERS=("${valid_containers[@]}"); break ;;
            3) return 0 ;;
            *) echo -e "${RED}无效选项!${NC}";;
        esac
    done

    if [ ${#TARGET_CONTAINERS[@]} -eq 0 ]; then echo -e "${YELLOW}未选择容器，操作取消。${NC}"; return 0; fi

    echo -e "${GREEN}备份文件命名为: ${YELLOW}${ARCHIVE_NAME}${NC}"
    local BACKUP_DIR="docker_backup_$$"; mkdir "$BACKUP_DIR"
    echo "#!/bin/bash" > "${BACKUP_DIR}/${RESTORE_SCRIPT}"
    echo "MIGRATION_DIR=\$(cd \"\$(dirname \"\$0\")\" && pwd)" >> "${BACKUP_DIR}/${RESTORE_SCRIPT}"

    for c in "${TARGET_CONTAINERS[@]}"; do
        echo -e "\n${GREEN}备份数据卷并生成 $c 的安装命令...${NC}"
        run_cmd=$(docker run --rm -v /var/run/docker.sock:/var/run/docker.sock assaflavie/runlike "$c")
        clean_cmd=$(echo "$run_cmd" | sed -E 's/--hostname=[^ ]+ //g; s/--mac-address=[^ ]+ //g')
        modified_cmd=$(echo "$clean_cmd" | sed -E "s|-v ([^:]+):|-v \${MIGRATION_DIR}\\1:|g")
        echo "echo -e \"\n--- 恢复: $c ---\"; CID=\$($modified_cmd); if [ -n \"\$CID\" ]; then echo -e \"\033[0;32m$c 恢复成功\033[0m\"; else echo -e \"\033[0;31m$c 恢复失败\033[0m\"; exit 1; fi" >> "${BACKUP_DIR}/${RESTORE_SCRIPT}"
        docker inspect "$c" --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' >> "${BACKUP_DIR}/volume_paths.txt.tmp"
    done
    sort -u "${BACKUP_DIR}/volume_paths.txt.tmp" > "${BACKUP_DIR}/volume_paths.txt"; rm "${BACKUP_DIR}/volume_paths.txt.tmp"

    echo -e "\n${GREEN}备份完成，执行打包程序... ${NC}"
    tar_opts=("-czf" "$ARCHIVE_NAME"); if [[ "$OS_TYPE" == "macos" ]]; then tar_opts+=("-P"); else tar_opts+=("--absolute-names"); fi
    sudo tar "${tar_opts[@]}" -C "${BACKUP_DIR}" "${RESTORE_SCRIPT}" -C / -T "${BACKUP_DIR}/volume_paths.txt" || { echo -e "${RED}打包失败!${NC}"; rm -rf "$BACKUP_DIR"; return 1; }
    rm -rf "$BACKUP_DIR"

    setup_nginx_for_download || return 1
    sudo mv -f "$ARCHIVE_NAME" "${NGINX_WEB_ROOT}/"
    local server_ip=$(get_server_ip)
    echo -e "\n${GREEN}--- ✅  备份完成！ ---${NC}"
    echo -e "下载地址: ${YELLOW}http://${server_ip}:8889/${ARCHIVE_NAME}${NC}"
    echo -e "在新服务器上恢复只需要输入 IP 地址 ${GREEN}${server_ip}${NC} 即可下载备份的容器。"
}


### ========================================================= ###
###        ★ 功能2: 完整迁移 - 恢复 ★ (已修正)
### ========================================================= ###
full_docker_restore() {
    echo -e "\n${YELLOW}--- 2. 完整迁移: 恢复容器 (新服务器) ---${NC}"
    ensure_packages "wget" "docker" "tar" "curl" || return 1
    read -p "请输入源服务器的 IP 地址或域名: " BACKUP_IP
    if [ -z "$BACKUP_IP" ]; then echo -e "${RED}IP 地址不能为空。${NC}"; return 1; fi

    local BASE_URL="http://${BACKUP_IP}:8889"
    local BAK_FILE="docker_migration_backup.tar.gz"
    local DL_URL="${BASE_URL}/${BAK_FILE}"
    
    echo "正在尝试从 $DL_URL 查找并下载备份文件..."
    wget -q --spider "$DL_URL" || { echo -e "${RED}错误: 无法在源服务器上找到指定的备份文件 ($BAK_FILE)。\n请确认源服务器已成功执行备份。${NC}"; return 1; }
    
    local RESTORE_DIR="migration_temp_$$"
    
    echo "正在下载文件: $DL_URL"; wget -q --show-progress "$DL_URL" || { echo -e "${RED}下载失败!${NC}"; return 1; }
    echo "创建恢复目录: ${RESTORE_DIR}/"; mkdir "$RESTORE_DIR"
    echo "解压缩备份文件...";
    tar_opts=("-xzf" "$BAK_FILE" "-C" "${RESTORE_DIR}/"); if [[ "$OS_TYPE" == "macos" ]]; then tar_opts+=("-P"); fi
    sudo tar "${tar_opts[@]}" || { echo -e "${RED}解压失败!${NC}"; rm -rf "$BAK_FILE" "$RESTORE_DIR"; return 1; }

    local SCRIPT_PATH=$(find "${RESTORE_DIR}" -name "restore_*.sh")
    if [ -z "$SCRIPT_PATH" ]; then
        echo -e "${RED}错误: 未在备份包中找到恢复脚本 (restore_*.sh)。${NC}"; rm -rf "$BAK_FILE" "$RESTORE_DIR"; return 1
    fi
    
    # --- BUG 修正处 ---
    echo "为恢复脚本授权..."
    sudo chmod +x "$SCRIPT_PATH" || { echo -e "${RED}授权失败!${NC}"; rm -rf "$BAK_FILE" "$RESTORE_DIR"; return 1; }

    echo -e "\n${GREEN}即将执行恢复脚本...${NC}"; sleep 2
    if ! sudo "$SCRIPT_PATH"; then 
        echo -e "\n${RED}恢复脚本执行过程中发生错误。${NC}";
    else 
        echo -e "\n${GREEN}--- ✅ 所有容器已成功恢复！ ---${NC}"; 
    fi

    rm "$BAK_FILE"
    # 使用 sudo 来清理 root 创建的目录
    echo "正在清理临时恢复目录..."
    sudo rm -rf "$RESTORE_DIR" 
    echo -e "\n${GREEN}--- 当前容器状态 ---${NC}"; docker ps
}


### ========================================================= ###
###        ★ 功能3: 备份数据卷 (本地) ★
### ========================================================= ###
backup_container_volumes() {
    echo -e "\n${YELLOW}--- 3. 备份数据卷 (本地) ---${NC}"
    ensure_packages "docker" "tar" || return 1
    local ALL_CONTAINERS=$(docker ps --format '{{.Names}}')
    if [ -z "$ALL_CONTAINERS" ]; then echo -e "${RED}错误: 未找到运行的容器。${NC}"; return 1; fi

    local TARGET_CONTAINERS=(); local BASE_FILENAME=""
    while true; do
        echo -e "当前运行的容器:\n${GREEN}$ALL_CONTAINERS${NC}"
        echo -e "\n1. 备份所有容器的数据卷\n2. 备份指定容器的数据卷\n3. 返回"
        read -p "请选择 (1-3): " v_choice
        case $v_choice in
            1) TARGET_CONTAINERS=($ALL_CONTAINERS); BASE_FILENAME="all_containers_volumes"; break;;
            2)
                read -p "请输入容器名称: " c_name
                if ! echo "$ALL_CONTAINERS" | grep -wq "$c_name"; then echo -e "${RED}错误: 找不到容器 '$c_name'。${NC}"; continue; fi
                TARGET_CONTAINERS=("$c_name"); BASE_FILENAME="${c_name}_volumes"; break ;;
            3) return 0 ;;
            *) echo -e "${RED}无效选项!${NC}" ;;
        esac
    done

    local ARCHIVE_NAME="${BASE_FILENAME}.tar.gz"
    echo -e "${GREEN}备份文件将命名为: ${YELLOW}${ARCHIVE_NAME}${NC}"

    local VOLUME_PATHS_FILE="volume_paths_$$.txt"; touch "$VOLUME_PATHS_FILE"
    echo "提取数据卷路径..."; for c in "${TARGET_CONTAINERS[@]}"; do docker inspect "$c" --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' >> "$VOLUME_PATHS_FILE"; done
    if [ ! -s "$VOLUME_PATHS_FILE" ]; then echo -e "${YELLOW}所选容器无挂载卷。${NC}"; rm "$VOLUME_PATHS_FILE"; return 0; fi
    sort -u "$VOLUME_PATHS_FILE" -o "$VOLUME_PATHS_FILE"

    echo -e "\n${YELLOW}打包中...${NC}"
    tar_opts=("-czf" "$ARCHIVE_NAME"); if [[ "$OS_TYPE" == "macos" ]]; then tar_opts+=("-P"); else tar_opts+=("--absolute-names"); fi
    sudo tar "${tar_opts[@]}" -C / -T "$VOLUME_PATHS_FILE" || { echo -e "${RED}打包失败!${NC}"; rm "$VOLUME_PATHS_FILE"; return 1; }
    rm "$VOLUME_PATHS_FILE"
    echo -e "\n${GREEN}--- ✅ 打包完成！ ---${NC}"; echo -e "备份文件位于: ${YELLOW}$(pwd)/${ARCHIVE_NAME}${NC}"

    read -p "需要启动 Web 服务器下载吗? (y/N): " start_server
    if [[ "$start_server" =~ ^[Yy]$ ]]; then
        ensure_packages "nginx" && setup_nginx_for_download && sudo mv -f "$ARCHIVE_NAME" "${NGINX_WEB_ROOT}/"
        local server_ip=$(get_server_ip)
        echo -e "${GREEN}下载地址: ${YELLOW}http://${server_ip}:8889/${ARCHIVE_NAME}${NC}"
    fi
}

# ==================================================
#                     程序主菜单
# ==================================================
main_menu() {
  while true; do
    echo -e "\n${Blue}=============================================${Font}"
    echo -e "        Docker 迁移与备份工具 v2.5"
    echo -e "${Blue}=============================================${Font}"
    echo -e "  ${GREEN}1.${NC}  备份容器 (源服务器执行)"
    echo -e "  ${GREEN}2.${NC}  恢复容器 (新服务器执行)"
    echo -e "  ${GREEN}3.${NC}  备份数据 (仅备份于本地)"
    echo -e "  ${Blue}4.${NC}  清理 Nginx 临时配置"
    echo -e "  ${RED}5.${NC}  退出"
    echo -e "${Blue}=============================================${Font}"
    read -p "请输入选项 (1-5): " choice
    case $choice in
      1) full_docker_backup ;;
      2) full_docker_restore ;;
      3) backup_container_volumes ;;
      4) restore_nginx_config ;;
      5) trap - INT TERM; restore_nginx_config; echo -e "${GREEN}脚本执行完毕!${NC}"; exit 0 ;;
      *) echo -e "${RED}无效选项。${NC}" >&2 ;;
    esac
  done
}

# --- 脚本主入口 ---
trap "echo -e '\n捕获到退出信号，正在清理...'; restore_nginx_config; exit 1" INT TERM
detect_os
check_privileges
main_menu
