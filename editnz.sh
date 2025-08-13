#!/bin/bash


# --- 配置 ---
CONFIG_FILE="/opt/nezha/agent/config.yml"
SERVICE_NAME="nezha-agent.service"
DEFAULT_SERVER="docker.cnno.de:8008"

# --- 颜色定义  ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- 函数定义 ---

# 打印信息
log_info() {
    echo -e "${GREEN}[信息] $1${NC}"
}

# 打印警告
log_warn() {
    echo -e "${YELLOW}[警告] $1${NC}"
}

# 打印错误并退出
log_error_exit() {
    echo -e "${RED}[错误] $1${NC}"
    exit 1
}

# --- 脚本主逻辑 ---

# 1. 检查是否以 root 用户运行
if [[ $EUID -ne 0 ]]; then
   log_error_exit "此脚本需要以 root 权限运行。请使用 'sudo ./update_nezha.sh' 来执行。"
fi

# 2. 检查配置文件是否存在
if [ ! -f "$CONFIG_FILE" ]; then
    log_error_exit "哪吒 Agent 配置文件未找到: ${CONFIG_FILE}"
fi

log_info "找到了哪吒 Agent 配置文件: ${CONFIG_FILE}"
echo "-----------------------------------------------------"

# 3. 提示用户输入新的服务器地址和密钥
echo -e "${YELLOW}请输入新的哪吒面板服务器信息:${NC}"
read -p "新的服务器地址 (回车默认为: ${DEFAULT_SERVER}): " NEW_SERVER

# 如果用户直接回车，则使用默认值
if [ -z "$NEW_SERVER" ]; then
    NEW_SERVER="$DEFAULT_SERVER"
    log_info "未输入服务器地址，已使用默认值: ${NEW_SERVER}"
fi

read -p "新的客户端密钥 (Client Secret): " NEW_SECRET

# 4. 验证密钥输入是否为空
if [ -z "$NEW_SECRET" ]; then
    log_error_exit "客户端密钥不能为空。"
fi

echo "-----------------------------------------------------"
log_info "您确认的信息如下:"
echo -e "新服务器地址: ${YELLOW}${NEW_SERVER}${NC}"
echo -e "新客户端密钥: ${YELLOW}${NEW_SECRET}${NC}"
read -p "确认信息无误并继续吗? (Y/N): " confirm
echo "-----------------------------------------------------"

if [[ ! "$confirm" =~ ^[yY]([eE][sS])?$ ]]; then
    log_warn "操作已取消。"
    exit 0
fi

# 5. 备份原始配置文件
BACKUP_FILE="${CONFIG_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
log_info "正在备份当前配置文件到: ${BACKUP_FILE}"
cp "$CONFIG_FILE" "$BACKUP_FILE"
if [ $? -ne 0 ]; then
    log_error_exit "备份配置文件失败！"
fi

# 6. 使用 sed 命令替换配置
# 使用 # 作为 sed 的分隔符，以避免服务器地址中的 : 和密钥中的 / 等特殊字符造成问题。
# ^server: 表示匹配以 "server:" 开头的行，确保不会误改其他地方。
log_info "正在更新配置文件..."
sed -i "s#^server:.*#server: ${NEW_SERVER}#" "$CONFIG_FILE"
sed -i "s#^client_secret:.*#client_secret: ${NEW_SECRET}#" "$CONFIG_FILE"

log_info "配置文件更新成功！"
echo "-----------------------------------------------------"

# 7. 重启哪吒 Agent 服务
log_info "正在重启 ${SERVICE_NAME} ..."
if systemctl restart "${SERVICE_NAME}"; then
    log_info "${SERVICE_NAME} 重启成功！"
    echo ""
    log_info "显示服务当前状态..."
    # 使用 --no-pager 选项防止输出被分页，便于在脚本中完整显示
    systemctl status "${SERVICE_NAME}" --no-pager
else
    log_error_exit "${SERVICE_NAME} 重启失败！请手动检查服务日志: journalctl -u ${SERVICE_NAME} -f"
fi

echo "====================================================="
log_info "所有操作已成功完成！"
echo "====================================================="
