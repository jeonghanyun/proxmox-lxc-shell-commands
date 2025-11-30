#!/usr/bin/env bash

# Proxmox LXC Taskosaur Installation Script - IMPROVED VERSION
# Description: Automated creation and configuration of Taskosaur project management with AI
# OS: Debian 12 (Bookworm) - Auto-detected latest version
# Taskosaur Ports: Frontend 3001, Backend API 3000
# Repository: https://github.com/jeonghanyun/proxmox-lxc-shell-commands
# Last Updated: 2025-11-30

set -euo pipefail

#################################################################
# Configuration Variables
#################################################################

# Container Configuration
CT_ID=${CT_ID:-201}                                    # Container ID
CT_HOSTNAME=${CT_HOSTNAME:-"taskosaur"}                # Container hostname
CT_CORES=${CT_CORES:-2}                                # CPU cores (Node.js needs more)
CT_MEMORY=${CT_MEMORY:-2048}                           # RAM in MB
CT_SWAP=${CT_SWAP:-1024}                               # Swap in MB
CT_DISK_SIZE=${CT_DISK_SIZE:-16}                       # Root disk size in GB

# Network Configuration
CT_IP=${CT_IP:-"dhcp"}                                 # IP address (dhcp or static like 192.168.1.100/24)
CT_GATEWAY=${CT_GATEWAY:-""}                           # Gateway (required for static IP)
CT_BRIDGE=${CT_BRIDGE:-"vmbr0"}                        # Network bridge
CT_NAMESERVER=${CT_NAMESERVER:-"8.8.8.8"}             # DNS server

# Storage Configuration
CT_STORAGE=${CT_STORAGE:-"local-lvm"}                  # Storage pool for container
TEMPLATE_STORAGE=${TEMPLATE_STORAGE:-"local"}          # Storage pool for templates

# Debian Template (will be auto-detected)
DEBIAN_VERSION="12"                                     # Debian version
TEMPLATE_NAME=""                                        # Auto-detected

# Taskosaur Configuration
TASKOSAUR_FRONTEND_PORT=${TASKOSAUR_FRONTEND_PORT:-3001}  # Frontend port
TASKOSAUR_BACKEND_PORT=${TASKOSAUR_BACKEND_PORT:-3000}    # Backend API port
TASKOSAUR_DB_PASSWORD=${TASKOSAUR_DB_PASSWORD:-"taskosaur_$(openssl rand -hex 8)"}
TASKOSAUR_JWT_SECRET=${TASKOSAUR_JWT_SECRET:-"$(openssl rand -hex 32)"}
TASKOSAUR_JWT_REFRESH_SECRET=${TASKOSAUR_JWT_REFRESH_SECRET:-"$(openssl rand -hex 32)"}
TASKOSAUR_ENCRYPTION_KEY=${TASKOSAUR_ENCRYPTION_KEY:-"$(openssl rand -hex 32)"}

# Container Options
CT_ONBOOT=${CT_ONBOOT:-1}                              # Start on boot (1=yes, 0=no)
CT_UNPRIVILEGED=${CT_UNPRIVILEGED:-1}                  # Unprivileged container (1=yes, 0=no)
CT_FEATURES=${CT_FEATURES:-"keyctl=1,nesting=1"}       # Container features

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
# Cleanup and Rollback Functions
#################################################################

cleanup_on_failure() {
    local step=$1
    error "Installation failed at step: $step"

    if pct status "$CT_ID" &> /dev/null; then
        warn "Container $CT_ID exists. Options:"
        echo "  1. Keep for debugging: pct enter $CT_ID"
        echo "  2. Remove and retry: pct stop $CT_ID && pct destroy $CT_ID"
        read -p "Remove container now? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            info "Removing container $CT_ID..."
            pct stop "$CT_ID" 2>/dev/null || true
            pct destroy "$CT_ID" 2>/dev/null || true
            success "Container removed"
        fi
    fi
    exit 1
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
    progress "Downloading Debian template (this may take a few minutes)..."
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
        --ostype debian || cleanup_on_failure "container creation"

    success "Container $CT_ID created successfully"
}

start_container() {
    info "Starting container $CT_ID..."
    pct start "$CT_ID" || cleanup_on_failure "container start"

    # Wait for container to be ready
    progress "Waiting for container to boot..."
    local max_wait=30
    local count=0

    while ! pct exec "$CT_ID" -- test -f /var/lib/dpkg/status 2>/dev/null; do
        sleep 1
        count=$((count + 1))
        if [[ $count -ge $max_wait ]]; then
            error "Container failed to boot in ${max_wait}s"
            cleanup_on_failure "container boot"
        fi
    done

    success "Container started successfully"
}

#################################################################
# Taskosaur Installation Functions
#################################################################

install_dependencies() {
    info "Installing system dependencies..."

    # Update package list
    progress "Updating package lists..."
    pct exec "$CT_ID" -- bash -c "apt-get update -qq" || cleanup_on_failure "apt-get update"

    # Install required packages
    progress "Installing Node.js 22, PostgreSQL, Redis, and build tools..."
    pct exec "$CT_ID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        curl \
        ca-certificates \
        gnupg \
        build-essential \
        git \
        postgresql \
        postgresql-contrib \
        redis-server" || cleanup_on_failure "dependency installation"

    # Install Node.js 22
    progress "Installing Node.js 22..."
    pct exec "$CT_ID" -- bash -c "curl -fsSL https://deb.nodesource.com/setup_22.x | bash -" || cleanup_on_failure "Node.js setup"
    pct exec "$CT_ID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs" || cleanup_on_failure "Node.js installation"

    # Verify Node.js installation
    local node_version
    node_version=$(pct exec "$CT_ID" -- node --version)
    success "Dependencies installed successfully (Node.js ${node_version})"
}

setup_database() {
    info "Setting up PostgreSQL database..."

    # Start PostgreSQL
    pct exec "$CT_ID" -- bash -c "systemctl start postgresql" || cleanup_on_failure "PostgreSQL start"
    pct exec "$CT_ID" -- bash -c "systemctl enable postgresql" || cleanup_on_failure "PostgreSQL enable"

    # Wait for PostgreSQL to be ready
    sleep 3

    # Create database and user
    progress "Creating database and user..."
    pct exec "$CT_ID" -- bash -c "su - postgres -c \"psql -c \\\"CREATE USER taskosaur WITH PASSWORD '${TASKOSAUR_DB_PASSWORD}';\\\"\"" || cleanup_on_failure "database user creation"
    pct exec "$CT_ID" -- bash -c "su - postgres -c \"psql -c \\\"CREATE DATABASE taskosaur OWNER taskosaur;\\\"\"" || cleanup_on_failure "database creation"
    pct exec "$CT_ID" -- bash -c "su - postgres -c \"psql -c \\\"GRANT ALL PRIVILEGES ON DATABASE taskosaur TO taskosaur;\\\"\"" || cleanup_on_failure "database privileges"

    success "PostgreSQL database configured"
}

setup_redis() {
    info "Setting up Redis..."

    # Start Redis
    pct exec "$CT_ID" -- bash -c "systemctl start redis-server" || cleanup_on_failure "Redis start"
    pct exec "$CT_ID" -- bash -c "systemctl enable redis-server" || cleanup_on_failure "Redis enable"

    success "Redis configured"
}

install_taskosaur() {
    info "Installing Taskosaur (this may take several minutes)..."

    # Clone repository
    progress "Cloning Taskosaur repository..."
    pct exec "$CT_ID" -- bash -c "cd /opt && git clone https://github.com/Taskosaur/Taskosaur.git taskosaur" || cleanup_on_failure "repository clone"

    # Create environment file using proper heredoc syntax
    progress "Creating environment configuration..."
    pct exec "$CT_ID" -- bash -c "cat > /opt/taskosaur/.env" <<EOF
DATABASE_URL="postgresql://taskosaur:${TASKOSAUR_DB_PASSWORD}@localhost:5432/taskosaur"
NODE_ENV=production
JWT_SECRET="${TASKOSAUR_JWT_SECRET}"
JWT_REFRESH_SECRET="${TASKOSAUR_JWT_REFRESH_SECRET}"
JWT_EXPIRES_IN="15m"
JWT_REFRESH_EXPIRES_IN="7d"
ENCRYPTION_KEY="${TASKOSAUR_ENCRYPTION_KEY}"
REDIS_HOST=localhost
REDIS_PORT=6379
FRONTEND_URL=http://0.0.0.0:${TASKOSAUR_FRONTEND_PORT}
CORS_ORIGIN="http://0.0.0.0:${TASKOSAUR_FRONTEND_PORT}"
NEXT_PUBLIC_API_BASE_URL=http://0.0.0.0:${TASKOSAUR_BACKEND_PORT}/api
UPLOAD_DEST="./uploads"
MAX_FILE_SIZE=10485760
EOF

    # Verify .env file was created
    if ! pct exec "$CT_ID" -- bash -c "test -f /opt/taskosaur/.env"; then
        cleanup_on_failure "environment file creation"
    fi
    success "Environment configuration created"

    # Install dependencies
    progress "Installing npm dependencies (this will take 5-10 minutes)..."
    if ! pct exec "$CT_ID" -- bash -c "cd /opt/taskosaur && npm install --legacy-peer-deps 2>&1 | tail -20"; then
        error "npm install failed - check if Taskosaur repository is accessible"
        cleanup_on_failure "npm install"
    fi
    success "npm dependencies installed"

    # Run database migrations
    progress "Running database migrations..."
    pct exec "$CT_ID" -- bash -c "cd /opt/taskosaur && npm run db:migrate:deploy" || {
        warn "Database migration failed - this might be expected if migrations don't exist yet"
    }

    # Generate Prisma client
    progress "Generating Prisma client..."
    pct exec "$CT_ID" -- bash -c "cd /opt/taskosaur && npm run db:generate" || {
        warn "Prisma client generation failed - continuing anyway"
    }

    # Build application
    progress "Building Taskosaur (this will take 5-10 minutes)..."
    if ! pct exec "$CT_ID" -- bash -c "cd /opt/taskosaur && npm run build 2>&1 | tail -20"; then
        error "Build failed - check Node.js version and dependencies"
        cleanup_on_failure "application build"
    fi
    success "Taskosaur built successfully"

    # Seed database with admin user
    progress "Creating admin user..."
    pct exec "$CT_ID" -- bash -c "cd /opt/taskosaur && npm run db:seed:admin" || {
        warn "Admin user seeding failed - you may need to create admin manually"
    }

    success "Taskosaur installed successfully"
}

configure_services() {
    info "Configuring systemd services with auto-restart..."

    # Create backend service with aggressive restart policy
    pct exec "$CT_ID" -- bash -c "cat > /etc/systemd/system/taskosaur-backend.service" <<'EOF'
[Unit]
Description=Taskosaur Backend API
After=network.target postgresql.service redis-server.service
Wants=postgresql.service redis-server.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/taskosaur
Environment=NODE_ENV=production
ExecStart=/usr/bin/npm run start:backend
Restart=always
RestartSec=10s
StartLimitBurst=5
StartLimitIntervalSec=30s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    # Create frontend service with aggressive restart policy
    pct exec "$CT_ID" -- bash -c "cat > /etc/systemd/system/taskosaur-frontend.service" <<'EOF'
[Unit]
Description=Taskosaur Frontend
After=network.target taskosaur-backend.service
Wants=taskosaur-backend.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/taskosaur
Environment=NODE_ENV=production
ExecStart=/usr/bin/npm run start:frontend
Restart=always
RestartSec=10s
StartLimitBurst=5
StartLimitIntervalSec=30s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    # Reload systemd and enable services
    pct exec "$CT_ID" -- bash -c "systemctl daemon-reload" || cleanup_on_failure "systemd reload"
    pct exec "$CT_ID" -- bash -c "systemctl enable taskosaur-backend taskosaur-frontend" || cleanup_on_failure "service enable"

    # Start backend first
    progress "Starting backend service..."
    pct exec "$CT_ID" -- bash -c "systemctl start taskosaur-backend" || {
        error "Backend service failed to start"
        pct exec "$CT_ID" -- bash -c "journalctl -u taskosaur-backend -n 50"
        cleanup_on_failure "backend service start"
    }

    # Wait for backend to be ready
    progress "Waiting for backend to initialize..."
    sleep 15

    # Start frontend
    progress "Starting frontend service..."
    pct exec "$CT_ID" -- bash -c "systemctl start taskosaur-frontend" || {
        error "Frontend service failed to start"
        pct exec "$CT_ID" -- bash -c "journalctl -u taskosaur-frontend -n 50"
        cleanup_on_failure "frontend service start"
    }

    # Wait for frontend to start
    sleep 10

    # Check service status with detailed feedback
    local backend_status
    local frontend_status

    if pct exec "$CT_ID" -- bash -c "systemctl is-active --quiet taskosaur-backend"; then
        success "Backend service is running"
        backend_status="✓"
    else
        warn "Backend service may have issues - check logs with:"
        echo "    pct exec $CT_ID -- journalctl -u taskosaur-backend -f"
        backend_status="⚠"
    fi

    if pct exec "$CT_ID" -- bash -c "systemctl is-active --quiet taskosaur-frontend"; then
        success "Frontend service is running"
        frontend_status="✓"
    else
        warn "Frontend service may have issues - check logs with:"
        echo "    pct exec $CT_ID -- journalctl -u taskosaur-frontend -f"
        frontend_status="⚠"
    fi

    info "Service Status: Backend [$backend_status] Frontend [$frontend_status]"
}

add_container_notes() {
    info "Adding container notes with access information..."

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

    local notes="TASKOSAUR - AI PROJECT MANAGEMENT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📋 CONTAINER DETAILS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Container ID:    ${CT_ID}
Hostname:        ${CT_HOSTNAME}
IP Address:      ${container_ip}
CPU Cores:       ${CT_CORES}
Memory:          ${CT_MEMORY}MB
Disk Size:       ${CT_DISK_SIZE}GB

🌐 TASKOSAUR ACCESS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Frontend:        http://${container_ip}:${TASKOSAUR_FRONTEND_PORT}
Backend API:     http://${container_ip}:${TASKOSAUR_BACKEND_PORT}/api
API Docs:        http://${container_ip}:${TASKOSAUR_BACKEND_PORT}/api/docs

🔑 CREDENTIALS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Database:        taskosaur / ${TASKOSAUR_DB_PASSWORD}
Check admin:     pct exec ${CT_ID} -- cat /opt/taskosaur/README.md

🔧 SERVICE MANAGEMENT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Backend Status:  pct exec ${CT_ID} -- systemctl status taskosaur-backend
Frontend Status: pct exec ${CT_ID} -- systemctl status taskosaur-frontend
Restart All:     pct exec ${CT_ID} -- systemctl restart taskosaur-backend taskosaur-frontend
Backend Logs:    pct exec ${CT_ID} -- journalctl -u taskosaur-backend -f
Frontend Logs:   pct exec ${CT_ID} -- journalctl -u taskosaur-frontend -f

🗄️ DATABASE MANAGEMENT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
PostgreSQL:      pct exec ${CT_ID} -- systemctl status postgresql
Redis:           pct exec ${CT_ID} -- systemctl status redis-server
DB Connect:      pct exec ${CT_ID} -- su - postgres -c "psql -d taskosaur"

📦 CONTAINER MANAGEMENT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Enter:           pct enter ${CT_ID}
Start:           pct start ${CT_ID}
Stop:            pct stop ${CT_ID}
Restart:         pct restart ${CT_ID}
Delete:          pct destroy ${CT_ID}

📁 IMPORTANT PATHS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Install Dir:     /opt/taskosaur
Config File:     /opt/taskosaur/.env
Uploads:         /opt/taskosaur/uploads

ℹ️  AUTO-GENERATED BY: https://github.com/jeonghanyun/proxmox-lxc-shell-commands"

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

    if [[ "$CT_IP" == "dhcp" ]]; then
        container_ip=$(pct exec "$CT_ID" -- hostname -I | awk '{print $1}')
    else
        container_ip="${CT_IP%/*}"
    fi

    echo ""
    echo "================================================================="
    success "Taskosaur LXC Container Setup Complete!"
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
    echo "Taskosaur Access:"
    echo "  • Frontend:          http://${container_ip}:${TASKOSAUR_FRONTEND_PORT}"
    echo "  • Backend API:       http://${container_ip}:${TASKOSAUR_BACKEND_PORT}/api"
    echo "  • API Docs:          http://${container_ip}:${TASKOSAUR_BACKEND_PORT}/api/docs"
    echo ""
    echo "Database Credentials:"
    echo "  • Database:          taskosaur"
    echo "  • Username:          taskosaur"
    echo "  • Password:          ${TASKOSAUR_DB_PASSWORD}"
    echo ""
    echo "Service Management:"
    echo "  • Backend Status:    pct exec $CT_ID -- systemctl status taskosaur-backend"
    echo "  • Frontend Status:   pct exec $CT_ID -- systemctl status taskosaur-frontend"
    echo "  • Restart Services:  pct exec $CT_ID -- systemctl restart taskosaur-backend taskosaur-frontend"
    echo ""
    echo "Container Management:"
    echo "  • Enter container:   pct enter $CT_ID"
    echo "  • Stop container:    pct stop $CT_ID"
    echo "  • Start container:   pct start $CT_ID"
    echo ""
    echo "Next Steps:"
    echo "  1. Open http://${container_ip}:${TASKOSAUR_FRONTEND_PORT} in your browser"
    echo "  2. Check README for default admin credentials"
    echo "  3. Configure your AI API keys in the settings"
    echo ""
    echo "Troubleshooting:"
    echo "  • Check backend logs:  pct exec $CT_ID -- journalctl -u taskosaur-backend -f"
    echo "  • Check frontend logs: pct exec $CT_ID -- journalctl -u taskosaur-frontend -f"
    echo "  • Restart services:    pct exec $CT_ID -- systemctl restart taskosaur-backend taskosaur-frontend"
    echo ""
    echo "================================================================="
}

#################################################################
# Main Execution
#################################################################

main() {
    echo ""
    echo "================================================================="
    info "Taskosaur LXC Container Installation - IMPROVED VERSION"
    echo "================================================================="
    echo ""

    # Pre-flight checks
    info "Running pre-flight checks..."
    check_root
    check_proxmox
    check_container_exists
    detect_and_download_template

    # Create and configure container
    info "Creating container infrastructure..."
    create_container
    start_container

    # Install dependencies and services
    info "Installing system dependencies..."
    install_dependencies
    setup_database
    setup_redis

    # Install and configure Taskosaur
    info "Installing Taskosaur application..."
    install_taskosaur
    configure_services

    # Add container notes
    add_container_notes

    # Display information
    display_info
}

# Run main function
main "$@"
