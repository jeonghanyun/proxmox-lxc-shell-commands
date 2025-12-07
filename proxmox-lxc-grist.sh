#!/usr/bin/env bash

# Grist LXC Installation Script
# Description: Install Grist - Modern Spreadsheet with Keycloak SSO, Mailpit & Custom Widgets
# OS: Debian 12 (Bookworm)
# Ports: Web UI: 8484, Mailpit Web: 8025, Mailpit SMTP: 1025, Widgets: 8585
# Repository: https://github.com/jeonghanyun/proxmox-lxc-shell-commands
# Last Updated: 2025-12

set -euo pipefail

#################################################################
# Configuration Variables
#################################################################

# Container Configuration
CT_ID=${CT_ID:-24006}
CT_HOSTNAME=${CT_HOSTNAME:-"grist"}
CT_CORES=${CT_CORES:-2}
CT_MEMORY=${CT_MEMORY:-2048}
CT_SWAP=${CT_SWAP:-1024}
CT_DISK_SIZE=${CT_DISK_SIZE:-10}

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

# Grist Configuration
GRIST_PORT=${GRIST_PORT:-8484}
GRIST_ORG=${GRIST_ORG:-"gupsa"}
GRIST_ADMIN_EMAIL=${GRIST_ADMIN_EMAIL:-"jeonghan.yun@gupsa.com"}
GRIST_DOMAIN=${GRIST_DOMAIN:-"grist.gupsa.net"}

# Locale & API Configuration
GRIST_LOCALE=${GRIST_LOCALE:-"ko"}
GRIST_CURRENCY=${GRIST_CURRENCY:-"KRW"}
GRIST_BOOT_KEY=${GRIST_BOOT_KEY:-"grist-api-boot-key-$(date +%s)"}
GRIST_API_SECRET=${GRIST_API_SECRET:-"grist-api-secret-$(date +%s)"}

# Keycloak SSO Configuration
KEYCLOAK_ENABLED=${KEYCLOAK_ENABLED:-true}
KEYCLOAK_REALM=${KEYCLOAK_REALM:-"master"}
KEYCLOAK_URL=${KEYCLOAK_URL:-"https://keycloak.gupsa.net"}
KEYCLOAK_CLIENT_ID=${KEYCLOAK_CLIENT_ID:-"grist"}
KEYCLOAK_CLIENT_SECRET=${KEYCLOAK_CLIENT_SECRET:-"grist-secret-2024"}

# Mailpit Configuration
MAILPIT_WEB_PORT=${MAILPIT_WEB_PORT:-8025}
MAILPIT_SMTP_PORT=${MAILPIT_SMTP_PORT:-1025}

# Widget Configuration
WIDGETS_ENABLED=${WIDGETS_ENABLED:-true}
WIDGETS_PORT=${WIDGETS_PORT:-8585}
WIDGETS_REPO=${WIDGETS_REPO:-"https://github.com/gristlabs/grist-widget.git"}

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
# Docker Installation
#################################################################

install_docker() {
    info "Installing Docker..."

    pct exec "$CT_ID" -- bash -c "apt-get update -qq"
    pct exec "$CT_ID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates gnupg sqlite3"

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

#################################################################
# Grist Installation Functions
#################################################################

install_grist() {
    info "Installing Grist with Mailpit..."

    # Create Grist directory
    pct exec "$CT_ID" -- bash -c "mkdir -p /opt/grist"

    # Build docker-compose.yml based on configuration
    local grist_env=""

    # Base environment
    grist_env+="      - APP_HOME_URL=https://${GRIST_DOMAIN}\n"
    grist_env+="      - GRIST_SINGLE_ORG=${GRIST_ORG}\n"
    grist_env+="      - GRIST_ORG_IN_PATH=false\n"
    grist_env+="      - GRIST_DEFAULT_EMAIL=${GRIST_ADMIN_EMAIL}\n"
    grist_env+="      - GRIST_FORCE_LOGIN=true\n"
    grist_env+="      - GRIST_DEFAULT_PRODUCT=team\n"
    grist_env+="      # Locale & Currency\n"
    grist_env+="      - GRIST_DEFAULT_LOCALE=${GRIST_LOCALE}\n"
    grist_env+="      - GRIST_DEFAULT_CURRENCY=${GRIST_CURRENCY}\n"
    grist_env+="      # API Configuration\n"
    grist_env+="      - GRIST_BOOT_KEY=${GRIST_BOOT_KEY}\n"
    grist_env+="      - GRIST_API_KEY_SECRET=${GRIST_API_SECRET}\n"

    # Keycloak SSO if enabled
    if [[ "$KEYCLOAK_ENABLED" == "true" ]]; then
        grist_env+="      # OIDC Configuration for Keycloak\n"
        grist_env+="      - GRIST_OIDC_IDP_ISSUER=${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}\n"
        grist_env+="      - GRIST_OIDC_IDP_CLIENT_ID=${KEYCLOAK_CLIENT_ID}\n"
        grist_env+="      - GRIST_OIDC_IDP_CLIENT_SECRET=${KEYCLOAK_CLIENT_SECRET}\n"
        grist_env+="      - GRIST_OIDC_IDP_SCOPES=openid email profile\n"
    fi

    # SMTP and other settings
    grist_env+="      # SMTP Configuration (Mailpit)\n"
    grist_env+="      - GRIST_SMTP_HOST=mailpit\n"
    grist_env+="      - GRIST_SMTP_PORT=1025\n"
    grist_env+="      - GRIST_SMTP_FROM=grist@${GRIST_DOMAIN#*.}\n"
    grist_env+="      # Session\n"
    grist_env+="      - GRIST_SESSION_SECRET=grist-session-secret-$(date +%s)\n"
    grist_env+="      # Timezone\n"
    grist_env+="      - TZ=Asia/Seoul"

    # Add widget configuration if enabled
    local widget_config=""
    local extra_hosts=""
    if [[ "$WIDGETS_ENABLED" == "true" ]]; then
        grist_env+="\n      # Custom Widgets\n"
        grist_env+="      - GRIST_WIDGET_LIST_URL=http://host.docker.internal:${WIDGETS_PORT}/manifest.json"
        extra_hosts="    extra_hosts:\n      - \"host.docker.internal:host-gateway\""
    fi

    # Create docker-compose.yml
    pct exec "$CT_ID" -- bash -c "cat > /opt/grist/docker-compose.yml << 'EOF'
services:
  grist:
    image: gristlabs/grist
    container_name: grist
    ports:
      - \"${GRIST_PORT}:8484\"
$(if [[ -n "$extra_hosts" ]]; then echo -e "$extra_hosts"; fi)
    environment:
$(echo -e "$grist_env")
    volumes:
      - grist_data:/persist
    depends_on:
      - mailpit
    restart: unless-stopped

  mailpit:
    image: axllent/mailpit
    container_name: mailpit
    ports:
      - \"${MAILPIT_WEB_PORT}:8025\"
      - \"${MAILPIT_SMTP_PORT}:1025\"
    environment:
      - TZ=Asia/Seoul
    volumes:
      - mailpit_data:/data
    restart: unless-stopped

volumes:
  grist_data:
  mailpit_data:
EOF"

    # Pull and start containers
    info "Pulling Docker images (this may take several minutes)..."
    pct exec "$CT_ID" -- bash -c "cd /opt/grist && docker compose pull"

    info "Starting Grist and Mailpit..."
    pct exec "$CT_ID" -- bash -c "cd /opt/grist && docker compose up -d"

    # Wait for startup
    info "Waiting for Grist to initialize..."
    local max_attempts=30
    local attempt=0
    while [[ $attempt -lt $max_attempts ]]; do
        if pct exec "$CT_ID" -- bash -c "docker ps --format '{{.Names}}' | grep -q grist" 2>/dev/null; then
            local status
            status=$(pct exec "$CT_ID" -- bash -c "docker inspect --format='{{.State.Status}}' grist" 2>/dev/null || echo "unknown")
            if [[ "$status" == "running" ]]; then
                success "Grist is running"
                break
            fi
        fi
        sleep 3
        ((attempt++))
    done

    if [[ $attempt -eq $max_attempts ]]; then
        warn "Grist may still be initializing. Check status with: pct exec $CT_ID -- docker ps"
    fi
}

#################################################################
# Widget Installation Functions
#################################################################

install_widgets() {
    if [[ "$WIDGETS_ENABLED" != "true" ]]; then
        info "Widgets disabled, skipping..."
        return 0
    fi

    info "Installing Grist custom widgets..."

    # Install required packages (git, nginx, nodejs, npm)
    pct exec "$CT_ID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git nginx nodejs npm"

    # Clone grist-widget repository
    pct exec "$CT_ID" -- bash -c "cd /opt && git clone ${WIDGETS_REPO}"

    # Install dependencies and build
    info "Building widgets (this may take a few minutes)..."
    pct exec "$CT_ID" -- bash -c "cd /opt/grist-widget && npm install --legacy-peer-deps"
    pct exec "$CT_ID" -- bash -c "cd /opt/grist-widget && git submodule update --init --recursive"
    pct exec "$CT_ID" -- bash -c "cd /opt/grist-widget && npx tsc --build"

    # Get container IP for widget URLs
    local container_ip
    container_ip=$(pct exec "$CT_ID" -- hostname -I | awk '{print $1}')

    # Build manifest with correct URL
    pct exec "$CT_ID" -- bash -c "cd /opt/grist-widget && node ./buildtools/publish.js manifest.json http://${container_ip}:${WIDGETS_PORT}"

    # Configure nginx for widget serving
    pct exec "$CT_ID" -- bash -c "cat > /etc/nginx/sites-available/grist-widget << 'NGINXEOF'
server {
    listen ${WIDGETS_PORT};
    root /opt/grist-widget;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
        add_header Access-Control-Allow-Origin *;
        add_header Access-Control-Allow-Methods 'GET, POST, OPTIONS';
        add_header Access-Control-Allow-Headers 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
    }

    location ~* \.(json|js|css|html)$ {
        add_header Access-Control-Allow-Origin *;
        add_header Cache-Control 'no-cache';
    }
}
NGINXEOF"

    # Enable nginx site and start
    pct exec "$CT_ID" -- bash -c "ln -sf /etc/nginx/sites-available/grist-widget /etc/nginx/sites-enabled/"
    pct exec "$CT_ID" -- bash -c "nginx -t && systemctl enable nginx && systemctl restart nginx"

    # Count installed widgets
    local widget_count
    widget_count=$(pct exec "$CT_ID" -- bash -c "curl -s http://localhost:${WIDGETS_PORT}/manifest.json | grep -c '\"name\"'" 2>/dev/null || echo "0")

    success "Installed ${widget_count} custom widgets"
}

configure_grist_permissions() {
    info "Configuring Grist organization permissions..."

    # Wait for database to be created
    sleep 10

    # Find the Grist data volume path
    local volume_path
    volume_path=$(pct exec "$CT_ID" -- bash -c "docker volume inspect grist_grist_data 2>/dev/null | grep Mountpoint | awk -F'\"' '{print \$4}'" || echo "")

    if [[ -z "$volume_path" ]]; then
        warn "Could not find Grist data volume, skipping permission configuration"
        return 1
    fi

    # Wait for home.sqlite3 to be created
    local db_attempts=0
    while [[ $db_attempts -lt 20 ]]; do
        if pct exec "$CT_ID" -- bash -c "test -f ${volume_path}/home.sqlite3" 2>/dev/null; then
            break
        fi
        sleep 3
        ((db_attempts++))
    done

    if [[ $db_attempts -eq 20 ]]; then
        warn "Database not ready, skipping permission configuration"
        return 1
    fi

    # Configure database to allow all SSO users to access the org
    info "Setting up organization access for all SSO users..."

    pct exec "$CT_ID" -- bash -c "
        DB='${volume_path}/home.sqlite3'

        # Wait a bit more for tables to be fully created
        sleep 5

        # Get the org ID for our organization
        ORG_ID=\$(sqlite3 \"\$DB\" \"SELECT id FROM orgs WHERE domain='${GRIST_ORG}' LIMIT 1;\" 2>/dev/null)

        if [[ -n \"\$ORG_ID\" ]]; then
            # Find the members group for this org
            MEMBERS_GROUP=\$(sqlite3 \"\$DB\" \"SELECT id FROM groups WHERE name='members' ORDER BY id DESC LIMIT 1;\" 2>/dev/null)

            # Get the Everyone user ID (usually 3)
            EVERYONE_ID=\$(sqlite3 \"\$DB\" \"SELECT id FROM users WHERE name='Everyone' LIMIT 1;\" 2>/dev/null)

            if [[ -n \"\$MEMBERS_GROUP\" ]] && [[ -n \"\$EVERYONE_ID\" ]]; then
                # Add Everyone to members group
                sqlite3 \"\$DB\" \"INSERT OR IGNORE INTO group_users (group_id, user_id) VALUES (\$MEMBERS_GROUP, \$EVERYONE_ID);\"
                echo 'Added Everyone to members group'
            fi
        fi
    " 2>/dev/null || warn "Could not configure permissions automatically"

    success "Organization permissions configured"
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

    local sso_info=""
    if [[ "$KEYCLOAK_ENABLED" == "true" ]]; then
        sso_info="
🔐 SSO CONFIGURATION (Keycloak)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Keycloak URL:    ${KEYCLOAK_URL}
Realm:           ${KEYCLOAK_REALM}
Client ID:       ${KEYCLOAK_CLIENT_ID}
Client Secret:   ${KEYCLOAK_CLIENT_SECRET}
Issuer:          ${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}
"
    fi

    local notes="Grist - Modern Spreadsheet with Mailpit
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
Grist Web UI:    https://${GRIST_DOMAIN}
                 http://${container_ip}:${GRIST_PORT}
Mailpit Web UI:  http://${container_ip}:${MAILPIT_WEB_PORT}
Mailpit SMTP:    ${container_ip}:${MAILPIT_SMTP_PORT}

Organization:    ${GRIST_ORG}
Admin Email:     ${GRIST_ADMIN_EMAIL}
Default Locale:  ${GRIST_LOCALE} (한국어)
Default Currency: ${GRIST_CURRENCY} (₩)

🔑 API CONFIGURATION
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Boot Key:        ${GRIST_BOOT_KEY}
API Secret:      ${GRIST_API_SECRET}

API Endpoints:
  Base URL:      https://${GRIST_DOMAIN}/api
  Docs:          https://${GRIST_DOMAIN}/apidocs

Usage:
  curl -H \"Authorization: Bearer \\\$API_KEY\" \\\\
    https://${GRIST_DOMAIN}/api/orgs/${GRIST_ORG}/workspaces
${sso_info}
📧 SMTP CONFIGURATION
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SMTP Host:       mailpit (internal) / ${container_ip} (external)
SMTP Port:       ${MAILPIT_SMTP_PORT}
From Address:    grist@${GRIST_DOMAIN#*.}

🧩 CUSTOM WIDGETS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Widget Server:   http://${container_ip}:${WIDGETS_PORT}
Manifest URL:    http://${container_ip}:${WIDGETS_PORT}/manifest.json
Repository:      https://github.com/gristlabs/grist-widget

Available widgets include:
  • Calendar, Map, Chart, QR Code
  • Markdown, Pivot Table, Timeline
  • Invoice, Print Labels, and more...

🔧 SERVICE MANAGEMENT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Status:          pct exec ${CT_ID} -- docker ps
Logs (Grist):    pct exec ${CT_ID} -- docker logs grist -f
Logs (Mailpit):  pct exec ${CT_ID} -- docker logs mailpit -f
Restart:         pct exec ${CT_ID} -- docker compose -f /opt/grist/docker-compose.yml restart
Stop:            pct exec ${CT_ID} -- docker compose -f /opt/grist/docker-compose.yml down
Start:           pct exec ${CT_ID} -- docker compose -f /opt/grist/docker-compose.yml up -d

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
    success "Grist LXC Container Setup Complete!"
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
    echo "  • Grist Web UI:      https://${GRIST_DOMAIN}"
    echo "                       http://${container_ip}:${GRIST_PORT}"
    echo "  • Mailpit Web UI:    http://${container_ip}:${MAILPIT_WEB_PORT}"
    echo "  • Mailpit SMTP:      ${container_ip}:${MAILPIT_SMTP_PORT}"
    echo ""
    echo "  • Organization:      ${GRIST_ORG}"
    echo "  • Admin Email:       ${GRIST_ADMIN_EMAIL}"
    echo "  • Locale:            ${GRIST_LOCALE} (한국어)"
    echo "  • Currency:          ${GRIST_CURRENCY} (₩)"
    echo ""
    echo "API Configuration:"
    echo "  • Boot Key:          ${GRIST_BOOT_KEY}"
    echo "  • API Secret:        ${GRIST_API_SECRET}"
    echo "  • API Docs:          https://${GRIST_DOMAIN}/apidocs"
    echo ""
    if [[ "$KEYCLOAK_ENABLED" == "true" ]]; then
        echo "SSO (Keycloak):"
        echo "  • Keycloak URL:      ${KEYCLOAK_URL}"
        echo "  • Realm:             ${KEYCLOAK_REALM}"
        echo "  • Client ID:         ${KEYCLOAK_CLIENT_ID}"
        echo ""
    fi
    if [[ "$WIDGETS_ENABLED" == "true" ]]; then
        echo "Custom Widgets:"
        echo "  • Widget Server:     http://${container_ip}:${WIDGETS_PORT}"
        echo "  • Includes:          Calendar, Map, Chart, QR Code, etc."
        echo ""
    fi
    echo "Service Management:"
    echo "  • Status:            pct exec $CT_ID -- docker ps"
    echo "  • Logs:              pct exec $CT_ID -- docker logs grist -f"
    echo "  • Restart:           pct exec $CT_ID -- docker compose -f /opt/grist/docker-compose.yml restart"
    echo ""
    echo "================================================================="
}

#################################################################
# Main Execution
#################################################################

main() {
    info "Starting Grist LXC container creation..."
    echo ""

    check_root
    check_proxmox
    check_container_exists
    detect_and_download_template

    create_container
    start_container
    configure_autologin

    install_docker
    install_grist
    install_widgets
    configure_grist_permissions

    add_container_notes
    display_info
}

main "$@"
