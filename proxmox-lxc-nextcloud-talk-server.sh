#!/usr/bin/env bash

# Nextcloud Talk Server (Signaling + TURN) LXC Installation Script
# Description: Creates LXC container with HPB signaling server and coturn TURN server
# OS: Debian 12 (Bookworm)
# Components: nextcloud-spreed-signaling, NATS, Janus Gateway, coturn
# Ports: Signaling: 8081, TURN: 3478 (UDP/TCP), Relay: 49152-49252 (UDP), Janus: 10000-10100 (UDP)
# Repository: https://github.com/jeonghanyun/proxmox-lxc-shell-commands
# Last Updated: 2024-12-09
#
# Usage:
#   CT_ID=11001 EXTERNAL_IP=221.147.34.113 TURN_DOMAIN=turn.example.com ./proxmox-lxc-nextcloud-talk-server.sh
#
# Add Nextcloud backends after installation:
#   pct exec 11001 -- /opt/signaling/add-backend.sh https://nextcloud.example.com

set -euo pipefail

#################################################################
# Configuration Variables
#################################################################

# Container Configuration
CT_ID=${CT_ID:-11001}
CT_HOSTNAME=${CT_HOSTNAME:-"talk-server"}
CT_CORES=${CT_CORES:-2}
CT_MEMORY=${CT_MEMORY:-2048}
CT_SWAP=${CT_SWAP:-1024}
CT_DISK_SIZE=${CT_DISK_SIZE:-20}

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

# Server Configuration
EXTERNAL_IP=${EXTERNAL_IP:-""}                          # Public IP for TURN (REQUIRED)
TURN_DOMAIN=${TURN_DOMAIN:-""}                          # TURN domain (optional, uses IP if not set)
SIGNALING_DOMAIN=${SIGNALING_DOMAIN:-""}                # Signaling domain (optional)

# Ports
SIGNALING_PORT=${SIGNALING_PORT:-8081}
TURN_PORT=${TURN_PORT:-3478}
JANUS_RTP_START=${JANUS_RTP_START:-10000}
JANUS_RTP_END=${JANUS_RTP_END:-10100}
TURN_RELAY_START=${TURN_RELAY_START:-49152}
TURN_RELAY_END=${TURN_RELAY_END:-49252}

# Directories
SIGNALING_DIR="/opt/signaling"

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
MAGENTA='\033[0;35m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
progress() { echo -e "${MAGENTA}[...]${NC} $1"; }

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

check_required_vars() {
    if [[ -z "$EXTERNAL_IP" ]]; then
        error "EXTERNAL_IP is required (public IP for TURN server)"
        error "Usage: CT_ID=11001 EXTERNAL_IP=1.2.3.4 $0"
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
    info "Detecting available Debian ${DEBIAN_VERSION} template..."

    pveam update &>/dev/null || true

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

    progress "Downloading Debian template..."
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME"
    success "Template downloaded"
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
        --ostype debian

    success "Container $CT_ID created"
}

start_container() {
    info "Starting container $CT_ID..."
    pct start "$CT_ID"
    sleep 5
    success "Container started"
}

#################################################################
# Docker Installation
#################################################################

install_docker() {
    info "Installing Docker..."

    pct exec "$CT_ID" -- bash -c "apt-get update -qq"
    pct exec "$CT_ID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        ca-certificates curl gnupg lsb-release"

    pct exec "$CT_ID" -- bash -c "install -m 0755 -d /etc/apt/keyrings"
    pct exec "$CT_ID" -- bash -c "curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
    pct exec "$CT_ID" -- bash -c "chmod a+r /etc/apt/keyrings/docker.gpg"
    pct exec "$CT_ID" -- bash -c 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list'

    pct exec "$CT_ID" -- bash -c "apt-get update -qq"
    pct exec "$CT_ID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin"

    pct exec "$CT_ID" -- bash -c "systemctl start docker && systemctl enable docker"

    success "Docker installed"
}

#################################################################
# Generate Secrets
#################################################################

generate_secrets() {
    HASH_KEY=$(openssl rand -hex 32)
    BLOCK_KEY=$(openssl rand -hex 16)
    BACKEND_SECRET=$(openssl rand -hex 32)
    TURN_SECRET=$(openssl rand -hex 32)
}

#################################################################
# Signaling Server Setup
#################################################################

setup_signaling_server() {
    info "Setting up signaling server..."

    pct exec "$CT_ID" -- bash -c "mkdir -p ${SIGNALING_DIR}/janus"

    # Create docker-compose.yml
    pct exec "$CT_ID" -- bash -c "cat > ${SIGNALING_DIR}/docker-compose.yml" <<EOF
services:
  signaling:
    image: strukturag/nextcloud-spreed-signaling:latest
    container_name: nextcloud-signaling
    restart: always
    ports:
      - "${SIGNALING_PORT}:8080"
    volumes:
      - ./server.conf:/config/server.conf:ro
    depends_on:
      - nats
      - janus

  nats:
    image: nats:latest
    container_name: nextcloud-nats
    restart: always

  janus:
    image: canyan/janus-gateway:latest
    container_name: nextcloud-janus
    restart: always
    ports:
      - "8088:8088"
      - "8188:8188"
      - "${JANUS_RTP_START}-${JANUS_RTP_END}:${JANUS_RTP_START}-${JANUS_RTP_END}/udp"
    volumes:
      - ./janus/janus.jcfg:/usr/local/etc/janus/janus.jcfg:ro
    command: ["/usr/local/bin/janus"]

  coturn:
    image: coturn/coturn:latest
    container_name: nextcloud-coturn
    restart: always
    network_mode: host
    volumes:
      - ./turnserver.conf:/etc/turnserver.conf:ro
    command: ["-c", "/etc/turnserver.conf"]
EOF

    # Create server.conf (allowall=true with global secret for easier setup)
    pct exec "$CT_ID" -- bash -c "cat > ${SIGNALING_DIR}/server.conf" <<EOF
[http]
listen = 0.0.0.0:8080

[sessions]
hashkey = ${HASH_KEY}
blockkey = ${BLOCK_KEY}

[backend]
backends =
allowall = true
secret = ${BACKEND_SECRET}

[nats]
url = nats://nats:4222

[mcu]
type = janus
url = ws://janus:8188
EOF

    # Create Janus config
    local turn_server="${TURN_DOMAIN:-$EXTERNAL_IP}"
    pct exec "$CT_ID" -- bash -c "cat > ${SIGNALING_DIR}/janus/janus.jcfg" <<EOF
general: {
    configs_folder = "/usr/local/etc/janus"
    plugins_folder = "/usr/local/lib/janus/plugins"
    transports_folder = "/usr/local/lib/janus/transports"
    events_folder = "/usr/local/lib/janus/events"
    loggers_folder = "/usr/local/lib/janus/loggers"
    debug_level = 4
    admin_secret = "janusoverlord"
    protected_folders = [
        "/bin", "/boot", "/dev", "/etc", "/initrd", "/lib", "/lib32", "/lib64",
        "/proc", "/sbin", "/sys", "/usr", "/var",
        "/opt/janus/bin", "/opt/janus/etc", "/opt/janus/include",
        "/opt/janus/lib", "/opt/janus/lib32", "/opt/janus/lib64", "/opt/janus/sbin"
    ]
}

certificates: {
}

media: {
    rtp_port_range = "${JANUS_RTP_START}-${JANUS_RTP_END}"
}

nat: {
    stun_server = "stun.l.google.com"
    stun_port = 19302
    nice_debug = false
    nat_1_1_mapping = "${EXTERNAL_IP}"
    ice_ignore_list = "vmnet"
}

plugins: {
}

transports: {
}

loggers: {
}

events: {
}
EOF

    # Create turnserver.conf
    local realm="${TURN_DOMAIN:-turn.local}"
    pct exec "$CT_ID" -- bash -c "cat > ${SIGNALING_DIR}/turnserver.conf" <<EOF
listening-port=${TURN_PORT}
external-ip=${EXTERNAL_IP}
min-port=${TURN_RELAY_START}
max-port=${TURN_RELAY_END}
realm=${realm}
lt-cred-mech
use-auth-secret
static-auth-secret=${TURN_SECRET}
verbose
log-file=stdout
fingerprint
no-tls
no-dtls
no-cli
EOF

    # Create .env file with secrets
    pct exec "$CT_ID" -- bash -c "cat > ${SIGNALING_DIR}/.env" <<EOF
BACKEND_SECRET=${BACKEND_SECRET}
TURN_SECRET=${TURN_SECRET}
EXTERNAL_IP=${EXTERNAL_IP}
EOF

    success "Signaling server configured"
}

#################################################################
# Backend Management Script
#################################################################

create_backend_script() {
    info "Creating backend management script..."

    pct exec "$CT_ID" -- bash -c "cat > ${SIGNALING_DIR}/add-backend.sh" <<'SCRIPT'
#!/bin/bash
# Add Nextcloud backend to signaling server
# Usage: ./add-backend.sh https://nextcloud.example.com [backend-name]

set -e

NEXTCLOUD_URL="$1"
BACKEND_NAME="${2:-backend-$(date +%s)}"

if [[ -z "$NEXTCLOUD_URL" ]]; then
    echo "Usage: $0 <nextcloud-url> [backend-name]"
    echo "Example: $0 https://nextcloud.example.com backend-1"
    exit 1
fi

source /opt/signaling/.env

CONFIG_FILE="/opt/signaling/server.conf"

# Check if backend already exists
if grep -q "url = ${NEXTCLOUD_URL}" "$CONFIG_FILE" 2>/dev/null; then
    echo "Backend for ${NEXTCLOUD_URL} already exists"
    exit 0
fi

# Get current backends list
CURRENT_BACKENDS=$(grep "^backends = " "$CONFIG_FILE" | cut -d'=' -f2 | tr -d ' ')

if [[ -z "$CURRENT_BACKENDS" ]]; then
    NEW_BACKENDS="${BACKEND_NAME}"
else
    NEW_BACKENDS="${CURRENT_BACKENDS},${BACKEND_NAME}"
fi

# Update backends list
sed -i "s/^backends = .*/backends = ${NEW_BACKENDS}/" "$CONFIG_FILE"

# Add new backend section
cat >> "$CONFIG_FILE" <<EOF

[backend-${BACKEND_NAME}]
url = ${NEXTCLOUD_URL}
secret = ${BACKEND_SECRET}
EOF

echo "Backend added: ${BACKEND_NAME} -> ${NEXTCLOUD_URL}"
echo "Secret: ${BACKEND_SECRET}"
echo ""
echo "Restarting signaling server..."
cd /opt/signaling && docker compose restart signaling

echo ""
echo "Add this to your Nextcloud Talk settings:"
echo "  Signaling server: https://your-signaling-domain"
echo "  Secret: ${BACKEND_SECRET}"
echo ""
echo "Or run on Nextcloud server:"
echo "  sudo -u www-data php occ config:app:set spreed signaling_servers \\"
echo "    --value='{\"servers\":[{\"server\":\"https://your-signaling-domain\",\"verify\":true}],\"secret\":\"${BACKEND_SECRET}\"}'"
SCRIPT

    pct exec "$CT_ID" -- bash -c "chmod +x ${SIGNALING_DIR}/add-backend.sh"

    # Create TURN info script
    pct exec "$CT_ID" -- bash -c "cat > ${SIGNALING_DIR}/turn-info.sh" <<'SCRIPT'
#!/bin/bash
# Display TURN server configuration for Nextcloud

source /opt/signaling/.env

TURN_SERVER="${TURN_DOMAIN:-$EXTERNAL_IP}"

echo "========================================"
echo "TURN Server Configuration for Nextcloud"
echo "========================================"
echo ""
echo "TURN Server: ${TURN_SERVER}:3478"
echo "Secret: ${TURN_SECRET}"
echo "Protocols: udp,tcp"
echo ""
echo "Add to Nextcloud Talk (use occ command):"
echo "  sudo -u www-data php occ talk:turn:add turn ${TURN_SERVER}:3478 udp,tcp --secret=${TURN_SECRET}"
echo ""
echo "Or via config (legacy format):"
echo "  sudo -u www-data php occ config:app:set spreed turn_servers \\"
echo "    --value='[{\"schemes\":\"turn\",\"server\":\"${TURN_SERVER}:3478\",\"secret\":\"${TURN_SECRET}\",\"protocols\":\"udp,tcp\"}]'"
echo ""
SCRIPT

    pct exec "$CT_ID" -- bash -c "chmod +x ${SIGNALING_DIR}/turn-info.sh"

    success "Management scripts created"
}

#################################################################
# Start Services
#################################################################

start_services() {
    info "Starting services..."

    pct exec "$CT_ID" -- bash -c "cd ${SIGNALING_DIR} && docker compose pull"
    pct exec "$CT_ID" -- bash -c "cd ${SIGNALING_DIR} && docker compose up -d"

    progress "Waiting for services to start..."
    sleep 15

    # Check status
    if pct exec "$CT_ID" -- bash -c "docker ps | grep -q nextcloud-signaling"; then
        success "Signaling server running"
    else
        error "Signaling server failed to start"
        pct exec "$CT_ID" -- bash -c "docker logs nextcloud-signaling"
        exit 1
    fi

    if pct exec "$CT_ID" -- bash -c "docker ps | grep -q nextcloud-coturn"; then
        success "TURN server running"
    else
        error "TURN server failed to start"
        pct exec "$CT_ID" -- bash -c "docker logs nextcloud-coturn"
        exit 1
    fi
}

#################################################################
# Container Notes
#################################################################

add_container_notes() {
    info "Adding container notes..."

    local container_ip
    if [[ "$CT_IP" == "dhcp" ]]; then
        sleep 3
        container_ip=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}')
    else
        container_ip="${CT_IP%/*}"
    fi

    local turn_server="${TURN_DOMAIN:-$EXTERNAL_IP}"

    local notes="NEXTCLOUD TALK SERVER (Signaling + TURN)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📋 CONTAINER DETAILS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Container ID:    ${CT_ID}
Hostname:        ${CT_HOSTNAME}
Internal IP:     ${container_ip}
External IP:     ${EXTERNAL_IP}
CPU Cores:       ${CT_CORES}
Memory:          ${CT_MEMORY}MB

🌐 SERVICE PORTS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Signaling:       ${SIGNALING_PORT} (HTTP)
TURN:            ${TURN_PORT} (UDP/TCP)
Janus RTP:       ${JANUS_RTP_START}-${JANUS_RTP_END} (UDP)
TURN Relay:      ${TURN_RELAY_START}-${TURN_RELAY_END} (UDP)

🔑 SECRETS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Backend Secret:  ${BACKEND_SECRET}
TURN Secret:     ${TURN_SECRET}

📝 ADD NEXTCLOUD BACKEND
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
pct exec ${CT_ID} -- ${SIGNALING_DIR}/add-backend.sh https://nextcloud.example.com

📝 NEXTCLOUD TALK SETTINGS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Signaling URL:   https://your-signaling-domain
TURN Server:     turn:${turn_server}:${TURN_PORT}

🔧 SERVICE MANAGEMENT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Status:          pct exec ${CT_ID} -- docker ps
Logs:            pct exec ${CT_ID} -- docker compose -f ${SIGNALING_DIR}/docker-compose.yml logs -f
Restart:         pct exec ${CT_ID} -- docker compose -f ${SIGNALING_DIR}/docker-compose.yml restart
TURN Info:       pct exec ${CT_ID} -- ${SIGNALING_DIR}/turn-info.sh

ℹ️  AUTO-GENERATED BY: https://github.com/jeonghanyun/proxmox-lxc-shell-commands"

    pct set "$CT_ID" -description "$notes" 2>/dev/null || true
    success "Container notes added"
}

#################################################################
# Display Information
#################################################################

display_info() {
    local container_ip
    if [[ "$CT_IP" == "dhcp" ]]; then
        container_ip=$(pct exec "$CT_ID" -- hostname -I | awk '{print $1}')
    else
        container_ip="${CT_IP%/*}"
    fi

    local turn_server="${TURN_DOMAIN:-$EXTERNAL_IP}"

    echo ""
    echo "================================================================="
    success "Nextcloud Talk Server Setup Complete!"
    echo "================================================================="
    echo ""
    echo "Container Details:"
    echo "  • Container ID:      $CT_ID"
    echo "  • Internal IP:       $container_ip"
    echo "  • External IP:       $EXTERNAL_IP"
    echo ""
    echo "Services:"
    echo "  • Signaling:         http://${container_ip}:${SIGNALING_PORT}"
    echo "  • TURN:              turn:${turn_server}:${TURN_PORT}"
    echo ""
    echo "Secrets:"
    echo "  • Backend Secret:    $BACKEND_SECRET"
    echo "  • TURN Secret:       $TURN_SECRET"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Next Steps:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "1. Configure reverse proxy for signaling server (HTTPS)"
    echo ""
    echo "2. Add Nextcloud backend:"
    echo "   pct exec $CT_ID -- ${SIGNALING_DIR}/add-backend.sh https://nextcloud.example.com"
    echo ""
    echo "3. Configure Nextcloud Talk (run on Nextcloud server):"
    echo ""
    echo "   # Signaling server"
    echo "   sudo -u www-data php occ talk:signaling:add https://your-signaling-domain ${BACKEND_SECRET} --verify"
    echo ""
    echo "   # TURN server (correct format - no 'turn:' prefix in server field)"
    echo "   sudo -u www-data php occ talk:turn:add turn ${turn_server}:${TURN_PORT} udp,tcp --secret=${TURN_SECRET}"
    echo ""
    echo "   # STUN servers"
    echo "   sudo -u www-data php occ config:app:set spreed stun_servers \\"
    echo "     --value='[\"stun.nextcloud.com:443\",\"stun.l.google.com:19302\"]'"
    echo ""
    echo "4. Open firewall ports:"
    echo "   • ${TURN_PORT} UDP/TCP (TURN)"
    echo "   • ${TURN_RELAY_START}-${TURN_RELAY_END} UDP (Relay)"
    echo "   • ${JANUS_RTP_START}-${JANUS_RTP_END} UDP (Janus RTP)"
    echo ""
    echo "================================================================="
}

#################################################################
# Main Execution
#################################################################

main() {
    echo ""
    echo "================================================================="
    info "Nextcloud Talk Server (Signaling + TURN) Installation"
    echo "================================================================="
    echo ""

    # Pre-flight checks
    check_root
    check_proxmox
    check_required_vars
    check_container_exists
    detect_and_download_template

    # Generate secrets
    generate_secrets

    # Create and configure container
    create_container
    start_container

    # Install Docker
    install_docker

    # Setup services
    setup_signaling_server
    create_backend_script
    start_services

    # Finalize
    add_container_notes
    display_info
}

main "$@"
