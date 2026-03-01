#!/bin/bash
set -e
red='\e[31m'; yellow='\e[33m'; green='\e[92m'; blue='\e[94m'; none='\e[0m'
_red() { echo -e ${red}$@${none}; }
_green() { echo -e ${green}$@${none}; }
_yellow() { echo -e ${yellow}$@${none}; }
_err() { echo -e "\n${red}错误!${none} $@\n" && exit 1; }
_warn() { echo -e "\n${yellow}警告!${none} $@\n"; }

[[ $EUID != 0 ]] && _err "请使用 root 运行"
cmd=$(type -P apt-get || type -P yum || type -P zypper || type -P apk) || _err "仅支持 apt/yum/zypper/apk"

# systemd 或 OpenRC
use_systemd=0
[[ $(type -P systemctl) ]] && use_systemd=1
_wget() { [[ $proxy ]] && export https_proxy=$proxy; wget --no-check-certificate -q "$@"; }

# 获取本机 IP
_get_ip() {
    local ip
    ip=$(_wget -6 -qO- "https://[2606:4700:4700::1111]/cdn-cgi/trace" 2>/dev/null | grep ^ip= | cut -d= -f2)
    [[ $ip ]] && echo "$ip" && return 0
    ip=$(_wget -4 -qO- "https://one.one.one.one/cdn-cgi/trace" 2>/dev/null | grep ^ip= | cut -d= -f2)
    [[ $ip ]] && echo "$ip" && return 0
    return 1
}

_rand_port() { local p; p=$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d ' '); echo $((${p:-30000} % 40000 + 20000)); }

case $(uname -m) in
    amd64|x86_64) arch=amd64 ;;
    *aarch64*|*armv8*) arch=arm64 ;;
    *) _err "仅支持 64 位" ;;
esac

# 路径定义
CORE=sing-box
CORE_DIR=/etc/$CORE
CORE_BIN=$CORE_DIR/bin/$CORE
CONF_DIR=$CORE_DIR/conf
LOG_DIR=/var/log/$CORE
BIN=/usr/local/bin/sb
CORE_REPO=SagerNet/$CORE
CADDY_BIN=/usr/local/bin/caddy
CADDY_DIR=/etc/caddy
CADDY_CONF=$CADDY_DIR/sing-box
CADDY_CONF_D=$CADDY_DIR/conf.d
CADDYFILE=$CADDY_DIR/Caddyfile
CONFIG_JSON=$CORE_DIR/config.json

# 是否已安装
installed() { [[ -f $CORE_BIN && -d $CONF_DIR ]]; }

# 服务控制
_svc_start() { 
    [[ $use_systemd -eq 1 ]] && systemctl start $CORE caddy 2>/dev/null || { /etc/init.d/$CORE start 2>/dev/null; /etc/init.d/caddy start 2>/dev/null; }; 
}
_svc_stop() { 
    [[ $use_systemd -eq 1 ]] && systemctl stop $CORE caddy 2>/dev/null || { /etc/init.d/$CORE stop 2>/dev/null; /etc/init.d/caddy stop 2>/dev/null; }; 
}
_svc_restart() { 
    [[ $use_systemd -eq 1 ]] && systemctl restart $CORE caddy 2>/dev/null || { _svc_stop; sleep 1; _svc_start; }; 
}
_svc_status() { 
    [[ $use_systemd -eq 1 ]] && systemctl status $CORE caddy --no-pager 2>/dev/null || (rc-status 2>/dev/null | grep -E "caddy|sing-box" || true); 
}

# 获取对外端口
_get_ext_port() {
    local host=$1
    local port
    if [[ -f $CADDY_CONF_D/${host}.caddy ]]; then
        port=$(grep -oE "${host}:[0-9]+" $CADDY_CONF_D/${host}.caddy | cut -d: -f2)
    elif [[ -f $CADDY_CONF/$host.conf ]]; then
        port=$(grep -oE "${host}:[0-9]+" $CADDY_CONF/$host.conf | cut -d: -f2)
    fi
    echo ${port:-443}
}

# ============ 安装 ============
do_install() {
    [[ -f $BIN && installed ]] && _err "已安装, 重装请先: sb uninstall"
    
    local caddy_mode="standalone"
    if type -P caddy &>/dev/null; then
        caddy_mode="existing"
        [[ -d $CADDY_CONF_D ]] && _yellow "检测到现有 Caddy 且存在 conf.d 目录，将采用共存模式。"
    fi

    echo -e "\n${green}===== sing-box 终极整合安装 =====${none}\n"
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -f|--core-file) [[ -f $2 ]] && core_file=$2; shift 2 ;;
            -p|--proxy) proxy=$2; shift 2 ;;
            *) shift ;;
        esac
    done
    
    # 【修复重点】判断是否为 apk (Alpine)，如果是则更新源并安装兼容库
    if [[ $cmd == *apk* ]]; then
        echo "检测到 Alpine 系统，正在安装基础依赖和 C 库兼容层..."
        apk update >/dev/null 2>&1 || true
        apk add --no-cache wget tar jq gcompat libc6-compat 2>/dev/null || true
    else
        $cmd install -y wget tar jq 2>/dev/null || true
    fi
    
    mkdir -p $CORE_DIR/bin $CONF_DIR $LOG_DIR
    
    if [[ $core_file ]]; then
        tar zxf "$core_file" --strip-components 1 -C $CORE_DIR/bin
    else
        echo "下载 sing-box..."
        ver=$(_wget -qO- "https://api.github.com/repos/$CORE_REPO/releases/latest" 2>/dev/null | grep -oE '"tag_name": "v[0-9.]+"' | head -1 | cut -d'"' -f4)
        [[ ! $ver ]] && ver="v1.12.21"
        _wget -O /tmp/sb.tar.gz "https://github.com/$CORE_REPO/releases/download/$ver/${CORE}-${ver#v}-linux-$arch.tar.gz" || _err "下载失败"
        tar zxf /tmp/sb.tar.gz --strip-components 1 -C $CORE_DIR/bin && rm -f /tmp/sb.tar.gz
    fi
    chmod +x $CORE_BIN

    if [[ "$caddy_mode" == "standalone" ]]; then
        echo "下载 Caddy (独立模式)..."
        mkdir -p $CADDY_DIR/sites $CADDY_CONF
        caddy_ver=$(_wget -qO- "https://api.github.com/repos/caddyserver/caddy/releases/latest" 2>/dev/null | grep -oE '"tag_name": "v[0-9.]+"' | head -1 | cut -d'"' -f4)
        [[ ! $caddy_ver ]] && caddy_ver="v2.8.4"
        _wget -O /tmp/caddy.tar.gz "https://github.com/caddyserver/caddy/releases/download/$caddy_ver/caddy_${caddy_ver#v}_linux_${arch}.tar.gz"
        tar zxf /tmp/caddy.tar.gz -C /tmp && mv /tmp/caddy $CADDY_BIN && rm -f /tmp/caddy.tar.gz
        chmod +x $CADDY_BIN
        
        cat > $CADDYFILE << EOF
{
  admin off
  http_port 80
  https_port 443
}
import $CADDY_CONF/*.conf
EOF
    fi

    # 生成服务文件 (兼顾 systemd 和 OpenRC)
    if [[ $use_systemd -eq 1 ]]; then
        cat > /lib/systemd/system/$CORE.service << EOF
[Unit]
Description=sing-box
After=network.target
[Service]
ExecStart=$CORE_BIN run -c $CONFIG_JSON -C $CONF_DIR
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
        if [[ "$caddy_mode" == "standalone" ]]; then
            cat > /lib/systemd/system/caddy.service << EOF
[Unit]
Description=Caddy
After=network.target
[Service]
ExecStart=$CADDY_BIN run --config $CADDYFILE --adapter caddyfile
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
        fi
        systemctl daemon-reload
        systemctl enable $CORE 2>/dev/null || true
        [[ "$caddy_mode" == "standalone" ]] && systemctl enable caddy 2>/dev/null || true
    else
        cat > /etc/init.d/$CORE << EOF
#!/sbin/openrc-run
name="$CORE"
command="$CORE_BIN"
command_args="run -c $CONFIG_JSON -C $CONF_DIR"
command_background=true
pidfile="/run/$CORE.pid"
depend() {
    need net
}
EOF
        chmod +x /etc/init.d/$CORE
        rc-update add $CORE default 2>/dev/null || true

        if [[ "$caddy_mode" == "standalone" ]]; then
            cat > /etc/init.d/caddy << EOF
#!/sbin/openrc-run
name="caddy"
command="$CADDY_BIN"
command_args="run --config $CADDYFILE --adapter caddyfile"
command_background=true
pidfile="/run/caddy.pid"
depend() {
    need net
}
EOF
            chmod +x /etc/init.d/caddy
            rc-update add caddy default 2>/dev/null || true
        fi
    fi
    
    cat > $CONFIG_JSON << 'JSON'
{
  "log": {"output":"/var/log/sing-box/access.log","level":"info"},
  "dns": {},
  "outbounds": [{"tag":"direct","type":"direct"}]
}
JSON
    
    echo ""
    read -p "请输入域名 (已解析到本机): " host
    [[ ! $host ]] && _err "域名不能为空"
    
    uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || (python3 -c 'import uuid;print(uuid.uuid4())'))
    port=$(_rand_port)
    path="/ws"
    
    cat > $CONF_DIR/vmess-${host}.json << CFG
{
  "inbounds": [{
    "tag": "vmess-${host}",
    "type": "vmess",
    "listen": "127.0.0.1",
    "listen_port": $port,
    "users": [{"uuid": "$uuid"}],
    "transport": {"type": "ws", "path": "$path", "headers": {"host": "$host"}}
  }]
}
CFG
    
    if [[ "$caddy_mode" == "existing" && -d $CADDY_CONF_D ]]; then
        cat > $CADDY_CONF_D/${host}.caddy << CADDY
${host}:443 {
    reverse_proxy ${path} 127.0.0.1:${port}
}
CADDY
        _green "Caddy 配置已写入: $CADDY_CONF_D/${host}.caddy"
    else
        mkdir -p $CADDY_CONF
        cat > $CADDY_CONF/$host.conf << CADDY
${host}:443 {
    reverse_proxy ${path} 127.0.0.1:${port}
}
CADDY
    fi
    
    cp -f "$0" $BIN && chmod +x $BIN
    _svc_restart
    sleep 2
    
    _green "\n========== 安装完成 =========="
    do_info "vmess-${host}"
    echo -e "\n${blue}VMess 链接:${none}"
    do_url "vmess-${host}"
    echo -e "\n管理: 运行 ${green}sb${none} 进入管理菜单"
}

_sel_cfg() {
    local list=($(ls $CONF_DIR/*.json 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\.json$//'))
    [[ ${#list[@]} -eq 0 ]] && _err "暂无配置"
    [[ ${#list[@]} -eq 1 ]] && { echo "${list[0]}"; return 0; }
    echo -e "\n请选择配置:" >&2
    local i=1
    for c in "${list[@]}"; do echo -e "  $i) $c" >&2; ((i++)); done
    echo -e "  0) 取消" >&2
    read -p "请输入 [1-${#list[@]}]: " n
    [[ "$n" == "0" ]] && return 1
    [[ "$n" =~ ^[0-9]+$ && $n -ge 1 && $n -le ${#list[@]} ]] && echo "${list[$((n-1))]}" && return 0
    return 1
}

do_info() {
    local cfg=$1
    [[ ! $cfg ]] && { ls $CONF_DIR/*.json 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\.json$//' || echo "无配置"; return 0; }
    local file=$CONF_DIR/${cfg}.json
    [[ ! -f $file ]] && _err "配置不存在"
    
    local uuid=$(jq -r '.inbounds[0].users[0].uuid' $file)
    local host=$(jq -r '.inbounds[0].transport.headers.host' $file)
    local path=$(jq -r '.inbounds[0].transport.path' $file)
    local ext_port=$(_get_ext_port "$host")
    
    echo -e "\n${blue}--------- 配置详情 ---------${none}"
    echo "  协议:    VMess"
    echo "  地址:    $host"
    echo "  对外端口: $ext_port"
    echo "  路径:    $path"
    echo "  UUID:    $uuid"
    echo "  传输:    ws (TLS)"
    echo -e "${blue}---------------------------${none}"
}

do_url() {
    local cfg=$1
    [[ ! $cfg ]] && { cfg=$(_sel_cfg) || return 0; }
    local file=$CONF_DIR/${cfg}.json
    [[ ! -f $file ]] && _err "配置不存在"
    
    local uuid=$(jq -r '.inbounds[0].users[0].uuid' $file)
    local host=$(jq -r '.inbounds[0].transport.headers.host' $file)
    local path=$(jq -r '.inbounds[0].transport.path // "/ws"' $file)
    local ext_port=$(_get_ext_port "$host")
    
    local vmess=$(echo -n "{\"v\":2,\"ps\":\"$host\",\"add\":\"$host\",\"port\":\"$ext_port\",\"id\":\"$uuid\",\"aid\":\"0\",\"net\":\"ws\",\"host\":\"$host\",\"path\":\"$path\",\"tls\":\"tls\"}" | base64 | tr -d '\n')
    echo "vmess://$vmess"
}

do_qr() {
    local cfg=$1
    [[ ! $cfg ]] && { cfg=$(_sel_cfg) || return 0; }
    local url=$(do_url "$cfg")
    if type -P qrencode &>/dev/null; then
        qrencode -t ANSI "$url"
    else
        echo "请安装 qrencode 或直接复制链接:"
        echo "$url"
    fi
}

do_port() {
    local cfg=$1
    [[ ! $cfg ]] && { cfg=$(_sel_cfg) || return 0; }
    local file=$CONF_DIR/${cfg}.json
    local host=$(jq -r '.inbounds[0].transport.headers.host' $file)
    
    echo -e "\n当前对外端口: $(_get_ext_port "$host")"
    read -p "请输入新的对外端口 (直接回车默认 443): " new_port
    [[ ! $new_port ]] && new_port=443
    [[ ! $new_port =~ ^[0-9]+$ || $new_port -lt 1 || $new_port -gt 65535 ]] && _err "端口范围错误"
    
    if [[ -f $CADDY_CONF_D/${host}.caddy ]]; then
        sed -i "s/${host}:[0-9]*/${host}:${new_port}/g" $CADDY_CONF_D/${host}.caddy
    elif [[ -f $CADDY_CONF/$host.conf ]]; then
        sed -i "s/${host}:[0-9]*/${host}:${new_port}/g" $CADDY_CONF/$host.conf
    else
        _err "找不到该域名的 Caddy 配置文件"
    fi

    _svc_restart
    _green "对外端口已更新为: $new_port"
    do_url "$cfg"
}

do_id() {
    local cfg=$1
    [[ ! $cfg ]] && { cfg=$(_sel_cfg) || return 0; }
    local file=$CONF_DIR/${cfg}.json
    read -p "新 UUID (回车随机生成): " new_uuid
    [[ ! $new_uuid ]] && new_uuid=$(cat /proc/sys/kernel/random/uuid)
    jq ".inbounds[0].users[0].uuid = \"$new_uuid\"" $file > ${file}.tmp && mv ${file}.tmp $file
    _svc_restart
    _green "UUID 已更新"
    do_url "$cfg"
}

do_uninstall() {
    read -p "确定卸载 sing-box? [y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && exit 0
    _svc_stop
    [[ $use_systemd -eq 1 ]] && { systemctl disable $CORE 2>/dev/null; rm -f /lib/systemd/system/$CORE.service; } || { rc-update del $CORE default 2>/dev/null; rm -f /etc/init.d/$CORE; }
    if [[ -f $CADDY_BIN ]]; then
         [[ $use_systemd -eq 1 ]] && { systemctl disable caddy 2>/dev/null; rm -f /lib/systemd/system/caddy.service; } || { rc-update del caddy default 2>/dev/null; rm -f /etc/init.d/caddy; }
         rm -rf $CADDY_DIR $CADDY_BIN
    fi
    rm -rf $CORE_DIR $LOG_DIR $BIN
    _green "卸载完成"
}

do_menu() {
    while true; do
        echo -e "\n${green}========== sb 管理菜单 ==========${none}"
        echo "  1) 启动服务      2) 停止服务      3) 重启服务"
        echo "  4) 查看状态      5) 查看配置      6) 获取链接/二维码"
        echo "  7) 修改对外端口  8) 修改 UUID     9) 卸载"
        echo "  0) 退出"
        echo ""
        read -p "请选择 [0-9]: " choice
        case $choice in
            1) _svc_start; _green "已启动" ;;
            2) _svc_stop; _green "已停止" ;;
            3) _svc_restart; _green "已重启" ;;
            4) _svc_status ;;
            5) cfg=$(_sel_cfg) && do_info "$cfg" ;;
            6) cfg=$(_sel_cfg) && { echo ""; do_url "$cfg"; echo ""; do_qr "$cfg"; } ;;
            7) do_port ;;
            8) do_id ;;
            9) do_uninstall; exit 0 ;;
            0) exit 0 ;;
            *) _warn "无效选择" ;;
        esac
    done
}

case "${1:-}" in
    install) shift; do_install "$@"; exit 0 ;;
    uninstall) do_uninstall; exit 0 ;;
esac

if ! installed; then
    do_install "$@"
else
    [[ $# -eq 0 ]] && do_menu || {
        case $1 in
            start) _svc_start ;;
            stop) _svc_stop ;;
            restart) _svc_restart ;;
            status) _svc_status ;;
            *) do_menu ;;
        esac
    }
fi
