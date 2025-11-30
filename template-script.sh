#!/usr/bin/env bash

# [YOUR APP NAME] LXC Installation Script
# Description: [Brief description of what this installs]
# OS: Debian 12 (Bookworm) - Auto-detected latest version
# Ports: [List your ports, e.g., Web: 8080, API: 3000]
# Repository: [Your GitHub URL]
# Last Updated: [Date]

set -euo pipefail

#################################################################
# Configuration Variables
#################################################################

# Container Configuration
CT_ID=${CT_ID:-200}                                    # Container ID
CT_HOSTNAME=${CT_HOSTNAME:-"myapp"}                    # Container hostname
CT_CORES=${CT_CORES:-1}                               # CPU cores
CT_MEMORY=${CT_MEMORY:-512}                           # RAM in MB
CT_SWAP=${CT_SWAP:-512}                               # Swap in MB
CT_DISK_SIZE=${CT_DISK_SIZE:-4}                       # Root disk size in GB

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

# Application Configuration
APP_PORT=${APP_PORT:-8080}                            # Main application port
# Add more application-specific variables here

# Container Options
CT_ONBOOT=${CT_ONBOOT:-1}                             # Start on boot (1=yes, 0=no)
CT_UNPRIVILEGED=${CT_UNPRIVILEGED:-1}                 # Unprivileged container (1=yes, 0=no)
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

#################################################################
# Application Installation Functions
#################################################################

install_application() {
    info "Installing [YOUR APPLICATION] in container $CT_ID..."

    # Update and install required packages
    info "Updating package list..."
    pct exec "$CT_ID" -- bash -c "apt-get update -qq"

    info "Installing required packages..."
    pct exec "$CT_ID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates wget"

    # TODO: Add your application installation steps here
    # Example:
    # info "Downloading application..."
    # pct exec "$CT_ID" -- bash -c "curl -sL https://example.com/install.sh | bash"

    success "Application installed successfully"
}

configure_service() {
    info "Configuring application service..."

    # TODO: Create systemd service file
    # Example:
    # pct exec "$CT_ID" -- bash -c "cat > /etc/systemd/system/myapp.service <<'EOF'
    # [Unit]
    # Description=My Application
    # After=network.target
    #
    # [Service]
    # Type=simple
    # User=root
    # ExecStart=/usr/local/bin/myapp --port ${APP_PORT}
    # Restart=on-failure
    # RestartSec=5s
    #
    # [Install]
    # WantedBy=multi-user.target
    # EOF"

    # Reload systemd and enable service
    pct exec "$CT_ID" -- bash -c "systemctl daemon-reload"
    pct exec "$CT_ID" -- bash -c "systemctl enable myapp"
    pct exec "$CT_ID" -- bash -c "systemctl start myapp"

    # Wait for service to start
    sleep 3

    # Check service status
    if pct exec "$CT_ID" -- bash -c "systemctl is-active --quiet myapp"; then
        success "Service configured and started"
    else
        error "Service failed to start"
        pct exec "$CT_ID" -- bash -c "systemctl status myapp"
        exit 1
    fi
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

    # TODO: Customize the notes content for your application
    local notes="[YOUR APPLICATION NAME]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📋 CONTAINER DETAILS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Container ID:    ${CT_ID}
Hostname:        ${CT_HOSTNAME}
IP Address:      ${container_ip}
CPU Cores:       ${CT_CORES}
Memory:          ${CT_MEMORY}MB
Disk Size:       ${CT_DISK_SIZE}GB

🌐 APPLICATION ACCESS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Web UI:          http://${container_ip}:${APP_PORT}

🔧 SERVICE MANAGEMENT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Status:          pct exec ${CT_ID} -- systemctl status myapp
Start:           pct exec ${CT_ID} -- systemctl start myapp
Stop:            pct exec ${CT_ID} -- systemctl stop myapp
Restart:         pct exec ${CT_ID} -- systemctl restart myapp
Logs:            pct exec ${CT_ID} -- journalctl -u myapp -f

📦 CONTAINER MANAGEMENT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Enter:           pct enter ${CT_ID}
Start:           pct start ${CT_ID}
Stop:            pct stop ${CT_ID}
Restart:         pct restart ${CT_ID}
Delete:          pct destroy ${CT_ID}

ℹ️  AUTO-GENERATED BY: [Your GitHub Repository URL]"

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
    success "[YOUR APPLICATION] LXC Container Setup Complete!"
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
    echo "Application Access:"
    echo "  • Web UI:            http://${container_ip}:${APP_PORT}"
    echo ""
    echo "Service Management:"
    echo "  • Status:            pct exec $CT_ID -- systemctl status myapp"
    echo "  • Start:             pct exec $CT_ID -- systemctl start myapp"
    echo "  • Stop:              pct exec $CT_ID -- systemctl stop myapp"
    echo "  • Restart:           pct exec $CT_ID -- systemctl restart myapp"
    echo "  • Logs:              pct exec $CT_ID -- journalctl -u myapp -f"
    echo ""
    echo "Container Management:"
    echo "  • Enter container:   pct enter $CT_ID"
    echo "  • Stop container:    pct stop $CT_ID"
    echo "  • Start container:   pct start $CT_ID"
    echo "  • Delete container:  pct destroy $CT_ID"
    echo ""
    echo "================================================================="
}

#################################################################
# Main Execution
#################################################################

main() {
    info "Starting [YOUR APPLICATION] LXC container creation..."
    echo ""

    # Pre-flight checks
    check_root
    check_proxmox
    check_container_exists
    detect_and_download_template

    # Create and configure container
    create_container
    start_container

    # Install and configure application
    install_application
    configure_service

    # Add container notes
    add_container_notes

    # Display information
    display_info
}

# Run main function
main "$@"
