#!/bin/bash
# Alpine-Exclusive Hysteria 2 Installer Script

export LANG=en_US.UTF-8

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

red(){
    echo -e "\033[31m\033[01m$1\033[0m"
}

green(){
    echo -e "\033[32m\033[01m$1\033[0m"
}

yellow(){
    echo -e "\033[33m\033[01m$1\033[0m"
}

# Ensure the user is root
[[ $EUID -ne 0 ]] && red "Error: Please run this script as root." && exit 1

# Check for Alpine Linux
if ! [[ -f /etc/alpine-release ]]; then
    red "This script is designed exclusively for Alpine Linux."
    exit 1
fi

realip(){
    # Use ip.sb for reliability on Alpine
    ip=$(curl -s4m8 ip.sb) || ip=$(curl -s6m8 ip.sb)
}

# Function to create a robust OpenRC service file
create_openrc_service() {
    green "Creating OpenRC service file for hysteria-server..."
    cat << EOF > /etc/init.d/hysteria-server
#!/sbin/openrc-run

description="Hysteria 2 is a feature-packed proxy & relay tool built for poor network conditions."
pidfile="/run/\${RC_SVCNAME}.pid"
command="/usr/local/bin/hysteria"
command_args="--config /etc/hysteria/config.yaml server"

depend() {
    need net
    after firewall
}

start() {
    ebegin "Starting hysteria-server"
    start-stop-daemon --start --background \\
        --make-pidfile --pidfile "\${pidfile}" \\
        --exec "\${command}" -- \${command_args}
    eend \$?
}

stop() {
    ebegin "Stopping hysteria-server"
    start-stop-daemon --stop --pidfile "\${pidfile}"
    eend \$?
}
EOF
    chmod +x /etc/init.d/hysteria-server
}

inst_cert(){
    green "Hysteria 2 Certificate Application Method:"
    echo ""
    echo -e " ${GREEN}1.${PLAIN} Use Bing self-signed certificate ${YELLOW}(Default)${PLAIN}"
    echo -e " ${GREEN}2.${PLAIN} Use Acme.sh to apply for a certificate"
    echo -e " ${GREEN}3.${PLAIN} Use custom certificate path"
    echo ""
    read -rp "Please select an option [1-3]: " certInput
    if [[ $certInput == 2 ]]; then
        cert_path="/root/cert.crt"
        key_path="/root/private.key"

        # Install dependencies for acme.sh
        apk add curl wget sudo socat openssl openssh-client dig
        
        # Check for existing certificate
        if [[ -f /root/cert.crt && -f /root/private.key ]] && [[ -s /root/cert.crt && -s /root/private.key ]] && [[ -f /root/ca.log ]]; then
            domain=$(cat /root/ca.log)
            green "Detected existing certificate for domain: $domain, applying..."
            hy_domain=$domain
        else
            realip
            
            read -p "Please enter the domain name for the certificate: " domain
            [[ -z $domain ]] && red "Domain not entered, aborting!" && exit 1
            green "Domain entered: $domain" && sleep 1
            domainIP=$(dig +short "$domain" @8.8.8.8)
            
            if [[ -z $domainIP ]]; then
                red "Could not resolve domain IP. Please check your domain." && exit 1
            fi

            if [[ "$domainIP" == "$ip" ]]; then
                # Install and run acme.sh
                curl https://get.acme.sh | sh -s email=$(date +%s%N | md5sum | cut -c 1-16)@gmail.com
                source ~/.bashrc
                bash ~/.acme.sh/acme.sh --upgrade --auto-upgrade
                bash ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
                
                # Issue certificate
                if [[ -n $(echo $ip | grep ":") ]]; then
                    bash ~/.acme.sh/acme.sh --issue -d "${domain}" --standalone -k ec-256 --listen-v6 --insecure
                else
                    bash ~/.acme.sh/acme.sh --issue -d "${domain}" --standalone -k ec-256 --insecure
                fi
                
                # Install certificate
                bash ~/.acme.sh/acme.sh --install-cert -d "${domain}" --key-file /root/private.key --fullchain-file /root/cert.crt --ecc
                if [[ -f /root/cert.crt && -s /root/cert.crt ]]; then
                    echo "$domain" > /root/ca.log
                    # Add cron job using Alpine's crond
                    (crontab -l 2>/dev/null; echo "0 0 * * * root bash /root/.acme.sh/acme.sh --cron -f >/dev/null 2>&1") | crontab -
                    rc-service crond start
                    rc-update add crond default
                    green "Certificate applied successfully!"
                    yellow "Certificate path: /root/cert.crt"
                    yellow "Private key path: /root/private.key"
                    hy_domain=$domain
                else
                    red "Certificate application failed."
                    exit 1
                fi
            else
                red "The IP resolved from the domain ($domainIP) does not match the server's public IP ($ip)."
                exit 1
            fi
        fi
    elif [[ $certInput == 3 ]]; then
        read -p "Enter the path to your certificate (crt file): " cert_path
        read -p "Enter the path to your private key (key file): " key_path
        read -p "Enter the domain name for the certificate: " domain
        [[ -z "$cert_path" || -z "$key_path" || -z "$domain" ]] && red "Paths or domain cannot be empty." && exit 1
        yellow "Certificate path: $cert_path"
        yellow "Key path: $key_path"
        yellow "Domain: $domain"
        hy_domain=$domain
    else
        green "Using self-signed certificate."
        cert_path="/etc/hysteria/cert.crt"
        key_path="/etc/hysteria/private.key"
        apk add openssl
        openssl ecparam -genkey -name prime256v1 -out "$key_path"
        openssl req -new -x509 -days 36500 -key "$key_path" -out "$cert_path" -subj "/CN=www.bing.com"
        chmod 644 "$cert_path"
        chmod 600 "$key_path"
        hy_domain="www.bing.com"
        domain="www.bing.com"
    fi
}

inst_port(){
    read -p "Set Hysteria 2 port [1-65535] (Enter for random): " port
    [[ -z $port ]] && port=$(shuf -i 2000-65535 -n 1)
    # Check if port is in use
    until ! ss -tulpn | grep -q ":$port " ; do
        red "Port $port is already in use, please choose another."
        read -p "Set Hysteria 2 port [1-65535] (Enter for random): " port
        [[ -z $port ]] && port=$(shuf -i 2000-65535 -n 1)
    done
    yellow "Hysteria 2 will use port: $port"
}

inst_pwd(){
    read -p "Set Hysteria 2 password (Enter for random): " auth_pwd
    [[ -z $auth_pwd ]] && auth_pwd=$(head -c 16 /dev/urandom | base64)
    yellow "Hysteria 2 password: $auth_pwd"
}

inst_site(){
    read -rp "Enter the masquerade website (without https://) [Enter for maimai.sega.jp]: " proxysite
    [[ -z $proxysite ]] && proxysite="maimai.sega.jp"
    yellow "Hysteria 2 will masquerade as: $proxysite"
}

insthysteria(){
    realip
    
    # Install necessary packages for Alpine
    green "Installing dependencies for Alpine Linux..."
    apk update
    apk add curl wget sudo qrencode procps iptables
    
    # Download and run the official installer
    wget -N https://raw.githubusercontent.com/Misaka-blog/hysteria-install/main/hy2/install_server.sh
    bash install_server.sh
    rm -f install_server.sh

    if [[ ! -f "/usr/local/bin/hysteria" ]]; then
        red "Hysteria 2 core installation failed!"
        exit 1
    fi
    green "Hysteria 2 core installed successfully!"

    # Create the service file
    create_openrc_service

    # Ask user for Hysteria configuration
    inst_cert
    inst_port
    inst_pwd
    inst_site

    # Create Hysteria config file
    green "Writing Hysteria configuration..."
    cat << EOF > /etc/hysteria/config.yaml
listen: :$port

tls:
  cert: $cert_path
  key: $key_path

auth:
  type: password
  password: $auth_pwd

masquerade:
  type: proxy
  proxy:
    url: https://$proxysite
    rewriteHost: true
EOF

    # Prepare client configs
    last_port=$port
    last_ip=$ip
    if [[ -n $(echo $ip | grep ":") ]]; then
        last_ip="[$ip]"
    fi

    mkdir -p /root/hy
    url="hysteria2://$auth_pwd@$last_ip:$last_port/?insecure=1&sni=$hy_domain#Alpine-Hysteria2"
    echo "$url" > /root/hy/url.txt
    
    # Start and enable the service using OpenRC
    starthysteria
    
    if rc-service hysteria-server status | grep -q "started"; then
        green "Hysteria 2 service started successfully."
    else
        red "Hysteria 2 service failed to start. Please check status with 'rc-service hysteria-server status' and logs."
        exit 1
    fi
    red "======================================================================================"
    green "Hysteria 2 proxy service is installed and running."
    yellow "Client share link is saved to /root/hy/url.txt"
    green "Share Link:"
    red "$(cat /root/hy/url.txt)"
    echo ""
    yellow "You can view the link again later with 'cat /root/hy/url.txt'"
}

unsthysteria(){
    green "Uninstalling Hysteria 2..."
    stophysteria
    rc-update del hysteria-server default 2>/dev/null
    rm -f /etc/init.d/hysteria-server
    rm -rf /usr/local/bin/hysteria /etc/hysteria /root/hy
    green "Hysteria 2 has been completely uninstalled."
}

starthysteria(){
    green "Starting Hysteria 2 service..."
    rc-service hysteria-server start
    rc-update add hysteria-server default
}

stophysteria(){
    green "Stopping Hysteria 2 service..."
    rc-service hysteria-server stop
}

restarthysteria(){
    green "Restarting Hysteria 2 service..."
    rc-service hysteria-server restart
}

showstatus(){
    rc-service hysteria-server status
}

manageservice() {
    clear
    echo "Hysteria 2 Service Management (Alpine/OpenRC)"
    echo "----------------------------------------"
    echo -e " ${GREEN}1.${PLAIN} Start Hysteria 2"
    echo -e " ${GREEN}2.${PLAIN} Stop Hysteria 2"
    echo -e " ${GREEN}3.${PLAIN} Restart Hysteria 2"
    echo -e " ${GREEN}4.${PLAIN} Show Service Status"
    echo "----------------------------------------"
    read -rp "Please enter an option [1-4]: " action
    case $action in
        1) starthysteria ;;
        2) stophysteria ;;
        3) restarthysteria ;;
        4) showstatus ;;
        *) red "Invalid option" ;;
    esac
}

update_core(){
    green "Updating Hysteria 2 core..."
    wget -N https://raw.githubusercontent.com/Misaka-blog/hysteria-install/main/hy2/install_server.sh
    bash install_server.sh
    rm -f install_server.sh
    restarthysteria
    green "Hysteria 2 core updated and service restarted."
}

menu() {
    clear
    echo "#############################################################"
    echo -e "#         ${GREEN}Hysteria 2 Alpine-Exclusive Installer${PLAIN}           #"
    echo "#############################################################"
    echo ""
    echo -e " ${GREEN}1.${PLAIN} Install Hysteria 2"
    echo -e " ${GREEN}2.${PLAIN} ${RED}Uninstall Hysteria 2${PLAIN}"
    echo " -------------"
    echo -e " ${GREEN}3.${PLAIN} Manage Hysteria 2 Service"
    echo -e " ${GREEN}4.${PLAIN} Update Hysteria 2 Core"
    echo " -------------"
    echo -e " ${GREEN}0.${PLAIN} Exit Script"
    echo ""
    read -rp "Please enter an option [0-4]: " menuInput
    case $menuInput in
        1) insthysteria ;;
        2) unsthysteria ;;
        3) manageservice ;;
        4) update_core ;;
        *) exit 0 ;;
    esac
}

menu
