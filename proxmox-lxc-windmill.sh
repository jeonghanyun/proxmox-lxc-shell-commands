#!/usr/bin/env bash

# Windmill LXC Installation Script
# Description: Install Windmill - Open-source developer platform for APIs, scripts, workflows
# OS: Debian 12 (Bookworm)
# Ports: Web UI: 80 (Caddy proxy), MariaDB: 3306, PostgreSQL: 5432
# Repository: https://github.com/jeonghanyun/proxmox-lxc-shell-commands
# Last Updated: 2025-12

set -euo pipefail

#################################################################
# Configuration Variables
#################################################################

# Container Configuration
CT_ID=${CT_ID:-204}
CT_HOSTNAME=${CT_HOSTNAME:-"windmill"}
CT_CORES=${CT_CORES:-4}
CT_MEMORY=${CT_MEMORY:-4096}
CT_SWAP=${CT_SWAP:-2048}
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

# Windmill Configuration
WINDMILL_PORT=${WINDMILL_PORT:-80}
WINDMILL_EMAIL=${WINDMILL_EMAIL:-"devops@gupsa.com"}
WINDMILL_PASSWORD=${WINDMILL_PASSWORD:-"Akehdtjr1@"}
WINDMILL_DEFAULT_EMAIL="admin@windmill.dev"
WINDMILL_DEFAULT_PASSWORD="changeme"

# Database Configuration
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD:-"windmill_root_2024"}
MYSQL_DATABASE=${MYSQL_DATABASE:-"windmill_db"}
MYSQL_USER=${MYSQL_USER:-"windmill"}
MYSQL_PASSWORD=${MYSQL_PASSWORD:-"windmill_mysql_2024"}

PG_DATABASE=${PG_DATABASE:-"windmill_db"}
PG_USER=${PG_USER:-"windmill"}
PG_PASSWORD=${PG_PASSWORD:-"windmill_pg_2024"}

# API Token (will be generated)
WINDMILL_API_TOKEN=""

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
# Database Installation Functions
#################################################################

install_mariadb() {
    info "Installing MariaDB..."

    pct exec "$CT_ID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mariadb-server mariadb-client"

    pct exec "$CT_ID" -- bash -c "systemctl enable mariadb && systemctl start mariadb"

    # Configure MariaDB
    pct exec "$CT_ID" -- bash -c "mysql -u root << EOSQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
CREATE DATABASE IF NOT EXISTS ${MYSQL_DATABASE} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'localhost' IDENTIFIED BY '${MYSQL_PASSWORD}';
CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}';
GRANT ALL PRIVILEGES ON ${MYSQL_DATABASE}.* TO '${MYSQL_USER}'@'localhost';
GRANT ALL PRIVILEGES ON ${MYSQL_DATABASE}.* TO '${MYSQL_USER}'@'%';
FLUSH PRIVILEGES;
EOSQL"

    success "MariaDB installed and configured"
}

install_postgresql() {
    info "Installing PostgreSQL..."

    pct exec "$CT_ID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq postgresql postgresql-contrib"

    pct exec "$CT_ID" -- bash -c "systemctl enable postgresql && systemctl start postgresql"

    sleep 3

    # Configure PostgreSQL
    pct exec "$CT_ID" -- bash -c "su - postgres -c \"psql << EOSQL
CREATE USER ${PG_USER} WITH PASSWORD '${PG_PASSWORD}';
CREATE DATABASE ${PG_DATABASE} OWNER ${PG_USER};
GRANT ALL PRIVILEGES ON DATABASE ${PG_DATABASE} TO ${PG_USER};
ALTER USER ${PG_USER} CREATEDB;
EOSQL\""

    # Configure remote access
    pct exec "$CT_ID" -- bash -c '
        PG_HBA=$(find /etc/postgresql -name pg_hba.conf | head -1)
        echo "host    all             all             0.0.0.0/0               scram-sha-256" >> "$PG_HBA"
        PG_CONF=$(find /etc/postgresql -name postgresql.conf | head -1)
        sed -i "s/#listen_addresses = '\''localhost'\''/listen_addresses = '\''*'\''/" "$PG_CONF"
    '

    pct exec "$CT_ID" -- bash -c "systemctl restart postgresql"

    success "PostgreSQL installed and configured"
}

#################################################################
# Windmill Installation Functions
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

install_windmill() {
    info "Installing Windmill..."

    # Create Windmill directory
    pct exec "$CT_ID" -- bash -c "mkdir -p /opt/windmill"

    # Download official configuration files
    info "Downloading Windmill configuration files..."
    pct exec "$CT_ID" -- bash -c "curl -fsSL https://raw.githubusercontent.com/windmill-labs/windmill/main/docker-compose.yml -o /opt/windmill/docker-compose.yml"
    pct exec "$CT_ID" -- bash -c "curl -fsSL https://raw.githubusercontent.com/windmill-labs/windmill/main/Caddyfile -o /opt/windmill/Caddyfile"
    pct exec "$CT_ID" -- bash -c "curl -fsSL https://raw.githubusercontent.com/windmill-labs/windmill/main/.env -o /opt/windmill/.env"

    # Remove port 25 mapping (SMTP) to avoid conflicts
    pct exec "$CT_ID" -- bash -c "sed -i '/- 25:25/d' /opt/windmill/docker-compose.yml"

    # Pull and start containers
    info "Pulling Windmill Docker images (this may take several minutes)..."
    pct exec "$CT_ID" -- bash -c "cd /opt/windmill && docker compose pull"

    info "Starting Windmill..."
    pct exec "$CT_ID" -- bash -c "cd /opt/windmill && docker compose up -d"

    # Wait for startup
    info "Waiting for Windmill to initialize..."
    sleep 30

    # Check status
    if pct exec "$CT_ID" -- bash -c "cd /opt/windmill && docker compose ps | grep -q 'Up'"; then
        success "Windmill installed and running"
    else
        warn "Windmill may still be initializing. Check logs with: pct exec $CT_ID -- docker compose -f /opt/windmill/docker-compose.yml logs -f"
    fi
}

configure_windmill_account() {
    info "Configuring Windmill account and API..."

    local container_ip
    if [[ "$CT_IP" == "dhcp" ]]; then
        container_ip=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}')
    else
        container_ip="${CT_IP%/*}"
    fi

    local windmill_url="http://${container_ip}"

    # Wait for Windmill API to be ready
    info "Waiting for Windmill API to be ready..."
    local max_attempts=30
    local attempt=0
    while [[ $attempt -lt $max_attempts ]]; do
        if curl -s "${windmill_url}/api/version" >/dev/null 2>&1; then
            success "Windmill API is ready"
            break
        fi
        sleep 2
        ((attempt++))
    done

    if [[ $attempt -eq $max_attempts ]]; then
        warn "Windmill API not responding, skipping account configuration"
        return 1
    fi

    # Login with default credentials
    info "Logging in with default credentials..."
    local default_token
    default_token=$(curl -s "${windmill_url}/api/auth/login" -X POST \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"${WINDMILL_DEFAULT_EMAIL}\",\"password\":\"${WINDMILL_DEFAULT_PASSWORD}\"}" 2>/dev/null)

    if [[ -z "$default_token" ]] || [[ "$default_token" == *"Invalid"* ]]; then
        warn "Could not login with default credentials, account may already be configured"
        return 1
    fi

    # Create new user account
    info "Creating new admin account: ${WINDMILL_EMAIL}..."
    curl -s "${windmill_url}/api/users/create" -X POST \
        -H "Authorization: Bearer ${default_token}" \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"${WINDMILL_EMAIL}\",\"password\":\"${WINDMILL_PASSWORD}\",\"super_admin\":true,\"name\":\"DevOps Admin\"}" >/dev/null 2>&1

    # Add user to admins workspace
    curl -s "${windmill_url}/api/w/admins/users/add" -X POST \
        -H "Authorization: Bearer ${default_token}" \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"${WINDMILL_EMAIL}\",\"is_admin\":true}" >/dev/null 2>&1

    # Login with new account
    info "Logging in with new account..."
    WINDMILL_API_TOKEN=$(curl -s "${windmill_url}/api/auth/login" -X POST \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"${WINDMILL_EMAIL}\",\"password\":\"${WINDMILL_PASSWORD}\"}" 2>/dev/null)

    if [[ -z "$WINDMILL_API_TOKEN" ]] || [[ "$WINDMILL_API_TOKEN" == *"Invalid"* ]]; then
        warn "Could not login with new account, trying default token"
        WINDMILL_API_TOKEN="$default_token"
    fi

    success "Windmill account configured"

    # Create database resources
    info "Creating database resources..."

    # Create PostgreSQL resource
    curl -s "${windmill_url}/api/w/admins/resources/create" -X POST \
        -H "Authorization: Bearer ${WINDMILL_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"path\":\"f/db/postgresql_local\",\"value\":{\"host\":\"localhost\",\"port\":5432,\"user\":\"${PG_USER}\",\"dbname\":\"${PG_DATABASE}\",\"password\":\"${PG_PASSWORD}\",\"sslmode\":\"disable\"},\"resource_type\":\"postgresql\",\"description\":\"Local PostgreSQL database\"}" >/dev/null 2>&1

    # Create MySQL resource
    curl -s "${windmill_url}/api/w/admins/resources/create" -X POST \
        -H "Authorization: Bearer ${WINDMILL_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"path\":\"f/db/mysql_local\",\"value\":{\"host\":\"localhost\",\"port\":3306,\"user\":\"${MYSQL_USER}\",\"database\":\"${MYSQL_DATABASE}\",\"password\":\"${MYSQL_PASSWORD}\"},\"resource_type\":\"mysql\",\"description\":\"Local MySQL/MariaDB database\"}" >/dev/null 2>&1

    success "Database resources created"
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

    local notes="Windmill - Developer Platform for Scripts/Workflows/Apps
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📋 CONTAINER DETAILS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Container ID:    ${CT_ID}
Hostname:        ${CT_HOSTNAME}
IP Address:      ${container_ip}
CPU Cores:       ${CT_CORES}
Memory:          ${CT_MEMORY}MB
Disk Size:       ${CT_DISK_SIZE}GB

🌐 WINDMILL ACCESS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Web UI:          http://${container_ip}
Email:           ${WINDMILL_EMAIL}
Password:        ${WINDMILL_PASSWORD}

🔑 API TOKEN
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Token:           ${WINDMILL_API_TOKEN:-"[Login to generate]"}

Usage:
curl -H \"Authorization: Bearer \${TOKEN}\" http://${container_ip}/api/...

🗄️ MARIADB (MySQL)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Port:            3306
Root Password:   ${MYSQL_ROOT_PASSWORD}
Database:        ${MYSQL_DATABASE}
Username:        ${MYSQL_USER}
Password:        ${MYSQL_PASSWORD}

Connection String:
mysql://${MYSQL_USER}:${MYSQL_PASSWORD}@${container_ip}:3306/${MYSQL_DATABASE}

Windmill Resource: f/db/mysql_local

🐘 POSTGRESQL
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Port:            5432
Database:        ${PG_DATABASE}
Username:        ${PG_USER}
Password:        ${PG_PASSWORD}

Connection String:
postgresql://${PG_USER}:${PG_PASSWORD}@${container_ip}:5432/${PG_DATABASE}

Windmill Resource: f/db/postgresql_local

🔧 SERVICE MANAGEMENT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Windmill:        pct exec ${CT_ID} -- docker ps
MariaDB Status:  pct exec ${CT_ID} -- systemctl status mariadb
PostgreSQL:      pct exec ${CT_ID} -- systemctl status postgresql

Windmill Logs:   pct exec ${CT_ID} -- docker compose -f /opt/windmill/docker-compose.yml logs -f
Restart:         pct exec ${CT_ID} -- docker compose -f /opt/windmill/docker-compose.yml restart

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
    success "Windmill LXC Container Setup Complete!"
    echo "================================================================="
    echo ""
    info "All access information has been saved to container Notes"
    echo ""
    echo "Container Details:"
    echo "  • Container ID:      $CT_ID"
    echo "  • Hostname:          $CT_HOSTNAME"
    echo "  • IP Address:        $container_ip"
    echo ""
    echo "Windmill Access:"
    echo "  • Web UI:            http://${container_ip}"
    echo "  • Email:             ${WINDMILL_EMAIL}"
    echo "  • Password:          ${WINDMILL_PASSWORD}"
    echo ""
    if [[ -n "$WINDMILL_API_TOKEN" ]]; then
        echo "API Token:"
        echo "  • Token:             ${WINDMILL_API_TOKEN}"
        echo ""
    fi
    echo "MariaDB (MySQL):"
    echo "  • Port:              3306"
    echo "  • Database:          ${MYSQL_DATABASE}"
    echo "  • User:              ${MYSQL_USER}"
    echo "  • Password:          ${MYSQL_PASSWORD}"
    echo "  • Resource:          f/db/mysql_local"
    echo ""
    echo "PostgreSQL:"
    echo "  • Port:              5432"
    echo "  • Database:          ${PG_DATABASE}"
    echo "  • User:              ${PG_USER}"
    echo "  • Password:          ${PG_PASSWORD}"
    echo "  • Resource:          f/db/postgresql_local"
    echo ""
    echo "Service Management:"
    echo "  • Logs:              pct exec $CT_ID -- docker compose -f /opt/windmill/docker-compose.yml logs -f"
    echo "  • Restart:           pct exec $CT_ID -- docker compose -f /opt/windmill/docker-compose.yml restart"
    echo ""
    echo "================================================================="
}

#################################################################
# Main Execution
#################################################################

main() {
    info "Starting Windmill LXC container creation..."
    echo ""

    check_root
    check_proxmox
    check_container_exists
    detect_and_download_template

    create_container
    start_container
    configure_autologin

    install_docker
    install_mariadb
    install_postgresql
    install_windmill
    configure_windmill_account

    add_container_notes
    display_info
}

main "$@"
