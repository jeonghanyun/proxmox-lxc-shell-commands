#!/usr/bin/env bash

# CloudPanel LXC Installation Script
# Description: CloudPanel - Modern Server Control Panel with NGINX, PHP, MySQL/MariaDB
# OS: Debian 12 (Bookworm) - Auto-detected latest version
# Ports: Web Panel: 8443 (HTTPS), HTTP: 80, HTTPS: 443
# Repository: https://github.com/jeonghanyun/proxmox-lxc-shell-commands
# Last Updated: 2025-12-01

set -euo pipefail

#################################################################
# Configuration Variables
#################################################################

# Container Configuration
CT_ID=${CT_ID:-207}                                    # Container ID
CT_HOSTNAME=${CT_HOSTNAME:-"cloudpanel"}               # Container hostname
CT_CORES=${CT_CORES:-2}                               # CPU cores (min 1)
CT_MEMORY=${CT_MEMORY:-2048}                          # RAM in MB (min 2GB)
CT_SWAP=${CT_SWAP:-1024}                              # Swap in MB
CT_DISK_SIZE=${CT_DISK_SIZE:-20}                      # Root disk size in GB (min 10GB)

# Network Configuration
CT_IP=${CT_IP:-"dhcp"}                                # IP address (dhcp or static like 192.168.1.100/24)
CT_GATEWAY=${CT_GATEWAY:-""}                          # Gateway (required for static IP)
CT_BRIDGE=${CT_BRIDGE:-"vmbr0"}                       # Network bridge
CT_NAMESERVER=${CT_NAMESERVER:-"8.8.8.8"}            # DNS server

# Storage Configuration
CT_STORAGE=${CT_STORAGE:-"local-lvm"}                 # Storage pool for container
TEMPLATE_STORAGE=${TEMPLATE_STORAGE:-"local"}         # Storage pool for templates

# Debian Template (will be auto-detected)
DEBIAN_VERSION="12"                                    # Debian version
TEMPLATE_NAME=""                                       # Auto-detected

# CloudPanel Configuration
CLOUDPANEL_PORT=${CLOUDPANEL_PORT:-8443}              # CloudPanel web UI port
DB_ENGINE=${DB_ENGINE:-"MYSQL_8.4"}                   # Database engine: MYSQL_8.4, MYSQL_8.0, MARIADB_11.4, MARIADB_10.11

# Locale and Timezone Configuration
CT_TIMEZONE=${CT_TIMEZONE:-"Asia/Seoul"}              # Container timezone
CT_LOCALE=${CT_LOCALE:-"ko_KR.UTF-8"}                 # Container locale

# Container Options
CT_ONBOOT=${CT_ONBOOT:-1}                             # Start on boot (1=yes, 0=no)
CT_UNPRIVILEGED=${CT_UNPRIVILEGED:-0}                 # Privileged container required for CloudPanel
CT_FEATURES=${CT_FEATURES:-"keyctl=1,nesting=1"}      # Container features

#################################################################
# Color Output Functions
#################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
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

check_requirements() {
    # Check minimum memory
    if [[ $CT_MEMORY -lt 2048 ]]; then
        warn "CloudPanel requires at least 2GB RAM. Setting to 2048MB"
        CT_MEMORY=2048
    fi

    # Check minimum disk size
    if [[ $CT_DISK_SIZE -lt 10 ]]; then
        warn "CloudPanel requires at least 10GB disk. Setting to 10GB"
        CT_DISK_SIZE=10
    fi

    # Validate DB_ENGINE
    case "$DB_ENGINE" in
        MYSQL_8.4|MYSQL_8.0|MARIADB_11.4|MARIADB_10.11)
            info "Database engine: $DB_ENGINE"
            ;;
        *)
            warn "Invalid DB_ENGINE '$DB_ENGINE'. Using MYSQL_8.4"
            DB_ENGINE="MYSQL_8.4"
            ;;
    esac
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
    warn "Downloading Debian template (this may take a few minutes)..."
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
        --ostype debian || {
            error "Failed to create container"
            exit 1
        }

    success "Container $CT_ID created successfully"
}

start_container() {
    info "Starting container $CT_ID..."
    pct start "$CT_ID" || {
        error "Failed to start container"
        exit 1
    }

    # Wait for container to be ready
    info "Waiting for container to boot..."
    sleep 5

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
# CloudPanel Installation Functions
#################################################################

install_cloudpanel() {
    info "Installing CloudPanel in container $CT_ID..."
    info "This may take 10-20 minutes depending on your internet speed..."

    # Update and install required packages
    info "Updating package list..."
    pct exec "$CT_ID" -- bash -c "apt-get update -qq"

    info "Upgrading system packages..."
    pct exec "$CT_ID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq"

    info "Installing required packages..."
    pct exec "$CT_ID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl wget sudo ca-certificates lsb-release locales"

    # Configure timezone and locale
    info "Configuring timezone (${CT_TIMEZONE}) and locale (${CT_LOCALE})..."
    pct exec "$CT_ID" -- bash -c "ln -sf /usr/share/zoneinfo/${CT_TIMEZONE} /etc/localtime"
    pct exec "$CT_ID" -- bash -c "echo '${CT_TIMEZONE}' > /etc/timezone"
    pct exec "$CT_ID" -- bash -c "sed -i 's/# ${CT_LOCALE}/${CT_LOCALE}/' /etc/locale.gen"
    pct exec "$CT_ID" -- bash -c "locale-gen"
    pct exec "$CT_ID" -- bash -c "update-locale LANG=${CT_LOCALE} LC_ALL=${CT_LOCALE}"

    # Download CloudPanel installer
    info "Downloading CloudPanel installer..."
    pct exec "$CT_ID" -- bash -c "curl -sS https://installer.cloudpanel.io/ce/v2/install.sh -o /tmp/install.sh"

    # Verify installer checksum
    info "Verifying installer checksum..."
    local checksum_result
    checksum_result=$(pct exec "$CT_ID" -- bash -c "echo '19cfa702e7936a79e47812ff57d9859175ea902c62a68b2c15ccd1ebaf36caeb /tmp/install.sh' | sha256sum -c 2>&1" || true)

    if echo "$checksum_result" | grep -q "OK"; then
        success "Installer checksum verified"
    else
        warn "Checksum verification failed - installer may have been updated"
        warn "Continuing with installation..."
    fi

    # Install CloudPanel
    info "Running CloudPanel installer with ${DB_ENGINE}..."
    info "This will take several minutes..."

    pct exec "$CT_ID" -- bash -c "DB_ENGINE=${DB_ENGINE} bash /tmp/install.sh" || {
        error "CloudPanel installation failed"
        error "Check logs with: pct exec $CT_ID -- cat /var/log/cloudpanel/installer.log"
        exit 1
    }

    success "CloudPanel installed successfully"
}

wait_for_cloudpanel() {
    info "Waiting for CloudPanel services to start..."

    local max_attempts=30
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        if pct exec "$CT_ID" -- bash -c "curl -sk https://localhost:8443 >/dev/null 2>&1"; then
            success "CloudPanel is ready"
            return 0
        fi
        info "Attempt $attempt/$max_attempts - Waiting for CloudPanel..."
        sleep 10
        ((attempt++))
    done

    warn "CloudPanel may still be starting up"
    warn "Try accessing it in a few minutes"
}

add_container_notes() {
    info "Adding container notes with access information..."

    local container_ip
    if [[ "$CT_IP" == "dhcp" ]]; then
        # Wait a bit for DHCP to assign IP
        sleep 3
        container_ip=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}')
        if [[ -z "$container_ip" ]]; then
            container_ip="[DHCP - check after boot]"
        fi
    else
        container_ip="${CT_IP%/*}"
    fi

    local notes="CloudPanel - Modern Server Control Panel
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📋 CONTAINER DETAILS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Container ID:    ${CT_ID}
Hostname:        ${CT_HOSTNAME}
IP Address:      ${container_ip}
CPU Cores:       ${CT_CORES}
Memory:          ${CT_MEMORY}MB
Disk Size:       ${CT_DISK_SIZE}GB
Database:        ${DB_ENGINE}
Timezone:        ${CT_TIMEZONE}
Locale:          ${CT_LOCALE}

🌐 CLOUDPANEL ACCESS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Admin Panel:     https://${container_ip}:8443

⚠️  FIRST LOGIN
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
1. Open https://${container_ip}:8443
2. Accept the self-signed certificate warning
3. Create your admin account on first access

🔧 SERVICE MANAGEMENT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
NGINX Status:    pct exec ${CT_ID} -- systemctl status nginx
PHP Status:      pct exec ${CT_ID} -- systemctl status php*-fpm
MySQL Status:    pct exec ${CT_ID} -- systemctl status mysql
CloudPanel:      pct exec ${CT_ID} -- clpctl system:info

🔒 PORTS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
8443:            CloudPanel Admin (HTTPS)
80:              HTTP Web Traffic
443:             HTTPS Web Traffic

📦 CONTAINER MANAGEMENT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Enter:           pct enter ${CT_ID}
Start:           pct start ${CT_ID}
Stop:            pct stop ${CT_ID}
Restart:         pct restart ${CT_ID}
Delete:          pct destroy ${CT_ID}

ℹ️  AUTO-GENERATED BY: https://github.com/jeonghanyun/proxmox-lxc-shell-commands"

    # Set container description using pct set
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

    # Get container IP address
    if [[ "$CT_IP" == "dhcp" ]]; then
        container_ip=$(pct exec "$CT_ID" -- hostname -I | awk '{print $1}')
    else
        container_ip="${CT_IP%/*}"  # Remove CIDR notation if present
    fi

    echo ""
    echo "================================================================="
    success "CloudPanel LXC Container Setup Complete!"
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
    echo "  • Database Engine:   $DB_ENGINE"
    echo "  • Timezone:          $CT_TIMEZONE"
    echo "  • Locale:            $CT_LOCALE"
    echo ""
    echo "CloudPanel Access:"
    echo "  • Admin Panel:       https://${container_ip}:8443"
    echo ""
    warn "⚠️  First Login:"
    echo "  1. Open https://${container_ip}:8443 in your browser"
    echo "  2. Accept the self-signed certificate warning"
    echo "  3. Create your admin account"
    echo ""
    echo "Service Management:"
    echo "  • System Info:       pct exec $CT_ID -- clpctl system:info"
    echo "  • NGINX Status:      pct exec $CT_ID -- systemctl status nginx"
    echo "  • PHP Status:        pct exec $CT_ID -- systemctl status php*-fpm"
    echo "  • MySQL Status:      pct exec $CT_ID -- systemctl status mysql"
    echo ""
    echo "Container Management:"
    echo "  • Enter container:   pct enter $CT_ID"
    echo "  • Stop container:    pct stop $CT_ID"
    echo "  • Start container:   pct start $CT_ID"
    echo "  • Delete container:  pct destroy $CT_ID"
    echo ""
    echo "Ports Used:"
    echo "  • 8443 - CloudPanel Admin Panel (HTTPS)"
    echo "  • 80   - HTTP Web Traffic"
    echo "  • 443  - HTTPS Web Traffic"
    echo ""
    echo "================================================================="
}

#################################################################
# Main Execution
#################################################################

main() {
    info "Starting CloudPanel LXC container creation..."
    echo ""
    info "CloudPanel: Modern Server Control Panel"
    info "Features: NGINX, PHP (multiple versions), MySQL/MariaDB, Let's Encrypt"
    echo ""

    # Pre-flight checks
    check_root
    check_proxmox
    check_container_exists
    check_requirements
    detect_and_download_template

    # Create and configure container
    create_container
    start_container
    configure_autologin

    # Install CloudPanel
    install_cloudpanel
    wait_for_cloudpanel

    # Add container notes
    add_container_notes

    # Display information
    display_info
}

# Run main function
main "$@"
