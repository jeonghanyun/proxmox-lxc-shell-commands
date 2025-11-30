#!/usr/bin/env bash

# ISPConfig 3 LXC Installation Script
# Description: Automated installation of ISPConfig 3 Web Hosting Control Panel
# OS: Debian 12 (Bookworm) - Auto-detected latest version
# Ports: Web Panel: 8080, HTTP: 80, HTTPS: 443, SMTP: 25, IMAP: 143, POP3: 110
# Repository: https://github.com/jeonghanyun/proxmox-lxc-shell-commands
# Last Updated: 2025-12-01

set -euo pipefail

#################################################################
# Configuration Variables
#################################################################

# Container Configuration
CT_ID=${CT_ID:-210}                                    # Container ID
CT_HOSTNAME=${CT_HOSTNAME:-"ispconfig"}                # Container hostname
CT_CORES=${CT_CORES:-2}                                # CPU cores
CT_MEMORY=${CT_MEMORY:-2048}                           # RAM in MB (2GB recommended)
CT_SWAP=${CT_SWAP:-1024}                               # Swap in MB
CT_DISK_SIZE=${CT_DISK_SIZE:-30}                       # Root disk size in GB

# Network Configuration
CT_IP=${CT_IP:-"dhcp"}                                 # IP address (dhcp or static like 192.168.1.100/24)
CT_GATEWAY=${CT_GATEWAY:-""}                           # Gateway (required for static IP)
CT_BRIDGE=${CT_BRIDGE:-"vmbr0"}                        # Network bridge
CT_NAMESERVER=${CT_NAMESERVER:-"8.8.8.8"}             # DNS server

# Storage Configuration
CT_STORAGE=${CT_STORAGE:-"local-lvm"}                  # Storage pool for container
TEMPLATE_STORAGE=${TEMPLATE_STORAGE:-"local"}          # Storage pool for templates

# Debian Template (will be auto-detected)
DEBIAN_VERSION="12"                                     # Debian version
TEMPLATE_NAME=""                                        # Auto-detected

# ISPConfig Configuration
ISPCONFIG_VERSION=${ISPCONFIG_VERSION:-"3.2.12"}       # ISPConfig version
ISPCONFIG_PORT=${ISPCONFIG_PORT:-8080}                 # ISPConfig web panel port
MYSQL_ROOT_PASS=${MYSQL_ROOT_PASS:-"$(openssl rand -base64 16)"}
ISPCONFIG_ADMIN_PASS=${ISPCONFIG_ADMIN_PASS:-"$(openssl rand -base64 12)"}

# Mail Domain (for postfix)
MAIL_DOMAIN=${MAIL_DOMAIN:-"local.domain"}

# Container Options
CT_ONBOOT=${CT_ONBOOT:-1}                              # Start on boot (1=yes, 0=no)
CT_UNPRIVILEGED=${CT_UNPRIVILEGED:-1}                  # Unprivileged container (1=yes, 0=no)
CT_FEATURES=${CT_FEATURES:-"keyctl=1,nesting=1"}       # Container features

#################################################################
# Color Output Functions
#################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[⚠]${NC} $1"
}

error() {
    echo -e "${RED}[✗]${NC} $1"
}

progress() {
    echo -e "${MAGENTA}[⏳]${NC} $1"
}

#################################################################
# Cleanup and Rollback Functions
#################################################################

cleanup_on_failure() {
    local step=$1
    error "Installation failed at step: $step"

    if pct status "$CT_ID" &> /dev/null; then
        warn "Container $CT_ID exists. Options:"
        echo "  1. Keep for debugging: pct enter $CT_ID"
        echo "  2. Remove and retry: pct stop $CT_ID && pct destroy $CT_ID"
        read -p "Remove container now? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            info "Removing container $CT_ID..."
            pct stop "$CT_ID" 2>/dev/null || true
            pct destroy "$CT_ID" 2>/dev/null || true
            success "Container removed"
        fi
    fi
    exit 1
}

#################################################################
# Validation Functions
#################################################################

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
}

check_proxmox() {
    if ! command -v pct &> /dev/null; then
        error "This script must be run on a Proxmox VE host"
        exit 1
    fi
}

check_container_exists() {
    if pct status "$CT_ID" &> /dev/null; then
        error "Container ID $CT_ID already exists"
        info "Please choose a different CT_ID or remove the existing container"
        exit 1
    fi
}

detect_and_download_template() {
    info "Updating template database..."

    if ! pveam update 2>&1 | grep -q "update successful\|already up to date"; then
        warn "Template database update encountered issues, continuing anyway..."
    fi

    info "Detecting available Debian ${DEBIAN_VERSION} template..."

    local available_template
    available_template=$(pveam available --section system 2>/dev/null | grep "debian-${DEBIAN_VERSION}" | grep "standard" | tail -1 | awk '{print $2}')

    if [[ -z "$available_template" ]]; then
        error "No Debian ${DEBIAN_VERSION} template found in available templates"
        info "Troubleshooting steps:"
        info "  1. Check DNS configuration: cat /etc/resolv.conf"
        info "  2. Test connectivity: ping -c 3 download.proxmox.com"
        info "  3. Manual check: pveam available --section system | grep debian"
        exit 1
    fi

    TEMPLATE_NAME="$available_template"
    info "Found template: $TEMPLATE_NAME"

    if pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$TEMPLATE_NAME"; then
        success "Template already downloaded"
        return 0
    fi

    progress "Downloading Debian template (this may take a few minutes)..."
    if pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME" 2>&1; then
        success "Template downloaded successfully"
    else
        error "Failed to download template"
        exit 1
    fi
}

#################################################################
# Container Creation Functions
#################################################################

create_container() {
    info "Creating LXC container $CT_ID ($CT_HOSTNAME)..."

    local net_config="name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP}"

    if [[ "$CT_IP" != "dhcp" ]] && [[ -n "$CT_GATEWAY" ]]; then
        net_config="${net_config},gw=${CT_GATEWAY}"
    fi

    pct create "$CT_ID" \
        "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_NAME}" \
        --hostname "$CT_HOSTNAME" \
        --cores "$CT_CORES" \
        --memory "$CT_MEMORY" \
        --swap "$CT_SWAP" \
        --rootfs "${CT_STORAGE}:${CT_DISK_SIZE}" \
        --net0 "$net_config" \
        --nameserver "$CT_NAMESERVER" \
        --onboot "$CT_ONBOOT" \
        --unprivileged "$CT_UNPRIVILEGED" \
        --features "$CT_FEATURES" \
        --ostype debian || cleanup_on_failure "container creation"

    success "Container $CT_ID created successfully"
}

start_container() {
    info "Starting container $CT_ID..."
    pct start "$CT_ID" || cleanup_on_failure "container start"

    progress "Waiting for container to boot..."
    local max_wait=30
    local count=0

    while ! pct exec "$CT_ID" -- test -f /var/lib/dpkg/status 2>/dev/null; do
        sleep 1
        count=$((count + 1))
        if [[ $count -ge $max_wait ]]; then
            error "Container failed to boot in ${max_wait}s"
            cleanup_on_failure "container boot"
        fi
    done

    success "Container started successfully"
}

configure_autologin() {
    info "Configuring automatic console login..."

    pct exec "$CT_ID" -- bash -c "mkdir -p /etc/systemd/system/container-getty@1.service.d"

    pct exec "$CT_ID" -- bash -c 'cat > /etc/systemd/system/container-getty@1.service.d/override.conf << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud tty%I 115200,38400,9600 \$TERM
EOF'

    pct exec "$CT_ID" -- bash -c "systemctl daemon-reload"
    pct exec "$CT_ID" -- bash -c "systemctl restart container-getty@1.service" 2>/dev/null || true

    success "Automatic console login configured"
}

#################################################################
# ISPConfig Installation Functions
#################################################################

install_dependencies() {
    info "Installing system dependencies..."

    progress "Updating package lists..."
    pct exec "$CT_ID" -- bash -c "apt-get update -qq" || cleanup_on_failure "apt-get update"

    progress "Installing base packages..."
    pct exec "$CT_ID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        curl \
        ca-certificates \
        gnupg \
        wget \
        unzip \
        sudo \
        lsb-release \
        apt-transport-https \
        software-properties-common \
        debconf-utils" || cleanup_on_failure "base package installation"

    success "Base dependencies installed"
}

configure_postfix_preseed() {
    info "Pre-configuring Postfix..."

    pct exec "$CT_ID" -- bash -c "debconf-set-selections <<< 'postfix postfix/mailname string ${MAIL_DOMAIN}'"
    pct exec "$CT_ID" -- bash -c "debconf-set-selections <<< 'postfix postfix/main_mailer_type select Internet Site'"

    success "Postfix pre-configured"
}

install_lamp_stack() {
    info "Installing LAMP stack and mail services..."

    # Configure Postfix first
    configure_postfix_preseed

    # Install MariaDB
    progress "Installing MariaDB..."
    pct exec "$CT_ID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mariadb-server mariadb-client" || cleanup_on_failure "MariaDB installation"

    # Install Apache
    progress "Installing Apache..."
    pct exec "$CT_ID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq apache2 apache2-utils" || cleanup_on_failure "Apache installation"

    # Install PHP and modules
    progress "Installing PHP and extensions..."
    pct exec "$CT_ID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        php \
        php-cli \
        php-fpm \
        php-mysql \
        php-gd \
        php-curl \
        php-mbstring \
        php-xml \
        php-zip \
        php-intl \
        php-soap \
        php-imap \
        libapache2-mod-php" || cleanup_on_failure "PHP installation"

    # Install mail services
    progress "Installing mail services (Postfix, Dovecot)..."
    pct exec "$CT_ID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        postfix \
        postfix-mysql \
        dovecot-core \
        dovecot-imapd \
        dovecot-pop3d \
        dovecot-mysql \
        dovecot-lmtpd" || cleanup_on_failure "Mail services installation"

    # Install additional services
    progress "Installing additional services..."
    pct exec "$CT_ID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        bind9 \
        pure-ftpd-mysql \
        quota \
        quotatool \
        haveged \
        certbot \
        python3-certbot-apache \
        awstats \
        webalizer \
        fail2ban \
        ufw" || cleanup_on_failure "Additional services installation"

    success "LAMP stack and services installed"
}

configure_mariadb() {
    info "Configuring MariaDB..."

    pct exec "$CT_ID" -- bash -c "systemctl start mariadb" || cleanup_on_failure "MariaDB start"
    pct exec "$CT_ID" -- bash -c "systemctl enable mariadb" || cleanup_on_failure "MariaDB enable"

    sleep 3

    # Secure MariaDB installation
    progress "Securing MariaDB..."
    pct exec "$CT_ID" -- bash -c "mysql -e \"ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}';\"" || cleanup_on_failure "MySQL root password"
    pct exec "$CT_ID" -- bash -c "mysql -u root -p'${MYSQL_ROOT_PASS}' -e \"DELETE FROM mysql.user WHERE User='';\"" || true
    pct exec "$CT_ID" -- bash -c "mysql -u root -p'${MYSQL_ROOT_PASS}' -e \"DROP DATABASE IF EXISTS test;\"" || true
    pct exec "$CT_ID" -- bash -c "mysql -u root -p'${MYSQL_ROOT_PASS}' -e \"FLUSH PRIVILEGES;\"" || cleanup_on_failure "MySQL flush privileges"

    success "MariaDB configured"
}

configure_apache() {
    info "Configuring Apache..."

    pct exec "$CT_ID" -- bash -c "a2enmod rewrite headers ssl proxy_fcgi setenvif" || cleanup_on_failure "Apache modules"
    pct exec "$CT_ID" -- bash -c "systemctl restart apache2" || cleanup_on_failure "Apache restart"

    success "Apache configured"
}

install_ispconfig() {
    info "Installing ISPConfig ${ISPCONFIG_VERSION}..."

    # Download ISPConfig
    progress "Downloading ISPConfig..."
    pct exec "$CT_ID" -- bash -c "cd /tmp && wget -q https://www.ispconfig.org/downloads/ISPConfig-${ISPCONFIG_VERSION}.tar.gz" || cleanup_on_failure "ISPConfig download"

    # Extract ISPConfig
    progress "Extracting ISPConfig..."
    pct exec "$CT_ID" -- bash -c "cd /tmp && tar xzf ISPConfig-${ISPCONFIG_VERSION}.tar.gz" || cleanup_on_failure "ISPConfig extraction"

    # Create autoinstall configuration
    progress "Creating auto-install configuration..."
    pct exec "$CT_ID" -- bash -c "cat > /tmp/ispconfig3_install/install/autoinstall.ini << EOF
[install]
language=en
install_mode=standard
hostname=${CT_HOSTNAME}.${MAIL_DOMAIN}
mysql_hostname=localhost
mysql_root_user=root
mysql_root_password=${MYSQL_ROOT_PASS}
mysql_database=dbispconfig
mysql_charset=utf8
http_server=apache
ispconfig_port=${ISPCONFIG_PORT}
ispconfig_use_ssl=y
ispconfig_admin_password=${ISPCONFIG_ADMIN_PASS}
configure_mail=y
configure_jailkit=n
configure_ftp=y
configure_dns=y
configure_apache=y
configure_firewall=y
install_ispconfig_web_interface=y

[ssl_cert]
ssl_cert_country=US
ssl_cert_state=California
ssl_cert_locality=SanFrancisco
ssl_cert_organisation=ISPConfig
ssl_cert_organisation_unit=IT
ssl_cert_common_name=${CT_HOSTNAME}.${MAIL_DOMAIN}
ssl_cert_email=admin@${MAIL_DOMAIN}
EOF"

    # Run ISPConfig installer
    progress "Running ISPConfig installer (this may take several minutes)..."
    pct exec "$CT_ID" -- bash -c "cd /tmp/ispconfig3_install/install && php -q install.php --autoinstall=autoinstall.ini" || cleanup_on_failure "ISPConfig installation"

    # Clean up
    pct exec "$CT_ID" -- bash -c "rm -rf /tmp/ispconfig3_install /tmp/ISPConfig-${ISPCONFIG_VERSION}.tar.gz" || true

    # Fix permissions for ISPConfig interface (required for mod_php)
    progress "Fixing ISPConfig permissions..."
    pct exec "$CT_ID" -- bash -c "chown -R ispconfig:www-data /usr/local/ispconfig/interface/"
    pct exec "$CT_ID" -- bash -c "chmod -R g+r /usr/local/ispconfig/interface/"
    pct exec "$CT_ID" -- bash -c "chmod -R 777 /usr/local/ispconfig/interface/temp"
    pct exec "$CT_ID" -- bash -c "chown -R www-data:www-data /usr/local/ispconfig/interface/temp"
    pct exec "$CT_ID" -- bash -c "chown -R ispconfig:www-data /var/www/ispconfig/"
    pct exec "$CT_ID" -- bash -c "chmod -R g+r /var/www/ispconfig/"

    success "ISPConfig installed successfully"
}

configure_ispconfig_vhost() {
    info "Configuring ISPConfig Apache vhost..."

    # Fix ISPConfig vhost for mod_php (remove fcgid dependency)
    pct exec "$CT_ID" -- bash -c "cat > /etc/apache2/sites-available/ispconfig.vhost << 'VHOSTEOF'
######################################################
# ISPConfig Control Panel Virtual Host
######################################################

Listen 8080

<VirtualHost _default_:8080>
  ServerAdmin webmaster@localhost
  DocumentRoot /var/www/ispconfig/

  <Directory /var/www/ispconfig/>
    Options -Indexes +FollowSymLinks
    AllowOverride All
    Require all granted
  </Directory>

  # SSL Configuration
  SSLEngine On
  SSLProtocol All -SSLv3 -TLSv1 -TLSv1.1
  SSLCertificateFile /usr/local/ispconfig/interface/ssl/ispserver.crt
  SSLCertificateKeyFile /usr/local/ispconfig/interface/ssl/ispserver.key

  SSLCipherSuite ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384
  SSLHonorCipherOrder On

  <IfModule mod_headers.c>
    Header set Content-Security-Policy \"default-src 'self' 'unsafe-inline' 'unsafe-eval'; img-src 'self' data:; object-src 'none'; upgrade-insecure-requests\"
    Header set X-Content-Type-Options: nosniff
    Header set X-Frame-Options: SAMEORIGIN
    Header set X-XSS-Protection: \"1; mode=block\"
    Header setifempty Strict-Transport-Security \"max-age=15768000\"
  </IfModule>

  ServerSignature Off
</VirtualHost>
VHOSTEOF"

    # Restart Apache to apply changes
    pct exec "$CT_ID" -- bash -c "systemctl restart apache2"

    success "ISPConfig vhost configured"
}

configure_services() {
    info "Configuring and starting services..."

    # Configure ISPConfig vhost first
    configure_ispconfig_vhost

    # Enable and start services
    local services=("apache2" "mariadb" "postfix" "dovecot" "bind9" "pure-ftpd-mysql" "fail2ban")

    for service in "${services[@]}"; do
        pct exec "$CT_ID" -- bash -c "systemctl enable $service" 2>/dev/null || warn "Could not enable $service"
        pct exec "$CT_ID" -- bash -c "systemctl start $service" 2>/dev/null || warn "Could not start $service"
    done

    success "Services configured"
}

add_container_notes() {
    info "Adding container notes with access information..."

    local container_ip
    if [[ "$CT_IP" == "dhcp" ]]; then
        sleep 3
        container_ip=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}')
        if [[ -z "$container_ip" ]]; then
            container_ip="[DHCP - check after boot]"
        fi
    else
        container_ip="${CT_IP%/*}"
    fi

    local notes="ISPCONFIG ${ISPCONFIG_VERSION} - WEB HOSTING CONTROL PANEL
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📋 CONTAINER DETAILS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Container ID:    ${CT_ID}
Hostname:        ${CT_HOSTNAME}
IP Address:      ${container_ip}
CPU Cores:       ${CT_CORES}
Memory:          ${CT_MEMORY}MB
Disk Size:       ${CT_DISK_SIZE}GB

🌐 ISPCONFIG ACCESS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Control Panel:   https://${container_ip}:${ISPCONFIG_PORT}
Admin User:      admin
Admin Password:  ${ISPCONFIG_ADMIN_PASS}

⚠️  IMPORTANT: Change the admin password after first login!

🔑 DATABASE CREDENTIALS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
MySQL Root Pass: ${MYSQL_ROOT_PASS}
ISPConfig DB:    dbispconfig

📧 MAIL SERVICES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SMTP:            Port 25, 587, 465
IMAP:            Port 143, 993
POP3:            Port 110, 995

🔧 SERVICE MANAGEMENT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Apache Status:   pct exec ${CT_ID} -- systemctl status apache2
MariaDB Status:  pct exec ${CT_ID} -- systemctl status mariadb
Postfix Status:  pct exec ${CT_ID} -- systemctl status postfix
Dovecot Status:  pct exec ${CT_ID} -- systemctl status dovecot

📦 CONTAINER MANAGEMENT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Enter:           pct enter ${CT_ID}
Start:           pct start ${CT_ID}
Stop:            pct stop ${CT_ID}
Restart:         pct restart ${CT_ID}
Delete:          pct destroy ${CT_ID}

📁 IMPORTANT PATHS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
ISPConfig Dir:   /usr/local/ispconfig
Websites:        /var/www/clients
Apache Config:   /etc/apache2
Mail Config:     /etc/postfix

💡 NEXT STEPS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
1. Access ISPConfig at https://${container_ip}:${ISPCONFIG_PORT}
2. Accept the self-signed SSL certificate
3. Login with admin credentials above
4. Change admin password in System → CP Users
5. Configure DNS and mail settings
6. Add your first website client

ℹ️  AUTO-GENERATED BY: https://github.com/jeonghanyun/proxmox-lxc-shell-commands"

    if pct set "$CT_ID" -description "$notes" 2>/dev/null; then
        success "Container notes added successfully"
    else
        warn "Failed to add container notes (not critical)"
    fi
}

#################################################################
# Information Display Functions
#################################################################

display_info() {
    local container_ip

    if [[ "$CT_IP" == "dhcp" ]]; then
        container_ip=$(pct exec "$CT_ID" -- hostname -I | awk '{print $1}')
    else
        container_ip="${CT_IP%/*}"
    fi

    echo ""
    echo "================================================================="
    success "ISPConfig ${ISPCONFIG_VERSION} LXC Container Setup Complete!"
    echo "================================================================="
    echo ""
    info "💡 All access information has been saved to container Notes"
    info "   View in Proxmox UI: Select container → Summary → Notes"
    echo ""
    echo "Container Details:"
    echo "  • Container ID:      $CT_ID"
    echo "  • Hostname:          $CT_HOSTNAME"
    echo "  • IP Address:        $container_ip"
    echo "  • CPU Cores:         $CT_CORES"
    echo "  • Memory:            ${CT_MEMORY}MB"
    echo "  • Disk Size:         ${CT_DISK_SIZE}GB"
    echo ""
    echo "ISPConfig Access:"
    echo "  • Control Panel:     https://${container_ip}:${ISPCONFIG_PORT}"
    echo "  • Admin User:        admin"
    echo "  • Admin Password:    $ISPCONFIG_ADMIN_PASS"
    echo ""
    warn "⚠️  IMPORTANT: Change the admin password after first login!"
    echo ""
    echo "Database Credentials:"
    echo "  • MySQL Root Pass:   $MYSQL_ROOT_PASS"
    echo "  • ISPConfig DB:      dbispconfig"
    echo ""
    echo "Services Installed:"
    echo "  • Web Server:        Apache 2"
    echo "  • Database:          MariaDB"
    echo "  • Mail:              Postfix + Dovecot"
    echo "  • DNS:               BIND9"
    echo "  • FTP:               Pure-FTPd"
    echo "  • Security:          Fail2ban"
    echo ""
    echo "Next Steps:"
    echo "  1. Open https://${container_ip}:${ISPCONFIG_PORT} in your browser"
    echo "  2. Accept the self-signed SSL certificate"
    echo "  3. Login with admin credentials"
    echo "  4. Change admin password in System → CP Users"
    echo "  5. Configure your DNS and mail settings"
    echo ""
    echo "================================================================="
}

#################################################################
# Main Execution
#################################################################

main() {
    echo ""
    echo "================================================================="
    info "ISPConfig ${ISPCONFIG_VERSION} LXC Container Installation"
    echo "================================================================="
    echo ""

    # Pre-flight checks
    info "Running pre-flight checks..."
    check_root
    check_proxmox
    check_container_exists
    detect_and_download_template

    # Create and configure container
    info "Creating container infrastructure..."
    create_container
    start_container
    configure_autologin

    # Install and configure services
    info "Installing LAMP stack and services..."
    install_dependencies
    install_lamp_stack
    configure_mariadb
    configure_apache

    # Install ISPConfig
    info "Installing ISPConfig ${ISPCONFIG_VERSION}..."
    install_ispconfig
    configure_services

    # Add container notes
    add_container_notes

    # Display information
    display_info
}

# Run main function
main "$@"
