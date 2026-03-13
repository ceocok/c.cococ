#!/bin/bash

# --- 定义颜色输出 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- 全局变量和系统检测 ---
OS_TYPE=""
NGINX_CONF_DIR=""
WEB_ROOT="/tmp/docker_migration_web" # 统一使用 tmp 目录更安全
NGINX_TEMP_CONF_NAME="docker_migration_server.conf"

# 记录当前运行的服务器类型和 PID
SERVER_TYPE="" 
PYTHON_PID=""

# --- 基础工具函数 ---

detect_os() {
	case "$(uname -s)" in
		Linux*)  OS_TYPE="linux";;
		Darwin*) OS_TYPE="macos";;
		*)       echo -e "${RED}错误: 不支持的操作系统: $(uname -s)${NC}" >&2; exit 1;;
	esac
	echo -e "${GREEN}检测到操作系统: $OS_TYPE${NC}"
}

check_privileges() {
	if [[ "$OS_TYPE" == "linux" && "$(id -u)" -ne 0 ]]; then
		echo -e "${RED}错误: 在 Linux 上, 此脚本必须以 root 权限运行。${NC}" >&2
		echo -e "${YELLOW}请尝试使用: sudo $0${NC}"
		exit 1
	fi
}

ensure_packages() {
	local pkgs_to_install=()
	for pkg in "$@"; do
		if ! command -v "$pkg" &> /dev/null; then
			[[ "$OS_TYPE" == "macos" && "$pkg" == "docker" ]] && { echo -e "${RED}错误: Docker Desktop for Mac 未安装。请先从官网安装。${NC}" >&2; return 1; }
			pkgs_to_install+=("$pkg")
		fi
	done

	if [ ${#pkgs_to_install[@]} -eq 0 ]; then return 0; fi

	echo -e "${YELLOW}以下依赖需要安装: ${pkgs_to_install[*]}${NC}"
	read -p "是否继续安装? (Y/N): " confirm_install
	[[ ! "$confirm_install" =~ ^[Yy]$ ]] && { echo "安装取消。"; return 1; }

	if [[ "$OS_TYPE" == "linux" ]]; then
		PKG_MANAGER=""
		if grep -qE 'ubuntu|debian' /etc/os-release; then
			PKG_MANAGER="apt-get"
			echo "正在更新包列表..."; sudo $PKG_MANAGER update -y >/dev/null
		elif grep -qE 'centos|rhel|fedora' /etc/os-release; then
			PKG_MANAGER="yum"
			command -v dnf &>/dev/null && PKG_MANAGER="dnf"
		else
			echo -e "${RED}错误: 不支持的 Linux 发行版。${NC}"; return 1
		fi
		sudo $PKG_MANAGER install -y "${pkgs_to_install[@]}" || { echo -e "${RED}依赖安装失败。${NC}"; return 1; }
	elif [[ "$OS_TYPE" == "macos" ]]; then
		command -v brew &> /dev/null || { echo -e "${RED}错误: Homebrew 未安装 (brew.sh)。${NC}"; return 1; }
		brew install "${pkgs_to_install[@]}" || { echo -e "${RED}依赖安装失败。${NC}"; return 1; }
	fi
}

get_server_ip() {
	local ip_addr
	ip_addr=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v 127.0.0.1 | head -n 1)
	if [ -z "$ip_addr" ]; then
		ip_addr=$(curl -s --connect-timeout 2 https://api.ipify.org) || ip_addr="[无法获取公网IP]"
	fi
	echo "$ip_addr"
}

# --- Web服务器 相关函数 (Nginx & Python 兜底) ---

detect_nginx_paths() {
	local common_dirs=(
		"/www/server/panel/vhost/nginx"    # 宝塔面板
		"/etc/nginx/conf.d"                # CentOS/官方默认
		"/etc/nginx/sites-enabled"         # Ubuntu/Debian 默认
		"/usr/local/nginx/conf/vhost"      # LNMP
		"/usr/local/nginx/conf/conf.d"
		"/opt/homebrew/etc/nginx/servers"  # Mac M1/M2
		"/usr/local/etc/nginx/servers"     # Mac Intel
	)

	NGINX_CONF_DIR=""
	for dir in "${common_dirs[@]}"; do
		if [ -d "$dir" ]; then
			NGINX_CONF_DIR="$dir"
			break
		fi
	done

	if [ -z "$NGINX_CONF_DIR" ]; then
		return 1
	fi
	return 0
}

start_python_server() {
	echo -e "${YELLOW}正在使用 Python 内置 HTTP 服务器作为备选方案...${NC}"
	sudo mkdir -p "$WEB_ROOT"
	sudo chmod 755 "$WEB_ROOT"

	local py_cmd=""
	if command -v python3 &>/dev/null; then
		py_cmd="python3 -m http.server 8889"
	elif command -v python &>/dev/null; then
		if python --version 2>&1 | grep -q "Python 3"; then
			py_cmd="python -m http.server 8889"
		else
			py_cmd="python -m SimpleHTTPServer 8889"
		fi
	else
		echo -e "${RED}错误: 系统未安装 Nginx，也未安装 Python，无法启动下载服务！${NC}"
		return 1
	fi

	# 切换目录并在后台启动 Python HTTP 服务
	cd "$WEB_ROOT" || return 1
	sudo nohup $py_cmd > /dev/null 2>&1 &
	PYTHON_PID=$!
	cd - > /dev/null || return 1

	sleep 2 # 等待服务启动
	if ps -p $PYTHON_PID > /dev/null; then
		echo -e "${GREEN}Python 临时下载服务器已在端口 8889 启动。${NC}"
		SERVER_TYPE="python"
		return 0
	else
		echo -e "${RED}Python 服务器启动失败，端口 8889 可能被占用。${NC}"
		return 1
	fi
}

setup_download_server() {
	sudo mkdir -p "$WEB_ROOT"
	sudo chmod 755 "$WEB_ROOT"

	# 1. 优先尝试配置 Nginx
	if detect_nginx_paths; then
		local conf_path="${NGINX_CONF_DIR}/${NGINX_TEMP_CONF_NAME}"
		echo -e "${YELLOW}检测到 Nginx 配置目录: $NGINX_CONF_DIR，尝试使用 Nginx...${NC}"
		
		local nginx_config="server { listen 8889; server_name _; root ${WEB_ROOT}; autoindex on; access_log off; }"
		echo "$nginx_config" | sudo tee "$conf_path" > /dev/null

		if sudo nginx -t &>/dev/null; then
			if [[ "$OS_TYPE" == "linux" ]]; then 
				sudo nginx -s reload || sudo systemctl reload nginx
			else 
				brew services reload nginx &>/dev/null || brew services restart nginx &>/dev/null
			fi
			
			if [ $? -eq 0 ]; then
				echo -e "${GREEN}Nginx 临时下载服务器已在端口 8889 启动。${NC}"
				SERVER_TYPE="nginx"
				return 0
			fi
		fi
		# Nginx 失败则清理产生的配置
		echo -e "${YELLOW}Nginx 配置或重载失败，自动清理残留并尝试备选方案...${NC}"
		sudo rm -f "$conf_path" &>/dev/null
	else
		echo -e "${YELLOW}未检测到支持的 Nginx 配置目录。${NC}"
	fi

	# 2. 如果 Nginx 失败或不存在，使用 Python 兜底
	start_python_server || return 1
}

cleanup_download_server() {
	echo -e "${YELLOW}\n正在清理临时 Web 服务与文件...${NC}"
	
	if [[ "$SERVER_TYPE" == "python" ]]; then
		if [ -n "$PYTHON_PID" ] && ps -p $PYTHON_PID > /dev/null; then
			sudo kill -9 "$PYTHON_PID" &>/dev/null
			echo -e "${GREEN}Python 临时服务器已关闭。${NC}"
		fi
	elif [[ "$SERVER_TYPE" == "nginx" ]]; then
		[ -z "$NGINX_CONF_DIR" ] && detect_nginx_paths &>/dev/null
		local conf_path="${NGINX_CONF_DIR}/${NGINX_TEMP_CONF_NAME}"
		
		if [ -f "$conf_path" ]; then
			sudo rm -f "$conf_path" &>/dev/null
			if sudo nginx -t &>/dev/null; then
				if [[ "$OS_TYPE" == "linux" ]]; then 
					sudo nginx -s reload || sudo systemctl reload nginx &>/dev/null
				else 
					brew services reload nginx &>/dev/null || brew services restart nginx &>/dev/null
				fi
				echo -e "${GREEN}Nginx 临时配置已清理并重载。${NC}"
			else
				echo -e "${RED}警告: 移除临时配置后 Nginx 自身配置异常。请手动检查!${NC}"
			fi
		fi
	fi
	
	# 清理下载目录
	sudo rm -rf "$WEB_ROOT" &>/dev/null
	SERVER_TYPE=""
}

# --- Docker 核心功能函数 ---

check_runlike() {
	if ! docker image inspect assaflavie/runlike:latest &>/dev/null; then
		echo -e "${YELLOW}迁移工具 'runlike' 未安装，正在拉取镜像...${NC}"
		docker pull assaflavie/runlike:latest || { echo -e "${RED}拉取 'runlike' 镜像失败。请检查网络和 Docker 环境。${NC}"; return 1; }
	fi
	return 0
}

### ========================================================= ###
###           ★ 功能1: Docker 迁移备份 ★
### ========================================================= ###
migration_backup() {
	echo -e "\n${BLUE}--- 1. Docker 迁移备份 (源服务器) ---${NC}"
	ensure_packages "docker" "tar" "gzip" "curl" || return 1
	check_runlike || return 1

	local ALL_CONTAINERS; ALL_CONTAINERS=$(docker ps --format '{{.Names}}')
	[ -z "$ALL_CONTAINERS" ] && { echo -e "${RED}错误: 未找到任何正在运行的容器。${NC}"; return 1; }

	echo "当前正在运行的容器:"; echo -e "${GREEN}${ALL_CONTAINERS}${NC}"
	read -p "请输入要备份的容器名称 (用空格分隔, 回车备份所有): " -r user_input
	
	local TARGET_CONTAINERS=()
	if [ -z "$user_input" ]; then
		TARGET_CONTAINERS=($ALL_CONTAINERS)
	else
		read -ra TARGET_CONTAINERS <<< "$user_input"
	fi

	local DATA_ARCHIVE_NAME="docker_data.tar.gz"
	local START_SCRIPT_NAME="docker_run.sh"
	local TEMP_DIR; TEMP_DIR=$(mktemp -d)

	echo "#!/bin/bash" > "${TEMP_DIR}/${START_SCRIPT_NAME}"
	echo "set -e" >> "${TEMP_DIR}/${START_SCRIPT_NAME}"
	echo "# Auto-generated by Docker Migration Tool. Run this script after restoring data." >> "${TEMP_DIR}/${START_SCRIPT_NAME}"

	local volume_paths_file="${TEMP_DIR}/volume_paths.txt"
	
	for c in "${TARGET_CONTAINERS[@]}"; do
		if ! docker ps -q --filter "name=^/${c}$" | grep -q .; then
			echo -e "${RED}错误: 容器 '$c' 不存在或未运行，已跳过。${NC}"; continue
		fi
		echo -e "\n${YELLOW}正在备份容器文件并生成安装命令: $c ...${NC}"
		
		# 1. 记录数据卷的绝对路径
		docker inspect "$c" --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' >> "${volume_paths_file}"
		
		# 2. 生成原始的、干净的 docker run 命令
		local run_cmd; run_cmd=$(docker run --rm -v /var/run/docker.sock:/var/run/docker.sock assaflavie/runlike "$c")
		local clean_cmd; clean_cmd=$(echo "$run_cmd" | sed -E 's/--hostname=[^ ]+ //g; s/--mac-address=[^ ]+ //g')
		
		echo "" >> "${TEMP_DIR}/${START_SCRIPT_NAME}"
		echo "echo -e \"\n${GREEN}>>> 正在启动容器: $c${NC}\"" >> "${TEMP_DIR}/${START_SCRIPT_NAME}"
		echo "$clean_cmd" >> "${TEMP_DIR}/${START_SCRIPT_NAME}"
	done
	
	# 去重并检查是否有数据卷
	sort -u "${volume_paths_file}" -o "${volume_paths_file}"
	if [ ! -s "${volume_paths_file}" ]; then
		echo -e "${YELLOW}警告: 所选容器没有发现任何挂载的数据卷。只生成启动脚本。${NC}"
		sudo touch "${TEMP_DIR}/${DATA_ARCHIVE_NAME}" # 创建空包
	else
		echo -e "\n${YELLOW}正在打包所有数据卷...${NC}"
		if ! sudo tar -czpf "${TEMP_DIR}/${DATA_ARCHIVE_NAME}" -P -C / -T "${volume_paths_file}"; then
			 echo -e "${RED}打包数据卷失败!${NC}"; sudo rm -rf "$TEMP_DIR"; return 1;
		fi
	fi

	# 启动下载服务
	setup_download_server || { sudo rm -rf "$TEMP_DIR"; return 1; }
	
	# 移动文件到提供下载的目录
	sudo mv "${TEMP_DIR}"/* "${WEB_ROOT}/"
	sudo rm -rf "$TEMP_DIR"
	
	local server_ip; server_ip=$(get_server_ip)
	echo -e "\n${GREEN}--- ✅  备份完成！【请在新服务器恢复完后再退出脚本】！！ ---${NC}"
	echo -e "在新服务器上，输入源服务器的IP或域名将会自动下载以下备份文件:"
	echo -e "1. 数据包:   ${BLUE}http://${server_ip}:8889/${DATA_ARCHIVE_NAME}${NC}"
	echo -e "2. 启动脚本: ${BLUE}http://${server_ip}:8889/${START_SCRIPT_NAME}${NC}"
}

### ========================================================= ###
###           ★ 功能2: Docker 备份恢复 ★
### ========================================================= ###
migration_restore() {
	echo -e "\n${BLUE}--- 2. Docker 备份恢复 (新服务器) ---${NC}"
	ensure_packages "wget" "tar" "gzip" "docker" || return 1
	
	local DATA_ARCHIVE_NAME="docker_data.tar.gz"
	local START_SCRIPT_NAME="docker_run.sh"

	read -p "请输入源服务器的 IP 地址或域名: " source_ip
	[ -z "$source_ip" ] && { echo -e "${RED}IP 地址不能为空。${NC}"; return 1; }

	local data_url="http://${source_ip}:8889/${DATA_ARCHIVE_NAME}"
	local script_url="http://${source_ip}:8889/${START_SCRIPT_NAME}"

	echo "正在下载启动脚本..."
	wget -q --show-progress "$script_url" -O "$START_SCRIPT_NAME" || { echo -e "${RED}下载启动脚本失败!${NC}"; return 1; }
	echo "正在下载备份数据包..."
	wget -q --show-progress "$data_url" -O "$DATA_ARCHIVE_NAME" || { echo -e "${RED}下载备份数据包失败!${NC}"; rm -f "$START_SCRIPT_NAME"; return 1; }
	
	echo -e "\n${YELLOW}正在解压数据到容器指定路径...${NC}"
	if ! sudo tar -xzpf "$DATA_ARCHIVE_NAME" -P -C /; then
		echo -e "${RED}解压数据失败！请检查文件是否损坏或磁盘空间。${NC}"
		return 1
	fi
	sudo chmod +x "$START_SCRIPT_NAME"

	echo -e "\n${GREEN}--- 数据已恢复完毕，准备启动容器... ---${NC}"
	echo "正在执行启动脚本..."
	if sudo ./"$START_SCRIPT_NAME"; then
		echo -e "\n${GREEN}--- ✅ 容器启动脚本执行完毕！---${NC}"
		
		echo "正在自动清理临时文件..."
		sudo rm -f "$DATA_ARCHIVE_NAME" "$START_SCRIPT_NAME"
		echo "临时文件已清理。"
		docker ps -a
	else
		echo -e "\n${RED}容器启动脚本执行时发生错误！请检查上面的日志输出。${NC}"
	fi
}

# ==================================================
#                     程序主菜单
# ==================================================
main_menu() {
	while true; do
		echo -e "\n${BLUE}=============================================${NC}"
		echo -e "      Docker 迁移与备份工具 v4.2 (by:ceocok)"
		echo -e "${BLUE}=============================================${NC}"
		echo -e "  --- 请选择操作 ---"
		echo -e "  ${GREEN}1.${NC}  Docker 迁移备份 (在源服务器运行)"
		echo -e "  ${GREEN}2.${NC}  Docker 备份恢复 (在新服务器运行)"
		echo ""
		echo -e "  ${RED}3.${NC}  退出"
		echo -e "${BLUE}=============================================${NC}"
		read -p "请输入选项 (1-3): " choice

		case $choice in
			1) migration_backup ;;
			2) migration_restore ;;
			3) trap - INT TERM; cleanup_download_server &>/dev/null; echo -e "\n${GREEN}脚本执行完毕，感谢使用！NodeSeek见！${NC}"; exit 0 ;;
			*) echo -e "${RED}无效选项。${NC}" ;;
		esac
	done
}

# --- 脚本主入口 ---
trap "echo -e '\n捕获到退出信号，正在强制清理...'; cleanup_download_server &>/dev/null; exit 1" INT TERM
clear
detect_os
check_privileges
main_menu
