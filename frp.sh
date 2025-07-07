#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

Green="\033[32m"
Red="\033[31m"
Yellow="\033[33m"
Blue="\033[36m"
Font="\033[0m"

CONFIG_DIR="/etc/frp"
BIN_DIR="/usr/local/bin"
FRP_DIR="/usr/local/frp"

pause() {
    read -rp $'\n按回车键返回...' _
}

check_installed() {
    local svc=$1
    if [ ! -f "$BIN_DIR/$svc" ]; then
        echo -e "${Red}${svc} 未安装！${Font}"
        echo -e "${Yellow}1) 安装 $svc\n[回车] 返回${Font}"
        read -p "请选择: " choice
        [[ "$choice" == "1" ]] && bash /usr/local/frp/frp-install.sh "$svc"
        return 1
    fi
    return 0
}

manage_service_menu() {
    local svc=$1
    local desc=$2
    while true; do
        echo -e "\n${Blue}===== ${desc} 管理菜单 =====${Font}"
        echo -e "${Green}1.${Font} 查看状态"
        echo -e "${Green}2.${Font} 查看日志"
        echo -e "${Green}3.${Font} 重启服务"
        echo -e "${Green}4.${Font} 停止服务"
        echo -e "${Green}5.${Font} 查看配置"
        echo -e "${Green}6.${Font} 修改配置文件"
        echo -e "${Green}7.${Font} 重新安装"
        echo -e "${Green}8.${Font} 卸载"
        [[ "$svc" == "frps" ]] && echo -e "${Green}9.${Font} tokens 配置"
        echo -e "${Green}0.${Font} 返回主菜单"
        read -p "请输入选项: " choice
        case "$choice" in
            1) check_installed "$svc" && systemctl status "$svc" --no-pager; pause ;;
            2) check_installed "$svc" && journalctl -u "$svc" -e; pause ;;
            3) check_installed "$svc" && systemctl restart "$svc"; echo -e "${Green}服务已重启${Font}"; pause ;;
            4) check_installed "$svc" && systemctl stop "$svc"; echo -e "${Green}服务已停止${Font}"; pause ;;
            5) check_installed "$svc" && cat "$CONFIG_DIR/$svc.toml"; pause ;;
            6) check_installed "$svc" && ${EDITOR:-nano} "$CONFIG_DIR/$svc.toml"; pause ;;
            7) bash /usr/local/frp/frp-install.sh "$svc"; pause ;;
            8) bash /usr/local/frp/frp-install.sh "uninstall_$svc"; pause ;;
            9) [[ "$svc" == "frps" ]] && tokens_menu ;;
            0) break ;;
            *) echo -e "${Red}无效输入${Font}" ;;
        esac
    done
}

tokens_menu() {
    while true; do
        echo -e "\n${Blue}===== tokens 配置 =====${Font}"
        echo -e "${Green}1.${Font} 查看当前 tokens"
        echo -e "${Green}2.${Font} 添加用户和 token"
        echo -e "${Green}3.${Font} 删除用户"
        echo -e "${Green}0.${Font} 返回"
        read -p "请输入选项: " TK
        case "$TK" in
            1) cat "$CONFIG_DIR/tokens" 2>/dev/null || echo "(无 tokens 文件)"; pause ;;
            2)
                while true; do
                    read -p "用户名: " U
                    [ -z "$U" ] && break
                    read -p "Token: " T
                    echo "${U}=${T}" >> "$CONFIG_DIR/tokens"
                done
                systemctl restart fp-multiuser.service frps.service
                echo -e "${Green}已添加并重启服务${Font}"; pause ;;
            3)
                cut -d= -f1 "$CONFIG_DIR/tokens" 2>/dev/null || echo "(无)"
                read -p "要删除的用户名: " D
                sed -i "/^$D=/d" "$CONFIG_DIR/tokens"
                systemctl restart fp-multiuser.service frps.service
                echo -e "${Green}已删除并重启服务${Font}"; pause ;;
            0) break ;;
            *) echo -e "${Red}无效输入${Font}" ;;
        esac
    done
}

main_menu() {
    while true; do
        echo -e "\n${Blue}========== FRP 管理主菜单 ==========${Font}"
        echo -e "${Green}1.${Font} frps 管理"
        echo -e "${Green}2.${Font} frpc 管理"
        echo -e "${Green}0.${Font} 退出"
        read -p "请输入选项: " main
        case "$main" in
            1) manage_service_menu "frps" "frps" ;;
            2) manage_service_menu "frpc" "frpc" ;;
            0) exit 0 ;;
            *) echo -e "${Red}无效输入${Font}" ;;
        esac
    done
}

main_menu
