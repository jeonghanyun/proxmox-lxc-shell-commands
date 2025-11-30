#!/usr/bin/env bash

# Claude Code LXC Installation Script
# Description: Install Claude Code CLI on existing LXC containers
# Usage: ./proxmox-lxc-claude-install.sh [CT_ID] or ./proxmox-lxc-claude-install.sh all
# Repository: https://github.com/jeonghanyun/proxmox-lxc-shell-commands
# Last Updated: 2024-11

set -euo pipefail

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

#################################################################
# Claude Code Installation Function
#################################################################

install_claude_on_container() {
    local ct_id="$1"

    # Check if container exists
    if ! pct status "$ct_id" &> /dev/null; then
        error "Container $ct_id does not exist"
        return 1
    fi

    # Check if container is running
    local status
    status=$(pct status "$ct_id" | awk '{print $2}')
    if [[ "$status" != "running" ]]; then
        warn "Container $ct_id is not running. Starting..."
        pct start "$ct_id" || {
            error "Failed to start container $ct_id"
            return 1
        }
        sleep 3
    fi

    local hostname
    hostname=$(pct exec "$ct_id" -- hostname 2>/dev/null || echo "CT-$ct_id")

    info "Installing Claude Code on container $ct_id ($hostname)..."

    # Check OS type
    local os_type
    os_type=$(pct exec "$ct_id" -- bash -c "cat /etc/os-release 2>/dev/null | grep ^ID= | cut -d= -f2 | tr -d '\"'" 2>/dev/null || echo "unknown")

    if [[ "$os_type" != "debian" && "$os_type" != "ubuntu" ]]; then
        warn "Container $ct_id uses $os_type (not Debian/Ubuntu). Skipping..."
        return 1
    fi

    # Update and install dependencies
    info "[$ct_id] Installing dependencies..."
    pct exec "$ct_id" -- bash -c "apt-get update -qq" 2>/dev/null
    pct exec "$ct_id" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates git" 2>/dev/null

    # Install Node.js (required for Claude Code)
    info "[$ct_id] Installing Node.js..."
    pct exec "$ct_id" -- bash -c '
        if ! command -v node &> /dev/null; then
            curl -fsSL https://deb.nodesource.com/setup_20.x | bash - 2>/dev/null
            apt-get install -y -qq nodejs 2>/dev/null
        else
            echo "Node.js already installed: $(node --version)"
        fi
    '

    # Install Claude Code via npm
    info "[$ct_id] Installing Claude Code CLI..."
    pct exec "$ct_id" -- bash -c '
        npm install -g @anthropic-ai/claude-code 2>/dev/null || {
            echo "npm install failed, trying alternative..."
            npm install -g @anthropic-ai/claude-code --force 2>/dev/null
        }
    '

    # Verify installation
    if pct exec "$ct_id" -- bash -c "command -v claude &> /dev/null"; then
        local version
        version=$(pct exec "$ct_id" -- claude --version 2>/dev/null || echo "unknown")
        success "[$ct_id] Claude Code installed successfully (v$version)"
        return 0
    else
        error "[$ct_id] Claude Code installation failed"
        return 1
    fi
}

#################################################################
# Get All Running LXC Container IDs
#################################################################

get_all_container_ids() {
    pct list | tail -n +2 | awk '{print $1}'
}

#################################################################
# Main Execution
#################################################################

show_usage() {
    echo "Usage: $0 [CT_ID|all]"
    echo ""
    echo "Arguments:"
    echo "  CT_ID    Install Claude Code on a specific container"
    echo "  all      Install Claude Code on all running containers"
    echo ""
    echo "Examples:"
    echo "  $0 100       # Install on container 100"
    echo "  $0 all       # Install on all containers"
    echo ""
}

main() {
    check_root
    check_proxmox

    if [[ $# -eq 0 ]]; then
        show_usage
        exit 1
    fi

    local target="$1"
    local success_count=0
    local fail_count=0

    if [[ "$target" == "all" ]]; then
        info "Installing Claude Code on all containers..."
        echo ""

        local containers
        containers=$(get_all_container_ids)

        if [[ -z "$containers" ]]; then
            error "No containers found"
            exit 1
        fi

        for ct_id in $containers; do
            if install_claude_on_container "$ct_id"; then
                ((success_count++))
            else
                ((fail_count++))
            fi
            echo ""
        done

        echo "================================================================="
        success "Installation complete!"
        echo "  • Successful: $success_count containers"
        if [[ $fail_count -gt 0 ]]; then
            warn "  • Failed: $fail_count containers"
        fi
        echo "================================================================="
    else
        if ! [[ "$target" =~ ^[0-9]+$ ]]; then
            error "Invalid container ID: $target"
            show_usage
            exit 1
        fi

        install_claude_on_container "$target"
    fi
}

main "$@"
