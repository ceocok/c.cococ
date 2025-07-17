#!/bin/bash
# Author: Jrohy 
# github: https://github.com/Jrohy/multi-v2ray

begin_path=$(pwd)
install_way=0
help=0
remove=0
chinese=1
base_source_path="https://multi.netlify.app"
util_path="/etc/v2ray_util/util.cfg"
util_cfg="$base_source_path/v2ray_util/util_core/util.cfg"
bash_completion_shell="$base_source_path/v2ray"
clean_iptables_shell="$base_source_path/v2ray_util/global_setting/clean_iptables.sh"

[[ -f /etc/redhat-release && -z $(echo $SHELL|grep zsh) ]] && unalias -a
[[ -z $(echo $SHELL|grep zsh) ]] && env_file=".bashrc" || env_file=".zshrc"

red="31m"
green="32m"
yellow="33m"
blue="36m"

colorEcho(){
    color=$1
    echo -e "\033[${color}${@:2}\033[0m"
}

while [[ $# > 0 ]];do
    key="$1"
    case $key in
        --remove) remove=1 ;;
        -h|--help) help=1 ;;
        -k|--keep) install_way=1; colorEcho ${blue} "keep config to update\n" ;;
        --zh) chinese=1; colorEcho ${blue} "安装中文版..\n" ;;
    esac
    shift
done

help(){
    echo "bash v2ray.sh [-h|--help] [-k|--keep] [--remove]"
    echo "  -h, --help           Show help"
    echo "  -k, --keep           keep the config.json to update"
    echo "      --remove         remove v2ray,xray && multi-v2ray"
    return 0
}

removeV2Ray() {
    bash <(curl -L -s https://multi.netlify.app/go.sh) --remove >/dev/null 2>&1
    rm -rf /etc/v2ray /var/log/v2ray /etc/xray /var/log/xray
    bash <(curl -L -s $clean_iptables_shell)
    pip uninstall v2ray_util -y
    rm -rf /usr/share/bash-completion/completions/{v2ray.bash,v2ray,xray}
    rm -rf /etc/bash_completion.d/v2ray.bash
    rm -rf /usr/local/bin/{v2ray,xray}
    rm -rf /etc/v2ray_util /etc/profile.d/iptables.sh /root/.iptables
    crontab -l|sed '/v2ray/d;/xray/d' > crontab.txt
    crontab crontab.txt && rm -f crontab.txt

    systemctl restart cron >/dev/null 2>&1
    sed -i '/v2ray/d' ~/$env_file
    sed -i '/xray/d' ~/$env_file
    source ~/$env_file

    sed -i '/iptables/d' /etc/rc.local 2>/dev/null
    colorEcho ${green} "uninstall success!"
}

closeSELinux() {
    if [ -s /etc/selinux/config ] && grep 'SELINUX=enforcing' /etc/selinux/config; then
        sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
        setenforce 0
    fi
}

checkSys() {
    [ $(id -u) != "0" ] && { colorEcho ${red} "Error: You must be root to run this script"; exit 1; }

    if command -v apt-get &>/dev/null; then
        package_manager='apt-get'
    elif command -v dnf &>/dev/null; then
        package_manager='dnf'
    elif command -v yum &>/dev/null; then
        package_manager='yum'
    else
        colorEcho $red "Not supported OS!"
        exit 1
    fi
}

installDependent(){
    if [[ ${package_manager} == 'dnf' || ${package_manager} == 'yum' ]];then
        ${package_manager} install socat crontabs bash-completion which python3 python3-pip -y
    else
        ${package_manager} install socat cron bash-completion ntpdate gawk python3-full python3-venv -y
    fi
}

updateProject() {
    # 创建虚拟环境
    mkdir -p /opt/v2env
    python3 -m venv /opt/v2env
    source /opt/v2env/bin/activate

    pip install --upgrade pip
    pip install -U v2ray_util

    ln -sf /opt/v2env/bin/v2ray-util /usr/local/bin/v2ray
    ln -sf /opt/v2env/bin/v2ray-util /usr/local/bin/xray

    [[ -e $util_path ]] || mkdir -p /etc/v2ray_util
    curl -s $util_cfg -o $util_path
    [[ $chinese == 1 ]] && sed -i "s/lang=en/lang=zh/g" $util_path

    curl -s $bash_completion_shell -o /usr/share/bash-completion/completions/v2ray
    curl -s $bash_completion_shell -o /usr/share/bash-completion/completions/xray
    [[ -z $(echo $SHELL|grep zsh) ]] && source /usr/share/bash-completion/completions/v2ray

    # 安装主程序
    [[ ${install_way} == 0 ]] && bash <(curl -L -s https://multi.netlify.app/go.sh)

    # 设置 rc.local
    rc_file="/etc/rc.local"
    [[ ! -f $rc_file ]] && echo -e '#!/bin/bash\nexit 0' > $rc_file && chmod +x $rc_file

    local_ip=$(curl -s http://api.ipify.org)
    [[ "$local_ip" =~ ":" ]] && iptable_way="ip6tables" || iptable_way="iptables"
    grep -q "/root/.iptables" $rc_file || echo "[[ -e /root/.iptables ]] && $iptable_way-restore -c < /root/.iptables" >> $rc_file
    $iptable_way-save -c > /root/.iptables

    systemctl enable rc-local
    systemctl restart rc-local
}

timeSync() {
    if [[ ${install_way} == 0 ]];then
        echo -e "Time Synchronizing..."
        if command -v ntpdate &>/dev/null; then
            ntpdate pool.ntp.org
        elif command -v chronyc &>/dev/null; then
            chronyc -a makestep
        fi
        [[ $? -eq 0 ]] && colorEcho $green "Time Sync Success"
        colorEcho $blue "now: $(date -R)"
    fi
}

profileInit() {
    sed -i '/v2ray/d' ~/$env_file
    [[ -z $(grep PYTHONIOENCODING=utf-8 ~/$env_file) ]] && echo "export PYTHONIOENCODING=utf-8" >> ~/$env_file
    source ~/$env_file
    [[ ${install_way} == 0 ]] && v2ray new
}

installFinish() {
    cd ${begin_path}
    [[ ${install_way} == 0 ]] && WAY="install" || WAY="update"
    colorEcho  ${green} "multi-v2ray ${WAY} success!\n"

    if [[ ${install_way} == 0 ]]; then
        clear
        v2ray info
        echo -e "please input 'v2ray' command to manage v2ray\n"
    fi
}

main() {
    [[ ${help} == 1 ]] && help && return
    [[ ${remove} == 1 ]] && removeV2Ray && return
    [[ ${install_way} == 0 ]] && colorEcho ${blue} "new install\n"

    checkSys
    installDependent
    closeSELinux
    timeSync
    updateProject
    profileInit
    installFinish
}

main

