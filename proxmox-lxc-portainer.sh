#!/usr/bin/env bash

# Portainer LXC Installation Script
# Description: Docker container management UI (Portainer CE)
# OS: Debian 12 (Bookworm) - Auto-detected latest version
# Ports: Web UI: 9443 (HTTPS), Agent: 8000
# Repository: https://github.com/portainer/portainer
# Last Updated: 2025-12-03

set -euo pipefail

#################################################################
# Configuration Variables
#################################################################

# Container Configuration
CT_ID=${CT_ID:-201}                                    # Container ID
CT_HOSTNAME=${CT_HOSTNAME:-"portainer"}                # Container hostname
CT_CORES=${CT_CORES:-2}                               # CPU cores
CT_MEMORY=${CT_MEMORY:-2048}                          # RAM in MB
CT_SWAP=${CT_SWAP:-512}                               # Swap in MB
CT_DISK_SIZE=${CT_DISK_SIZE:-16}                      # Root disk size in GB

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
PORTAINER_PORT_HTTPS=${PORTAINER_PORT_HTTPS:-9443}    # HTTPS Web UI port
PORTAINER_PORT_AGENT=${PORTAINER_PORT_AGENT:-8000}    # Agent communication port
PORTAINER_EDITION=${PORTAINER_EDITION:-"ce"}          # ce (Community) or be (Business)

# Container Options - IMPORTANT: Privileged required for Docker-in-LXC
CT_ONBOOT=${CT_ONBOOT:-1}                             # Start on boot (1=yes, 0=no)
CT_UNPRIVILEGED=${CT_UNPRIVILEGED:-0}                 # Must be 0 (privileged) for Docker
CT_FEATURES=${CT_FEATURES:-"keyctl=1,nesting=1"}      # Container features for Docker

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
# Docker Installation
#################################################################

install_docker() {
    info "Installing Docker in container $CT_ID..."

    # Update and install prerequisites
    info "Updating package list..."
    pct exec "$CT_ID" -- bash -c "apt-get update -qq"

    info "Installing required packages..."
    pct exec "$CT_ID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        ca-certificates \
        curl \
        gnupg \
        lsb-release"

    # Add Docker's official GPG key
    info "Adding Docker GPG key..."
    pct exec "$CT_ID" -- bash -c "install -m 0755 -d /etc/apt/keyrings"
    pct exec "$CT_ID" -- bash -c "curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc"
    pct exec "$CT_ID" -- bash -c "chmod a+r /etc/apt/keyrings/docker.asc"

    # Add Docker repository
    info "Adding Docker repository..."
    pct exec "$CT_ID" -- bash -c 'echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
        $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null'

    # Install Docker
    info "Installing Docker Engine..."
    pct exec "$CT_ID" -- bash -c "apt-get update -qq"
    pct exec "$CT_ID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin"

    # Start and enable Docker
    pct exec "$CT_ID" -- bash -c "systemctl enable docker"
    pct exec "$CT_ID" -- bash -c "systemctl start docker"

    # Wait for Docker to be ready
    sleep 3

    # Verify Docker installation
    if pct exec "$CT_ID" -- bash -c "docker --version" &>/dev/null; then
        success "Docker installed successfully"
    else
        error "Docker installation failed"
        exit 1
    fi
}

#################################################################
# Portainer Installation
#################################################################

install_portainer() {
    info "Installing Portainer CE in container $CT_ID..."

    # Create Portainer data volume
    info "Creating Portainer data volume..."
    pct exec "$CT_ID" -- bash -c "docker volume create portainer_data"

    # Pull and run Portainer
    info "Deploying Portainer container..."
    pct exec "$CT_ID" -- bash -c "docker run -d \
        --name portainer \
        --restart=always \
        -p ${PORTAINER_PORT_AGENT}:8000 \
        -p ${PORTAINER_PORT_HTTPS}:9443 \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v portainer_data:/data \
        portainer/portainer-ce:latest"

    # Wait for Portainer to start
    info "Waiting for Portainer to initialize..."
    sleep 10

    # Verify Portainer is running
    if pct exec "$CT_ID" -- bash -c "docker ps | grep -q portainer"; then
        success "Portainer installed and running"
    else
        error "Portainer failed to start"
        pct exec "$CT_ID" -- bash -c "docker logs portainer"
        exit 1
    fi
}

#################################################################
# Container Notes
#################################################################

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

    local notes="Portainer CE - Docker Management UI
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📋 CONTAINER DETAILS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Container ID:    ${CT_ID}
Hostname:        ${CT_HOSTNAME}
IP Address:      ${container_ip}
CPU Cores:       ${CT_CORES}
Memory:          ${CT_MEMORY}MB
Disk Size:       ${CT_DISK_SIZE}GB

🌐 PORTAINER ACCESS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Web UI (HTTPS):  https://${container_ip}:${PORTAINER_PORT_HTTPS}
Agent Port:      ${container_ip}:${PORTAINER_PORT_AGENT}

⚠️  IMPORTANT: Create admin user within 5 minutes of first access!

🐳 DOCKER COMMANDS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Portainer Status:  pct exec ${CT_ID} -- docker ps
Portainer Logs:    pct exec ${CT_ID} -- docker logs portainer
Restart Portainer: pct exec ${CT_ID} -- docker restart portainer
Docker Version:    pct exec ${CT_ID} -- docker --version

📦 CONTAINER MANAGEMENT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Enter:           pct enter ${CT_ID}
Start:           pct start ${CT_ID}
Stop:            pct stop ${CT_ID}
Restart:         pct restart ${CT_ID}
Delete:          pct destroy ${CT_ID}

ℹ️  AUTO-GENERATED BY: proxmox-lxc-portainer.sh"

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
    success "Portainer CE LXC Container Setup Complete!"
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
    echo "Portainer Access:"
    echo "  - Web UI (HTTPS):    https://${container_ip}:${PORTAINER_PORT_HTTPS}"
    echo "  - Agent Port:        ${container_ip}:${PORTAINER_PORT_AGENT}"
    echo ""
    warn "IMPORTANT: Create your admin user within 5 minutes of first access!"
    echo ""
    echo "Docker Commands:"
    echo "  - Portainer Status:  pct exec $CT_ID -- docker ps"
    echo "  - Portainer Logs:    pct exec $CT_ID -- docker logs portainer"
    echo "  - Restart Portainer: pct exec $CT_ID -- docker restart portainer"
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
    info "Starting Portainer CE LXC container creation..."
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

    # Install Docker and Portainer
    install_docker
    install_portainer

    # Add container notes
    add_container_notes

    # Display information
    display_info
}

# Run main function
main "$@"
