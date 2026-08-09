#!/bin/bash

# 检查 root
if [ "$EUID" -ne 0 ]; then
    echo "请使用 root 用户运行"
    exit 1
fi

URL="https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh"
SCRIPT="/tmp/reinstall.sh"

echo "正在下载 reinstall.sh..."

curl -L "$URL" -o "$SCRIPT"

if [ ! -s "$SCRIPT" ]; then
    echo "下载失败"
    exit 1
fi

chmod +x "$SCRIPT"

clear

echo "=============================="
echo "      Linux DD 重装系统"
echo "=============================="
echo
echo "请选择系统:"
echo
echo "1) Debian"
echo "2) Alpine"
echo "3) Ubuntu"
echo "4) CentOS"
echo "5) FNOS"
echo "6) openSUSE"
echo "7) openEuler"
echo "0) 退出"
echo

read -p "请输入选项: " OS


case $OS in

# Debian
1)
clear
echo "Debian版本:"
echo "1) Debian 13"
echo "2) Debian 12"
echo "3) Debian 11"
echo "4) Debian 10"
echo "5) Debian 9"

read -p "选择: " VER

case $VER in
1) bash "$SCRIPT" debian 13 ;;
2) bash "$SCRIPT" debian 12 ;;
3) bash "$SCRIPT" debian 11 ;;
4) bash "$SCRIPT" debian 10 ;;
5) bash "$SCRIPT" debian 9 ;;
*) echo "错误选择" ;;
esac
;;


# Alpine
2)
clear
echo "Alpine版本:"
echo "1) Alpine 3.24"
echo "2) Alpine 3.23"
echo "3) Alpine 3.22"
echo "4) Alpine 3.21"

read -p "选择: " VER

case $VER in
1) bash "$SCRIPT" alpine 3.24 ;;
2) bash "$SCRIPT" alpine 3.23 ;;
3) bash "$SCRIPT" alpine 3.22 ;;
4) bash "$SCRIPT" alpine 3.21 ;;
*) echo "错误选择" ;;
esac
;;


# Ubuntu
3)
clear
echo "Ubuntu版本:"
echo "1) Ubuntu 26.04"
echo "2) Ubuntu 24.04"
echo "3) Ubuntu 22.04"
echo "4) Ubuntu 20.04"
echo "5) Ubuntu 18.04"
echo "6) Ubuntu 24.04 Minimal"

read -p "选择: " VER

case $VER in
1) bash "$SCRIPT" ubuntu 26.04 ;;
2) bash "$SCRIPT" ubuntu 24.04 ;;
3) bash "$SCRIPT" ubuntu 22.04 ;;
4) bash "$SCRIPT" ubuntu 20.04 ;;
5) bash "$SCRIPT" ubuntu 18.04 ;;
6) bash "$SCRIPT" ubuntu 24.04 --minimal ;;
*) echo "错误选择" ;;
esac
;;


# CentOS
4)
clear
echo "CentOS版本:"
echo "1) CentOS 10"
echo "2) CentOS 9"

read -p "选择: " VER

case $VER in
1) bash "$SCRIPT" centos 10 ;;
2) bash "$SCRIPT" centos 9 ;;
*) echo "错误选择" ;;
esac
;;


# FNOS
5)
bash "$SCRIPT" fnos 1
;;


# openSUSE
6)
clear
echo "openSUSE版本:"
echo "1) Tumbleweed"
echo "2) 16.0"

read -p "选择: " VER

case $VER in
1) bash "$SCRIPT" opensuse tumbleweed ;;
2) bash "$SCRIPT" opensuse 16.0 ;;
*) echo "错误选择" ;;
esac
;;


# openEuler
7)
clear
echo "openEuler版本:"
echo "1) 24.03"
echo "2) 22.03"
echo "3) 20.03"

read -p "选择: " VER

case $VER in
1) bash "$SCRIPT" openeuler 24.03 ;;
2) bash "$SCRIPT" openeuler 22.03 ;;
3) bash "$SCRIPT" openeuler 20.03 ;;
*) echo "错误选择" ;;
esac
;;


0)
exit 0
;;

*)
echo "无效选择"
;;

esac
