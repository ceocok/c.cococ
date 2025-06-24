#!/bin/bash

# ==========================================
# IRIS自用工具箱 - GitHub一键版
# 项目地址：https://github.com/Acacia415/GPT-Scripts
# ==========================================

# 全局颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
NC='\033[0m'

# ===================== IRIS 工具箱快捷键自动安装 =====================

# 确保以 root 权限运行
if [ "$EUID" -ne 0 ]; then
    echo "请使用 sudo 执行本脚本"
    exit 1
fi

# 获取脚本的绝对路径
SCRIPT_PATH=$(realpath "$0")

# 创建 /usr/local/bin/p 命令
cp -f "$(realpath "$0")" /usr/local/bin/p
chmod +x /usr/local/bin/p
echo "[+] 已创建命令：p ✅"

# ======================= 系统信息查询 =======================
display_system_info() {
    # 检查依赖
    check_deps() {
        local deps=(jq whois)
        local missing=()
        for dep in "${deps[@]}"; do
            if ! command -v $dep &>/dev/null; then
                missing+=("$dep")
            fi
        done
        if [ ${#missing[@]} -gt 0 ]; then
            echo -e "${YELLOW}正在安装依赖：${missing[*]}${NC}"
            apt-get update >/dev/null 2>&1
            apt-get install -y "${missing[@]}" >/dev/null 2>&1
        fi
    }

    # 获取公网IP信息
    get_ip_info() {
        local ipv4=$(curl -s4 ifconfig.me)
        local ipv6=$(curl -s6 ifconfig.me)
        echo "$ipv4" "$ipv6"
    }

    # 获取ASN信息
    get_asn() {
        local ip=$1
        whois -h whois.radb.net -- "-i origin $ip" 2>/dev/null | grep -i descr: | head -1 | awk -F': ' '{print $2}' | xargs
    }

    # 获取地理信息
    get_geo() {
        local ip=$1
        curl -s "https://ipinfo.io/$ip/json" 2>/dev/null | jq -r '[.country, .city] | join(" ")' 
    }

    # 获取CPU使用率
    get_cpu_usage() {
        echo $(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{printf "%.1f%%", 100 - $1}')
    }

    # 主显示逻辑
    clear
    check_deps
    read ipv4 ipv6 <<< $(get_ip_info)
    
    echo -e "${CYAN}\n系统信息查询"
    echo "------------------------"
    echo -e "主机名\t: ${GREEN}$(hostname)${NC}"
    echo -e "运营商\t: ${GREEN}$(get_asn $ipv4)${NC}"
    echo "------------------------"
    echo -e "系统版本\t: ${GREEN}$(lsb_release -sd)${NC}"
    echo -e "内核版本\t: ${GREEN}$(uname -r)${NC}"
    echo "------------------------"
    echo -e "CPU架构\t: ${GREEN}$(uname -m)${NC}"
    echo -e "CPU型号\t: ${GREEN}$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)${NC}"
    echo -e "CPU核心\t: ${GREEN}$(nproc) 核${NC}"
    echo -e "CPU占用\t: ${GREEN}$(get_cpu_usage)${NC}"
    echo "------------------------"
    echo -e "物理内存\t: ${GREEN}$(free -m | awk '/Mem/{printf "%.2f/%.2f MB (%.2f%%)", $3, $2, $3/$2*100}')${NC}"
    echo -e "虚拟内存\t: ${GREEN}$(free -m | awk '/Swap/{printf "%.2f/%.2f MB (%.2f%%)", $3, $2, ($3/$2)*100}')${NC}"
    echo -e "硬盘使用\t: ${GREEN}$(df -h / | awk 'NR==2{printf "%s/%s (%s)", $3, $2, $5}')${NC}"
    echo "------------------------"
    echo -e "公网IPv4\t: ${GREEN}${ipv4:-未检测到}${NC}"
    echo -e "公网IPv6\t: ${GREEN}${ipv6:-未检测到}${NC}"
    echo -e "地理位置\t: ${GREEN}$(get_geo $ipv4)${NC}"
    echo -e "系统时区\t: ${GREEN}$(timedatectl | grep "Time zone" | awk '{print $3}')${NC}"
    echo -e "运行时间\t: ${GREEN}$(awk '{printf "%d天%d时%d分", $1/86400, ($1%86400)/3600, ($1%3600)/60}' /proc/uptime)${NC}"
    echo "------------------------"
}

# ======================= 开启root登录 =======================
enable_root_login() {
  # 移除文件保护属性
  lsattr /etc/passwd /etc/shadow >/dev/null 2>&1
  chattr -i /etc/passwd /etc/shadow >/dev/null 2>&1
  chattr -a /etc/passwd /etc/shadow >/dev/null 2>&1

  # 交互设置密码
  read -p "请输入自定义 root 密码: " mima
  if [[ -n $mima ]]; then
    # 修改密码和SSH配置
    echo root:$mima | chpasswd root
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/g' /etc/ssh/sshd_config
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config
    sed -i 's/^#\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication yes/g' /etc/ssh/sshd_config
    
    # 重启SSH服务
    systemctl restart sshd
    
    echo -e "\n${GREEN}配置完成！请手动重启服务器使部分设置生效！${NC}"
    echo -e "------------------------------------------"
    echo -e "VPS 当前用户名：root"
    echo -e "VPS 当前 root 密码：$mima"
    echo -e "------------------------------------------"
    echo -e "${YELLOW}请使用以下方式登录："
    echo -e "1. 密码方式登录"
    echo -e "2. keyboard-interactive 验证方式${NC}\n"
  else
    echo -e "${RED}密码不能为空，设置失败！${NC}"
  fi
}

# ======================= 流量监控安装 =======================
install_traffic_monitor() {
  # 检查依赖并安装
check_dependencies() {
    local deps=("ipset" "iptables" "ip")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v $dep &>/dev/null; then
            missing+=("$dep")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${YELLOW}正在安装缺失依赖：${missing[*]}${NC}"
        apt-get update
        if ! apt-get install -y ipset iptables iproute2; then
            return 1
        fi
    fi
    return 0
}

  #---------- 生成主监控脚本 ----------#
  echo -e "\n${CYAN}[1/4] 生成主脚本到 /root/ip_blacklist.sh${NC}"
  cat > /root/ip_blacklist.sh <<'EOF'
#!/bin/bash

# 彩色输出定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
NC='\033[0m'

# 检查root权限
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误：此脚本必须以root权限运行！${NC}"
    exit 1
fi

# 加载ipset规则
if [ -f /etc/ipset.conf ]; then
    ipset restore -! < /etc/ipset.conf
fi

#---------- 核心初始化 ----------#
init_system() {
    # 创建ipset集合
    ipset create whitelist hash:ip timeout 0 2>/dev/null || true
    ipset create banlist hash:ip timeout 86400 2>/dev/null || true

    # 配置iptables规则
    iptables -N TRAFFIC_BLOCK 2>/dev/null
    iptables -F TRAFFIC_BLOCK 2>/dev/null
    
    # 白名单优先规则
    iptables -C INPUT -j TRAFFIC_BLOCK 2>/dev/null || iptables -I INPUT -j TRAFFIC_BLOCK
    iptables -A TRAFFIC_BLOCK -m set --match-set whitelist src -j ACCEPT
    iptables -A TRAFFIC_BLOCK -m set --match-set banlist src -j DROP

    # 获取活动网卡
    INTERFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1)
    [ -z "$INTERFACE" ] && {
        echo -e "${RED}未找到有效的网卡接口！${NC}"
        exit 1
    }
    echo -e "监控网卡: ${GREEN}$INTERFACE${NC}"
}

#---------- 流量监控逻辑 ----------#
start_monitor() {
    declare -A ip_first_seen
    LIMIT=40  # 流量阈值(MB/s)
    LOG_FILE="/var/log/iptables_ban.log"

    while true; do
        # 实时流量计算
        RX_BYTES_1=$(cat /sys/class/net/$INTERFACE/statistics/rx_bytes)
        TX_BYTES_1=$(cat /sys/class/net/$INTERFACE/statistics/tx_bytes)
        sleep 1
        RX_BYTES_2=$(cat /sys/class/net/$INTERFACE/statistics/rx_bytes)
        TX_BYTES_2=$(cat /sys/class/net/$INTERFACE/statistics/tx_bytes)

        RX_RATE=$(echo "scale=2; ($RX_BYTES_2 - $RX_BYTES_1) / 1048576" | bc)
        TX_RATE=$(echo "scale=2; ($TX_BYTES_2 - $TX_BYTES_1) / 1048576" | bc)

        echo -e "[$(date +%H:%M:%S)] 接收: ${BLUE}${RX_RATE}MB/s${NC} 发送: ${CYAN}${TX_RATE}MB/s${NC}"

        # 超速处理逻辑
        if (( $(echo "$RX_RATE > $LIMIT || $TX_RATE > $LIMIT" | bc -l) )); then
            echo -e "\n${YELLOW}⚠️  检测到流量超限！正在分析连接...${NC}"
            
            # 获取可疑IP（排除SSH和白名单）
            IP_LIST=$(ss -ntu state established | awk -v port=22 '
                NR > 1 {
                    match($5, /:([0-9]+)$/, port_arr);
                    current_port = port_arr[1];
                    ip = gensub(/\[|\]/, "", "g", substr($5, 1, RSTART-1));
                    if (current_port != port && ip != "0.0.0.0") {
                        print ip;
                    }
                }' | sort | uniq -c | sort -nr)
            
            BAN_IP=$(echo "$IP_LIST" | awk 'NR==1 && $2 != "" {print $2}')
            
            # 跳过白名单IP
            if [[ -n "$BAN_IP" ]] && ! ipset test whitelist "$BAN_IP" &>/dev/null; then
                current_time=$(date +%s)
                
                if [[ -z "${ip_first_seen[$BAN_IP]}" ]]; then
                    ip_first_seen[$BAN_IP]=$current_time
                    echo -e "首次发现 ${RED}$BAN_IP${NC} 超速于 $(date -d @$current_time '+%H:%M:%S')"
                else
                    duration=$(( current_time - ip_first_seen[$BAN_IP] ))
                    
                    if (( duration >= 60 )); then
                        echo -e "${RED}🚫 封禁 $BAN_IP（持续超速 ${duration}秒）${NC}"
                        ipset add banlist "$BAN_IP" timeout 86400
                        echo "$(date '+%Y-%m-%d %H:%M:%S') 封禁 $BAN_IP RX:${RX_RATE}MB/s TX:${TX_RATE}MB/s 持续:${duration}秒" >> $LOG_FILE
                        unset ip_first_seen[$BAN_IP]
                    else
                        echo -e "IP ${YELLOW}$BAN_IP${NC} 已超速 ${duration}秒（需满60秒触发封禁）"
                    fi
                fi
            else
                echo -e "${YELLOW}⚠️  未找到有效封禁目标或目标在白名单中${NC}"
            fi
        else
            ip_first_seen=()
        fi

        # +++ 新增CPU优化 +++
        sleep 0.5  # 降低CPU占用
    done
}

# 主执行流程
init_system
start_monitor
EOF

  #---------- 白名单交互配置 ----------#
  echo -e "\n${CYAN}[2/4] 白名单配置${NC}"
  function validate_ip() {
      local ip=$1
      local pattern='^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)(/([12][0-9]|3[0-2]|[0-9]))?$'
      [[ $ip =~ $pattern ]] && return 0 || return 1
  }

  ipset create whitelist hash:ip 2>/dev/null || true

  read -p $'\033[33m是否要配置白名单IP？(y/N) \033[0m' REPLY
  if [[ "${REPLY,,}" == "y" ]]; then
      echo -e "\n${CYAN}请输入IP地址（支持格式示例）："
      echo -e "  • 单个IP: 192.168.1.1"
      echo -e "  • IP段: 10.0.0.0/24"
      echo -e "  • 多个IP用空格分隔${NC}"
      
      while :; do
          read -p $'\033[33m请输入IP（多个用空格分隔，直接回车结束）: \033[0m' input
          [[ -z "$input" ]] && break
          
          IFS=' ' read -ra ips <<< "$input"
          for ip in "${ips[@]}"; do
              if validate_ip "$ip"; then
                  if ipset add whitelist "$ip" 2>/dev/null; then
                      echo -e "${GREEN} ✓ 成功添加：$ip${NC}"
                  else
                      echo -e "${YELLOW} ⚠️  已存在：$ip${NC}"
                  fi
              else
                  echo -e "${RED} ✗ 无效格式：$ip${NC}"
              fi
          done
      done
  else
      echo -e "${CYAN}已跳过白名单配置${NC}"
  fi

  #---------- 持久化配置 ----------#
  echo -e "\n${CYAN}[3/4] 保存防火墙规则${NC}"
  mkdir -p /etc/ipset
  ipset save > /etc/ipset.conf
  iptables-save > /etc/iptables/rules.v4

  #---------- 系统服务配置 ----------#
  echo -e "\n${CYAN}[4/4] 配置系统服务${NC}"
  chmod +x /root/ip_blacklist.sh

  cat > /etc/systemd/system/ip_blacklist.service <<EOF
[Unit]
Description=IP流量监控与封禁服务
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/bin/bash /root/ip_blacklist.sh
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now ip_blacklist.service

  # +++ 新增日志轮替配置 +++
  echo -e "\n${CYAN}[附加] 配置日志轮替规则${NC}"
  sudo tee /etc/logrotate.d/iptables_ban <<'EOF'
/var/log/iptables_ban.log {
    daily
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
}
EOF

  # ▼▼▼ 新增：立即触发日志轮替 ▼▼▼
  sudo logrotate -f /etc/logrotate.d/iptables_ban

  # 完成提示
  echo -e "\n${GREEN}✅ 部署完成！${NC}"
  echo -e "白名单IP列表："
  ipset list whitelist -output save | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?' | sed 's/^/  ➤ /'
  echo -e "\n管理命令："
  echo -e "  查看日志: ${CYAN}journalctl -u ip_blacklist.service -f${NC}"
  echo -e "  临时解封: ${CYAN}ipset del banlist <IP地址>${NC}"
  echo -e "  添加白名单: ${CYAN}ipset add whitelist <IP地址>${NC}"
  # +++ 新增日志管理提示 +++
  echo -e "\n日志管理："
  echo -e "  • 实时日志: ${CYAN}tail -f /var/log/iptables_ban.log${NC}"
  echo -e "  • 日志轮替: ${CYAN}每天自动压缩，保留最近7天日志${NC}"
}

# ======================= 流量监控卸载 =======================
uninstall_service() {
    # 彩色定义
    RED='\033[31m'
    GREEN='\033[32m'
    YELLOW='\033[33m'
    NC='\033[0m'

    # 权限检查
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}错误：请使用sudo运行此脚本${NC}"
        return 1
    fi

    clear
    echo -e "${RED}⚠️ ⚠️ ⚠️  危险操作警告 ⚠️ ⚠️ ⚠️ ${NC}"
    echo -e "${YELLOW}此操作将执行以下操作："
    echo -e "1. 永久删除所有防火墙规则"
    echo -e "2. 清除全部流量监控数据"
    echo -e "3. 移除所有相关系统服务${NC}\n"
    read -p "确定要彻底卸载所有组件吗？[y/N] " confirm
    [[ ! "$confirm" =~ [yY] ]] && echo "操作已取消" && return

    echo -e "\n${YELLOW}[1/6] 停止服务...${NC}"
    systemctl disable --now ip_blacklist.service 2>/dev/null || true

    echo -e "\n${YELLOW}[2/6] 删除文件...${NC}"
    rm -vf /etc/systemd/system/ip_blacklist.service /root/ip_blacklist.sh

    echo -e "\n${YELLOW}[3/6] 清理网络规则...${NC}"
    # 分步清理策略
    {
        echo -e "${YELLOW}[步骤3.1] 清除动态规则${NC}"
        iptables -S | grep -E 'TRAFFIC_BLOCK|whitelist|banlist' | sed 's/^-A//' | xargs -rL1 iptables -D 2>/dev/null || true

        echo -e "${YELLOW}[步骤3.2] 清理自定义链${NC}"
        iptables -D INPUT -j TRAFFIC_BLOCK 2>/dev/null
        iptables -F TRAFFIC_BLOCK 2>/dev/null
        iptables -X TRAFFIC_BLOCK 2>/dev/null

        echo -e "${YELLOW}[步骤3.3] 刷新全局规则${NC}"
        iptables -F 2>/dev/null && iptables -X 2>/dev/null

        echo -e "${YELLOW}[步骤3.4] 持久化清理${NC}"
        iptables-save | grep -vE 'TRAFFIC_BLOCK|banlist|whitelist' | iptables-restore
    } || true

    # 内核级清理
    {
        echo -e "${YELLOW}[步骤3.5] 清理ipset集合${NC}"
        ipset list whitelist &>/dev/null && {
            ipset flush whitelist
            ipset destroy whitelist
        }
        ipset list banlist &>/dev/null && {
            ipset flush banlist
            ipset destroy banlist
        }
        echo -e "${YELLOW}[步骤3.6] 卸载内核模块（安全模式）${NC}"
        rmmod ip_set_hash_net 2>/dev/null || true
        rmmod xt_set 2>/dev/null || true
        rmmod ip_set 2>/dev/null || true
    } || true

    echo -e "\n${YELLOW}[4/6] 删除配置...${NC}"
    rm -vf /etc/ipset.conf /etc/iptables/rules.v4

    echo -e "\n${YELLOW}[5/6] 重置系统...${NC}"
    systemctl daemon-reload
    systemctl reset-failed
    sysctl -w net.ipv4.ip_forward=1 >/dev/null

    echo -e "\n${YELLOW}[6/6] 验证卸载...${NC}"
    local check_fail=0
    echo -n "服务状态: " && { systemctl status ip_blacklist.service &>/dev/null && check_fail=1 && echo -e "${RED}存在${NC}" || echo -e "${GREEN}已移除${NC}"; }
    echo -n "IPTables链: " && { iptables -L TRAFFIC_BLOCK &>/dev/null && check_fail=1 && echo -e "${RED}存在${NC}" || echo -e "${GREEN}已移除${NC}"; }
    echo -n "IPSet黑名单: " && { ipset list banlist &>/dev/null && check_fail=1 && echo -e "${RED}存在${NC}" || echo -e "${GREEN}已移除${NC}"; }
    echo -n "IPSet白名单: " && { ipset list whitelist &>/dev/null && check_fail=1 && echo -e "${RED}存在${NC}" || echo -e "${GREEN}已移除${NC}"; }
    echo -n "残留配置文件: " && { ls /etc/ipset.conf /etc/iptables/rules.v4 &>/dev/null && check_fail=1 && echo -e "${RED}存在${NC}" || echo -e "${GREEN}已清除${NC}"; }

    [ $check_fail -eq 0 ] && echo -e "\n${GREEN}✅ 卸载完成，无残留${NC}" || echo -e "\n${RED}⚠️  检测到残留组件，请重启系统${NC}"
}

# ======================= 安装snell协议 =======================
install_snell() {
    clear
    # 添加来源提示（使用工具箱内置颜色变量）
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/xOS/Snell${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    # 执行安装流程（增加错误处理和自动清理）
    if wget -O snell.sh https://raw.githubusercontent.com/xOS/Snell/master/Snell.sh; then
        chmod +x snell.sh
        ./snell.sh
        rm -f snell.sh  # 新增清理步骤
    else
        echo -e "${RED}下载 Snell 安装脚本失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
}

# ======================= 安装Hysteria2协议 =======================
install_hysteria2() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/Misaka-blog/hysteria-install${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    if wget -N --no-check-certificate https://raw.githubusercontent.com/Misaka-blog/hysteria-install/main/hy2/hysteria.sh; then
        chmod +x hysteria.sh
        bash hysteria.sh
        rm -f hysteria.sh  # 新增清理步骤
    else
        echo -e "${RED}下载 Hysteria2 安装脚本失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
}

# ======================= 安装SS协议 =======================
install_ss_rust() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/shadowsocks/shadowsocks-rust${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    if wget -O ss-rust.sh --no-check-certificate https://git.io/Shadowsocks-Rust.sh; then
        chmod +x ss-rust.sh
        ./ss-rust.sh
        rm -f ss-rust.sh  # 清理安装脚本
    else
        echo -e "${RED}下载 SS-Rust 安装脚本失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
}

# ====================== 安装 ShadowTLS ======================
install_shadowtls() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/Kismet0123/ShadowTLS-Manager${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    if wget -O ShadowTLS_Manager.sh --no-check-certificate https://raw.githubusercontent.com/Kismet0123/ShadowTLS-Manager/refs/heads/main/ShadowTLS_Manager.sh; then
        chmod +x ShadowTLS_Manager.sh
        ./ShadowTLS_Manager.sh
        rm -f ShadowTLS_Manager.sh  # 清理安装脚本
    else
        echo -e "${RED}下载 ShadowTLS 安装脚本失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
}

# ======================= 安装3X-UI面板 =======================
install_3x_ui() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/mhsanaei/3x-ui${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    local install_script="/tmp/3x-ui_install.sh"
    if curl -Ls -o "$install_script" https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh; then
        chmod +x "$install_script"
        "$install_script"
        rm -f "$install_script"
    else
        echo -e "${RED}下载 3X-UI 安装脚本失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
}

# ======================= 流媒体检测 =======================
install_media_check() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：ip.check.place${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    local install_script="/tmp/media_check.sh"
    if curl -L -s -o "$install_script" ip.check.place; then
        chmod +x "$install_script"
        "$install_script"
        rm -f "$install_script"
    else
        echo -e "${RED}下载流媒体检测脚本失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
}


# ======================= Speedtest测速 =======================
install_speedtest() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}Speedtest测速组件安装${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    # 下载packagecloud安装脚本
    local install_script="/tmp/speedtest_install.sh"
    echo -e "${CYAN}下载Speedtest安装脚本...${NC}"
    if ! curl -s --ssl https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh -o "$install_script"; then
        echo -e "${RED}下载Speedtest安装脚本失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
    
    # 执行安装脚本
    echo -e "${CYAN}添加Speedtest仓库...${NC}"
    if ! sudo bash "$install_script"; then
        echo -e "${RED}添加仓库失败！${NC}"
        rm -f "$install_script"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
    rm -f "$install_script"
    
    # 更新软件源并安装
    echo -e "${CYAN}安装Speedtest...${NC}"
    if ! sudo apt-get update || ! sudo apt-get install -y speedtest; then
        echo -e "${RED}安装Speedtest失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
    
    # 自动执行测速
    echo -e "${CYAN}开始网络测速...${NC}"
    speedtest --accept-license --accept-gdpr
}

# ======================= 开放所有端口 =======================
open_all_ports() {
    clear
    echo -e "${RED}════════════ 安全警告 ════════════${NC}"
    echo -e "${YELLOW}此操作将：${NC}"
    echo -e "1. 清空所有防火墙规则"
    echo -e "2. 设置默认策略为全部允许"
    echo -e "3. 完全开放所有网络端口"
    echo -e "${RED}═════════════════════════════════${NC}"
    read -p "确认继续操作？[y/N] " confirm
    
    if [[ $confirm =~ ^[Yy]$ ]]; then
        echo -e "${CYAN}正在重置防火墙规则...${NC}"
        
        # 设置默认策略
        sudo iptables -P INPUT ACCEPT    # 修正缺少的ACCEPT
        sudo iptables -P FORWARD ACCEPT
        sudo iptables -P OUTPUT ACCEPT
        
        # 清空所有规则
        sudo iptables -F
        sudo iptables -X
        sudo iptables -Z
        
        echo -e "${GREEN}所有端口已开放！${NC}"
        echo -e "${YELLOW}当前防火墙规则：${NC}"
        sudo iptables -L -n --line-numbers
    else
        echo -e "${BLUE}已取消操作${NC}"
    fi
}

# ======================= Caddy反代管理 =======================
configure_caddy_reverse_proxy() {
    # 环境常量定义
    local CADDY_SERVICE="/lib/systemd/system/caddy.service"
    local CADDYFILE="/etc/caddy/Caddyfile"
    local TEMP_CONF=$(mktemp)
    local domain ip port

    # 首次安装检测
    if ! command -v caddy &>/dev/null; then
        echo -e "${CYAN}开始安装Caddy服务器...${NC}"
        
        # 安装依赖组件（显示进度）
        echo -e "${YELLOW}[1/5] 安装依赖组件...${NC}"
        sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https 2>&1 | \
            while read line; do 
                echo "  ▸ $line"
            done
        
        # 添加官方软件源（显示进度）
        echo -e "\n${YELLOW}[2/5] 添加Caddy官方源...${NC}"
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | \
            sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | \
            sudo tee /etc/apt/sources.list.d/caddy-stable.list | \
            sed 's/^/  ▸ /'
        # 更新软件源（显示进度）
        echo -e "\n${YELLOW}[3/5] 更新软件源...${NC}"
        sudo apt-get update -o Dir::Etc::sourcelist="sources.list.d/caddy-stable.list" \
            -o Dir::Etc::sourceparts="-" \
            -o APT::Get::List-Cleanup="0" 2>&1 | \
            grep -v '^$' | \
            sed 's/^/  ▸ /'
        # 安装Caddy（显示进度）
        echo -e "\n${YELLOW}[4/5] 安装Caddy...${NC}"
        sudo apt-get install -y caddy 2>&1 | \
            grep --line-buffered -E 'Unpacking|Setting up' | \
            sed 's/^/  ▸ /'
        # 初始化配置（显示进度）
        echo -e "\n${YELLOW}[5/5] 初始化配置...${NC}"
        sudo mkdir -vp /etc/caddy | sed 's/^/  ▸ /'
        [ ! -f "$CADDYFILE" ] && sudo touch "$CADDYFILE"
        echo -e "# Caddyfile自动生成配置\n# 手动修改后请执行 systemctl reload caddy" | \
            sudo tee "$CADDYFILE" | sed 's/^/  ▸ /'
        sudo chown caddy:caddy "$CADDYFILE"
        
        echo -e "${GREEN}✅ Caddy安装完成，版本：$(caddy version)${NC}"
    else
        echo -e "${CYAN}检测到Caddy已安装，版本：$(caddy version)${NC}"
    fi

    # 配置输入循环
    while : ; do
        # 域名输入验证
        until [[ $domain =~ ^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$ ]]; do
            read -p "请输入域名（无需https://）：" domain
            domain=$(echo "$domain" | sed 's/https\?:\/\///g')
            [[ $domain =~ ^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$ ]] || echo -e "${RED}域名格式无效！示例：example.com${NC}"
        done

        # 目标IP输入（支持域名/IPv4/IPv6）
        read -p "请输入目标服务器地址（默认为localhost）:" ip
        ip=${ip:-localhost}

        # 端口输入验证
        until [[ $port =~ ^[0-9]+$ ]] && [ "$port" -ge 1 -a "$port" -le 65535 ]; do
            read -p "请输入目标端口号（1-65535）:" port
            [[ $port =~ ^[0-9]+$ ]] || { echo -e "${RED}端口必须为数字！"; continue; }
            [ "$port" -ge 1 -a "$port" -le 65535 ] || echo -e "${RED}端口范围1-65535！"
        done

        # 配置冲突检测
        if sudo caddy validate --config "$CADDYFILE" --adapter caddyfile 2>/dev/null; then
            if grep -q "^$domain {" "$CADDYFILE"; then
                echo -e "${YELLOW}⚠ 检测到现有配置："
                grep -A3 "^$domain {" "$CADDYFILE"
                read -p "要覆盖此配置吗？[y/N] " overwrite
                [[ $overwrite =~ ^[Yy]$ ]] || continue
                sudo caddy adapt --config "$CADDYFILE" --adapter caddyfile | \
                awk -v domain="$domain" '/^'$domain' {/{flag=1} !flag; /^}/{flag=0}' | \
                sudo tee "$TEMP_CONF" >/dev/null
                sudo mv "$TEMP_CONF" "$CADDYFILE"
            fi
        else
            echo -e "${YELLOW}⚠ 当前配置文件存在错误，将创建新配置${NC}"
            sudo truncate -s 0 "$CADDYFILE"
        fi

        # 生成配置块
        echo -e "\n# 自动生成配置 - $(date +%F)" | sudo tee -a "$CADDYFILE" >/dev/null
        cat <<EOF | sudo tee -a "$CADDYFILE" >/dev/null
$domain {
    reverse_proxy $ip:$port {
        header_up Host {host}
        header_up X-Real-IP {remote}
        header_up X-Forwarded-For {remote}
        header_up X-Forwarded-Proto {scheme}
    }
    encode gzip
    tls {
        protocols tls1.2 tls1.3
        ciphers TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
    }
}
EOF

        # 格式化配置文件
        sudo caddy fmt "$CADDYFILE" --overwrite

        # 配置验证与生效
        if ! sudo caddy validate --config "$CADDYFILE"; then
            echo -e "${RED}配置验证失败！错误详情："
            sudo caddy validate --config "$CADDYFILE" 2>&1 | grep -v "valid"
            sudo sed -i "/# 自动生成配置 - $(date +%F)/,+6d" "$CADDYFILE"
            return 1
        fi

        # 服务热重载
        if systemctl is-active caddy &>/dev/null; then
            sudo systemctl reload caddy || sudo systemctl restart caddy
        else
            sudo systemctl enable --now caddy &>/dev/null
        fi

        echo -e "${GREEN}✅ 配置生效成功！访问地址：https://$domain${NC}"
        read -p "是否继续添加配置？[y/N] " more
        [[ $more =~ ^[Yy]$ ]] || break

        # 重置变量进行下一轮循环
        domain=""
        ip=""
        port=""
    done

    # 清理临时文件
    rm -f "$TEMP_CONF"
}

# ======================= 卸载Caddy =======================
uninstall_caddy() {
    echo -e "${RED}警告：此操作将完全移除Caddy及所有相关配置！${NC}"
    read -p "确定要卸载Caddy吗？(y/N) " confirm
    [[ ! $confirm =~ ^[Yy]$ ]] && return

    # 停止服务
    echo -e "${CYAN}停止Caddy服务...${NC}"
    sudo systemctl stop caddy.service 2>/dev/null

    # 卸载软件包
    if command -v caddy &>/dev/null; then
        echo -e "${CYAN}卸载Caddy程序...${NC}"
        sudo apt-get purge -y caddy 2>/dev/null
    fi

    # 删除配置文件
    declare -a caddy_files=(
        "/etc/caddy"
        "/lib/systemd/system/caddy.service"
        "/usr/share/keyrings/caddy-stable-archive-keyring.gpg"
        "/etc/apt/sources.list.d/caddy-stable.list"
        "/var/lib/caddy"
        "/etc/ssl/caddy"
    )

    # 删除文件及目录
    echo -e "${CYAN}清理残留文件...${NC}"
    for target in "${caddy_files[@]}"; do
        if [[ -e $target ]]; then
            echo "删除：$target"
            sudo rm -rf "$target"
        fi
    done

    # 删除APT源更新
    sudo apt-get update 2>/dev/null

    # 清除无人值守安装标记（如有）
    sudo rm -f /var/lib/cloud/instances/*/sem/config_apt_source

    # 删除日志（可选）
    read -p "是否删除所有Caddy日志文件？(y/N) " del_log
    if [[ $del_log =~ ^[Yy]$ ]]; then
        sudo journalctl --vacuum-time=1s --quiet
        sudo rm -f /var/log/caddy/*.log 2>/dev/null
    fi

    echo -e "${GREEN}✅ Caddy已完全卸载，再见！${NC}"
}

# ======================= Caddy子菜单 =======================
show_caddy_menu() {
    clear
    echo -e "${CYAN}=== Caddy 管理脚本 v1.2 ===${NC}"
    echo "1. 安装/配置反向代理"
    echo "2. 完全卸载Caddy"
    echo "3. 返回主菜单"
    echo -e "${YELLOW}===============================${NC}"
}
# ======================= Cady主逻辑 =======================
caddy_main() {
    while true; do
        show_caddy_menu
        read -p "请输入Caddy管理选项：" caddy_choice
        case $caddy_choice in
            1) 
                configure_caddy_reverse_proxy
                read -p "按回车键返回菜单..." 
                ;;
            2) 
                uninstall_caddy
                read -p "按回车键返回菜单..." 
                ;;
            3) 
                break
                ;;
            *) 
                echo -e "${RED}无效选项！${NC}"
                sleep 1
                ;;
        esac
    done
}

# ====================== 修改后的Nginx管理函数 =======================
nginx_main() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/Acacia415/GPT-Scripts${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    local nginx_script="/tmp/nginx-manager.sh"
    
    if wget -O "$nginx_script" --no-check-certificate \
        https://raw.githubusercontent.com/Acacia415/GPT-Scripts/main/nginx-manager.sh; then
        chmod +x "$nginx_script"
        "$nginx_script"
        rm -f "$nginx_script"
    else
        echo -e "${RED}错误：Nginx 管理脚本下载失败！${NC}"
    fi
    
}

# ======================= IP优先级设置 =======================
modify_ip_preference() {
    # 权限检查
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}错误：请使用sudo运行此脚本${NC}"
        return 1
    fi

    # 配置文件路径
    CONF_FILE="/etc/gai.conf"
    BACKUP_FILE="/etc/gai.conf.bak"

    show_current_status() {
        echo -e "\n${YELLOW}当前优先级配置："
        if grep -qE "^precedence ::ffff:0:0/96 100" $CONF_FILE; then
            echo -e "  ▸ ${GREEN}IPv4优先模式 (precedence ::ffff:0:0/96 100)${NC}"
        elif grep -qE "^precedence ::/0 40" $CONF_FILE; then
            echo -e "  ▸ ${GREEN}IPv6优先模式 (precedence ::/0 40)${NC}"
        else
            echo -e "  ▸ ${YELLOW}系统默认配置${NC}"
        fi
    }

    interactive_menu() {
        clear
        echo -e "${GREEN}=== IP协议优先级设置 ==="
        echo -e "1. IPv4优先 (推荐)"
        echo -e "2. IPv6优先"
        echo -e "3. 恢复默认配置"
        echo -e "0. 返回主菜单"
        show_current_status
        read -p "请输入选项 [0-3]: " choice
    }

    apply_ipv4_preference() {
        echo -e "${YELLOW}\n[1/3] 备份原配置..."
        cp -f $CONF_FILE $BACKUP_FILE 2>/dev/null || true

        echo -e "${YELLOW}[2/3] 生成新配置..."
        cat > $CONF_FILE << EOF
# 由网络工具箱设置 IPv4 优先
precedence ::ffff:0:0/96 100
#precedence ::/0 40
EOF

        echo -e "${YELLOW}[3/3] 应用配置..."
        sysctl -p $CONF_FILE >/dev/null 2>&1 || true
    }

    apply_ipv6_preference() {
        echo -e "${YELLOW}\n[1/3] 备份原配置..."
        cp -f $CONF_FILE $BACKUP_FILE 2>/dev/null || true

        echo -e "${YELLOW}[2/3] 生成新配置..."
        cat > $CONF_FILE << EOF
# 由网络工具箱设置 IPv6 优先
precedence ::/0 40
#precedence ::ffff:0:0/96 100
EOF

        echo -e "${YELLOW}[3/3] 应用配置..."
    }

    restore_default() {
        if [ -f $BACKUP_FILE ]; then
            echo -e "${YELLOW}\n[1/2] 恢复备份文件..."
            cp -f $BACKUP_FILE $CONF_FILE
            echo -e "${YELLOW}[2/2] 删除备份..."
            rm -f $BACKUP_FILE
        else
            echo -e "${YELLOW}\n[1/1] 重置为默认配置..."
            sed -i '/^precedence/d' $CONF_FILE
        fi
    }

    while true; do
        interactive_menu
        case $choice in
            1)
                apply_ipv4_preference
                echo -e "${GREEN}\n✅ 已设置为IPv4优先模式！"
                echo -e "  更改将在下次网络连接时生效${NC}"
                sleep 2
                ;;
            2)
                apply_ipv6_preference
                echo -e "${GREEN}\n✅ 已设置为IPv6优先模式！"
                echo -e "  更改将在下次网络连接时生效${NC}"
                sleep 2
                ;;
            3)
                restore_default
                echo -e "${GREEN}\n✅ 已恢复默认系统配置！${NC}"
                sleep 2
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}无效选项，请重新输入${NC}"
                sleep 1
                ;;
        esac
    done
}
# ======================= TCP性能优化 =======================
install_magic_tcp() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/qiuxiuya/magicTCP${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    # 用户确认环节
    read -p "是否要执行TCP性能优化？[y/N] " confirm
    if [[ ! "$confirm" =~ [yY] ]]; then
        echo -e "${BLUE}操作已取消${NC}"
        return 1
    fi  # 必须显式闭合if语句
    
    # 网络检测环节
    if ! curl -Is https://raw.githubusercontent.com >/dev/null 2>&1; then
        echo -e "${RED}❌ 网络连接异常，无法访问GitHub${NC}"
        return 1
    fi
    
    # 执行优化脚本
    echo -e "${CYAN}正在应用TCP优化参数..."
    if bash <(curl -sSL https://raw.githubusercontent.com/qiuxiuya/magicTCP/main/main.sh); then
        echo -e "${GREEN}✅ 优化成功完成，重启后生效${NC}"
    else
        echo -e "${RED}❌ 优化过程中出现错误，请检查："
        echo -e "1. 系统是否为Debian/Ubuntu"
        echo -e "2. 是否具有root权限"
        echo -e "3. 查看日志：/var/log/magic_tcp.log${NC}"
        return 1
    fi  # 闭合核心if语句
}  # 函数结束（对应原错误行号807）

# ======================= 命令行美化 =======================
install_shell_beautify() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}正在安装命令行美化组件...${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"

    echo -e "${CYAN}[1/6] 更新软件源...${NC}"
    apt-get update

    echo -e "${CYAN}[2/6] 安装依赖组件...${NC}"
    if ! command -v git &> /dev/null; then
        apt-get install -y git > /dev/null
    else
        echo -e "${GREEN} ✓ Git 已安装${NC}"
    fi

    echo -e "${CYAN}[3/6] 检查zsh...${NC}"
    if ! command -v zsh &> /dev/null; then
        echo -e "${YELLOW}未检测到zsh，正在安装...${NC}"
        apt-get install -y zsh > /dev/null
    else
        echo -e "${GREEN} ✓ Zsh 已安装${NC}"
    fi

    echo -e "${CYAN}[4/6] 配置oh-my-zsh...${NC}"
    if [ ! -d "$HOME/.oh-my-zsh" ]; then
        echo -e "首次安装oh-my-zsh..."
        sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
        if [ $? -ne 0 ]; then
            echo -e "${RED}oh-my-zsh安装失败！请检查网络连接${NC}"
            return 1
        fi
    else
        echo -e "${GREEN} ✓ oh-my-zsh 已安装${NC}"
    fi

    echo -e "${CYAN}[5/6] 设置ultima主题...${NC}"
    ULTIMA_REPO="https://github.com/egorlem/ultima.zsh-theme"
    TEMP_DIR="$HOME/ultima-shell"
    THEME_DEST="$HOME/.oh-my-zsh/themes"

    rm -rf "$TEMP_DIR"
    git clone -q "$ULTIMA_REPO" "$TEMP_DIR"
    if [ -f "$TEMP_DIR/ultima.zsh-theme" ]; then
        mv -f "$TEMP_DIR/ultima.zsh-theme" "$THEME_DEST/ultima.zsh-theme"
        echo -e "${GREEN} ✓ 主题安装完成${NC}"
    else
        echo -e "${RED}❌ 克隆失败或找不到主题文件${NC}"
        return 1
    fi

    sed -i 's/ZSH_THEME=.*/ZSH_THEME="ultima"/' ~/.zshrc

    echo -e "${CYAN}[6/6] 设置默认shell...${NC}"
    if [ "$SHELL" != "$(which zsh)" ]; then
        chsh -s $(which zsh) >/dev/null
    fi

    echo -e "\n${GREEN}✅ 美化完成！重启终端后生效${NC}"
    read -p "$(echo -e "${YELLOW}是否立即生效主题？[${GREEN}Y${YELLOW}/n] ${NC}")" confirm
    confirm=${confirm:-Y}
    if [[ "${confirm^^}" == "Y" ]]; then
        echo -e "${GREEN}正在应用新配置...${NC}"
        exec zsh
    else
        echo -e "\n${YELLOW}可稍后手动执行：${CYAN}exec zsh ${YELLOW}生效配置${NC}"
    fi
}

# ======================= DNS解锁管理 =======================
dns_unlock_menu() {
  while true; do
    clear
    echo -e "${YELLOW}════════════ DNS解锁服务管理 ════════════${NC}"
    echo -e "1. 安装服务端 (DNS解锁服务器)"
    echo -e "2. 卸载服务端"
    echo -e "3. 设置客户端"
    echo -e "4. 卸载客户端"
    echo -e "5. IP白名单管理"
    echo -e "0. 返回主菜单"
    echo -e "${YELLOW}════════════════════════════════════════${NC}"
    read -p "请输入选项: " sub_choice

    case $sub_choice in
      1)
        install_dns_unlock_server
        read -n 1 -s -r -p "按任意键返回..."
        ;;
      2)
        uninstall_dns_unlock_server
        read -n 1 -s -r -p "按任意键返回..."
        ;;
      3)
        setup_dns_client
        read -n 1 -s -r -p "按任意键返回..."
        ;;
      4)
        uninstall_dns_client
        read -n 1 -s -r -p "按任意键返回..."
        ;;
      5)
        manage_iptables_rules
        read -n 1 -s -r -p "按任意键返回..."
        ;;
      0)
        break
        ;;
      *)
        echo -e "${RED}无效选项，请重新输入${NC}"
        sleep 1
        ;;
    esac
  done
}

# 安装服务端（优化版）
install_dns_unlock_server() {
  clear
  echo -e "${YELLOW}正在安装DNS解锁服务端...${NC}"
  
  # 禁用系统DNS服务
  sudo systemctl stop systemd-resolved 2>/dev/null
  sudo systemctl disable systemd-resolved 2>/dev/null
  sudo systemctl mask systemd-resolved 2>/dev/null
  sudo rm -f /etc/resolv.conf
  echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf

  # 安装基础依赖
  sudo apt-get update
  sudo apt-get install -y dnsmasq build-essential libev-dev libpcre3-dev libudns-dev autoconf

  # 编译安装SNI Proxy
  wget -q https://github.com/dlundquist/sniproxy/archive/refs/tags/0.6.1.tar.gz
  tar -zxvf 0.6.1.tar.gz
  cd sniproxy-0.6.1
  ./autogen.sh && ./configure && make
  sudo make install
  cd ..

  # 配置DNSmasq
  LOCAL_IP=$(curl -4s ip.sb)
  sudo tee /etc/dnsmasq.d/custom.conf <<EOF
server=8.8.8.8
address=/chatgpt.com/$LOCAL_IP
address=/netflix.com/$LOCAL_IP
address=/example.com/$LOCAL_IP
EOF
  sudo systemctl restart dnsmasq

  # 配置SNI Proxy
  sudo tee /etc/sniproxy.conf <<EOF
user daemon
pidfile /var/run/sniproxy.pid

listen 80 {
    proto http
}

listen 443 {
    proto tls
}

table {
    .*chatgpt\.com$ *
    .*netflix\.com$ *
    .*example\.com$ *
}
EOF

  # 创建systemd服务
  sudo tee /etc/systemd/system/sniproxy.service <<EOF
[Unit]
Description=SNI Proxy
After=network.target

[Service]
ExecStart=/usr/local/sbin/sniproxy -c /etc/sniproxy.conf
Restart=always

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable sniproxy --now

  # 初始防火墙规则（保留原有限制逻辑）
  sudo iptables -I INPUT -p tcp --dport 53 -j DROP
  sudo iptables -I INPUT -p tcp --dport 80,443 -j DROP
  sudo netfilter-persistent save

  echo -e "${GREEN}服务端安装完成！${NC}"
}

# IP白名单管理（增强版）
manage_iptables_rules() {
  while true; do
    clear
    echo -e "${YELLOW}════════ IP白名单管理 ════════${NC}"
    echo -e "1. 添加白名单IP（全端口）"
    echo -e "2. 添加白名单IP（指定端口）"
    echo -e "3. 移除白名单IP"
    echo -e "0. 返回上级"
    echo -e "${YELLOW}═════════════════════════════${NC}"
    read -p "请选择: " rule_choice

    case $rule_choice in
      1)
        read -p "请输入允许的IP地址（多个用空格分隔）: " ips
        for ip in $ips; do
          sudo iptables -I INPUT -s $ip -p tcp -m multiport --dports 53,80,443 -j ACCEPT
        done
        sudo netfilter-persistent save
        echo -e "${GREEN}全端口白名单已添加！${NC}"
        ;;
      2)
        read -p "请输入端口号（多个用逗号分隔）: " ports
        read -p "请输入允许的IP地址（多个用空格分隔）: " ips
        for ip in $ips; do
          sudo iptables -I INPUT -s $ip -p tcp -m multiport --dports ${ports//,/ } -j ACCEPT
        done
        sudo netfilter-persistent save
        echo -e "${GREEN}指定端口白名单已添加！${NC}"
        ;;
      3)
        echo -e "${CYAN}当前规则列表：${NC}"
        sudo iptables -L INPUT -v -n --line-numbers | grep ACCEPT
        read -p "请输入要删除的规则行号: " line_num
        sudo iptables -D INPUT $line_num
        sudo netfilter-persistent save
        echo -e "${GREEN}规则已删除！${NC}"
        ;;
      0)
        break
        ;;
      *)
        echo -e "${RED}无效输入！${NC}"
        sleep 1
        ;;
    esac
    read -n 1 -s -r -p "按任意键继续..."
  done
}

# 卸载服务端（增强版）
uninstall_dns_unlock_server() {
  clear
  echo -e "${YELLOW}正在卸载服务端组件...${NC}"
  
  # 停止服务
  sudo systemctl stop dnsmasq
  sudo systemctl stop sniproxy

  # 移除服务
  sudo systemctl disable dnsmasq 2>/dev/null
  sudo systemctl disable sniproxy 2>/dev/null
  sudo rm -f /etc/systemd/system/sniproxy.service
  sudo systemctl daemon-reload

  # 删除配置文件
  sudo rm -rf /etc/dnsmasq.d/custom.conf
  sudo rm -f /etc/sniproxy.conf

  # 卸载软件
  sudo apt-get remove -y dnsmasq
  sudo rm -f /usr/local/sbin/sniproxy

  # 恢复DNS设置
  sudo rm -f /etc/resolv.conf
  echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf
  sudo systemctl unmask systemd-resolved 2>/dev/null
  sudo systemctl start systemd-resolved 2>/dev/null

  # 清理防火墙规则
  sudo iptables -D INPUT -p tcp --dport 53 -j DROP 2>/dev/null
  sudo iptables -D INPUT -p tcp --dport 80 -j DROP 2>/dev/null
  sudo iptables -D INPUT -p tcp --dport 443 -j DROP 2>/dev/null
  sudo netfilter-persistent save

  echo -e "${GREEN}服务端已彻底卸载！${NC}"
}

# 客户端设置（兼容性增强）
setup_dns_client() {
  clear
  read -p "请输入解锁服务器的IP地址: " server_ip
  
  # 备份原配置
  sudo cp /etc/resolv.conf /etc/resolv.conf.bak
  
  # 针对不同系统处理
  if grep -q "Ubuntu" /etc/os-release; then
    sudo systemctl stop systemd-resolved
    sudo rm -f /etc/resolv.conf
    echo "nameserver $server_ip" | sudo tee /etc/resolv.conf
    sudo chattr +i /etc/resolv.conf
  else
    sudo sed -i "/^# Generated by NetworkManager/d" /etc/resolv.conf
    echo "nameserver $server_ip" | sudo tee /etc/resolv.conf
    sudo chattr +i /etc/resolv.conf 2>/dev/null || \
    (echo -e "${YELLOW}无法锁定DNS设置，建议手动配置网络管理器${NC}")
  fi
  
  echo -e "${GREEN}客户端设置完成！${NC}"
}

# 客户端卸载（兼容性增强）
uninstall_dns_client() {
  clear
  sudo chattr -i /etc/resolv.conf 2>/dev/null
  if [ -f /etc/resolv.conf.bak ]; then
    sudo mv /etc/resolv.conf.bak /etc/resolv.conf
  else
    echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf
  fi
  
  # 恢复Ubuntu系统服务
  if grep -q "Ubuntu" /etc/os-release; then
    sudo systemctl start systemd-resolved
  fi
  
  echo -e "${GREEN}客户端配置已恢复！${NC}"
}

# ======================= Sub-Store安装模块 =======================
install_substore() {
  check_root
  public_ip=$(get_public_ip)
  install_docker_packages
  setup_substore_docker
}
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}运行脚本需要 root 权限${NC}" >&2
        exit 1
    fi
}
get_public_ip() {
    local ip_services=("ifconfig.me" "ipinfo.io/ip" "icanhazip.com" "ipecho.net/plain" "ident.me")

    for service in "${ip_services[@]}"; do
        if public_ip=$(curl -sS --connect-timeout 5 "$service"); then
            if [[ "$public_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo "$public_ip"
                return 0
            fi
        fi
        sleep 1
    done

    echo -e "${RED}无法获取公共 IP 地址。${NC}" >&2
    exit 1
}
install_docker_packages() {
    if ! command -v docker &> /dev/null; then
        echo -e "${YELLOW}正在安装 Docker 和 Docker Compose...${NC}"
        if ! curl -fsSL https://get.docker.com | bash; then
            echo -e "${RED}Docker 安装失败${NC}" >&2
            exit 1
        fi
        # 尝试使用 apt-get 安装 docker-compose，如果失败，提示其他安装方式
        if ! apt-get update && apt-get install -y docker-compose; then
            echo -e "${YELLOW}使用 apt-get 安装 Docker Compose 失败，尝试其他方法...${NC}"
            # 对于较新的 Docker 版本，docker-compose 可能作为插件 docker-compose-plugin 提供
            if apt-get install -y docker-compose-plugin; then
                 echo -e "${GREEN}Docker Compose Plugin 安装完成。${NC}"
            else
                echo -e "${RED}Docker Compose 或其插件安装失败。请尝试手动安装。${NC}" >&2
                echo -e "${RED}可以参考 Docker 官方文档: https://docs.docker.com/compose/install/${NC}" >&2
                exit 1
            fi
        fi
        echo -e "${GREEN}Docker 和 Docker Compose (或插件) 安装完成。${NC}"
    else
        echo -e "${CYAN}Docker 和 Docker Compose (或插件) 已安装。${NC}"
    fi

    # 检查 docker compose v2 (docker-compose-plugin) 是否可用
    if ! docker compose version &>/dev/null; then
        # 如果 docker compose v2 不可用，检查 docker-compose v1
        if ! command -v docker-compose &>/dev/null; then
            echo -e "${RED}Docker Compose (v1 或 v2 插件) 未找到。请确保已正确安装。${NC}" >&2
            exit 1
        else
            echo -e "${CYAN}检测到 Docker Compose v1 (docker-compose)。${NC}"
        fi
    else
        echo -e "${CYAN}检测到 Docker Compose v2 (docker compose plugin)。${NC}"
    fi
}
setup_substore_docker() {
    local secret_key
    local compose_file="docker-compose.yml" # 定义 docker-compose 文件名

    # 检查 docker-compose.yml 是否存在，并尝试从中提取 secret_key
    if [ -f "$compose_file" ]; then
        extracted_key=$(sed -n 's|.*SUB_STORE_FRONTEND_BACKEND_PATH=/\([0-9a-fA-F]\{32\}\).*|\1|p' "$compose_file" | head -n 1)
        if [[ -n "$extracted_key" && ${#extracted_key} -eq 32 ]]; then
            secret_key="$extracted_key"
            echo -e "${GREEN}检测到已存在的密钥，将继续使用: ${secret_key}${NC}"
        else
            echo -e "${YELLOW}未能从现有的 ${compose_file} 中提取有效密钥，或文件格式不符。${NC}"
        fi
    fi

    # 如果 secret_key 仍然为空 (文件不存在或提取失败)，则生成一个新的密钥
    if [ -z "$secret_key" ]; then
        secret_key=$(openssl rand -hex 16)
        echo -e "${YELLOW}生成新的密钥: ${secret_key}${NC}"
    fi

    mkdir -p /root/sub-store-data

    echo -e "${YELLOW}清理旧容器和相关配置...${NC}"
    docker rm -f sub-store >/dev/null 2>&1 || true
    # 优先使用 docker compose (v2)，如果失败则尝试 docker-compose (v1)
    if docker compose -p sub-store down >/dev/null 2>&1; then
        echo -e "${CYAN}使用 'docker compose down' 清理项目。${NC}"
    elif command -v docker-compose &>/dev/null && docker-compose -p sub-store -f "$compose_file" down >/dev/null 2>&1; then
        echo -e "${CYAN}使用 'docker-compose down' 清理项目。${NC}"
    else
        echo -e "${YELLOW}未找到 docker-compose.yml 或无法执行 down 命令，可能没有旧项目需要清理。${NC}"
    fi

    echo -e "${YELLOW}创建/更新 ${compose_file} 配置文件...${NC}"
    cat <<EOF > "$compose_file"
version: '3.8' # 建议使用较新的compose版本，例如3.8
services:
  sub-store:
    image: xream/sub-store:latest
    container_name: sub-store
    restart: unless-stopped
    environment:
      - SUB_STORE_FRONTEND_BACKEND_PATH=/$secret_key
    ports:
      - "3001:3001"
    volumes:
      - /root/sub-store-data:/opt/app/data
EOF

    echo -e "${YELLOW}拉取最新镜像 (xream/sub-store:latest)...${NC}"
    # 优先使用 docker compose (v2)，如果失败则尝试 docker-compose (v1)
    local pull_cmd_success=false
    if docker compose -p sub-store pull sub-store; then
        pull_cmd_success=true
    elif command -v docker-compose &>/dev/null && docker-compose -p sub-store -f "$compose_file" pull sub-store; then
        pull_cmd_success=true
    fi

    if ! $pull_cmd_success; then
        echo -e "${RED}拉取镜像失败，请检查网络连接或镜像名称 (xream/sub-store:latest)。${NC}"
        # 您可以在这里决定是否退出脚本
        # exit 1
    fi

    echo -e "${YELLOW}启动容器 (项目名: sub-store)...${NC}"
    # 优先使用 docker compose (v2)，如果失败则尝试 docker-compose (v1)
    local up_cmd_success=false
    if docker compose -p sub-store up -d; then
        up_cmd_success=true
    elif command -v docker-compose &>/dev/null && docker-compose -p sub-store -f "$compose_file" up -d; then
        up_cmd_success=true
    fi

    if ! $up_cmd_success; then
        echo -e "${RED}启动容器失败。请检查 Docker 服务状态及 ${compose_file} 文件配置。${NC}"
        echo -e "${RED}可以使用 'docker logs sub-store' 查看容器日志。${NC}"
        # exit 1
    else
        # 可以增加一个短暂的延时，给容器一些启动时间
        echo -e "${YELLOW}等待容器启动 (约5-10秒)...${NC}"
        sleep 10 # 可以根据实际情况调整这个延时

        # 检查容器是否仍在运行
        if docker ps -q -f name=sub-store | grep -q .; then
            echo -e "\n${GREEN}Sub-Store 已启动！${NC}"
            echo -e "Sub-Store 面板访问地址: ${CYAN}http://${public_ip}:3001${NC}"
            echo -e "Sub-Store 后端API地址: ${CYAN}http://${public_ip}:3001/${secret_key}${NC}"
            echo -e "\n${YELLOW}如果服务无法访问，请检查容器日志: ${CYAN}docker logs sub-store${NC}"
            echo -e "${YELLOW}或通过本地验证服务是否监听端口: ${CYAN}curl -I http://127.0.0.1:3001${NC}"
        else
            echo -e "\n${RED}Sub-Store 容器未能保持运行状态。${NC}"
            echo -e "${RED}请手动检查容器日志: ${CYAN}docker logs sub-store${NC}"
        fi
    fi

    local compose_cmd_v2="docker compose -p sub-store -f \"$(pwd)/${compose_file}\""
    local compose_cmd_v1="docker-compose -p sub-store -f \"$(pwd)/${compose_file}\""
    local compose_cmd_prefix=""

    # 检测使用哪个compose命令
    if docker compose version &>/dev/null; then
        compose_cmd_prefix="$compose_cmd_v2"
        echo -e "${CYAN}将使用 'docker compose' (v2) 命令进行管理。${NC}"
    elif command -v docker-compose &>/dev/null; then
        compose_cmd_prefix="$compose_cmd_v1"
        echo -e "${CYAN}将使用 'docker-compose' (v1) 命令进行管理。${NC}"
    else
        echo -e "${RED}未找到 'docker compose' 或 'docker-compose' 命令，管理命令可能无法直接使用。${NC}"
    fi


    echo -e "\n${YELLOW}常用管理命令 (如果 ${compose_file} 不在当前目录，请先 cd 到对应目录):${NC}"
    if [[ -n "$compose_cmd_prefix" ]]; then
        echo -e "启动 Sub-Store: ${CYAN}${compose_cmd_prefix} start sub-store${NC} (如果服务已定义在compose文件中)"
        echo -e "或者: ${CYAN}${compose_cmd_prefix} up -d sub-store${NC}"
        echo -e "停止 Sub-Store: ${CYAN}${compose_cmd_prefix} stop sub-store${NC}"
        echo -e "重启 Sub-Store: ${CYAN}${compose_cmd_prefix} restart sub-store${NC}"
        echo -e "查看 Sub-Store 状态: ${CYAN}${compose_cmd_prefix} ps${NC}"
        echo -e "更新 Sub-Store (重新执行此安装模块即可，或手动):"
        echo -e "  1. 拉取新镜像: ${CYAN}${compose_cmd_prefix} pull sub-store${NC}"
        echo -e "  2. 重启服务:   ${CYAN}${compose_cmd_prefix} up -d --force-recreate sub-store${NC}"
        echo -e "完全卸载 Sub-Store (包括数据):"
        echo -e "  1. 停止并删除容器/网络: ${CYAN}${compose_cmd_prefix} down${NC}"
    else
        echo -e "请根据您安装的 Docker Compose 版本手动执行相应命令。"
    fi
    echo -e "查看 Sub-Store 日志: ${CYAN}docker logs --tail 100 sub-store${NC}"
    echo -e "删除数据目录: ${CYAN}rm -rf /root/sub-store-data${NC}"
    echo -e "删除配置文件: ${CYAN}rm -f \"$(pwd)/${compose_file}\"${NC}"
}

# ======================= 搭建TG图床 =======================
install_tg_image_host() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/Acacia415/GPT-Scripts${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo # Add an empty line for spacing

    local install_script_url="https://raw.githubusercontent.com/Acacia415/GPT-Scripts/main/install_imghub.sh"
    local temp_install_script="/tmp/tg_imghub_install.sh"

    echo -e "${CYAN}正在下载 TG图床 安装脚本...${NC}"
    if curl -sSL -o "$temp_install_script" "$install_script_url"; then
        chmod +x "$temp_install_script"
        echo -e "${GREEN}下载完成，开始执行安装脚本...${NC}"
        # Execute the script
        "$temp_install_script"
        # Optionally, remove the script after execution
        rm -f "$temp_install_script"
        echo -e "${GREEN}TG图床 安装脚本执行完毕。${NC}"
        # 成功时，不再有模块内部的 read 暂停
    else
        echo -e "${RED}下载 TG图床 安装脚本失败！${NC}"
        # 失败时，移除了这里的 read 暂停
        # read -n 1 -s -r -p "按任意键返回主菜单..." # 已移除
        return 1 # 仍然返回错误码，主菜单可以根据需要处理或忽略
    fi
    # 确保函数末尾没有其他 read 暂停
    # # Add a pause before returning to the main menu, if desired, after successful installation
    # # read -n 1 -s -r -p "安装完成，按任意键返回主菜单..." # 此行保持注释或删除
}

# ======================= TCP性能优化 (BBR+fq) =======================
optimize_tcp_performance() {
    clear
    echo -e "${YELLOW}==================================================${NC}"
    echo -e "${CYAN}        TCP 性能优化 (BBR + fq) 安装脚本        ${NC}"
    echo -e "${YELLOW}==================================================${NC}"
    echo # Add an empty line for spacing
    echo -e "此脚本将通过以下步骤优化系统的TCP性能："
    echo -e "1. 自动备份当前的 sysctl.conf 和 sysctl.d 目录。"
    echo -e "2. 检查并注释掉与BBR相关的旧配置。"
    echo -e "3. 添加最新的BBR和fq配置以提升网络吞吐量。"
    echo -e "4. 提醒您手动检查 sysctl.d 目录中的潜在冲突。"
    echo

    # 检查内核版本，BBR需要4.9及以上版本
    local kernel_version
    kernel_version=$(uname -r | cut -d- -f1)
    if ! dpkg --compare-versions "$kernel_version" "ge" "4.9"; then
        echo -e "${RED}错误: BBR 需要 Linux 内核版本 4.9 或更高。${NC}"
        echo -e "${RED}您当前的内核版本是: ${kernel_version}${NC}"
        echo -e "${RED}无法继续，请升级您的系统内核。${NC}"
        # 主菜单会处理 "按任意键返回" 的暂停，这里直接返回
        return 1
    fi
    echo -e "${GREEN}内核版本 ${kernel_version}，满足要求。${NC}"
    echo

    # --- 要添加或更新的参数列表 ---
    local params=(
        "net.core.default_qdisc"
        "net.ipv4.tcp_congestion_control"
        "net.core.rmem_max"
        "net.core.wmem_max"
        "net.core.netdev_max_backlog"
        "net.ipv4.tcp_rmem"
        "net.ipv4.tcp_wmem"
    )

    # --- 1. 执行备份 ---
    echo -e "${CYAN}INFO: 正在备份 /etc/sysctl.conf 和 /etc/sysctl.d/ 目录...${NC}"
    sudo cp /etc/sysctl.conf "/etc/sysctl.conf.bk_$(date +%Y%m%d_%H%M%S)" &>/dev/null
    sudo cp -r /etc/sysctl.d/ "/etc/sysctl.d.bk_$(date +%Y%m%d_%H%M%S)" &>/dev/null
    echo -e "${GREEN}INFO: 备份完成。${NC}"
    echo

    # --- 2. 自动注释掉 /etc/sysctl.conf 中的旧配置 ---
    echo -e "${CYAN}INFO: 正在检查并注释掉 /etc/sysctl.conf 中的旧配置...${NC}"
    for param in "${params[@]}"; do
        # 使用sed命令查找参数并将其注释掉。-E使用扩展正则, \.转义点.
        # s/^\s*.../ 表示从行首开始匹配，可以有空格
        sudo sed -i.bak -E "s/^\s*${param//./\\.}.*/# &/" /etc/sysctl.conf
    done
    sudo rm -f /etc/sysctl.conf.bak
    echo -e "${GREEN}INFO: 旧配置注释完成。${NC}"
    echo

    # --- 3. 追加新的配置到 /etc/sysctl.conf ---
    echo -e "${CYAN}INFO: 正在将新的网络优化配置追加到文件末尾...${NC}"
    sudo tee -a /etc/sysctl.conf > /dev/null << EOF

# --- BBR and Network Optimization Settings Added by Toolbox on $(date +%Y-%m-%d) ---
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.core.netdev_max_backlog=250000
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
# --- End of BBR Settings ---
EOF
    echo -e "${GREEN}INFO: 新配置追加完成。${NC}"
    echo

    # --- 4. 提醒检查 /etc/sysctl.d/ 目录 ---
    echo -e "${YELLOW}!!! 警告: 请手动检查 /etc/sysctl.d/ 目录中的配置文件。${NC}"
    echo -e "以下是该目录中的文件列表:"
    ls -l /etc/sysctl.d/
    echo -e "${YELLOW}请确认其中没有与BBR或网络缓冲区相关的冲突配置（例如 99-bbr.conf 等）。${NC}"
    echo -e "${YELLOW}如果有，请手动检查、备份并决定是否删除它们。${NC}"
    read -n 1 -s -r -p "检查完毕后，按任意键继续应用配置..."
    echo
    echo

    # --- 5. 应用配置并验证 ---
    echo -e "${CYAN}INFO: 正在应用新的 sysctl 配置...${NC}"
    if sudo sysctl -p; then
        echo -e "${GREEN}INFO: 配置已成功应用。${NC}"
    else
        echo -e "${RED}ERROR: 应用 sysctl 配置时出错。请检查 /etc/sysctl.conf 的语法。${NC}"
        return 1
    fi
    echo
    echo -e "${CYAN}INFO: 正在验证BBR是否成功启用...${NC}"

    local bbr_status
    bbr_status=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    local fq_status
    fq_status=$(sysctl net.core.default_qdisc | awk '{print $3}')

    echo -e "当前TCP拥塞控制算法: ${GREEN}${bbr_status}${NC}"
    echo -e "当前默认队列调度算法: ${GREEN}${fq_status}${NC}"
    echo

    if [[ "$bbr_status" == "bbr" && "$fq_status" == "fq" ]]; then
        echo -e "${GREEN}SUCCESS: TCP 性能优化（BBR + fq）已成功启用！${NC}"
    else
        echo -e "${RED}WARNING: 验证失败。BBR 或 fq 未能成功启用。${NC}"
        echo -e "${RED}请检查系统日志和以上步骤的输出。${NC}"
    fi
    # "按任意键返回主菜单..." 将由主菜单的 case 语句处理
}

# ======================= 脚本更新 =======================
update_script() {
  echo -e "${YELLOW}开始更新脚本...${NC}"
  
  # 删除旧脚本
  rm -f /root/tool.sh
  
  # 下载并执行新脚本
  if curl -sSL https://raw.githubusercontent.com/Acacia415/GPT-Scripts/main/tool.sh -o /root/tool.sh && 
     chmod +x /root/tool.sh
  then
    echo -e "${GREEN}更新成功，即将启动新脚本...${NC}"
    sleep 2
    exec /root/tool.sh  # 用新脚本替换当前进程
  else
    echo -e "${RED}更新失败！请手动执行："
    echo -e "curl -sSL https://raw.githubusercontent.com/Acacia415/GPT-Scripts/main/tool.sh -o tool.sh"
    echo -e "chmod +x tool.sh && ./tool.sh${NC}"
    exit 1
  fi
}

# ======================= 主菜单 =======================
main_menu() {
  while true; do
    clear
    echo -e "${CYAN}"
    echo "  _____ _____  _____  _____   _______ ____   ____  _      ____   ______   __"
    echo " |_   _|  __ \|_   _|/ ____| |__   __/ __ \ / __ \| |    |  _ \ / __ \ \ / /"
    echo "   | | | |__) | | | | (___      | | | |  | | |  | | |    | |_) | |  | \ V / "
    echo "   | | |  _  /  | |  \___ \     | | | |  | | |  | | |    |  _ <| |  | |> <  "
    echo "  _| |_| | \ \ _| |_ ____) |    | | | |__| | |__| | |____| |_) | |__| / . \ "
    echo " |_____|_|  \_\_____|_____/     |_|  \____/ \____/|______|____/ \____/_/ \_\\"
    echo -e "                                                              ${NC}"
    echo -e "${YELLOW}==================================================${NC}"
    echo -e "1. 系统信息查询"
    echo -e "2. 开启root用户登录"
    echo -e "3. 安装流量监控服务"
    echo -e "4. 完全卸载流量监控"
    echo -e "5. 安装 Snell 协议服务"
    echo -e "6. 安装 Hysteria2 协议服务"
    echo -e "7. 安装 SS-Rust 协议服务"
    echo -e "8. 安装 ShadowTLS"
    echo -e "9. 安装 3X-UI 管理面板"
    echo -e "10. 流媒体解锁检测"
    echo -e "11. Speedtest网络测速"
    echo -e "12. 开放所有端口"
    echo -e "13. Caddy反代管理"
    echo -e "14. Nginx管理"
    echo -e "15. IP优先级设置"
    echo -e "16. TCP性能优化"
    echo -e "17. 命令行美化"
    echo -e "18. DNS解锁服务"
    echo -e "19. 安装Sub-Store"
    echo -e "20. 搭建TG图床"
    echo -e "21. TCP性能优化 (BBR+fq)"
    echo -e "0. 退出脚本"
    echo -e "${YELLOW}==================================================${NC}"
    echo -e "99. 脚本更新"
    echo -e "${YELLOW}==================================================${NC}"

    read -p "请输入选项 : " choice
    case $choice in
      1)
        display_system_info
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      2) 
        enable_root_login
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      3) 
        install_traffic_monitor
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      4) 
        uninstall_service 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      5) 
        install_snell 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      6)  
        install_hysteria2 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      7)  
        install_ss_rust 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      8)  
        install_shadowtls 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      9)  
        install_3x_ui 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      10)  
        install_media_check 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      11)  
        install_speedtest 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      12)  
        open_all_ports 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      13)
        caddy_main
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      14)
        nginx_main
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      15)
        modify_ip_preference
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      16)
        install_magic_tcp 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      17)  
        install_shell_beautify 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      18)  
        dns_unlock_menu 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      19)  
        install_substore 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      20)  
        install_tg_image_host 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      21)
        optimize_tcp_performance 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      99)  
        update_script 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      0) 
        echo -e "${GREEN}已退出${NC}"
        exit 0
        ;;
      *) 
        echo -e "${RED}无效选项，请重新输入${NC}"
        sleep 1
        ;;
    esac
  done
}


# ======================= 执行入口 =======================
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}请使用 sudo -i 切换root用户后再运行本脚本！${NC}"
  exit 1
fi

# Bash版本检查
if (( BASH_VERSINFO < 4 )); then
  echo -e "${RED}需要Bash 4.0及以上版本${NC}"
  exit 1
fi

main_menu
