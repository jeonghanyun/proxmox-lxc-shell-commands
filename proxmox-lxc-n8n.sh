#!/usr/bin/env bash

# n8n LXC Installation Script
# Description: Installs n8n workflow automation with graphicsmagick, ffmpeg, chromium
# OS: Debian 13 (Trixie) - Auto-detected latest version
# Ports: Web UI: 5678
# Repository: https://github.com/jeonghanyun/proxmox-lxc-shell-commands
# Last Updated: 2025-12-06

set -euo pipefail

#################################################################
# Configuration Variables
#################################################################

# Container Configuration
CT_ID=${CT_ID:-200}
CT_HOSTNAME=${CT_HOSTNAME:-"n8n"}
CT_CORES=${CT_CORES:-2}
CT_MEMORY=${CT_MEMORY:-2048}
CT_SWAP=${CT_SWAP:-512}
CT_DISK_SIZE=${CT_DISK_SIZE:-20}

# Network Configuration
CT_IP=${CT_IP:-"dhcp"}
CT_GATEWAY=${CT_GATEWAY:-""}
CT_BRIDGE=${CT_BRIDGE:-"vmbr0"}
CT_NAMESERVER=${CT_NAMESERVER:-"8.8.8.8"}

# Storage Configuration
CT_STORAGE=${CT_STORAGE:-"local-lvm"}
TEMPLATE_STORAGE=${TEMPLATE_STORAGE:-"local"}

# Debian Template (will be auto-detected)
DEBIAN_VERSION="13"
TEMPLATE_NAME=""

# Application Configuration
APP_PORT=${APP_PORT:-5678}

# Container Options
CT_ONBOOT=${CT_ONBOOT:-1}
CT_UNPRIVILEGED=${CT_UNPRIVILEGED:-1}
CT_FEATURES=${CT_FEATURES:-"keyctl=1,nesting=1,fuse=1"}

#################################################################
# Color Output Functions
#################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

    local net_config="name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP},ip6=auto"

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

    info "Waiting for container to boot..."
    sleep 5

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
# Application Installation Functions
#################################################################

install_nodejs() {
    info "Installing Node.js 22.x..."

    pct exec "$CT_ID" -- bash -c "apt-get update -qq"
    pct exec "$CT_ID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates gnupg"

    pct exec "$CT_ID" -- bash -c "mkdir -p /etc/apt/keyrings"
    pct exec "$CT_ID" -- bash -c "curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg"
    pct exec "$CT_ID" -- bash -c 'echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" > /etc/apt/sources.list.d/nodesource.list'

    pct exec "$CT_ID" -- bash -c "apt-get update -qq"
    pct exec "$CT_ID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs"

    success "Node.js installed: $(pct exec "$CT_ID" -- node -v)"
}

install_optional_packages() {
    info "Installing optional packages (graphicsmagick, ffmpeg, chromium)..."

    pct exec "$CT_ID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq graphicsmagick ffmpeg chromium" || {
        warn "Some optional packages may have failed to install"
    }

    success "Optional packages installed"
}

install_n8n() {
    info "Installing n8n globally via npm..."

    pct exec "$CT_ID" -- bash -c "npm install -g n8n" || {
        error "Failed to install n8n"
        exit 1
    }

    success "n8n installed successfully"
}

configure_service() {
    info "Configuring n8n systemd service..."

    pct exec "$CT_ID" -- bash -c "cat > /etc/systemd/system/n8n.service <<'EOF'
[Unit]
Description=n8n - Workflow Automation
After=network.target

[Service]
Type=simple
Environment=\"N8N_HOST=0.0.0.0\"
Environment=\"N8N_PORT=5678\"
Environment=\"N8N_PROTOCOL=http\"
Environment=\"N8N_SECURE_COOKIE=false\"
Environment=\"DB_SQLITE_POOL_SIZE=2\"
Environment=\"N8N_RUNNERS_ENABLED=true\"
Environment=\"N8N_BLOCK_ENV_ACCESS_IN_NODE=false\"
Environment=\"N8N_GIT_NODE_DISABLE_BARE_REPOS=true\"
ExecStart=/usr/bin/n8n
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF"

    pct exec "$CT_ID" -- bash -c "systemctl daemon-reload"
    pct exec "$CT_ID" -- bash -c "systemctl enable n8n"
    pct exec "$CT_ID" -- bash -c "systemctl start n8n"

    info "Waiting for n8n to start..."
    sleep 5

    if pct exec "$CT_ID" -- bash -c "systemctl is-active --quiet n8n"; then
        success "n8n service configured and started"
    else
        error "n8n service failed to start"
        pct exec "$CT_ID" -- bash -c "systemctl status n8n"
        exit 1
    fi
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

    local notes="n8n Workflow Automation
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

CONTAINER DETAILS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Container ID:    ${CT_ID}
Hostname:        ${CT_HOSTNAME}
IP Address:      ${container_ip}
CPU Cores:       ${CT_CORES}
Memory:          ${CT_MEMORY}MB
Disk Size:       ${CT_DISK_SIZE}GB

APPLICATION ACCESS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Web UI:          http://${container_ip}:${APP_PORT}

INSTALLED PACKAGES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
- Node.js 22.x
- n8n (latest)
- GraphicsMagick (image processing)
- FFmpeg (video/audio processing)
- Chromium (web scraping, PDF generation)

SERVICE MANAGEMENT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Status:          pct exec ${CT_ID} -- systemctl status n8n
Start:           pct exec ${CT_ID} -- systemctl start n8n
Stop:            pct exec ${CT_ID} -- systemctl stop n8n
Restart:         pct exec ${CT_ID} -- systemctl restart n8n
Logs:            pct exec ${CT_ID} -- journalctl -u n8n -f

CONTAINER MANAGEMENT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Enter:           pct enter ${CT_ID}
Start:           pct start ${CT_ID}
Stop:            pct stop ${CT_ID}
Restart:         pct restart ${CT_ID}
Delete:          pct destroy ${CT_ID}

AUTO-GENERATED BY: https://github.com/jeonghanyun/proxmox-lxc-shell-commands"

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
    success "n8n LXC Container Setup Complete!"
    echo "================================================================="
    echo ""
    info "All access information has been saved to container Notes"
    info "View in Proxmox UI: Select container -> Summary -> Notes"
    echo ""
    echo "Container Details:"
    echo "  - Container ID:      $CT_ID"
    echo "  - Hostname:          $CT_HOSTNAME"
    echo "  - IP Address:        $container_ip"
    echo "  - CPU Cores:         $CT_CORES"
    echo "  - Memory:            ${CT_MEMORY}MB"
    echo "  - Disk Size:         ${CT_DISK_SIZE}GB"
    echo ""
    echo "Application Access:"
    echo "  - Web UI:            http://${container_ip}:${APP_PORT}"
    echo ""
    echo "Installed Packages:"
    echo "  - Node.js 22.x"
    echo "  - n8n (latest)"
    echo "  - GraphicsMagick"
    echo "  - FFmpeg"
    echo "  - Chromium"
    echo ""
    echo "Service Management:"
    echo "  - Status:            pct exec $CT_ID -- systemctl status n8n"
    echo "  - Start:             pct exec $CT_ID -- systemctl start n8n"
    echo "  - Stop:              pct exec $CT_ID -- systemctl stop n8n"
    echo "  - Restart:           pct exec $CT_ID -- systemctl restart n8n"
    echo "  - Logs:              pct exec $CT_ID -- journalctl -u n8n -f"
    echo ""
    echo "Container Management:"
    echo "  - Enter container:   pct enter $CT_ID"
    echo "  - Stop container:    pct stop $CT_ID"
    echo "  - Start container:   pct start $CT_ID"
    echo "  - Delete container:  pct destroy $CT_ID"
    echo ""
    echo "================================================================="
}

#################################################################
# Main Execution
#################################################################

main() {
    info "Starting n8n LXC container creation..."
    echo ""

    # Pre-flight checks
    check_root
    check_proxmox
    check_container_exists
    detect_and_download_template

    # Create and configure container
    create_container
    start_container
    configure_autologin

    # Install and configure application
    install_nodejs
    install_optional_packages
    install_n8n
    configure_service

    # Add container notes
    add_container_notes

    # Display information
    display_info
}

# Run main function
main "$@"
