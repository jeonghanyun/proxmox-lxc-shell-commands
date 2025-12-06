#!/usr/bin/env bash

# Huginn LXC Installation Script
# Description: Install Huginn - Build agents that monitor and act on your behalf
# OS: Debian 12 (Bookworm)
# Ports: Web UI: 3000
# Repository: https://github.com/jeonghanyun/proxmox-lxc-shell-commands
# Last Updated: 2025-12

set -euo pipefail

#################################################################
# Configuration Variables
#################################################################

# Container Configuration
CT_ID=${CT_ID:-26004}
CT_HOSTNAME=${CT_HOSTNAME:-"huginn"}
CT_CORES=${CT_CORES:-2}
CT_MEMORY=${CT_MEMORY:-2048}
CT_SWAP=${CT_SWAP:-1024}
CT_DISK_SIZE=${CT_DISK_SIZE:-15}

# Network Configuration
CT_IP=${CT_IP:-"dhcp"}
CT_GATEWAY=${CT_GATEWAY:-""}
CT_BRIDGE=${CT_BRIDGE:-"vmbr0"}
CT_NAMESERVER=${CT_NAMESERVER:-"8.8.8.8"}

# Storage Configuration
CT_STORAGE=${CT_STORAGE:-"local-lvm"}
TEMPLATE_STORAGE=${TEMPLATE_STORAGE:-"local"}

# Debian Template
DEBIAN_VERSION="12"
TEMPLATE_NAME=""

# Huginn Configuration
HUGINN_PORT=${HUGINN_PORT:-3000}
HUGINN_INVITATION_CODE=${HUGINN_INVITATION_CODE:-"gupsa"}
HUGINN_TIMEZONE=${HUGINN_TIMEZONE:-"Asia/Seoul"}
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD:-"huginn_root"}
MYSQL_PASSWORD=${MYSQL_PASSWORD:-"huginn"}

# Container Options - MUST be privileged for Docker
CT_ONBOOT=${CT_ONBOOT:-1}
CT_UNPRIVILEGED=0
CT_FEATURES="keyctl=1,nesting=1"

#################################################################
# Color Output Functions
#################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

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
        exit 1
    fi
}

detect_and_download_template() {
    info "Updating template database..."
    pveam update 2>&1 | grep -q "update successful\|already up to date" || true

    info "Detecting available Debian ${DEBIAN_VERSION} template..."
    local available_template
    available_template=$(pveam available --section system 2>/dev/null | grep "debian-${DEBIAN_VERSION}" | grep "standard" | tail -1 | awk '{print $2}')

    if [[ -z "$available_template" ]]; then
        error "No Debian ${DEBIAN_VERSION} template found"
        exit 1
    fi

    TEMPLATE_NAME="$available_template"
    info "Found template: $TEMPLATE_NAME"

    if pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$TEMPLATE_NAME"; then
        success "Template already downloaded"
        return 0
    fi

    warn "Downloading Debian template..."
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME" 2>&1
    success "Template downloaded successfully"
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
# Huginn Installation Functions
#################################################################

install_docker() {
    info "Installing Docker..."

    pct exec "$CT_ID" -- bash -c "apt-get update -qq"
    pct exec "$CT_ID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates gnupg"

    pct exec "$CT_ID" -- bash -c '
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
    '

    pct exec "$CT_ID" -- bash -c "systemctl enable docker && systemctl start docker"
    success "Docker installed successfully"
}

install_huginn() {
    info "Installing Huginn..."

    # Create Huginn directory
    pct exec "$CT_ID" -- bash -c "mkdir -p /opt/huginn"

    # Create docker-compose.yml
    info "Creating Huginn configuration..."
    pct exec "$CT_ID" -- bash -c "cat > /opt/huginn/docker-compose.yml << 'EOF'
services:
  huginn:
    image: ghcr.io/huginn/huginn
    container_name: huginn
    ports:
      - \"${HUGINN_PORT}:3000\"
    environment:
      - HUGINN_DATABASE_ADAPTER=mysql2
      - HUGINN_DATABASE_NAME=huginn
      - HUGINN_DATABASE_USERNAME=huginn
      - HUGINN_DATABASE_PASSWORD=${MYSQL_PASSWORD}
      - DATABASE_HOST=mysql
      - SEED_DATABASE=true
      - INVITATION_CODE=${HUGINN_INVITATION_CODE}
      - TIMEZONE=${HUGINN_TIMEZONE}
    depends_on:
      mysql:
        condition: service_healthy
    restart: unless-stopped

  mysql:
    image: mysql:8.0
    container_name: huginn_mysql
    environment:
      - MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
      - MYSQL_DATABASE=huginn
      - MYSQL_USER=huginn
      - MYSQL_PASSWORD=${MYSQL_PASSWORD}
    volumes:
      - mysql_data:/var/lib/mysql
    healthcheck:
      test: [\"CMD\", \"mysqladmin\", \"ping\", \"-h\", \"localhost\"]
      interval: 10s
      timeout: 5s
      retries: 5
    restart: unless-stopped

volumes:
  mysql_data:
EOF"

    # Pull and start containers
    info "Pulling Huginn Docker images (this may take several minutes)..."
    pct exec "$CT_ID" -- bash -c "cd /opt/huginn && docker compose pull"

    info "Starting Huginn..."
    pct exec "$CT_ID" -- bash -c "cd /opt/huginn && docker compose up -d"

    # Wait for startup
    info "Waiting for Huginn to initialize (this may take up to 3 minutes)..."
    local max_attempts=36
    local attempt=0
    while [[ $attempt -lt $max_attempts ]]; do
        if pct exec "$CT_ID" -- bash -c "docker ps --format '{{.Names}}' | grep -q huginn" 2>/dev/null; then
            local status
            status=$(pct exec "$CT_ID" -- bash -c "docker inspect --format='{{.State.Status}}' huginn" 2>/dev/null || echo "unknown")
            if [[ "$status" == "running" ]]; then
                success "Huginn is running"
                return 0
            fi
        fi
        sleep 5
        ((attempt++))
        if [[ $((attempt % 6)) -eq 0 ]]; then
            info "Still waiting... ($((attempt * 5))s elapsed)"
        fi
    done

    warn "Huginn may still be initializing. Check status with: pct exec $CT_ID -- docker ps"
}

add_container_notes() {
    info "Adding container notes..."

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

    local notes="Huginn - Agent Automation Platform
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
Web UI:          http://${container_ip}:${HUGINN_PORT}
Default Login:   admin / password
Invitation Code: ${HUGINN_INVITATION_CODE}

📧 SETUP INSTRUCTIONS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Default admin credentials: admin / password
Change password after first login!

🔧 SERVICE MANAGEMENT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Status:          pct exec ${CT_ID} -- docker ps
Logs:            pct exec ${CT_ID} -- docker logs huginn -f
Restart:         pct exec ${CT_ID} -- docker compose -f /opt/huginn/docker-compose.yml restart
Stop:            pct exec ${CT_ID} -- docker compose -f /opt/huginn/docker-compose.yml down
Start:           pct exec ${CT_ID} -- docker compose -f /opt/huginn/docker-compose.yml up -d

📦 CONTAINER MANAGEMENT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Enter:           pct enter ${CT_ID}
Start:           pct start ${CT_ID}
Stop:            pct stop ${CT_ID}
Delete:          pct destroy ${CT_ID}

ℹ️  AUTO-GENERATED BY: github.com/jeonghanyun/proxmox-lxc-shell-commands"

    pct set "$CT_ID" -description "$notes" 2>/dev/null || true
    success "Container notes added"
}

display_info() {
    local container_ip
    if [[ "$CT_IP" == "dhcp" ]]; then
        container_ip=$(pct exec "$CT_ID" -- hostname -I | awk '{print $1}')
    else
        container_ip="${CT_IP%/*}"
    fi

    echo ""
    echo "================================================================="
    success "Huginn LXC Container Setup Complete!"
    echo "================================================================="
    echo ""
    info "All access information has been saved to container Notes"
    echo ""
    echo "Container Details:"
    echo "  • Container ID:      $CT_ID"
    echo "  • Hostname:          $CT_HOSTNAME"
    echo "  • IP Address:        $container_ip"
    echo ""
    echo "Application Access:"
    echo "  • Web UI:            http://${container_ip}:${HUGINN_PORT}"
    echo "  • Default Login:     admin / password"
    echo "  • Invitation Code:   ${HUGINN_INVITATION_CODE}"
    echo ""
    echo "Setup Instructions:"
    echo "  • Login with default credentials and change password"
    echo "  • Start building automation agents!"
    echo ""
    echo "Service Management:"
    echo "  • Status:            pct exec $CT_ID -- docker ps"
    echo "  • Logs:              pct exec $CT_ID -- docker logs huginn -f"
    echo "  • Restart:           pct exec $CT_ID -- docker compose -f /opt/huginn/docker-compose.yml restart"
    echo ""
    echo "================================================================="
}

#################################################################
# Main Execution
#################################################################

main() {
    info "Starting Huginn LXC container creation..."
    echo ""

    check_root
    check_proxmox
    check_container_exists
    detect_and_download_template

    create_container
    start_container
    configure_autologin

    install_docker
    install_huginn

    add_container_notes
    display_info
}

main "$@"
