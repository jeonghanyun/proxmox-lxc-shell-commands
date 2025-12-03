#!/usr/bin/env bash

# Proxmox LXC APITable Installation Script
# Description: Automated creation and configuration of APITable in LXC container
# OS: Debian 12 (Bookworm) - Auto-detected latest version
# Ports: Web UI 80
# Requirements: Privileged container with Docker support, 4+ CPUs, 8GB+ RAM
# Repository: https://github.com/jeonghanyun/proxmox-lxc-shell-commands
# Last Updated: 2025-12-03

set -euo pipefail

#################################################################
# Configuration Variables
#################################################################

# Container Configuration
CT_ID=${CT_ID:-50001}                                  # Container ID
CT_HOSTNAME=${CT_HOSTNAME:-"apitable"}                 # Container hostname
CT_CORES=${CT_CORES:-4}                               # CPU cores (minimum 4 recommended)
CT_MEMORY=${CT_MEMORY:-8192}                          # RAM in MB (minimum 8GB recommended)
CT_SWAP=${CT_SWAP:-4096}                              # Swap in MB
CT_DISK_SIZE=${CT_DISK_SIZE:-50}                      # Root disk size in GB (minimum 50GB recommended)

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

# APITable Configuration
APITABLE_WEB_PORT=${APITABLE_WEB_PORT:-80}            # Web UI port

# Container Options - MUST be privileged for Docker
CT_ONBOOT=${CT_ONBOOT:-1}                             # Start on boot (1=yes, 0=no)
CT_UNPRIVILEGED=0                                     # MUST be privileged for Docker (0=privileged)
CT_FEATURES="keyctl=1,nesting=1"                      # Container features for Docker

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

check_resources() {
    # Warn if resources are below recommended
    if [[ $CT_MEMORY -lt 8192 ]]; then
        warn "Memory is set to ${CT_MEMORY}MB. APITable recommends at least 8192MB (8GB)"
        warn "Proceeding anyway, but performance may be affected"
    fi

    if [[ $CT_CORES -lt 4 ]]; then
        warn "CPU cores set to ${CT_CORES}. APITable recommends at least 4 cores"
        warn "Proceeding anyway, but performance may be affected"
    fi

    if [[ $CT_DISK_SIZE -lt 50 ]]; then
        warn "Disk size is ${CT_DISK_SIZE}GB. APITable recommends at least 50GB"
        warn "Proceeding anyway, but you may run out of space"
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
    warn "Creating PRIVILEGED container (required for Docker)"

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

configure_lxc_for_docker() {
    info "Configuring LXC container for Docker support..."

    # Get the LXC config file path
    local lxc_conf="/etc/pve/lxc/${CT_ID}.conf"

    # Add Docker-required configurations
    cat >> "$lxc_conf" <<EOF

# Docker support configurations
lxc.apparmor.profile: unconfined
lxc.cgroup2.devices.allow: a
lxc.cap.drop:
lxc.mount.auto: proc:rw sys:rw
EOF

    success "LXC Docker configuration added"
}

start_container() {
    info "Starting container $CT_ID..."
    pct start "$CT_ID" || {
        error "Failed to start container"
        exit 1
    }

    # Wait for container to be ready
    info "Waiting for container to boot..."
    sleep 8

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
# Docker Installation Functions
#################################################################

install_docker() {
    info "Installing Docker in container $CT_ID..."

    # Update and install required packages
    info "Updating package list..."
    pct exec "$CT_ID" -- bash -c "apt-get update -qq"

    info "Installing required packages..."
    pct exec "$CT_ID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates gnupg lsb-release git"

    # Add Docker's official GPG key
    info "Adding Docker GPG key..."
    pct exec "$CT_ID" -- bash -c "install -m 0755 -d /etc/apt/keyrings"
    pct exec "$CT_ID" -- bash -c "curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
    pct exec "$CT_ID" -- bash -c "chmod a+r /etc/apt/keyrings/docker.gpg"

    # Add Docker repository
    info "Adding Docker repository..."
    pct exec "$CT_ID" -- bash -c 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null'

    # Install Docker
    info "Installing Docker Engine..."
    pct exec "$CT_ID" -- bash -c "apt-get update -qq"
    pct exec "$CT_ID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"

    # Start and enable Docker
    pct exec "$CT_ID" -- bash -c "systemctl enable docker"
    pct exec "$CT_ID" -- bash -c "systemctl start docker"

    # Verify Docker installation
    if pct exec "$CT_ID" -- bash -c "docker --version" &>/dev/null; then
        success "Docker installed successfully"
    else
        error "Docker installation failed"
        exit 1
    fi
}

#################################################################
# APITable Installation Functions
#################################################################

install_apitable() {
    info "Installing APITable in container $CT_ID..."
    info "This may take several minutes (downloading images)..."

    # Create working directory
    pct exec "$CT_ID" -- bash -c "mkdir -p /opt/apitable"
    pct exec "$CT_ID" -- bash -c "cd /opt/apitable"

    # Run APITable installer
    info "Running APITable installer..."
    pct exec "$CT_ID" -- bash -c "cd /opt/apitable && curl -fsSL https://apitable.github.io/install.sh | bash" || {
        warn "Official installer failed, trying alternative method..."

        # Alternative: Clone and use docker-compose directly
        info "Cloning APITable repository..."
        pct exec "$CT_ID" -- bash -c "cd /opt && git clone https://github.com/apitable/apitable.git apitable-src" || true

        if pct exec "$CT_ID" -- bash -c "test -d /opt/apitable-src"; then
            info "Starting APITable with docker compose..."
            pct exec "$CT_ID" -- bash -c "cd /opt/apitable-src && docker compose up -d" || {
                error "APITable installation failed"
                exit 1
            }
        else
            error "APITable installation failed"
            exit 1
        fi
    }

    # Wait for APITable to start
    info "Waiting for APITable to initialize (this may take a few minutes)..."
    sleep 60

    # Check if APITable containers are running
    if pct exec "$CT_ID" -- bash -c "docker ps | grep -q -E 'apitable|room-server|web-server'"; then
        success "APITable installed and running"
    else
        warn "APITable containers may still be starting..."
        info "You can check status with: pct exec $CT_ID -- docker ps"
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

    # Create notes content
    local notes="APITABLE - AIRTABLE ALTERNATIVE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📋 CONTAINER DETAILS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Container ID:    ${CT_ID}
Hostname:        ${CT_HOSTNAME}
IP Address:      ${container_ip}
CPU Cores:       ${CT_CORES}
Memory:          ${CT_MEMORY}MB
Disk Size:       ${CT_DISK_SIZE}GB
Type:            Privileged (Docker support)

🌐 APITABLE ACCESS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Web UI:          http://${container_ip}:${APITABLE_WEB_PORT}
Initial Setup:   Create account on first access

🐳 DOCKER MANAGEMENT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Containers:      pct exec ${CT_ID} -- docker ps
Images:          pct exec ${CT_ID} -- docker images
Logs:            pct exec ${CT_ID} -- docker logs <container>
Compose:         pct exec ${CT_ID} -- docker compose ps

🔧 APITABLE MANAGEMENT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Status:          pct exec ${CT_ID} -- docker ps
Restart:         pct exec ${CT_ID} -- docker compose restart
Logs:            pct exec ${CT_ID} -- docker compose logs -f
Stop:            pct exec ${CT_ID} -- docker compose down
Start:           pct exec ${CT_ID} -- docker compose up -d

📦 CONTAINER MANAGEMENT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Enter:           pct enter ${CT_ID}
Start:           pct start ${CT_ID}
Stop:            pct stop ${CT_ID}
Restart:         pct restart ${CT_ID}
Delete:          pct destroy ${CT_ID}

⚠️  NOTES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
• This is a PRIVILEGED container (required for Docker)
• First access: Create your account
• APITable docs: https://apitable.com/docs
• GitHub: https://github.com/apitable/apitable

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
    success "APITable LXC Container Setup Complete!"
    echo "================================================================="
    echo ""
    info "All access information has been saved to container Notes"
    info "   View in Proxmox UI: Select container -> Summary -> Notes"
    echo ""
    echo "Container Details:"
    echo "  • Container ID:      $CT_ID"
    echo "  • Hostname:          $CT_HOSTNAME"
    echo "  • IP Address:        $container_ip"
    echo "  • CPU Cores:         $CT_CORES"
    echo "  • Memory:            ${CT_MEMORY}MB"
    echo "  • Disk Size:         ${CT_DISK_SIZE}GB"
    echo "  • Container Type:    Privileged"
    echo ""
    echo "APITable Access:"
    echo "  • Web UI:            http://${container_ip}:${APITABLE_WEB_PORT}"
    echo "  • First Access:      Create your account"
    echo ""
    echo "Docker Management:"
    echo "  • List containers:   pct exec $CT_ID -- docker ps"
    echo "  • List images:       pct exec $CT_ID -- docker images"
    echo "  • View logs:         pct exec $CT_ID -- docker compose logs -f"
    echo ""
    echo "Container Management:"
    echo "  • Enter container:   pct enter $CT_ID"
    echo "  • Stop container:    pct stop $CT_ID"
    echo "  • Start container:   pct start $CT_ID"
    echo "  • Delete container:  pct destroy $CT_ID"
    echo ""
    warn "First Access: Go to http://${container_ip}:${APITABLE_WEB_PORT}"
    warn "    and create your account to complete setup"
    echo ""
    echo "================================================================="
}

#################################################################
# Main Execution
#################################################################

main() {
    info "Starting APITable LXC container creation..."
    warn "APITable requires a PRIVILEGED container with Docker"
    warn "Recommended: 4+ CPUs, 8GB+ RAM, 50GB+ disk"
    echo ""

    # Pre-flight checks
    check_root
    check_proxmox
    check_container_exists
    check_resources
    detect_and_download_template

    # Create and configure container
    create_container
    configure_lxc_for_docker
    start_container
    configure_autologin

    # Install Docker and APITable
    install_docker
    install_apitable

    # Add container notes
    add_container_notes

    # Display information
    display_info
}

# Run main function
main "$@"
