#!/usr/bin/env bash

# Proxmox LXC OpenProject Installation Script
# Description: Automated creation and configuration of OpenProject project management in LXC container
# OS: Debian 12 (Bookworm) - Auto-detected latest version
# Ports: Web UI 80/443 (Apache)
# Default Login: admin / admin (change immediately after first login)
# Repository: https://github.com/jeonghanyun/proxmox-lxc-shell-commands
# Last Updated: 2025-12-01

set -euo pipefail

#################################################################
# Configuration Variables
#################################################################

# Container Configuration
CT_ID=${CT_ID:-202}                                    # Container ID
CT_HOSTNAME=${CT_HOSTNAME:-"openproject"}              # Container hostname
CT_CORES=${CT_CORES:-4}                               # CPU cores (minimum 2 recommended)
CT_MEMORY=${CT_MEMORY:-4096}                          # RAM in MB (minimum 4GB recommended)
CT_SWAP=${CT_SWAP:-2048}                              # Swap in MB
CT_DISK_SIZE=${CT_DISK_SIZE:-20}                      # Root disk size in GB

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

# OpenProject Configuration
OPENPROJECT_VERSION=${OPENPROJECT_VERSION:-"stable/16"}  # OpenProject version branch
OPENPROJECT_PORT=${OPENPROJECT_PORT:-80}                  # Web port

# Container Options
CT_ONBOOT=${CT_ONBOOT:-1}                             # Start on boot (1=yes, 0=no)
CT_UNPRIVILEGED=${CT_UNPRIVILEGED:-1}                 # Unprivileged container (1=yes, 0=no)
CT_FEATURES=${CT_FEATURES:-"keyctl=1,nesting=1"}      # Container features

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
    if [[ $CT_MEMORY -lt 4096 ]]; then
        warn "Memory is set to ${CT_MEMORY}MB. OpenProject recommends at least 4096MB (4GB)"
        warn "Proceeding anyway, but performance may be affected"
    fi

    if [[ $CT_CORES -lt 2 ]]; then
        warn "CPU cores set to ${CT_CORES}. OpenProject recommends at least 2 cores"
        warn "Proceeding anyway, but performance may be affected"
    fi

    if [[ $CT_DISK_SIZE -lt 20 ]]; then
        warn "Disk size is ${CT_DISK_SIZE}GB. OpenProject recommends at least 20GB"
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
# OpenProject Installation Functions
#################################################################

install_openproject() {
    info "Installing OpenProject in container $CT_ID..."
    info "This may take 10-15 minutes..."

    # Update and install required packages
    info "Updating package list..."
    pct exec "$CT_ID" -- bash -c "apt-get update -qq"

    info "Installing required packages..."
    pct exec "$CT_ID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq apt-transport-https ca-certificates wget gnupg"

    # Add OpenProject repository key
    info "Adding OpenProject GPG key..."
    pct exec "$CT_ID" -- bash -c "wget -qO /etc/apt/trusted.gpg.d/openproject.asc https://dl.packager.io/srv/opf/openproject/key"

    # Add OpenProject repository
    info "Adding OpenProject repository..."
    pct exec "$CT_ID" -- bash -c "wget -qO /etc/apt/sources.list.d/openproject.list https://dl.packager.io/srv/opf/openproject/${OPENPROJECT_VERSION}/installer/debian/12.repo"

    # Update and install OpenProject
    info "Installing OpenProject (this will take a while)..."
    pct exec "$CT_ID" -- bash -c "apt-get update -qq"
    pct exec "$CT_ID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y openproject"

    success "OpenProject package installed"
}

configure_openproject() {
    info "Configuring OpenProject (automated setup)..."

    # Create automated configuration
    info "Setting up PostgreSQL, Apache, and other components..."

    # Run openproject configure with pre-set answers using expect or automated input
    # OpenProject uses debconf for configuration
    pct exec "$CT_ID" -- bash -c "cat > /tmp/openproject-config.sh << 'CONFIGEOF'
#!/bin/bash

# Pre-configure debconf selections for non-interactive install
debconf-set-selections <<EOF
openproject openproject/database select postgresql/local
openproject openproject/edition select default
openproject openproject/server/autoinstall select install
openproject openproject/server/server_path_prefix string /
openproject openproject/server/hostname string localhost
openproject openproject/server/ssl select no
openproject openproject/repositories/svn-install select skip
openproject openproject/repositories/git-install select skip
openproject openproject/outbound_email select skip
openproject openproject/memcached/autoinstall select install
openproject openproject/admin_email string admin@localhost
openproject openproject/default_language string en
EOF

# Run configure with defaults
openproject configure <<ANSWERS
1
1
1
/
localhost
1
2
2
2
1
admin@localhost
en
ANSWERS
CONFIGEOF"

    pct exec "$CT_ID" -- bash -c "chmod +x /tmp/openproject-config.sh"

    # Install expect for automated configuration
    pct exec "$CT_ID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq expect"

    # Create expect script for automated configuration
    pct exec "$CT_ID" -- bash -c 'cat > /tmp/configure-openproject.exp << '\''EXPECTEOF'\''
#!/usr/bin/expect -f
set timeout 300

spawn openproject configure

# PostgreSQL selection (1 = install)
expect {
    "PostgreSQL database" { send "1\r" }
    timeout { exit 1 }
}

# Edition selection (1 = default)
expect {
    "edition" { send "1\r" }
    timeout { exit 1 }
}

# Apache installation (1 = install)
expect {
    -re "Apache|web server|autoinstall" { send "1\r" }
    timeout { exit 1 }
}

# Server path prefix
expect {
    "path prefix" { send "/\r" }
    timeout { exit 1 }
}

# Hostname
expect {
    "hostname" { send "localhost\r" }
    timeout { exit 1 }
}

# SSL (1 = no)
expect {
    "SSL" { send "1\r" }
    timeout { exit 1 }
}

# SVN (2 = skip)
expect {
    -re "SVN|Subversion" { send "2\r" }
    timeout { exit 1 }
}

# Git (2 = skip)
expect {
    "Git" { send "2\r" }
    timeout { exit 1 }
}

# Email (2 = skip for now)
expect {
    -re "email|mail" { send "2\r" }
    timeout { exit 1 }
}

# Memcached (1 = install)
expect {
    -re "memcached|Memcached" { send "1\r" }
    timeout { exit 1 }
}

# Wait for configuration to complete
expect {
    eof { exit 0 }
    timeout { exit 0 }
}
EXPECTEOF'

    pct exec "$CT_ID" -- bash -c "chmod +x /tmp/configure-openproject.exp"

    info "Running OpenProject configuration wizard (automated)..."
    # Run the expect script with extended timeout
    if ! pct exec "$CT_ID" -- bash -c "timeout 600 /tmp/configure-openproject.exp" 2>&1; then
        warn "Automated configuration may have issues, trying direct configure..."
        # Fallback: run configure and accept defaults
        pct exec "$CT_ID" -- bash -c "echo -e '1\n1\n1\n/\nlocalhost\n1\n2\n2\n2\n1\n' | timeout 600 openproject configure" 2>&1 || true
    fi

    # Wait for services to start
    info "Waiting for OpenProject services to initialize..."
    sleep 30

    # Ensure services are running
    pct exec "$CT_ID" -- bash -c "systemctl restart apache2" 2>/dev/null || true

    success "OpenProject configuration completed"
}

verify_installation() {
    info "Verifying OpenProject installation..."

    # Check if OpenProject service is running
    if pct exec "$CT_ID" -- bash -c "systemctl is-active openproject" &>/dev/null; then
        success "OpenProject service is active"
    else
        warn "OpenProject service status unclear, checking web server..."
    fi

    # Check if Apache is running
    if pct exec "$CT_ID" -- bash -c "systemctl is-active apache2" &>/dev/null; then
        success "Apache web server is running"
    else
        warn "Apache may need manual start: pct exec $CT_ID -- systemctl start apache2"
    fi

    # Check if PostgreSQL is running
    if pct exec "$CT_ID" -- bash -c "systemctl is-active postgresql" &>/dev/null; then
        success "PostgreSQL database is running"
    else
        warn "PostgreSQL may need attention"
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
    local notes="OPENPROJECT PROJECT MANAGEMENT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📋 CONTAINER DETAILS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Container ID:    ${CT_ID}
Hostname:        ${CT_HOSTNAME}
IP Address:      ${container_ip}
CPU Cores:       ${CT_CORES}
Memory:          ${CT_MEMORY}MB
Disk Size:       ${CT_DISK_SIZE}GB

🌐 OPENPROJECT ACCESS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Web UI:          http://${container_ip}
Username:        admin
Password:        admin (CHANGE IMMEDIATELY!)

🔧 SERVICE MANAGEMENT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Status:          pct exec ${CT_ID} -- openproject run info
Reconfigure:     pct exec ${CT_ID} -- openproject reconfigure
Restart:         pct exec ${CT_ID} -- systemctl restart openproject
Logs:            pct exec ${CT_ID} -- openproject run log
Apache Status:   pct exec ${CT_ID} -- systemctl status apache2
PostgreSQL:      pct exec ${CT_ID} -- systemctl status postgresql

📦 CONTAINER MANAGEMENT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Enter:           pct enter ${CT_ID}
Start:           pct start ${CT_ID}
Stop:            pct stop ${CT_ID}
Restart:         pct restart ${CT_ID}
Delete:          pct destroy ${CT_ID}

⚠️  IMPORTANT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
• Change admin password immediately after first login!
• For SSL: pct exec ${CT_ID} -- openproject reconfigure
• Docs: https://www.openproject.org/docs/

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
    success "OpenProject LXC Container Setup Complete!"
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
    echo "OpenProject Access:"
    echo "  • Web UI:            http://${container_ip}"
    echo "  • Username:          admin"
    echo "  • Password:          admin"
    echo ""
    warn "⚠️  IMPORTANT: Change the admin password immediately after first login!"
    echo ""
    echo "Service Management:"
    echo "  • Status:            pct exec $CT_ID -- openproject run info"
    echo "  • Reconfigure:       pct exec $CT_ID -- openproject reconfigure"
    echo "  • Restart:           pct exec $CT_ID -- systemctl restart openproject"
    echo "  • Logs:              pct exec $CT_ID -- openproject run log"
    echo ""
    echo "Container Management:"
    echo "  • Enter container:   pct enter $CT_ID"
    echo "  • Stop container:    pct stop $CT_ID"
    echo "  • Start container:   pct start $CT_ID"
    echo "  • Delete container:  pct destroy $CT_ID"
    echo ""
    echo "================================================================="
}

#################################################################
# Main Execution
#################################################################

main() {
    info "Starting OpenProject LXC container creation..."
    info "OpenProject is a web-based project management software"
    echo ""

    # Pre-flight checks
    check_root
    check_proxmox
    check_container_exists
    check_resources
    detect_and_download_template

    # Create and configure container
    create_container
    start_container
    configure_autologin

    # Install and configure OpenProject
    install_openproject
    configure_openproject
    verify_installation

    # Add container notes
    add_container_notes

    # Display information
    display_info
}

# Run main function
main "$@"
