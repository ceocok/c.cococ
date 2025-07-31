#!/bin/bash

# =================================================================
# Docker 迁移交互式脚本 (V7 - 支持 NPM 并重构)
# 作者: AI Assistant & User
# 更新: 添加NPM备份恢复；重构菜单；抽象出通用Nginx下载服务。
# =================================================================

# --- 定义颜色输出 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- 脚本必须以 root 权限运行 ---
check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}错误: 此脚本必须以 root 权限运行。${NC}" >&2
    echo -e "${YELLOW}请尝试使用 'sudo ./docker_manager.sh'${NC}"
    exit 1
  fi
}

# --- 按需检查并安装依赖的函数 ---
ensure_packages() {
  local PKG_MANAGER=""
  if [ -f /etc/os-release ]; then . /etc/os-release; OS_ID=$ID; else echo -e "${RED}无法检测到操作系统。${NC}" >&2; exit 1; fi
  if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then PKG_MANAGER="apt-get"; elif [[ "$OS_ID" == "centos" || "$OS_ID" == "rhel" || "$OS_ID" == "fedora" ]]; then PKG_MANAGER="yum"; if ! command -v yum &> /dev/null; then PKG_MANAGER="dnf"; fi; else echo -e "${RED}不支持的操作系统: $OS_ID ${NC}" >&2; exit 1; fi
  if [[ $PKG_MANAGER == "apt-get" ]]; then echo "正在更新软件包列表..."; sudo $PKG_MANAGER update > /dev/null; fi

  for pkg in "$@"; do
    if ! command -v "$pkg" &> /dev/null; then
      echo -e "${YELLOW}未找到命令: $pkg, 正在安装...${NC}"
      if [ "$pkg" == "docker" ]; then
        curl -fsSL https://get.docker.com -o get-docker.sh; sudo sh get-docker.sh; rm get-docker.sh
        if [ $? -ne 0 ]; then echo -e "${RED}Docker 安装失败。${NC}" >&2; exit 1; fi
        sudo systemctl start docker && sudo systemctl enable docker
      else
        sudo $PKG_MANAGER install -y "$pkg"
        if [ $? -ne 0 ]; then echo -e "${RED}依赖 $pkg 安装失败。${NC}" >&2; exit 1; fi
      fi
      echo -e "${GREEN}$pkg 安装成功。${NC}"
    else
      echo -e "${GREEN}依赖 $pkg 已安装。${NC}"
    fi
  done
}

# --- 智能修正 Nginx 配置结构的函数 ---
fix_nginx_symlink() {
  if [ -f "/etc/nginx/sites-enabled/default" ] && [ ! -L "/etc/nginx/sites-enabled/default" ]; then
    echo -e "${YELLOW}警告: 检测到非标准的 Nginx 配置，正在自动修正...${NC}"
    rm -f "/etc/nginx/sites-enabled/default"
    ln -s "/etc/nginx/sites-available/default" "/etc/nginx/sites-enabled/default"
    echo -e "${GREEN}Nginx 配置结构已修正为标准符号链接。${NC}"
    sleep 1
  fi
}

# --- ★ 通用功能: 启动 Nginx 临时下载服务器 ★ ---
setup_nginx_for_download() {
  if ss -tlpn | grep -q ':8889'; then
    echo -e "${GREEN}Nginx 临时下载服务器已在运行。${NC}"; return 0
  fi
  echo -e "${YELLOW}正在配置 Nginx 临时文件服务器...${NC}"
  fix_nginx_symlink
  local NGINX_CONF="/etc/nginx/sites-available/default"
  local NGINX_BAK_FILE="$NGINX_CONF.bak_script"
  if [ ! -f "$NGINX_BAK_FILE" ]; then
      cp "$NGINX_CONF" "$NGINX_BAK_FILE"
      echo "已创建原始 Nginx 配置文件备份: ${GREEN}$NGINX_BAK_FILE${NC}"
  fi
read -r -d '' NGX_DL_CONF <<'EOF'
server { listen 8889 default_server; root /var/www/html; server_name _; access_log off; location / { try_files $uri =404; } }
EOF
  echo "$NGX_DL_CONF" > "$NGINX_CONF"
  nginx -t && systemctl restart nginx
  if [ $? -ne 0 ]; then
    echo -e "${RED}启动 Nginx 临时服务器失败！正在恢复...${NC}"; cp "$NGINX_BAK_FILE" "$NGINX_CONF"; nginx -t && systemctl restart nginx
    return 1
  fi
  echo -e "${GREEN}Nginx 已成功配置在 8889 端口用于文件下载。${NC}"; return 0
}

# --- ★ 通用功能: 恢复原始 Nginx 配置 ★ ---
restore_nginx_config() {
    local NGINX_CONF="/etc/nginx/sites-available/default"
    local NGINX_BAK_FILE="$NGINX_CONF.bak_script"
    if [ -f "$NGINX_BAK_FILE" ]; then
        echo -e "${YELLOW}检测到配置文件备份，正在恢复 Nginx 原始配置...${NC}"
        cp "$NGINX_BAK_FILE" "$NGINX_CONF"
        nginx -t && systemctl restart nginx
        if [ $? -ne 0 ]; then
            echo -e "${RED}恢复 Nginx 配置失败，请手动检查。${NC}"
        else
            echo -e "${GREEN}Nginx 原始配置已成功恢复。${NC}"
            rm "$NGINX_BAK_FILE"
        fi
    else
        echo -e "${YELLOW}未找到由本脚本创建的 Nginx 备份文件，无需恢复。${NC}"
    fi
}


# ==================================================
#                  功能模块: Alist
# ==================================================
alist_backup() {
  echo -e "\n${YELLOW}--- 开始 ALIST 备份 ---${NC}"
  ensure_packages "tar" "nginx"
  if [ ! -d "/etc/alistdata/" ]; then echo -e "${RED}错误: 目录 /etc/alistdata/ 不存在。${NC}" >&2; return; fi
  echo "1. 正在打包 /etc/alistdata/ ..."
  tar -czvf alistdata.tar.gz /etc/alistdata/
  if [ $? -ne 0 ]; then echo -e "${RED}打包失败!${NC}" >&2; return; fi; echo -e "${GREEN}打包成功！${NC}"
  echo "2. 配置下载服务器..."
  setup_nginx_for_download
  if [ $? -ne 0 ]; then echo -e "${RED}无法配置下载服务器，中止备份。${NC}"; return; fi
  echo "3. 移动备份文件至 Web 根目录..."
  mv alistdata.tar.gz /var/www/html/alistdata.tar.gz
  local SERVER_IP=$(hostname -I | awk '{print $1}')
  echo -e "\n${GREEN}--- ✅ ALIST 备份完成！ ---${NC}"
  echo -e "下载地址: ${YELLOW}http://${SERVER_IP}:8889/alistdata.tar.gz${NC}"
}
alist_restore() {
  echo -e "\n${YELLOW}--- 开始 ALIST 恢复 ---${NC}"
  ensure_packages "wget" "docker" "tar"
  read -p "请输入备份文件所在的服务器 IP 或域名: " BACKUP_IP
  if [ -z "$BACKUP_IP" ]; then echo -e "${RED}IP 地址不能为空。${NC}"; return; fi
  local DOWNLOAD_URL="http://${BACKUP_IP}:8889/alistdata.tar.gz"
  echo "1. 正在下载备份文件..."; wget "$DOWNLOAD_URL"
  if [ $? -ne 0 ]; then echo -e "${RED}下载失败!${NC}"; return; fi; echo -e "${GREEN}下载成功！${NC}"
  echo "2. 正在解压到 /etc/ ..."; tar -xzvf alistdata.tar.gz -C /etc/
   if [ $? -ne 0 ]; then echo -e "${RED}解压失败!${NC}"; return; fi; echo -e "${GREEN}解压成功！${NC}"
  echo "3. 正在批量启动 Docker 容器..."
read -r -d '' DOCKER_COMMANDS <<'EOF'
docker run -d --restart=unless-stopped -v /etc/alistdata/alistchenxin:/opt/openlist/data -p 5255:5244 --name="olist-chenxin" openlistteam/openlist:beta
docker run -d --restart=unless-stopped -v /etc/alistdata/alistx9:/opt/openlist/data -p 5267:5244 --name="olist-x9" openlistteam/openlist:beta
docker run -d --restart=unless-stopped -v /etc/alistdata/alistxiaobai:/opt/openlist/data -p 5249:5244 --name="olist-xiaobai" openlistteam/openlist:beta
docker run -d --restart=unless-stopped -v /etc/alistdata/alistzhuzhu:/opt/openlist/data -p 5263:5244 --name="olist-zhuzhu" openlistteam/openlist:beta
docker run -d --restart=unless-stopped -v /etc/alistdata/alisthuiqi:/opt/openlist/data -p 5253:5244 --name="olist-huiqi" openlistteam/openlist:beta
docker run -d --restart=unless-stopped -v /etc/alistdata/alistwjs:/opt/openlist/data -p 5245:5244 --name="olist-wjs" openlistteam/openlist:beta
docker run -d --restart=unless-stopped -v /etc/alistdata/alistluozhi:/opt/openlist/data -p 5248:5244 --name="olist-luozhi" openlistteam/openlist:beta
docker run -d --restart=unless-stopped -v /etc/alistdata/alistye:/opt/openlist/data -p 5252:5244 --name="olist-ye" openlistteam/openlist:beta
docker run -d --restart=unless-stopped -v /etc/alistdata/alistmai:/opt/openlist/data -p 5250:5244 --name="olist-mai" openlistteam/openlist:beta
docker run -d --restart=unless-stopped -v /etc/alistdata/alistweida:/opt/openlist/data -p 5259:5244 --name="olist-weida" openlistteam/openlist:beta
docker run -d --restart=unless-stopped -v /etc/alistdata/alistsingo:/opt/openlist/data -p 5258:5244 --name="olist-singo" openlistteam/openlist:beta
docker run -d --restart=unless-stopped -v /etc/alistdata/alistguoli:/opt/openlist/data -p 5262:5244 --name="olist-guoli" openlistteam/openlist:beta
docker run -d --restart=unless-stopped -v /etc/alistdata/alistreset:/opt/openlist/data -p 5246:5244 --name="olist-reset" openlistteam/openlist:beta
EOF
  while IFS= read -r cmd; do if [ -n "$cmd" ]; then echo -e "${YELLOW}执行: $cmd ${NC}"; eval "$cmd"; fi; done <<< "$DOCKER_COMMANDS"
  rm alistdata.tar.gz
  echo -e "\n${GREEN}--- ✅ ALIST 恢复完成！ ---${NC}"
}


# ==================================================
#            功能模块: Nginx Proxy Manager
# ==================================================
npm_backup() {
  echo -e "\n${YELLOW}--- 开始 NPM 备份 ---${NC}"
  ensure_packages "tar" "nginx"
  local NPM_DIR="/home/docker/npm"
  if [ ! -d "${NPM_DIR}/data" ] || [ ! -d "${NPM_DIR}/letsencrypt" ]; then
     echo -e "${RED}错误: NPM 数据目录 ${NPM_DIR}/data 或 letsencrypt 不存在。${NC}"; return;
  fi
  echo "1. 正在打包 NPM 数据..."
  tar -czvf npm_backup.tar.gz -C "${NPM_DIR}" data letsencrypt
  if [ $? -ne 0 ]; then echo -e "${RED}打包失败!${NC}"; return; fi; echo -e "${GREEN}打包成功！${NC}"
  echo "2. 配置下载服务器..."
  setup_nginx_for_download
  if [ $? -ne 0 ]; then echo -e "${RED}无法配置下载服务器，中止备份。${NC}"; return; fi
  echo "3. 移动备份文件至 Web 根目录..."
  mv npm_backup.tar.gz /var/www/html/npm_backup.tar.gz
  local SERVER_IP=$(hostname -I | awk '{print $1}')
  echo -e "\n${GREEN}--- ✅ NPM 备份完成！ ---${NC}"
  echo -e "下载地址: ${YELLOW}http://${SERVER_IP}:8889/npm_backup.tar.gz${NC}"
}
npm_restore() {
  echo -e "\n${YELLOW}--- 开始 NPM 恢复 ---${NC}"
  ensure_packages "wget" "docker" "tar"
  read -p "请输入备份文件所在的服务器 IP 或域名: " BACKUP_IP
  if [ -z "$BACKUP_IP" ]; then echo -e "${RED}IP 地址不能为空。${NC}"; return; fi
  local DOWNLOAD_URL="http://${BACKUP_IP}:8889/npm_backup.tar.gz"
  echo "1. 正在下载备份文件..."; wget "$DOWNLOAD_URL"
  if [ $? -ne 0 ]; then echo -e "${RED}下载失败!${NC}"; return; fi; echo -e "${GREEN}下载成功！${NC}"
  if [ "$(docker ps -aq -f name=^npm$)" ]; then
    read -p "检测到已存在名为 'npm' 的容器，是否停止并删除它以继续？(y/n) " -n 1 -r; echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      docker stop npm && docker rm npm; echo -e "${GREEN}旧容器已删除。${NC}"
    else
      echo -e "${YELLOW}恢复中止。${NC}"; return
    fi
  fi
  local NPM_DIR="/home/docker/npm"; mkdir -p "${NPM_DIR}"
  echo "2. 正在解压到 ${NPM_DIR}..."; tar -xzvf npm_backup.tar.gz -C "${NPM_DIR}/"
  if [ $? -ne 0 ]; then echo -e "${RED}解压失败!${NC}"; return; fi; echo -e "${GREEN}解压成功！${NC}"
  echo "3. 正在重新创建 NPM 容器..."
read -r -d '' NPM_RUN_CMD <<'EOF'
docker run --name=npm --volume /home/docker/npm/data:/data --volume /home/docker/npm/letsencrypt:/etc/letsencrypt --network=bridge --workdir=/app -p 443:443 -p 80:80 -p 81:81 --restart=always --runtime=runc --detach=true jc21/nginx-proxy-manager:latest
EOF
  echo -e "${YELLOW}执行: $NPM_RUN_CMD ${NC}"; eval "$NPM_RUN_CMD"
  if [ $? -ne 0 ]; then echo -e "${RED}NPM 容器创建失败!${NC}"; return; fi
  rm npm_backup.tar.gz
  echo -e "\n${GREEN}--- ✅ NPM 恢复完成！ ---${NC}"
}


# ==================================================
#                     程序主菜单
# ==================================================
alist_menu() {
    while true; do
        echo -e "\n--- Alist 迁移菜单 ---"; echo " 1. 备份 Alist (在本机执行)"; echo " 2. 恢复 Alist (在新机执行)"; echo " 3. 返回主菜单"
        read -p "请选择 (1-3): " choice
        case $choice in
            1) alist_backup ;;
            2) alist_restore ;;
            3) break ;;
            *) echo -e "${RED}无效选项!${NC}" ;;
        esac
    done
}
npm_menu() {
    while true; do
        echo -e "\n--- NPM 迁移菜单 ---"; echo " 1. 备份 NPM (在本机执行)"; echo " 2. 恢复 NPM (在新机执行)"; echo " 3. 返回主菜单"
        read -p "请选择 (1-3): " choice
        case $choice in
            1) npm_backup ;;
            2) npm_restore ;;
            3) break ;;
            *) echo -e "${RED}无效选项!${NC}" ;;
        esac
    done
}
main_menu() {
  while true; do
    echo -e "\n=============================="; echo -e "  Docker 迁移工具 (V7)"; echo -e "=============================="
    echo -e "  ${GREEN}1.${NC} Alist 迁移"
    echo -e "  ${GREEN}2.${NC} Nginx Proxy Manager (NPM) 迁移"
    echo -e "------------------------------"
    echo -e "  ${YELLOW}3.${NC} [在源服务器] 恢复原始 Nginx 配置"
    echo -e "  ${RED}4.${NC} 退出脚本"
    echo "=============================="
    read -p "请输入主菜单选项 (1-4): " choice
    case $choice in
      1) alist_menu ;;
      2) npm_menu ;;
      3) restore_nginx_config ;;
      4) echo -e "${YELLOW}正在退出...${NC}"; exit 0 ;;
      *) echo -e "${RED}无效选项，请重试。${NC}" >&2 ;;
    esac
  done
}

# --- 脚本主入口 ---
check_root
main_menu
