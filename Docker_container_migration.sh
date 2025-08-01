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
    Linux*)
      OS_TYPE="linux"
      NGINX_CONF_DIR="/etc/nginx"
      NGINX_WEB_ROOT="/var/www/html"
      ;;
    Darwin*)
      OS_TYPE="macos"
      if [ -d "/opt/homebrew" ]; then
        NGINX_CONF_DIR="/opt/homebrew/etc/nginx"
        NGINX_WEB_ROOT="/opt/homebrew/var/www"
      else
        NGINX_CONF_DIR="/usr/local/etc/nginx"
        NGINX_WEB_ROOT="/usr/local/var/www"
      fi
      ;;
    *)
      echo -e "${RED}不支持的操作系统: $(uname -s)${NC}" >&2
      exit 1
      ;;
  esac
  echo -e "${GREEN}检测到操作系统: $OS_TYPE${NC}"
}

check_privileges() {
  if [[ "$OS_TYPE" == "linux" && "$(id -u)" -ne 0 ]]; then
    echo -e "${RED}错误: 在 Linux 上，此脚本必须以 root 权限运行。${NC}" >&2
    echo -e "${YELLOW}请尝试使用 'sudo ./docker_manager.sh'${NC}"
    exit 1
  elif [[ "$OS_TYPE" == "macos" ]]; then
    echo -e "${YELLOW}在 macOS 上运行。需要 sudo 权限的操作 (如管理 Nginx、打包系统目录) 会提示您输入密码。${NC}"
  fi
}

ensure_packages() {
  local pkgs_to_install=()
  for pkg in "$@"; do
      if ! command -v "$pkg" &> /dev/null; then
          if [[ "$OS_TYPE" == "macos" && "$pkg" == "docker" ]]; then
              echo -e "${RED}错误: Docker 未安装。请先从官网安装 Docker Desktop for Mac。${NC}" >&2; return 1
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
    if [ -f /etc/os-release ]; then . /etc/os-release; OS_ID=$ID; else echo -e "${RED}无法检测到 OS。${NC}" >&2; return 1; fi
    if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then PKG_MANAGER="apt-get"; elif [[ "$OS_ID" == "centos" || "$OS_ID" == "rhel" || "$OS_ID" == "fedora" ]]; then PKG_MANAGER="yum"; if ! command -v yum &> /dev/null; then PKG_MANAGER="dnf"; fi; else echo -e "${RED}不支持的 OS: $OS_ID ${NC}" >&2; return 1; fi
    if [[ $PKG_MANAGER == "apt-get" ]]; then echo "正在更新..."; sudo $PKG_MANAGER update > /dev/null; fi

    for pkg in "${pkgs_to_install[@]}"; do
      echo -e "${YELLOW}正在安装: $pkg...${NC}"
      if [ "$pkg" == "docker" ]; then
        curl -fsSL https://get.docker.com -o get-docker.sh; sudo sh get-docker.sh; rm get-docker.sh
        if [ $? -ne 0 ]; then echo -e "${RED}Docker 安装失败。${NC}" >&2; return 1; fi
        sudo systemctl start docker && sudo systemctl enable docker
      else
        sudo $PKG_MANAGER install -y "$pkg"
        if [ $? -ne 0 ]; then echo -e "${RED}依赖 $pkg 安装失败。${NC}" >&2; return 1; fi
      fi
    done
  elif [[ "$OS_TYPE" == "macos" ]]; then
      if ! command -v brew &> /dev/null; then echo -e "${RED}错误: Homebrew 未安装 (brew.sh)。${NC}" >&2; return 1; fi
      for pkg in "${pkgs_to_install[@]}"; do
         echo -e "${YELLOW}正在使用 brew 安装: $pkg...${NC}"
         brew install "$pkg"
         if [ $? -ne 0 ]; then echo -e "${RED}依赖 $pkg 安装失败。${NC}" >&2; return 1; fi
      done
  fi
}


### ========================================================= ###
###            ★ 安全的 Nginx 操作 (跨平台) ★
### ========================================================= ###
NGINX_TEMP_CONF_NAME="docker-migration-server.conf"

setup_nginx_for_download() {
  local conf_path=""
  local enabled_link_path=""
  if [[ "$OS_TYPE" == "linux" ]]; then
    conf_path="${NGINX_CONF_DIR}/sites-available/${NGINX_TEMP_CONF_NAME}"
    enabled_link_path="${NGINX_CONF_DIR}/sites-enabled/${NGINX_TEMP_CONF_NAME}"
  else
    mkdir -p "${NGINX_CONF_DIR}/servers" # 确保目录存在
    conf_path="${NGINX_CONF_DIR}/servers/${NGINX_TEMP_CONF_NAME}"
    if ! grep -q "include ${NGINX_CONF_DIR}/servers/\*;" "${NGINX_CONF_DIR}/nginx.conf"; then
        echo -e "${RED}警告: Nginx 主配置文件未包含 'servers' 目录。${NC}"
        echo -e "${YELLOW}请手动添加: 'include ${NGINX_CONF_DIR}/servers/*;' 到 http 块中。${NC}"
        return 1
    fi
  fi
  
  if [ -f "$conf_path" ]; then echo -e "${GREEN}Nginx 临时下载服务器已配置。${NC}"; return 0; fi
  echo -e "${YELLOW}正在配置 Nginx 临时文件服务器...${NC}"
read -r -d '' NGX_DL_CONF <<EOF
server { listen 8889; server_name _; root ${NGINX_WEB_ROOT}; autoindex on; access_log off; }
EOF
  echo "$NGX_DL_CONF" | sudo tee "$conf_path" > /dev/null
  sudo mkdir -p "${NGINX_WEB_ROOT}"
  if [[ "$OS_TYPE" == "linux" ]]; then sudo ln -sf "$conf_path" "$enabled_link_path"; fi
  
  echo "正在测试并重载 Nginx..."
  if ! sudo nginx -t; then
    echo -e "${RED}Nginx 配置测试失败！${NC}"; sudo rm -f "$conf_path" "$enabled_link_path"; return 1
  fi

  if [[ "$OS_TYPE" == "linux" ]]; then sudo systemctl reload nginx; else brew services reload nginx >/dev/null 2>&1 || brew services restart nginx >/dev/null 2>&1; fi
  if [ $? -ne 0 ]; then echo -e "${RED}重载 Nginx 失败，请检查端口 8889 是否被占用。${NC}"; sudo rm -f "$conf_path" "$enabled_link_path"; return 1; fi
  echo -e "${GREEN}Nginx 已在 8889 端口上准备就绪。${NC}"; return 0
}

restore_nginx_config() {
    local conf_path=""
    if [[ "$OS_TYPE" == "linux" ]]; then
        conf_path="${NGINX_CONF_DIR}/sites-available/${NGINX_TEMP_CONF_NAME}"
    else
        conf_path="${NGINX_CONF_DIR}/servers/${NGINX_TEMP_CONF_NAME}"
    fi

    if [ -f "$conf_path" ]; then
        echo -e "${YELLOW}检测到临时 Nginx 配置，正在移除...${NC}"
        sudo rm -f "$conf_path"
        if [[ "$OS_TYPE" == "linux" ]]; then sudo rm -f "${NGINX_CONF_DIR}/sites-enabled/${NGINX_TEMP_CONF_NAME}"; fi
        echo "正在测试并重载 Nginx..."
        if sudo nginx -t; then
            if [[ "$OS_TYPE" == "linux" ]]; then sudo systemctl reload nginx; else brew services reload nginx >/dev/null 2>&1 || brew services restart nginx >/dev/null 2>&1; fi
            echo -e "${GREEN}Nginx 临时配置已成功移除。${NC}"
        else
            echo -e "${RED}恢复 Nginx 配置失败，请手动检查。${NC}"
        fi
    else
        echo -e "${YELLOW}未找到 Nginx 临时配置文件，无需恢复。${NC}"
    fi
}

check_runlike() {
    echo "检查 runlike 工具..."
    if ! docker image inspect assaflavie/runlike:latest >/dev/null 2>&1; then
        echo -e "${YELLOW}正在拉取 runlike 镜像...${NC}"
        docker pull assaflavie/runlike:latest
        if [ $? -ne 0 ]; then echo -e "${RED}拉取 runlike 镜像失败。${NC}"; return 1; fi
    fi
    echo -e "${GREEN}runlike 镜像已就绪。${NC}"
    return 0
}

### ========================================================= ###
###        ★ 功能1: 完整迁移 - 备份 ★
### ========================================================= ###
full_docker_backup() {
    echo -e "\n${YELLOW}--- 1. 完整迁移: 备份所有容器 (源服务器) ---${NC}"
    ensure_packages "docker" "tar" "nginx" || return 1
    check_runlike || return 1

    local BACKUP_DIR="docker_full_backup_$$"
    mkdir "$BACKUP_DIR"
    local CONTAINERS=$(docker ps --format '{{.Names}}')
    if [ -z "$CONTAINERS" ]; then echo -e "${RED}错误: 未找到任何正在运行的容器。${NC}"; rm -rf "$BACKUP_DIR"; return 1; fi
    echo "发现正在运行的容器: ${GREEN}$CONTAINERS${NC}"

    echo "#!/bin/bash" > "${BACKUP_DIR}/restore_all_containers.sh"
    echo "MIGRATION_DIR=\$(cd \"\$(dirname \"\$0\")\" && pwd)" >> "${BACKUP_DIR}/restore_all_containers.sh"

    for c in $CONTAINERS; do
        echo -e "\n${YELLOW}--- 处理中: $c ---${NC}"
        echo "生成 'docker run' 命令..."
        local run_cmd=$(docker run --rm -v /var/run/docker.sock:/var/run/docker.sock assaflavie/runlike "$c")
        local clean_cmd=$(echo "$run_cmd" | sed -E 's/--hostname=[^ ]+ //g; s/--mac-address=[^ ]+ //g; s/--name=[^ ]+ //g' | sed 's/ -d / -d --name '"$c"' /')
        local modified_cmd=$(echo "$clean_cmd" | sed -E "s|-v ([^:]+):|-v \${MIGRATION_DIR}\\1:|g")
        echo "echo -e \"\n--- 正在恢复: $c ---\"; CID=\$($modified_cmd); if [ -n \"\$CID\" ]; then echo -e \"\033[0;32m容器 $c 恢复成功！\033[0m\"; else echo -e \"\033[0;31m容器 $c 恢复失败！\033[0m\"; exit 1; fi" >> "${BACKUP_DIR}/restore_all_containers.sh"
        docker inspect "$c" --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' >> "${BACKUP_DIR}/volume_paths.txt.tmp"
    done
    sort -u "${BACKUP_DIR}/volume_paths.txt.tmp" > "${BACKUP_DIR}/volume_paths.txt"; rm "${BACKUP_DIR}/volume_paths.txt.tmp"

    echo -e "\n${YELLOW}--- 开始打包... ---${NC}"
    local tar_opts=("-czf" "docker_full_backup.tar.gz")
    if [[ "$OS_TYPE" == "macos" ]]; then tar_opts+=("-P"); else tar_opts+=("--absolute-names"); fi
    sudo tar "${tar_opts[@]}" -C "${BACKUP_DIR}" "restore_all_containers.sh" -C / -T "${BACKUP_DIR}/volume_paths.txt"
    if [ $? -ne 0 ]; then echo -e "${RED}打包失败!${NC}"; rm -rf "$BACKUP_DIR"; return 1; fi
    rm -rf "$BACKUP_DIR"

    echo "配置下载服务器..."
    setup_nginx_for_download || return 1
    sudo mv "docker_full_backup.tar.gz" "${NGINX_WEB_ROOT}/"

    local server_ip
    if [[ "$OS_TYPE" == "linux" ]]; then server_ip=$(hostname -I | awk '{print $1}'); else server_ip=$(ipconfig getifaddr en0 || ipconfig getifaddr en1); fi
    echo -e "\n${GREEN}--- ✅  备份完成！ ---${NC}"
    echo -e "下载地址: ${YELLOW}http://${server_ip}:8889/docker_full_backup.tar.gz${NC}"
}

### ========================================================= ###
###        ★ 功能2: 完整迁移 - 恢复 ★
### ========================================================= ###
full_docker_restore() {
    echo -e "\n${YELLOW}--- 2. 完整迁移: 恢复所有容器 (新服务器) ---${NC}"
    ensure_packages "wget" "docker" "tar" || return 1
    read -p "请输入备份文件所在的服务器 IP 或域名: " BACKUP_IP
    if [ -z "$BACKUP_IP" ]; then echo -e "${RED}IP 地址不能为空。${NC}"; return 1; fi

    local DL_URL="http://${BACKUP_IP}:8889/docker_full_backup.tar.gz"
    local BAK_FILE="docker_full_backup.tar.gz"
    local RESTORE_DIR="migration_temp_$$"
    
    echo "正在下载..."; wget -q --show-progress "$DL_URL" || { echo -e "${RED}下载失败!${NC}"; return 1; }
    echo "正在创建恢复目录: ${RESTORE_DIR}/"; mkdir "$RESTORE_DIR"
    echo "正在安全解压..."
    local tar_opts=("-xzf" "$BAK_FILE" "-C" "${RESTORE_DIR}/")
    if [[ "$OS_TYPE" == "macos" ]]; then tar_opts+=("-P"); fi
    sudo tar "${tar_opts[@]}" || { echo -e "${RED}解压失败!${NC}"; rm -rf "$BAK_FILE" "$RESTORE_DIR"; return 1; }

    local SCRIPT_PATH=$(find "${RESTORE_DIR}" -name "restore_all_containers.sh")
    if [ -z "$SCRIPT_PATH" ]; then echo -e "${RED}错误: 未找到恢复脚本。${NC}"; rm -rf "$BAK_FILE" "$RESTORE_DIR"; return 1; fi
    
    chmod +x "$SCRIPT_PATH"
    echo -e "\n${YELLOW}即将自动执行恢复脚本...${NC}"; sleep 2
    if ! "$SCRIPT_PATH"; then
        echo -e "\n${RED}恢复过程中发生错误。${NC}"
    else
        echo -e "\n${GREEN}--- ✅ 所有容器已成功恢复！ ---${NC}"
    fi

    rm "$BAK_FILE"
    echo "恢复后的数据卷保留在: $(pwd)/${RESTORE_DIR}/"
    echo -e "\n${YELLOW}--- 当前容器状态 ---${NC}"; docker ps
}

### ========================================================= ###
###        ★ 功能3: 备份容器数据卷 (本地) ★
### ========================================================= ###
backup_container_volumes() {
    echo -e "\n${YELLOW}--- 3. 备份容器数据卷 (本地) ---${NC}"
    ensure_packages "docker" "tar" || return 1
    local CONTAINERS=$(docker ps --format '{{.Names}}')
    if [ -z "$CONTAINERS" ]; then echo -e "${RED}错误: 未找到任何正在运行的容器。${NC}"; return 1; fi

    local TARGET_CONTAINERS=()
    local ARCHIVE_NAME_PROMPT=""

    while true; do
        echo "当前正在运行的容器:"
        echo -e "${GREEN}$CONTAINERS${NC}"
        echo -e "\n请选择要备份的范围:"
        echo " 1. 备份所有容器的数据卷"
        echo " 2. 备份指定容器的数据卷"
        echo " 3. 返回主菜单"
        read -p "请选择 (1-3): " v_choice
        case $v_choice in
            1)
                TARGET_CONTAINERS=($CONTAINERS)
                ARCHIVE_NAME_PROMPT="all_containers_volumes"
                break
                ;;
            2)
                read -p "请输入要备份的容器名称: " c_name
                if ! echo "$CONTAINERS" | grep -wq "$c_name"; then
                    echo -e "${RED}错误: 找不到名为 '$c_name' 的运行中容器。${NC}"; continue
                fi
                TARGET_CONTAINERS=("$c_name")
                ARCHIVE_NAME_PROMPT="${c_name}_volumes"
                break
                ;;
            3) return 0 ;;
            *) echo -e "${RED}无效选项!${NC}" ;;
        esac
    done

    local VOLUME_PATHS_FILE="volume_paths_$$.txt"
    touch "$VOLUME_PATHS_FILE"
    echo "正在提取数据卷路径..."
    for c in "${TARGET_CONTAINERS[@]}"; do
        docker inspect "$c" --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' >> "$VOLUME_PATHS_FILE"
    done

    if [ ! -s "$VOLUME_PATHS_FILE" ]; then
        echo -e "${YELLOW}所选容器没有任何挂载的数据卷。${NC}"; rm "$VOLUME_PATHS_FILE"; return 0
    fi
    sort -u "$VOLUME_PATHS_FILE" -o "$VOLUME_PATHS_FILE"
    echo "将要打包以下路径:"; cat "$VOLUME_PATHS_FILE"

    local ARCHIVE_NAME
    read -p "请输入备份文件名 (默认: ${ARCHIVE_NAME_PROMPT}.tar.gz): " ARCHIVE_NAME
    ARCHIVE_NAME=${ARCHIVE_NAME:-"${ARCHIVE_NAME_PROMPT}.tar.gz"}

    echo -e "\n${YELLOW}--- 开始打包数据卷 ---${NC}"
    local tar_opts=("-czf" "$ARCHIVE_NAME")
    if [[ "$OS_TYPE" == "macos" ]]; then tar_opts+=("-P"); else tar_opts+=("--absolute-names"); fi
    sudo tar "${tar_opts[@]}" -C / -T "$VOLUME_PATHS_FILE"
    
    if [ $? -ne 0 ]; then echo -e "${RED}打包失败!${NC}"; rm "$VOLUME_PATHS_FILE"; return 1; fi
    rm "$VOLUME_PATHS_FILE"
    echo -e "\n${GREEN}--- ✅ 数据卷打包完成！ ---${NC}"
    echo -e "备份文件位于: ${YELLOW}$(pwd)/${ARCHIVE_NAME}${NC}"

    read -p "是否需要启动临时Web服务器以便下载此文件? (y/N): " start_server
    if [[ "$start_server" == "y" || "$start_server" == "Y" ]]; then
        ensure_packages "nginx" || return 1
        setup_nginx_for_download || return 1
        sudo mv "$ARCHIVE_NAME" "${NGINX_WEB_ROOT}/"
        local server_ip
        if [[ "$OS_TYPE" == "linux" ]]; then server_ip=$(hostname -I | awk '{print $1}'); else server_ip=$(ipconfig getifaddr en0 || ipconfig getifaddr en1); fi
        echo -e "${GREEN}下载服务器已启动。 地址: ${YELLOW}http://${server_ip}:8889/${ARCHIVE_NAME}${NC}"
        echo -e "下载完成后，记得从主菜单选择 '${GREEN}清理Nginx临时配置${NC}'。"
    fi
}

# ==================================================
#                     程序主菜单
# ==================================================
main_menu() {
  while true; do
    echo -e "\n${Blue}=============================================${Font}"
    echo -e "                Docker 迁移与备份工具  "
    echo -e "${Blue}=============================================${Font}"
    echo -e "  ${GREEN}1.${NC}  完整迁移: 备份所有容器 (用于恢复)"
    echo -e "  ${GREEN}2.${NC}  完整迁移: 恢复所有容器 (需要备份文件)"
    echo -e "  ${GREEN}3.${NC}  备份数据卷: 打包容器数据卷 (本地备份)"
    echo -e "  ${GREEN}4.${NC}  工具: 清理Nginx临时配置"
    echo -e "  ${RED}5.${NC}  退出脚本"
    echo -e "${Blue}=============================================${Font}"
    read -p "请输入选项 (1-5): " choice
    case $choice in
      1) full_docker_backup ;;
      2) full_docker_restore ;;
      3) backup_container_volumes ;;
      4) restore_nginx_config ;;
      5) 
        trap - INT TERM 
        restore_nginx_config
        echo -e "${YELLOW}正在退出...${NC}"; exit 0 ;;
      *) echo -e "${RED}无效选项，请重试。${NC}" >&2 ;;
    esac
  done
}

# --- 脚本主入口 ---
trap cleanup_on_exit INT TERM
detect_os
check_privileges
main_menu
