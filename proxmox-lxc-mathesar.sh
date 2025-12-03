#!/usr/bin/env bash

# Proxmox LXC Mathesar Installation Script
# Description: Automated creation and configuration of Mathesar in LXC container
# OS: Debian 12 (Bookworm)
# Ports: Web UI 8000
# Requirements: Privileged container with Docker support
# Repository: https://github.com/jeonghanyun/proxmox-lxc-shell-commands
# Last Updated: 2025-12-03

set -euo pipefail

#################################################################
# Configuration Variables
#################################################################

CT_ID=${CT_ID:-50002}
CT_HOSTNAME=${CT_HOSTNAME:-"mathesar"}
CT_CORES=${CT_CORES:-2}
CT_MEMORY=${CT_MEMORY:-2048}
CT_SWAP=${CT_SWAP:-1024}
CT_DISK_SIZE=${CT_DISK_SIZE:-20}

CT_IP=${CT_IP:-"dhcp"}
CT_GATEWAY=${CT_GATEWAY:-""}
CT_BRIDGE=${CT_BRIDGE:-"vmbr0"}
CT_NAMESERVER=${CT_NAMESERVER:-"8.8.8.8"}

CT_STORAGE=${CT_STORAGE:-"local-lvm"}
TEMPLATE_STORAGE=${TEMPLATE_STORAGE:-"local"}

DEBIAN_VERSION="12"
TEMPLATE_NAME=""

MATHESAR_WEB_PORT=${MATHESAR_WEB_PORT:-8000}

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
    pveam update 2>&1 || true

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
    warn "Creating PRIVILEGED container (required for Docker)"

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
        --ostype debian || { error "Failed to create container"; exit 1; }

    success "Container $CT_ID created successfully"
}

configure_lxc_for_docker() {
    info "Configuring LXC container for Docker support..."
    local lxc_conf="/etc/pve/lxc/${CT_ID}.conf"

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
    pct start "$CT_ID" || { error "Failed to start container"; exit 1; }
    info "Waiting for container to boot..."
    sleep 8
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
# Docker Installation Functions
#################################################################

install_docker() {
    info "Installing Docker in container $CT_ID..."

    info "Updating package list..."
    pct exec "$CT_ID" -- bash -c "apt-get update -qq"

    info "Installing required packages..."
    pct exec "$CT_ID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates gnupg lsb-release"

    info "Adding Docker GPG key..."
    pct exec "$CT_ID" -- bash -c "install -m 0755 -d /etc/apt/keyrings"
    pct exec "$CT_ID" -- bash -c "curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
    pct exec "$CT_ID" -- bash -c "chmod a+r /etc/apt/keyrings/docker.gpg"

    info "Adding Docker repository..."
    pct exec "$CT_ID" -- bash -c 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null'

    info "Installing Docker Engine..."
    pct exec "$CT_ID" -- bash -c "apt-get update -qq"
    pct exec "$CT_ID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"

    pct exec "$CT_ID" -- bash -c "systemctl enable docker"
    pct exec "$CT_ID" -- bash -c "systemctl start docker"

    if pct exec "$CT_ID" -- bash -c "docker --version" &>/dev/null; then
        success "Docker installed successfully"
    else
        error "Docker installation failed"
        exit 1
    fi
}

#################################################################
# Mathesar Installation Functions
#################################################################

install_mathesar() {
    info "Installing Mathesar in container $CT_ID..."

    # Create working directory
    pct exec "$CT_ID" -- bash -c "mkdir -p /opt/mathesar"

    # Create docker-compose.yml
    info "Creating docker-compose configuration..."
    pct exec "$CT_ID" -- bash -c 'cat > /opt/mathesar/docker-compose.yml << '\''EOF'\''
services:
  mathesar:
    image: mathesar/mathesar:latest
    container_name: mathesar
    restart: unless-stopped
    ports:
      - "8000:8000"
    environment:
      - DJANGO_DATABASE_URL=postgresql://mathesar:mathesar@db:5432/mathesar
      - SECRET_KEY=your-secret-key-change-me-in-production
      - ALLOWED_HOSTS=*
      - DJANGO_SUPERUSER_PASSWORD=admin
    volumes:
      - mathesar_media:/var/lib/mathesar/media
      - mathesar_static:/var/lib/mathesar/static
    depends_on:
      db:
        condition: service_healthy

  db:
    image: postgres:15
    container_name: mathesar-db
    restart: unless-stopped
    environment:
      - POSTGRES_DB=mathesar
      - POSTGRES_USER=mathesar
      - POSTGRES_PASSWORD=mathesar
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U mathesar"]
      interval: 5s
      timeout: 5s
      retries: 5

volumes:
  mathesar_media:
  mathesar_static:
  pgdata:
EOF'

    # Start Mathesar
    info "Starting Mathesar (downloading images)..."
    pct exec "$CT_ID" -- bash -c "cd /opt/mathesar && docker compose up -d"

    # Wait for startup
    info "Waiting for Mathesar to initialize..."
    sleep 30

    # Check status
    if pct exec "$CT_ID" -- bash -c "docker ps | grep -q mathesar"; then
        success "Mathesar installed and running"
    else
        warn "Mathesar containers may still be starting..."
        info "Check status with: pct exec $CT_ID -- docker ps"
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

    local notes="MATHESAR - PostgreSQL Spreadsheet Interface
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Container ID:    ${CT_ID}
Hostname:        ${CT_HOSTNAME}
IP Address:      ${container_ip}
CPU/Memory:      ${CT_CORES} cores / ${CT_MEMORY}MB

WEB ACCESS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Web UI:          http://${container_ip}:${MATHESAR_WEB_PORT}
Admin Password:  admin (change after first login)

DOCKER MANAGEMENT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Status:          pct exec ${CT_ID} -- docker ps
Logs:            pct exec ${CT_ID} -- docker logs mathesar -f
Restart:         pct exec ${CT_ID} -- docker compose -f /opt/mathesar/docker-compose.yml restart

CONTAINER MANAGEMENT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Enter:           pct enter ${CT_ID}
Stop:            pct stop ${CT_ID}
Start:           pct start ${CT_ID}

AUTO-GENERATED BY: https://github.com/jeonghanyun/proxmox-lxc-shell-commands"

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
    success "Mathesar LXC Container Setup Complete!"
    echo "================================================================="
    echo ""
    echo "Container: $CT_ID ($CT_HOSTNAME)"
    echo "IP:        $container_ip"
    echo ""
    echo "Access:    http://${container_ip}:${MATHESAR_WEB_PORT}"
    echo "Password:  admin"
    echo ""
    echo "Commands:"
    echo "  pct enter $CT_ID"
    echo "  pct exec $CT_ID -- docker ps"
    echo "  pct exec $CT_ID -- docker logs mathesar -f"
    echo ""
    echo "================================================================="
}

#################################################################
# Main Execution
#################################################################

main() {
    info "Starting Mathesar LXC container creation..."
    echo ""

    check_root
    check_proxmox
    check_container_exists
    detect_and_download_template

    create_container
    configure_lxc_for_docker
    start_container
    configure_autologin

    install_docker
    install_mathesar

    add_container_notes
    display_info
}

main "$@"
