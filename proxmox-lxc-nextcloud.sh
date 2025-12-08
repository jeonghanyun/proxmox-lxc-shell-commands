#!/usr/bin/env bash

# Nextcloud LXC Installation Script
# Description: Automated installation of latest Nextcloud with PHP 8.3, MariaDB, and Redis
# OS: Debian 12 (Bookworm) - Auto-detected latest version
# Nextcloud Version: 32.0.1 (Hub 25 Autumn) - Latest as of Nov 2025
# Ports: Web: 80, HTTPS: 443
# Repository: https://github.com/jeonghanyun/proxmox-lxc-shell-commands
# Last Updated: 2025-12-02
#
# OPcache Settings (optimized for Nextcloud):
#   - memory_consumption: 1024MB
#   - interned_strings_buffer: 512MB
#   - JIT enabled with 128MB buffer
# Recommended: CT_MEMORY=4096 or higher for production use
#
# Notes:
#   - AppAPI is auto-disabled due to Docker API version incompatibility
#     (AppAPI requires Docker API v1.41, but Docker 29+ requires v1.44+)
#   - HSTS header is enabled by default for security

set -euo pipefail

#################################################################
# Configuration Variables
#################################################################

# Container Configuration
CT_ID=${CT_ID:-202}                                    # Container ID
CT_HOSTNAME=${CT_HOSTNAME:-"nextcloud"}                # Container hostname
CT_CORES=${CT_CORES:-2}                                # CPU cores
CT_MEMORY=${CT_MEMORY:-4096}                           # RAM in MB (4GB recommended for OPcache settings)
CT_SWAP=${CT_SWAP:-1024}                               # Swap in MB
CT_DISK_SIZE=${CT_DISK_SIZE:-20}                       # Root disk size in GB

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

# Nextcloud Configuration
NEXTCLOUD_VERSION=${NEXTCLOUD_VERSION:-"32.0.1"}       # Nextcloud version
NEXTCLOUD_ADMIN_USER=${NEXTCLOUD_ADMIN_USER:-"admin"}
NEXTCLOUD_ADMIN_PASS=${NEXTCLOUD_ADMIN_PASS:-"$(openssl rand -base64 16)"}
NEXTCLOUD_DB_NAME="nextcloud"
NEXTCLOUD_DB_USER="nextcloud"
NEXTCLOUD_DB_PASS=${NEXTCLOUD_DB_PASS:-"$(openssl rand -base64 16)"}
NEXTCLOUD_DATA_DIR="/var/www/nextcloud/data"

# PHP Configuration
PHP_VERSION="8.3"                                       # Recommended for Nextcloud 32

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

    # Update template list first (best practice)
    if ! pveam update 2>&1 | grep -q "update successful\|already up to date"; then
        warn "Template database update encountered issues, continuing anyway..."
    fi

    info "Detecting available Debian ${DEBIAN_VERSION} template..."

    # Get latest Debian template for the specified version
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

    # Check if already downloaded
    if pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$TEMPLATE_NAME"; then
        success "Template already downloaded"
        return 0
    fi

    # Download template
    progress "Downloading Debian template (this may take a few minutes)..."
    if pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME" 2>&1; then
        success "Template downloaded successfully"
    else
        error "Failed to download template"
        info "Common fixes:"
        info "  1. Add DNS server: echo 'nameserver 8.8.8.8' >> /etc/resolv.conf"
        info "  2. Check internet: curl -I https://download.proxmox.com"
        info "  3. Check storage: df -h"
        exit 1
    fi
}

#################################################################
# Container Creation Functions
#################################################################

create_container() {
    info "Creating LXC container $CT_ID ($CT_HOSTNAME)..."

    local net_config="name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP}"

    # Add gateway if static IP is used
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

    # Wait for container to be ready
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

    # Create systemd override directory for container-getty
    pct exec "$CT_ID" -- bash -c "mkdir -p /etc/systemd/system/container-getty@1.service.d"

    # Create autologin override configuration
    pct exec "$CT_ID" -- bash -c 'cat > /etc/systemd/system/container-getty@1.service.d/override.conf << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud tty%I 115200,38400,9600 \$TERM
EOF'

    # Reload systemd and restart getty service
    pct exec "$CT_ID" -- bash -c "systemctl daemon-reload"
    pct exec "$CT_ID" -- bash -c "systemctl restart container-getty@1.service" 2>/dev/null || true

    success "Automatic console login configured"
}

#################################################################
# Nextcloud Installation Functions
#################################################################

install_dependencies() {
    info "Installing system dependencies..."

    # Update package list
    progress "Updating package lists..."
    pct exec "$CT_ID" -- bash -c "apt-get update -qq" || cleanup_on_failure "apt-get update"

    # Install base packages
    progress "Installing base packages..."
    pct exec "$CT_ID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        curl \
        ca-certificates \
        gnupg \
        wget \
        unzip \
        sudo \
        lsb-release \
        apt-transport-https" || cleanup_on_failure "base package installation"

    # Add Sury PHP repository for PHP 8.3
    progress "Adding PHP 8.3 repository..."
    pct exec "$CT_ID" -- bash -c "curl -sSLo /tmp/debsuryorg-archive-keyring.deb https://packages.sury.org/debsuryorg-archive-keyring.deb" || cleanup_on_failure "PHP repo key download"
    pct exec "$CT_ID" -- bash -c "dpkg -i /tmp/debsuryorg-archive-keyring.deb" || cleanup_on_failure "PHP repo key install"
    pct exec "$CT_ID" -- bash -c "echo 'deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ bookworm main' > /etc/apt/sources.list.d/sury-php.list" || cleanup_on_failure "PHP repo setup"
    pct exec "$CT_ID" -- bash -c "apt-get update -qq" || cleanup_on_failure "apt-get update after PHP repo"

    # Install Apache, MariaDB, and PHP 8.3 with required modules
    progress "Installing Apache, MariaDB, Redis, and PHP ${PHP_VERSION} (this may take a few minutes)..."
    pct exec "$CT_ID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        apache2 \
        mariadb-server \
        redis-server \
        php${PHP_VERSION} \
        php${PHP_VERSION}-fpm \
        php${PHP_VERSION}-gd \
        php${PHP_VERSION}-mysql \
        php${PHP_VERSION}-curl \
        php${PHP_VERSION}-mbstring \
        php${PHP_VERSION}-intl \
        php${PHP_VERSION}-gmp \
        php${PHP_VERSION}-bcmath \
        php${PHP_VERSION}-xml \
        php${PHP_VERSION}-zip \
        php${PHP_VERSION}-redis \
        php${PHP_VERSION}-imagick \
        php${PHP_VERSION}-apcu \
        libapache2-mod-php${PHP_VERSION}" || cleanup_on_failure "LAMP stack installation"

    success "Dependencies installed successfully"
}

configure_mariadb() {
    info "Configuring MariaDB database..."

    # Start and enable MariaDB
    pct exec "$CT_ID" -- bash -c "systemctl start mariadb" || cleanup_on_failure "MariaDB start"
    pct exec "$CT_ID" -- bash -c "systemctl enable mariadb" || cleanup_on_failure "MariaDB enable"

    sleep 3

    # Create database and user
    progress "Creating Nextcloud database and user..."
    pct exec "$CT_ID" -- bash -c "mysql -e \"CREATE DATABASE ${NEXTCLOUD_DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;\"" || cleanup_on_failure "database creation"
    pct exec "$CT_ID" -- bash -c "mysql -e \"CREATE USER '${NEXTCLOUD_DB_USER}'@'localhost' IDENTIFIED BY '${NEXTCLOUD_DB_PASS}';\"" || cleanup_on_failure "database user creation"
    pct exec "$CT_ID" -- bash -c "mysql -e \"GRANT ALL PRIVILEGES ON ${NEXTCLOUD_DB_NAME}.* TO '${NEXTCLOUD_DB_USER}'@'localhost';\"" || cleanup_on_failure "database privileges"
    pct exec "$CT_ID" -- bash -c "mysql -e \"FLUSH PRIVILEGES;\"" || cleanup_on_failure "database flush privileges"

    # Configure MariaDB for Nextcloud (READ COMMITTED transaction isolation)
    progress "Configuring MariaDB settings for Nextcloud..."
    pct exec "$CT_ID" -- bash -c "cat >> /etc/mysql/mariadb.conf.d/50-server.cnf" <<'EOF'

# Nextcloud Optimizations
innodb_buffer_pool_size = 512M
innodb_io_capacity = 4000
transaction-isolation = READ-COMMITTED
binlog_format = ROW
EOF

    pct exec "$CT_ID" -- bash -c "systemctl restart mariadb" || cleanup_on_failure "MariaDB restart"
    sleep 3

    success "MariaDB configured successfully"
}

configure_redis() {
    info "Configuring Redis for file locking..."

    # Start and enable Redis
    pct exec "$CT_ID" -- bash -c "systemctl start redis-server" || cleanup_on_failure "Redis start"
    pct exec "$CT_ID" -- bash -c "systemctl enable redis-server" || cleanup_on_failure "Redis enable"

    success "Redis configured successfully"
}

configure_php() {
    info "Configuring PHP ${PHP_VERSION} settings..."

    # Optimize PHP settings for Nextcloud
    pct exec "$CT_ID" -- bash -c "sed -i 's/memory_limit = .*/memory_limit = 512M/' /etc/php/${PHP_VERSION}/apache2/php.ini"
    pct exec "$CT_ID" -- bash -c "sed -i 's/upload_max_filesize = .*/upload_max_filesize = 10G/' /etc/php/${PHP_VERSION}/apache2/php.ini"
    pct exec "$CT_ID" -- bash -c "sed -i 's/post_max_size = .*/post_max_size = 10G/' /etc/php/${PHP_VERSION}/apache2/php.ini"
    pct exec "$CT_ID" -- bash -c "sed -i 's/max_execution_time = .*/max_execution_time = 3600/' /etc/php/${PHP_VERSION}/apache2/php.ini"
    pct exec "$CT_ID" -- bash -c "sed -i 's/;date.timezone.*/date.timezone = UTC/' /etc/php/${PHP_VERSION}/apache2/php.ini"

    # Configure OPcache in php.ini (base settings)
    pct exec "$CT_ID" -- bash -c "sed -i 's/;opcache.enable=.*/opcache.enable=1/' /etc/php/${PHP_VERSION}/apache2/php.ini"
    pct exec "$CT_ID" -- bash -c "sed -i 's/;opcache.memory_consumption=.*/opcache.memory_consumption=1024/' /etc/php/${PHP_VERSION}/apache2/php.ini"
    pct exec "$CT_ID" -- bash -c "sed -i 's/opcache.memory_consumption=.*/opcache.memory_consumption=1024/' /etc/php/${PHP_VERSION}/apache2/php.ini"
    pct exec "$CT_ID" -- bash -c "sed -i 's/;opcache.interned_strings_buffer=.*/opcache.interned_strings_buffer=512/' /etc/php/${PHP_VERSION}/apache2/php.ini"
    pct exec "$CT_ID" -- bash -c "sed -i 's/opcache.interned_strings_buffer=.*/opcache.interned_strings_buffer=512/' /etc/php/${PHP_VERSION}/apache2/php.ini"
    pct exec "$CT_ID" -- bash -c "sed -i 's/;opcache.max_accelerated_files=.*/opcache.max_accelerated_files=10000/' /etc/php/${PHP_VERSION}/apache2/php.ini"
    pct exec "$CT_ID" -- bash -c "sed -i 's/;opcache.revalidate_freq=.*/opcache.revalidate_freq=1/' /etc/php/${PHP_VERSION}/apache2/php.ini"
    pct exec "$CT_ID" -- bash -c "sed -i 's/;opcache.save_comments=.*/opcache.save_comments=1/' /etc/php/${PHP_VERSION}/apache2/php.ini"

    # Configure OPcache in opcache.ini (overrides php.ini settings loaded via conf.d)
    # This is critical because /etc/php/8.3/mods-available/opcache.ini is loaded after php.ini
    progress "Configuring OPcache module settings..."
    pct exec "$CT_ID" -- bash -c "cat > /etc/php/${PHP_VERSION}/mods-available/opcache.ini" <<'EOF'
; OPcache configuration optimized for Nextcloud
; This file overrides php.ini settings

opcache.enable=1
opcache.interned_strings_buffer=512
opcache.max_accelerated_files=10000
opcache.memory_consumption=1024
opcache.save_comments=1
opcache.revalidate_freq=1

; JIT compilation for improved performance (PHP 8+)
opcache.jit=1255
opcache.jit_buffer_size=128M
EOF

    success "PHP configured successfully"
}

install_nextcloud() {
    info "Installing Nextcloud ${NEXTCLOUD_VERSION}..."

    # Download Nextcloud
    progress "Downloading Nextcloud ${NEXTCLOUD_VERSION}..."
    pct exec "$CT_ID" -- bash -c "cd /tmp && wget -q https://download.nextcloud.com/server/releases/nextcloud-${NEXTCLOUD_VERSION}.zip" || cleanup_on_failure "Nextcloud download"

    # Extract Nextcloud
    progress "Extracting Nextcloud..."
    pct exec "$CT_ID" -- bash -c "cd /tmp && unzip -q nextcloud-${NEXTCLOUD_VERSION}.zip" || cleanup_on_failure "Nextcloud extraction"
    pct exec "$CT_ID" -- bash -c "mv /tmp/nextcloud /var/www/" || cleanup_on_failure "Nextcloud move"
    pct exec "$CT_ID" -- bash -c "rm /tmp/nextcloud-${NEXTCLOUD_VERSION}.zip" || true

    # Create data directory
    progress "Creating data directory..."
    pct exec "$CT_ID" -- bash -c "mkdir -p ${NEXTCLOUD_DATA_DIR}" || cleanup_on_failure "data directory creation"

    # Set permissions
    progress "Setting permissions..."
    pct exec "$CT_ID" -- bash -c "chown -R www-data:www-data /var/www/nextcloud" || cleanup_on_failure "Nextcloud permissions"
    pct exec "$CT_ID" -- bash -c "chown -R www-data:www-data ${NEXTCLOUD_DATA_DIR}" || cleanup_on_failure "data directory permissions"

    success "Nextcloud files installed successfully"
}

configure_apache() {
    info "Configuring Apache web server..."

    # Enable required Apache modules
    progress "Enabling Apache modules..."
    pct exec "$CT_ID" -- bash -c "a2enmod rewrite headers env dir mime ssl proxy_fcgi setenvif" || cleanup_on_failure "Apache modules"
    pct exec "$CT_ID" -- bash -c "a2enconf php${PHP_VERSION}-fpm" || cleanup_on_failure "PHP-FPM configuration"

    # Create Nextcloud Apache configuration
    progress "Creating Apache virtual host..."
    pct exec "$CT_ID" -- bash -c "cat > /etc/apache2/sites-available/nextcloud.conf" <<'EOF'
<VirtualHost *:80>
    DocumentRoot /var/www/nextcloud
    ServerName nextcloud

    # Security headers
    Header always set Strict-Transport-Security "max-age=15552000; includeSubDomains"

    <Directory /var/www/nextcloud/>
        Require all granted
        AllowOverride All
        Options FollowSymLinks MultiViews

        <IfModule mod_dav.c>
            Dav off
        </IfModule>
    </Directory>

    ErrorLog ${APACHE_LOG_DIR}/nextcloud_error.log
    CustomLog ${APACHE_LOG_DIR}/nextcloud_access.log combined
</VirtualHost>
EOF

    # Enable Nextcloud site and disable default
    pct exec "$CT_ID" -- bash -c "a2ensite nextcloud.conf" || cleanup_on_failure "Apache site enable"
    pct exec "$CT_ID" -- bash -c "a2dissite 000-default.conf" || cleanup_on_failure "Apache default disable"

    # Restart Apache
    pct exec "$CT_ID" -- bash -c "systemctl restart apache2" || cleanup_on_failure "Apache restart"

    success "Apache configured successfully"
}

install_nextcloud_cli() {
    info "Running Nextcloud installation via CLI..."

    progress "Installing Nextcloud (this may take a minute)..."
    pct exec "$CT_ID" -- bash -c "cd /var/www/nextcloud && sudo -u www-data php occ maintenance:install \
        --database='mysql' \
        --database-name='${NEXTCLOUD_DB_NAME}' \
        --database-user='${NEXTCLOUD_DB_USER}' \
        --database-pass='${NEXTCLOUD_DB_PASS}' \
        --admin-user='${NEXTCLOUD_ADMIN_USER}' \
        --admin-pass='${NEXTCLOUD_ADMIN_PASS}' \
        --data-dir='${NEXTCLOUD_DATA_DIR}'" || cleanup_on_failure "Nextcloud CLI installation"

    success "Nextcloud installed successfully"
}

configure_nextcloud() {
    info "Configuring Nextcloud settings..."

    # Get container IP for trusted domains
    local container_ip
    if [[ "$CT_IP" == "dhcp" ]]; then
        sleep 2
        container_ip=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}')
    else
        container_ip="${CT_IP%/*}"
    fi

    # Add trusted domains
    progress "Configuring trusted domains..."
    pct exec "$CT_ID" -- bash -c "cd /var/www/nextcloud && sudo -u www-data php occ config:system:set trusted_domains 1 --value='${container_ip}'" || warn "Failed to add IP to trusted domains"
    pct exec "$CT_ID" -- bash -c "cd /var/www/nextcloud && sudo -u www-data php occ config:system:set trusted_domains 2 --value='${CT_HOSTNAME}'" || warn "Failed to add hostname to trusted domains"

    # Configure Redis for file locking
    progress "Configuring Redis..."
    pct exec "$CT_ID" -- bash -c "cd /var/www/nextcloud && sudo -u www-data php occ config:system:set redis host --value='localhost'" || warn "Redis host config failed"
    pct exec "$CT_ID" -- bash -c "cd /var/www/nextcloud && sudo -u www-data php occ config:system:set redis port --value=6379" || warn "Redis port config failed"
    pct exec "$CT_ID" -- bash -c "cd /var/www/nextcloud && sudo -u www-data php occ config:system:set memcache.local --value='\\OC\\Memcache\\APCu'" || warn "APCu config failed"
    pct exec "$CT_ID" -- bash -c "cd /var/www/nextcloud && sudo -u www-data php occ config:system:set memcache.locking --value='\\OC\\Memcache\\Redis'" || warn "Redis locking config failed"

    # Set maintenance window (for background jobs)
    pct exec "$CT_ID" -- bash -c "cd /var/www/nextcloud && sudo -u www-data php occ config:system:set maintenance_window_start --type=integer --value=1" || warn "Maintenance window config failed"

    # Configure background jobs to use cron
    progress "Configuring cron for background jobs..."
    pct exec "$CT_ID" -- bash -c "cd /var/www/nextcloud && sudo -u www-data php occ background:cron" || warn "Background job config failed"

    # Add cron job for www-data user
    pct exec "$CT_ID" -- bash -c "echo '*/5 * * * * php -f /var/www/nextcloud/cron.php' | sudo -u www-data crontab -" || warn "Cron job setup failed"

    # Disable AppAPI if installed (Docker API version compatibility issue)
    # AppAPI hardcodes Docker API v1.41, but newer Docker versions require v1.44+
    progress "Checking and disabling AppAPI if installed..."
    if pct exec "$CT_ID" -- bash -c "cd /var/www/nextcloud && sudo -u www-data php occ app:list --enabled 2>/dev/null | grep -q app_api"; then
        pct exec "$CT_ID" -- bash -c "cd /var/www/nextcloud && sudo -u www-data php occ app:disable app_api" || warn "AppAPI disable failed"
        success "AppAPI disabled (Docker API version incompatibility)"
    fi

    success "Nextcloud configured successfully"
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

    local notes="NEXTCLOUD ${NEXTCLOUD_VERSION} - FILE HOSTING & COLLABORATION
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📋 CONTAINER DETAILS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Container ID:    ${CT_ID}
Hostname:        ${CT_HOSTNAME}
IP Address:      ${container_ip}
CPU Cores:       ${CT_CORES}
Memory:          ${CT_MEMORY}MB
Disk Size:       ${CT_DISK_SIZE}GB

🌐 NEXTCLOUD ACCESS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Web UI:          http://${container_ip}
Admin User:      ${NEXTCLOUD_ADMIN_USER}
Admin Password:  ${NEXTCLOUD_ADMIN_PASS}

⚠️  IMPORTANT: Change the admin password after first login!

🔑 DATABASE CREDENTIALS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Database:        ${NEXTCLOUD_DB_NAME}
DB User:         ${NEXTCLOUD_DB_USER}
DB Password:     ${NEXTCLOUD_DB_PASS}

🔧 SERVICE MANAGEMENT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Apache Status:   pct exec ${CT_ID} -- systemctl status apache2
MariaDB Status:  pct exec ${CT_ID} -- systemctl status mariadb
Redis Status:    pct exec ${CT_ID} -- systemctl status redis-server
Restart Apache:  pct exec ${CT_ID} -- systemctl restart apache2
Apache Logs:     pct exec ${CT_ID} -- tail -f /var/log/apache2/nextcloud_error.log

🛠️ NEXTCLOUD OCC COMMANDS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Enter Container: pct enter ${CT_ID}
OCC Command:     sudo -u www-data php /var/www/nextcloud/occ
Status Check:    sudo -u www-data php /var/www/nextcloud/occ status
Update:          sudo -u www-data php /var/www/nextcloud/occ upgrade
Maintenance:     sudo -u www-data php /var/www/nextcloud/occ maintenance:mode --on/--off

📦 CONTAINER MANAGEMENT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Enter:           pct enter ${CT_ID}
Start:           pct start ${CT_ID}
Stop:            pct stop ${CT_ID}
Restart:         pct restart ${CT_ID}
Delete:          pct destroy ${CT_ID}

📁 IMPORTANT PATHS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Nextcloud Root:  /var/www/nextcloud
Data Directory:  ${NEXTCLOUD_DATA_DIR}
Config File:     /var/www/nextcloud/config/config.php
Apache Config:   /etc/apache2/sites-available/nextcloud.conf
PHP Config:      /etc/php/${PHP_VERSION}/apache2/php.ini

💡 NEXT STEPS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
1. Access Nextcloud at http://${container_ip}
2. Login with admin credentials above
3. Change admin password in Settings → Security
4. Install apps from the App Store
5. Configure external storage if needed
6. Set up SSL/TLS for production use

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
    success "Nextcloud ${NEXTCLOUD_VERSION} LXC Container Setup Complete!"
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
    echo "Nextcloud Access:"
    echo "  • Web UI:            http://${container_ip}"
    echo "  • Admin User:        $NEXTCLOUD_ADMIN_USER"
    echo "  • Admin Password:    $NEXTCLOUD_ADMIN_PASS"
    echo ""
    warn "⚠️  IMPORTANT: Change the admin password after first login!"
    echo ""
    echo "Database Credentials:"
    echo "  • Database:          $NEXTCLOUD_DB_NAME"
    echo "  • DB User:           $NEXTCLOUD_DB_USER"
    echo "  • DB Password:       $NEXTCLOUD_DB_PASS"
    echo ""
    echo "Service Management:"
    echo "  • Apache Status:     pct exec $CT_ID -- systemctl status apache2"
    echo "  • MariaDB Status:    pct exec $CT_ID -- systemctl status mariadb"
    echo "  • Redis Status:      pct exec $CT_ID -- systemctl status redis-server"
    echo ""
    echo "Nextcloud Commands (inside container):"
    echo "  • Enter Container:   pct enter $CT_ID"
    echo "  • OCC Status:        sudo -u www-data php /var/www/nextcloud/occ status"
    echo "  • Maintenance Mode:  sudo -u www-data php /var/www/nextcloud/occ maintenance:mode --on"
    echo ""
    echo "Next Steps:"
    echo "  1. Open http://${container_ip} in your browser"
    echo "  2. Login with admin credentials"
    echo "  3. Change admin password in Settings → Security"
    echo "  4. Install desired apps from the App Store"
    echo "  5. Configure SSL/TLS for production use"
    echo ""
    echo "================================================================="
}

#################################################################
# Main Execution
#################################################################

main() {
    echo ""
    echo "================================================================="
    info "Nextcloud ${NEXTCLOUD_VERSION} LXC Container Installation"
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
    info "Installing LAMP stack and dependencies..."
    install_dependencies
    configure_mariadb
    configure_redis
    configure_php

    # Install and configure Nextcloud
    info "Installing Nextcloud ${NEXTCLOUD_VERSION}..."
    install_nextcloud
    configure_apache
    install_nextcloud_cli
    configure_nextcloud

    # Add container notes
    add_container_notes

    # Display information
    display_info
}

# Run main function
main "$@"
