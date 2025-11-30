#!/usr/bin/env bash

# CyberPanel LXC Installation Script
# Description: Automated installation of CyberPanel with OpenLiteSpeed
# OS: Debian 12 (Bookworm) / Ubuntu 22.04 - Auto-detected latest version
# Ports: Web Panel: 8090, HTTP: 80, HTTPS: 443, SSH: 22
# Repository: https://github.com/jeonghanyun/proxmox-lxc-shell-commands
# Last Updated: 2025-11-30

set -euo pipefail

#################################################################
# Configuration Variables
#################################################################

# Container Configuration
CT_ID=${CT_ID:-211}                                    # Container ID
CT_HOSTNAME=${CT_HOSTNAME:-"cyberpanel"}               # Container hostname
CT_CORES=${CT_CORES:-2}                                # CPU cores
CT_MEMORY=${CT_MEMORY:-2048}                           # RAM in MB (2GB minimum recommended)
CT_SWAP=${CT_SWAP:-2048}                               # Swap in MB
CT_DISK_SIZE=${CT_DISK_SIZE:-30}                       # Root disk size in GB

# Network Configuration
CT_IP=${CT_IP:-"dhcp"}                                 # IP address (dhcp or static like 192.168.1.100/24)
CT_GATEWAY=${CT_GATEWAY:-""}                           # Gateway (required for static IP)
CT_BRIDGE=${CT_BRIDGE:-"vmbr0"}                        # Network bridge
CT_NAMESERVER=${CT_NAMESERVER:-"8.8.8.8"}             # DNS server

# Storage Configuration
CT_STORAGE=${CT_STORAGE:-"local-lvm"}                  # Storage pool for container
TEMPLATE_STORAGE=${TEMPLATE_STORAGE:-"local"}          # Storage pool for templates

# OS Template Configuration
# CyberPanel officially supports Ubuntu 22.04 and Ubuntu 24.04
USE_UBUNTU=${USE_UBUNTU:-"yes"}                        # Use Ubuntu instead of Debian (recommended)
UBUNTU_VERSION="22.04"                                  # Ubuntu version
DEBIAN_VERSION="12"                                     # Debian version (fallback)
TEMPLATE_NAME=""                                        # Auto-detected

# CyberPanel Configuration
CYBERPANEL_PORT=${CYBERPANEL_PORT:-8090}               # CyberPanel web panel port
CYBERPANEL_ADMIN_PASS=${CYBERPANEL_ADMIN_PASS:-"$(openssl rand -base64 12)"}
MYSQL_ROOT_PASS=${MYSQL_ROOT_PASS:-"$(openssl rand -base64 16)"}

# Installation Options
INSTALL_POWERDNS=${INSTALL_POWERDNS:-"yes"}            # Install PowerDNS
INSTALL_POSTFIX=${INSTALL_POSTFIX:-"yes"}              # Install Postfix
INSTALL_PUREFTPD=${INSTALL_PUREFTPD:-"yes"}            # Install Pure-FTPd
INSTALL_MEMCACHED=${INSTALL_MEMCACHED:-"no"}           # Install Memcached
INSTALL_REDIS=${INSTALL_REDIS:-"yes"}                  # Install Redis

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

    local available_template=""

    if [[ "$USE_UBUNTU" == "yes" ]]; then
        info "Detecting available Ubuntu ${UBUNTU_VERSION} template..."
        available_template=$(pveam available --section system 2>/dev/null | grep "ubuntu-${UBUNTU_VERSION}" | grep "standard" | tail -1 | awk '{print $2}')

        if [[ -z "$available_template" ]]; then
            warn "Ubuntu ${UBUNTU_VERSION} template not found, trying Debian..."
            USE_UBUNTU="no"
        fi
    fi

    if [[ "$USE_UBUNTU" != "yes" ]] || [[ -z "$available_template" ]]; then
        info "Detecting available Debian ${DEBIAN_VERSION} template..."
        available_template=$(pveam available --section system 2>/dev/null | grep "debian-${DEBIAN_VERSION}" | grep "standard" | tail -1 | awk '{print $2}')
    fi

    if [[ -z "$available_template" ]]; then
        error "No suitable template found in available templates"
        info "Troubleshooting steps:"
        info "  1. Check DNS configuration: cat /etc/resolv.conf"
        info "  2. Test connectivity: ping -c 3 download.proxmox.com"
        info "  3. Manual check: pveam available --section system"
        exit 1
    fi

    TEMPLATE_NAME="$available_template"
    info "Found template: $TEMPLATE_NAME"

    if pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$TEMPLATE_NAME"; then
        success "Template already downloaded"
        return 0
    fi

    progress "Downloading template (this may take a few minutes)..."
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

    local ostype="debian"
    if [[ "$USE_UBUNTU" == "yes" ]]; then
        ostype="ubuntu"
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
        --ostype "$ostype" || cleanup_on_failure "container creation"

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
# CyberPanel Installation Functions
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
        sudo \
        lsb-release \
        python3 \
        python3-pip" || cleanup_on_failure "base package installation"

    success "Base dependencies installed"
}

prepare_cyberpanel_install() {
    info "Preparing CyberPanel installation..."

    # Create installation options file for automated install
    progress "Creating installation configuration..."

    local dns_option="1"  # PowerDNS
    local postfix_option="1"  # Postfix
    local ftp_option="1"  # Pure-FTPd
    local memcached_option="0"  # Memcached
    local redis_option="1"  # Redis

    [[ "$INSTALL_POWERDNS" == "no" ]] && dns_option="0"
    [[ "$INSTALL_POSTFIX" == "no" ]] && postfix_option="0"
    [[ "$INSTALL_PUREFTPD" == "no" ]] && ftp_option="0"
    [[ "$INSTALL_MEMCACHED" == "yes" ]] && memcached_option="1"
    [[ "$INSTALL_REDIS" == "no" ]] && redis_option="0"

    # Create expect-like input file for the installer
    pct exec "$CT_ID" -- bash -c "cat > /tmp/cyberpanel_install_answers << EOF
1
y
1
${dns_option}
${postfix_option}
${ftp_option}
${memcached_option}
${redis_option}
r
${CYBERPANEL_ADMIN_PASS}
${CYBERPANEL_ADMIN_PASS}
s
EOF"

    success "Installation configuration prepared"
}

install_cyberpanel() {
    info "Installing CyberPanel with OpenLiteSpeed..."

    progress "Downloading CyberPanel installer..."
    pct exec "$CT_ID" -- bash -c "cd /tmp && wget -q -O installer.sh https://cyberpanel.net/install.sh" || cleanup_on_failure "CyberPanel download"
    pct exec "$CT_ID" -- bash -c "chmod +x /tmp/installer.sh" || cleanup_on_failure "Set installer permissions"

    # Run the installer with automated responses
    progress "Running CyberPanel installer (this may take 15-30 minutes)..."
    warn "Please be patient - CyberPanel installation takes time..."

    # CyberPanel installer with automated input
    # Using environment variables and pre-seeded responses
    pct exec "$CT_ID" -- bash -c "export CYBERPANEL_ADMIN_PASS='${CYBERPANEL_ADMIN_PASS}' && \
        export MYSQL_ROOT_PASS='${MYSQL_ROOT_PASS}' && \
        cd /tmp && \
        echo '1' | bash installer.sh --postfix yes --powerdns yes --pureftpd yes --redis yes -v ols --admin-pass '${CYBERPANEL_ADMIN_PASS}' -m '${MYSQL_ROOT_PASS}'" 2>&1 || {
            warn "Automated install may have issues, trying alternative method..."
            # Fallback: Run with expect-like inputs
            pct exec "$CT_ID" -- bash -c "cd /tmp && cat cyberpanel_install_answers | bash installer.sh" 2>&1 || cleanup_on_failure "CyberPanel installation"
        }

    # Clean up
    pct exec "$CT_ID" -- bash -c "rm -f /tmp/installer.sh /tmp/cyberpanel_install_answers" || true

    success "CyberPanel installation completed"
}

verify_installation() {
    info "Verifying CyberPanel installation..."

    # Check if LiteSpeed is running
    if pct exec "$CT_ID" -- bash -c "systemctl is-active lsws" 2>/dev/null | grep -q "active"; then
        success "OpenLiteSpeed is running"
    else
        warn "OpenLiteSpeed may not be running - please check manually"
    fi

    # Check if CyberPanel service is available
    if pct exec "$CT_ID" -- bash -c "test -d /usr/local/CyberCP" 2>/dev/null; then
        success "CyberPanel directory found"
    else
        warn "CyberPanel directory not found - installation may have issues"
    fi

    success "Verification completed"
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

    local notes="CYBERPANEL - WEB HOSTING CONTROL PANEL (OpenLiteSpeed)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📋 CONTAINER DETAILS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Container ID:    ${CT_ID}
Hostname:        ${CT_HOSTNAME}
IP Address:      ${container_ip}
CPU Cores:       ${CT_CORES}
Memory:          ${CT_MEMORY}MB
Disk Size:       ${CT_DISK_SIZE}GB

🌐 CYBERPANEL ACCESS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Control Panel:   https://${container_ip}:${CYBERPANEL_PORT}
Admin User:      admin
Admin Password:  ${CYBERPANEL_ADMIN_PASS}

⚠️  IMPORTANT: Change the admin password after first login!

🔑 DATABASE CREDENTIALS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
MySQL Root Pass: ${MYSQL_ROOT_PASS}

📊 ADDITIONAL PANELS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
phpMyAdmin:      https://${container_ip}:${CYBERPANEL_PORT}/phpmyadmin
File Manager:    https://${container_ip}:${CYBERPANEL_PORT}/filemanager
Webmail:         https://${container_ip}:${CYBERPANEL_PORT}/snappymail

🔧 SERVICE MANAGEMENT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
LiteSpeed Status: pct exec ${CT_ID} -- systemctl status lsws
MariaDB Status:   pct exec ${CT_ID} -- systemctl status mariadb
PowerDNS Status:  pct exec ${CT_ID} -- systemctl status pdns
Postfix Status:   pct exec ${CT_ID} -- systemctl status postfix

🛠️ CYBERPANEL CLI
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Enter Container: pct enter ${CT_ID}
CLI Menu:        cyberpanel
Upgrade:         cyberpanel upgrade
Create Website:  cyberpanel createWebsite --domainName example.com --email admin@example.com --package Default

📦 CONTAINER MANAGEMENT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Enter:           pct enter ${CT_ID}
Start:           pct start ${CT_ID}
Stop:            pct stop ${CT_ID}
Restart:         pct restart ${CT_ID}
Delete:          pct destroy ${CT_ID}

📁 IMPORTANT PATHS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
CyberPanel Dir:  /usr/local/CyberCP
Websites:        /home
LiteSpeed:       /usr/local/lsws
Logs:            /usr/local/lsws/logs

💡 NEXT STEPS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
1. Access CyberPanel at https://${container_ip}:${CYBERPANEL_PORT}
2. Accept the self-signed SSL certificate
3. Login with admin credentials above
4. Change admin password in Users → Modify User
5. Create your first website
6. Install SSL certificates via CyberPanel

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
    success "CyberPanel LXC Container Setup Complete!"
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
    echo "CyberPanel Access:"
    echo "  • Control Panel:     https://${container_ip}:${CYBERPANEL_PORT}"
    echo "  • Admin User:        admin"
    echo "  • Admin Password:    $CYBERPANEL_ADMIN_PASS"
    echo ""
    warn "⚠️  IMPORTANT: Change the admin password after first login!"
    echo ""
    echo "Database Credentials:"
    echo "  • MySQL Root Pass:   $MYSQL_ROOT_PASS"
    echo ""
    echo "Services Installed:"
    echo "  • Web Server:        OpenLiteSpeed"
    echo "  • Database:          MariaDB"
    echo "  • DNS:               PowerDNS (if enabled)"
    echo "  • Mail:              Postfix (if enabled)"
    echo "  • FTP:               Pure-FTPd (if enabled)"
    echo "  • Cache:             Redis (if enabled)"
    echo ""
    echo "Additional Access:"
    echo "  • phpMyAdmin:        https://${container_ip}:${CYBERPANEL_PORT}/phpmyadmin"
    echo "  • File Manager:      https://${container_ip}:${CYBERPANEL_PORT}/filemanager"
    echo "  • Webmail:           https://${container_ip}:${CYBERPANEL_PORT}/snappymail"
    echo ""
    echo "CLI Commands (inside container):"
    echo "  • Enter Container:   pct enter $CT_ID"
    echo "  • CyberPanel CLI:    cyberpanel"
    echo "  • Upgrade:           cyberpanel upgrade"
    echo ""
    echo "Next Steps:"
    echo "  1. Open https://${container_ip}:${CYBERPANEL_PORT} in your browser"
    echo "  2. Accept the self-signed SSL certificate"
    echo "  3. Login with admin credentials"
    echo "  4. Change admin password in Users → Modify User"
    echo "  5. Create your first website"
    echo ""
    echo "================================================================="
}

#################################################################
# Main Execution
#################################################################

main() {
    echo ""
    echo "================================================================="
    info "CyberPanel LXC Container Installation"
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

    # Install dependencies
    info "Installing system dependencies..."
    install_dependencies

    # Install CyberPanel
    info "Installing CyberPanel..."
    prepare_cyberpanel_install
    install_cyberpanel
    verify_installation

    # Add container notes
    add_container_notes

    # Display information
    display_info
}

# Run main function
main "$@"
