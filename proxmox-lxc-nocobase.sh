#!/usr/bin/env bash

# NocoBase v2 LXC Installation Script
# Description: Install NocoBase v2 - AI-powered no-code/low-code platform
# OS: Debian 12 (Bookworm)
# Ports: Web UI: 13000
# Repository: https://github.com/jeonghanyun/proxmox-lxc-shell-commands
# Last Updated: 2024-11

set -euo pipefail

#################################################################
# Configuration Variables
#################################################################

# Container Configuration
CT_ID=${CT_ID:-203}
CT_HOSTNAME=${CT_HOSTNAME:-"nocobase"}
CT_CORES=${CT_CORES:-2}
CT_MEMORY=${CT_MEMORY:-2048}
CT_SWAP=${CT_SWAP:-1024}
CT_DISK_SIZE=${CT_DISK_SIZE:-16}

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

# NocoBase Configuration
NOCOBASE_PORT=${NOCOBASE_PORT:-13000}
APP_KEY=${APP_KEY:-$(openssl rand -hex 32)}
DB_PASSWORD=${DB_PASSWORD:-$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)}

# Container Options
CT_ONBOOT=${CT_ONBOOT:-1}
CT_UNPRIVILEGED=${CT_UNPRIVILEGED:-1}
CT_FEATURES=${CT_FEATURES:-"keyctl=1,nesting=1"}

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
        info "Please choose a different CT_ID or remove the existing container"
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
# NocoBase Installation Functions
#################################################################

install_docker() {
    info "Installing Docker..."

    pct exec "$CT_ID" -- bash -c "apt-get update -qq"
    pct exec "$CT_ID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates gnupg"

    # Install Docker
    pct exec "$CT_ID" -- bash -c '
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
    '

    # Start Docker
    pct exec "$CT_ID" -- bash -c "systemctl enable docker && systemctl start docker"

    success "Docker installed successfully"
}

install_nocobase() {
    info "Installing NocoBase v2..."

    # Create NocoBase directory
    pct exec "$CT_ID" -- bash -c "mkdir -p /opt/nocobase"

    # Create docker-compose.yml
    pct exec "$CT_ID" -- bash -c "cat > /opt/nocobase/docker-compose.yml << 'DOCKEREOF'
networks:
  nocobase:
    driver: bridge

services:
  app:
    image: nocobase/nocobase:latest-full
    restart: always
    networks:
      - nocobase
    depends_on:
      - postgres
    environment:
      - APP_KEY=${APP_KEY}
      - DB_DIALECT=postgres
      - DB_HOST=postgres
      - DB_PORT=5432
      - DB_DATABASE=nocobase
      - DB_USER=nocobase
      - DB_PASSWORD=${DB_PASSWORD}
      - TZ=Asia/Seoul
    volumes:
      - ./storage:/app/nocobase/storage
    ports:
      - '${NOCOBASE_PORT}:80'

  postgres:
    image: postgres:16
    restart: always
    command: postgres -c wal_level=logical
    environment:
      POSTGRES_USER: nocobase
      POSTGRES_DB: nocobase
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - ./storage/db/postgres:/var/lib/postgresql/data
    networks:
      - nocobase
DOCKEREOF"

    # Pull and start containers
    info "Pulling NocoBase Docker images (this may take a few minutes)..."
    pct exec "$CT_ID" -- bash -c "cd /opt/nocobase && docker compose pull"

    info "Starting NocoBase..."
    pct exec "$CT_ID" -- bash -c "cd /opt/nocobase && docker compose up -d"

    # Wait for startup
    info "Waiting for NocoBase to initialize (this may take 1-2 minutes)..."
    sleep 30

    # Check status
    if pct exec "$CT_ID" -- bash -c "cd /opt/nocobase && docker compose ps | grep -q 'Up'"; then
        success "NocoBase installed and running"
    else
        warn "NocoBase may still be initializing. Check logs with: pct exec $CT_ID -- docker compose -f /opt/nocobase/docker-compose.yml logs -f app"
    fi
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

    local notes="NocoBase v2 - No-Code/Low-Code Platform
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
Web UI:          http://${container_ip}:${NOCOBASE_PORT}

📧 DEFAULT CREDENTIALS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Email:           admin@nocobase.com
Password:        admin123

⚠️  CHANGE DEFAULT PASSWORD IMMEDIATELY!

🔧 SERVICE MANAGEMENT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Logs:            pct exec ${CT_ID} -- docker compose -f /opt/nocobase/docker-compose.yml logs -f
Restart:         pct exec ${CT_ID} -- docker compose -f /opt/nocobase/docker-compose.yml restart
Stop:            pct exec ${CT_ID} -- docker compose -f /opt/nocobase/docker-compose.yml down
Start:           pct exec ${CT_ID} -- docker compose -f /opt/nocobase/docker-compose.yml up -d

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
    success "NocoBase v2 LXC Container Setup Complete!"
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
    echo "  • Web UI:            http://${container_ip}:${NOCOBASE_PORT}"
    echo ""
    echo "Default Login:"
    echo "  • Email:             admin@nocobase.com"
    echo "  • Password:          admin123"
    echo ""
    warn "⚠️  CHANGE DEFAULT PASSWORD IMMEDIATELY!"
    echo ""
    echo "Service Management:"
    echo "  • Logs:              pct exec $CT_ID -- docker compose -f /opt/nocobase/docker-compose.yml logs -f"
    echo "  • Restart:           pct exec $CT_ID -- docker compose -f /opt/nocobase/docker-compose.yml restart"
    echo ""
    echo "================================================================="
}

#################################################################
# Main Execution
#################################################################

main() {
    info "Starting NocoBase v2 LXC container creation..."
    echo ""

    check_root
    check_proxmox
    check_container_exists
    detect_and_download_template

    create_container
    start_container
    configure_autologin

    install_docker
    install_nocobase

    add_container_notes
    display_info
}

main "$@"
