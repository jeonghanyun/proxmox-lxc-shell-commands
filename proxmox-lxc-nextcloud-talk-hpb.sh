#!/usr/bin/env bash

# Nextcloud Talk High-Performance Backend (HPB) Setup Script
# Description: Configures HPB signaling server with Docker (NATS + Janus Gateway)
# Requirements: Existing Nextcloud LXC container with Talk app installed
# Components: nextcloud-spreed-signaling, NATS, Janus Gateway
# Repository: https://github.com/jeonghanyun/proxmox-lxc-shell-commands
# Last Updated: 2025-12-02
#
# Usage:
#   CT_ID=20001 NEXTCLOUD_URL=https://nextcloud.example.com SIGNALING_URL=https://signaling.example.com ./proxmox-lxc-nextcloud-talk-hpb.sh
#
# Notes:
#   - Requires Docker to be installed in the container
#   - Signaling server runs on port 8081 (internal), reverse proxy required for HTTPS
#   - External signaling mode is configured automatically

set -euo pipefail

#################################################################
# Configuration Variables
#################################################################

# Container Configuration
CT_ID=${CT_ID:-""}                                      # Container ID (REQUIRED)

# Nextcloud Configuration
NEXTCLOUD_URL=${NEXTCLOUD_URL:-""}                      # Nextcloud URL (REQUIRED, e.g., https://nextcloud.example.com)
SIGNALING_URL=${SIGNALING_URL:-""}                      # Signaling server URL (REQUIRED, e.g., https://signaling.example.com)

# Signaling Server Configuration
SIGNALING_PORT=${SIGNALING_PORT:-8081}                  # Internal port for signaling server
SIGNALING_DIR="/opt/signaling"                          # Directory for signaling server files

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
    if [[ -z "$CT_ID" ]]; then
        error "CT_ID is required. Usage: CT_ID=20001 NEXTCLOUD_URL=https://... SIGNALING_URL=https://... $0"
        exit 1
    fi

    if [[ -z "$NEXTCLOUD_URL" ]]; then
        error "NEXTCLOUD_URL is required (e.g., https://nextcloud.example.com)"
        exit 1
    fi

    if [[ -z "$SIGNALING_URL" ]]; then
        error "SIGNALING_URL is required (e.g., https://signaling.example.com)"
        exit 1
    fi
}

check_container_exists() {
    if ! pct status "$CT_ID" &> /dev/null; then
        error "Container $CT_ID does not exist"
        exit 1
    fi

    if [[ "$(pct status "$CT_ID" | awk '{print $2}')" != "running" ]]; then
        error "Container $CT_ID is not running"
        exit 1
    fi
}

check_talk_installed() {
    info "Checking if Nextcloud Talk is installed..."
    if ! pct exec "$CT_ID" -- bash -c "sudo -u www-data php /var/www/nextcloud/occ app:list --enabled 2>/dev/null | grep -q spreed"; then
        error "Nextcloud Talk (spreed) is not installed or enabled"
        info "Install Talk first: sudo -u www-data php /var/www/nextcloud/occ app:install spreed"
        exit 1
    fi
    success "Nextcloud Talk is installed"
}

#################################################################
# Docker Installation Functions
#################################################################

install_docker() {
    info "Checking Docker installation..."

    if pct exec "$CT_ID" -- bash -c "command -v docker &> /dev/null"; then
        success "Docker is already installed"
        return 0
    fi

    progress "Installing Docker..."

    # Install prerequisites
    pct exec "$CT_ID" -- bash -c "apt-get update -qq"
    pct exec "$CT_ID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        ca-certificates \
        curl \
        gnupg \
        lsb-release"

    # Add Docker's official GPG key
    pct exec "$CT_ID" -- bash -c "install -m 0755 -d /etc/apt/keyrings"
    pct exec "$CT_ID" -- bash -c "curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
    pct exec "$CT_ID" -- bash -c "chmod a+r /etc/apt/keyrings/docker.gpg"

    # Add Docker repository
    pct exec "$CT_ID" -- bash -c 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list'

    # Install Docker
    pct exec "$CT_ID" -- bash -c "apt-get update -qq"
    pct exec "$CT_ID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin"

    # Start and enable Docker
    pct exec "$CT_ID" -- bash -c "systemctl start docker"
    pct exec "$CT_ID" -- bash -c "systemctl enable docker"

    success "Docker installed successfully"
}

#################################################################
# Signaling Server Setup Functions
#################################################################

generate_secrets() {
    # Generate random secrets for signaling server
    HASH_KEY=$(openssl rand -hex 32)
    BLOCK_KEY=$(openssl rand -hex 16)
    BACKEND_SECRET=$(openssl rand -hex 32)
}

create_signaling_config() {
    info "Creating signaling server configuration..."

    generate_secrets

    # Create signaling directory
    pct exec "$CT_ID" -- bash -c "mkdir -p ${SIGNALING_DIR}"

    # Create docker-compose.yml
    pct exec "$CT_ID" -- bash -c "cat > ${SIGNALING_DIR}/docker-compose.yml" <<EOF
services:
  signaling:
    image: strukturag/nextcloud-spreed-signaling:latest
    container_name: nextcloud-signaling
    restart: always
    ports:
      - '${SIGNALING_PORT}:8080'
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
      - '8088:8088'
      - '8188:8188'
    command: ["/usr/local/bin/janus"]
EOF

    # Create server.conf
    pct exec "$CT_ID" -- bash -c "cat > ${SIGNALING_DIR}/server.conf" <<EOF
[http]
listen = 0.0.0.0:8080

[sessions]
hashkey = ${HASH_KEY}
blockkey = ${BLOCK_KEY}

[backend]
backends = backend-1
allowall = false

[backend-1]
url = ${NEXTCLOUD_URL}
secret = ${BACKEND_SECRET}

[nats]
url = nats://nats:4222

[mcu]
type = janus
url = ws://janus:8188
EOF

    success "Signaling server configuration created"
}

start_signaling_server() {
    info "Starting signaling server containers..."

    pct exec "$CT_ID" -- bash -c "cd ${SIGNALING_DIR} && docker compose pull"
    pct exec "$CT_ID" -- bash -c "cd ${SIGNALING_DIR} && docker compose up -d"

    # Wait for containers to be ready
    progress "Waiting for containers to start..."
    sleep 10

    # Check container status
    if pct exec "$CT_ID" -- bash -c "docker ps | grep -q nextcloud-signaling"; then
        success "Signaling server is running"
    else
        error "Signaling server failed to start"
        pct exec "$CT_ID" -- bash -c "cd ${SIGNALING_DIR} && docker compose logs"
        exit 1
    fi
}

#################################################################
# Nextcloud Configuration Functions
#################################################################

configure_nextcloud_hpb() {
    info "Configuring Nextcloud Talk for external signaling..."

    # Set signaling mode to external
    pct exec "$CT_ID" -- bash -c "sudo -u www-data php /var/www/nextcloud/occ config:app:set spreed signaling_mode --value=external"

    # Remove any existing signaling servers
    pct exec "$CT_ID" -- bash -c "sudo -u www-data php /var/www/nextcloud/occ talk:signaling:delete 0 2>/dev/null || true"

    # Add new signaling server
    pct exec "$CT_ID" -- bash -c "sudo -u www-data php /var/www/nextcloud/occ talk:signaling:add '${SIGNALING_URL}' '${BACKEND_SECRET}' --verify"

    success "Nextcloud Talk HPB configured"
}

verify_configuration() {
    info "Verifying HPB configuration..."

    echo ""
    echo "Signaling Server Status:"
    pct exec "$CT_ID" -- bash -c "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E '(NAMES|nextcloud-)'"

    echo ""
    echo "Nextcloud Talk Signaling Configuration:"
    pct exec "$CT_ID" -- bash -c "sudo -u www-data php /var/www/nextcloud/occ talk:signaling:list"

    echo ""
    success "Verification complete"
}

#################################################################
# Information Display Functions
#################################################################

display_info() {
    echo ""
    echo "================================================================="
    success "Nextcloud Talk HPB Setup Complete!"
    echo "================================================================="
    echo ""
    info "Configuration Summary:"
    echo "  • Container ID:        $CT_ID"
    echo "  • Nextcloud URL:       $NEXTCLOUD_URL"
    echo "  • Signaling URL:       $SIGNALING_URL"
    echo "  • Signaling Port:      $SIGNALING_PORT (internal)"
    echo "  • Backend Secret:      $BACKEND_SECRET"
    echo ""
    info "Docker Containers:"
    echo "  • nextcloud-signaling  - Signaling server"
    echo "  • nextcloud-nats       - NATS message broker"
    echo "  • nextcloud-janus      - Janus WebRTC gateway"
    echo ""
    info "Configuration Files:"
    echo "  • ${SIGNALING_DIR}/docker-compose.yml"
    echo "  • ${SIGNALING_DIR}/server.conf"
    echo ""
    info "Management Commands:"
    echo "  • View logs:     pct exec $CT_ID -- docker compose -f ${SIGNALING_DIR}/docker-compose.yml logs -f"
    echo "  • Restart:       pct exec $CT_ID -- docker compose -f ${SIGNALING_DIR}/docker-compose.yml restart"
    echo "  • Stop:          pct exec $CT_ID -- docker compose -f ${SIGNALING_DIR}/docker-compose.yml down"
    echo "  • Start:         pct exec $CT_ID -- docker compose -f ${SIGNALING_DIR}/docker-compose.yml up -d"
    echo ""
    warn "IMPORTANT: Configure your reverse proxy to forward ${SIGNALING_URL} to localhost:${SIGNALING_PORT}"
    echo ""
    echo "================================================================="
}

#################################################################
# Main Execution
#################################################################

main() {
    echo ""
    echo "================================================================="
    info "Nextcloud Talk High-Performance Backend Setup"
    echo "================================================================="
    echo ""

    # Pre-flight checks
    info "Running pre-flight checks..."
    check_root
    check_proxmox
    check_required_vars
    check_container_exists
    check_talk_installed

    # Install Docker if needed
    install_docker

    # Setup signaling server
    create_signaling_config
    start_signaling_server

    # Configure Nextcloud
    configure_nextcloud_hpb
    verify_configuration

    # Display information
    display_info
}

# Run main function
main "$@"
