#!/bin/sh
# /root/openwrt-port-manager.sh
# OpenWrt 端口转发交互式管理（支持开机自启）
# 配置文件
CONFIG_FILE="/etc/port_forward.conf"
# 自动恢复脚本路径
AUTOSTART_SCRIPT="/etc/init.d/port-forward-autostart"

touch $CONFIG_FILE

show_menu() {
    echo "--------------------------"
    echo "OpenWrt 端口转发管理"
    echo "1) 查看现有端口转发"
    echo "2) 添加端口转发"
    echo "3) 修改端口转发"
    echo "4) 删除端口转发"
    echo "5) 设置开机自动恢复"
    echo "6) 退出"
    echo "--------------------------"
    echo -n "请选择操作: "
}

list_forwards() {
    echo "当前端口转发列表:"
    if [ ! -s $CONFIG_FILE ]; then
        echo "无转发规则"
        return
    fi
    nl -w2 -s'. ' $CONFIG_FILE
}

add_forward() {
    echo -n "请输入本地端口: "
    read LOCAL_PORT
    echo -n "请输入目标 IP: "
    read TARGET_IP
    echo -n "请输入目标端口: "
    read TARGET_PORT
    echo -n "协议 (tcp/udp/both): "
    read PROTOCOL

    [ -z "$PROTOCOL" ] && PROTOCOL="both"

    apply_iptables "$LOCAL_PORT" "$TARGET_IP" "$TARGET_PORT" "$PROTOCOL"

    # 保存配置
    echo "$LOCAL_PORT $TARGET_IP $TARGET_PORT $PROTOCOL" >> $CONFIG_FILE
    echo "添加成功!"
}

delete_forward() {
    list_forwards
    echo -n "请输入要删除的规则编号: "
    read NUM
    LINE=$(sed -n "${NUM}p" $CONFIG_FILE)
    if [ -z "$LINE" ]; then
        echo "编号无效"
        return
    fi
    remove_iptables "$LINE"
    sed -i "${NUM}d" $CONFIG_FILE
    echo "删除成功!"
}

modify_forward() {
    list_forwards
    echo -n "请输入要修改的规则编号: "
    read NUM
    LINE=$(sed -n "${NUM}p" $CONFIG_FILE)
    if [ -z "$LINE" ]; then
        echo "编号无效"
        return
    fi
    remove_iptables "$LINE"
    sed -i "${NUM}d" $CONFIG_FILE
    echo "请输入新规则信息:"
    add_forward
}

apply_iptables() {
    LOCAL_PORT=$1
    TARGET_IP=$2
    TARGET_PORT=$3
    PROTOCOL=$4

    case "$PROTOCOL" in
        tcp)
            iptables -t nat -A PREROUTING -p tcp --dport $LOCAL_PORT -j DNAT --to-destination $TARGET_IP:$TARGET_PORT
            iptables -t nat -A POSTROUTING -p tcp -d $TARGET_IP --dport $TARGET_PORT -j MASQUERADE
            ;;
        udp)
            iptables -t nat -A PREROUTING -p udp --dport $LOCAL_PORT -j DNAT --to-destination $TARGET_IP:$TARGET_PORT
            iptables -t nat -A POSTROUTING -p udp -d $TARGET_IP --dport $TARGET_PORT -j MASQUERADE
            ;;
        both)
            iptables -t nat -A PREROUTING -p tcp --dport $LOCAL_PORT -j DNAT --to-destination $TARGET_IP:$TARGET_PORT
            iptables -t nat -A POSTROUTING -p tcp -d $TARGET_IP --dport $TARGET_PORT -j MASQUERADE
            iptables -t nat -A PREROUTING -p udp --dport $LOCAL_PORT -j DNAT --to-destination $TARGET_IP:$TARGET_PORT
            iptables -t nat -A POSTROUTING -p udp -d $TARGET_IP --dport $TARGET_PORT -j MASQUERADE
            ;;
    esac
}

remove_iptables() {
    LINE="$1"
    LOCAL_PORT=$(echo $LINE | awk '{print $1}')
    TARGET_IP=$(echo $LINE | awk '{print $2}')
    TARGET_PORT=$(echo $LINE | awk '{print $3}')
    PROTOCOL=$(echo $LINE | awk '{print $4}')

    case "$PROTOCOL" in
        tcp)
            iptables -t nat -D PREROUTING -p tcp --dport $LOCAL_PORT -j DNAT --to-destination $TARGET_IP:$TARGET_PORT
            iptables -t nat -D POSTROUTING -p tcp -d $TARGET_IP --dport $TARGET_PORT -j MASQUERADE
            ;;
        udp)
            iptables -t nat -D PREROUTING -p udp --dport $LOCAL_PORT -j DNAT --to-destination $TARGET_IP:$TARGET_PORT
            iptables -t nat -D POSTROUTING -p udp -d $TARGET_IP --dport $TARGET_PORT -j MASQUERADE
            ;;
        both)
            iptables -t nat -D PREROUTING -p tcp --dport $LOCAL_PORT -j DNAT --to-destination $TARGET_IP:$TARGET_PORT
            iptables -t nat -D POSTROUTING -p tcp -d $TARGET_IP --dport $TARGET_PORT -j MASQUERADE
            iptables -t nat -D PREROUTING -p udp --dport $LOCAL_PORT -j DNAT --to-destination $TARGET_IP:$TARGET_PORT
            iptables -t nat -D POSTROUTING -p udp -d $TARGET_IP --dport $TARGET_PORT -j MASQUERADE
            ;;
    esac
}

setup_autostart() {
    echo "创建开机自动恢复脚本..."
    cat <<EOF > $AUTOSTART_SCRIPT
#!/bin/sh /etc/rc.common
START=99
start() {
    echo 1 > /proc/sys/net/ipv4/ip_forward
    if [ -f "$CONFIG_FILE" ]; then
        while read LINE; do
            LOCAL_PORT=\$(echo \$LINE | awk '{print \$1}')
            TARGET_IP=\$(echo \$LINE | awk '{print \$2}')
            TARGET_PORT=\$(echo \$LINE | awk '{print \$3}')
            PROTOCOL=\$(echo \$LINE | awk '{print \$4}')
            case "\$PROTOCOL" in
                tcp)
                    iptables -t nat -A PREROUTING -p tcp --dport \$LOCAL_PORT -j DNAT --to-destination \$TARGET_IP:\$TARGET_PORT
                    iptables -t nat -A POSTROUTING -p tcp -d \$TARGET_IP --dport \$TARGET_PORT -j MASQUERADE
                    ;;
                udp)
                    iptables -t nat -A PREROUTING -p udp --dport \$LOCAL_PORT -j DNAT --to-destination \$TARGET_IP:\$TARGET_PORT
                    iptables -t nat -A POSTROUTING -p udp -d \$TARGET_IP --dport \$TARGET_PORT -j MASQUERADE
                    ;;
                both)
                    iptables -t nat -A PREROUTING -p tcp --dport \$LOCAL_PORT -j DNAT --to-destination \$TARGET_IP:\$TARGET_PORT
                    iptables -t nat -A POSTROUTING -p tcp -d \$TARGET_IP --dport \$TARGET_PORT -j MASQUERADE
                    iptables -t nat -A PREROUTING -p udp --dport \$LOCAL_PORT -j DNAT --to-destination \$TARGET_IP:\$TARGET_PORT
                    iptables -t nat -A POSTROUTING -p udp -d \$TARGET_IP --dport \$TARGET_PORT -j MASQUERADE
                    ;;
            esac
        done < "$CONFIG_FILE"
    fi
}
EOF
    chmod +x $AUTOSTART_SCRIPT
    /etc/init.d/port-forward-autostart enable
    echo "开机自动恢复已设置完成"
}

# 主循环
while true; do
    show_menu
    read CHOICE
    case $CHOICE in
        1) list_forwards ;;
        2) add_forward ;;
        3) modify_forward ;;
        4) delete_forward ;;
        5) setup_autostart ;;
        6) exit 0 ;;
        *) echo "无效选项" ;;
    esac
done
