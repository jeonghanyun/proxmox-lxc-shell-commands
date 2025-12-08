# Proxmox LXC Shell Commands

Collection of automated shell scripts for creating and configuring LXC containers in Proxmox VE.

## 📋 Available Scripts

### Nextcloud File Hosting & Collaboration

**Script**: `proxmox-lxc-nextcloud.sh`

Automatically creates and configures Nextcloud 32.0.1 with PHP 8.3, MariaDB, and Redis in a Debian 12 LXC container.

**Features**:
- 🚀 Latest Nextcloud 32.0.1 (Hub 25 Autumn)
- 🔧 PHP 8.3 with optimized OPcache settings (1GB memory, 512MB interned strings, JIT enabled)
- 🗄️ MariaDB with Nextcloud-optimized configuration
- ⚡ Redis for caching and file locking
- 🔐 Auto-generated secure passwords
- 📝 Complete with OCC command setup
- 🔒 HSTS security header enabled
- ⚠️ AppAPI auto-disabled (Docker API version incompatibility)

**Installation**:
```bash
# Basic installation
bash <(curl -s https://raw.githubusercontent.com/jeonghanyun/proxmox-lxc-shell-commands/master/proxmox-lxc-nextcloud.sh)

# With custom settings
CT_ID=300 CT_MEMORY=4096 bash <(curl -s https://raw.githubusercontent.com/jeonghanyun/proxmox-lxc-shell-commands/master/proxmox-lxc-nextcloud.sh)
```

**Customization**:
```bash
CT_ID=202                    # Container ID
CT_HOSTNAME="nextcloud"      # Hostname
CT_CORES=2                   # CPU cores
CT_MEMORY=4096               # RAM in MB (4GB recommended for OPcache settings)
CT_DISK_SIZE=20              # Disk size in GB
CT_IP="dhcp"                 # IP (dhcp or static like 192.168.1.100/24)
CT_GATEWAY=""                # Gateway for static IP
NEXTCLOUD_ADMIN_USER="admin" # Admin username
```

---

### Nextcloud Talk High-Performance Backend (HPB)

**Script**: `proxmox-lxc-nextcloud-talk-hpb.sh`

Configures Nextcloud Talk HPB with Docker-based signaling server (NATS + Janus Gateway) for an existing Nextcloud container.

**Features**:
- 🚀 Docker-based signaling server (strukturag/nextcloud-spreed-signaling)
- 📡 NATS message broker for scalability
- 🎥 Janus WebRTC gateway for video calls
- 🔧 Automatic Nextcloud Talk configuration
- 🔐 Auto-generated secure secrets

**Installation**:
```bash
# Configure HPB for existing Nextcloud container
CT_ID=20001 \
NEXTCLOUD_URL=https://nextcloud.example.com \
SIGNALING_URL=https://signaling.example.com \
bash <(curl -s https://raw.githubusercontent.com/jeonghanyun/proxmox-lxc-shell-commands/master/proxmox-lxc-nextcloud-talk-hpb.sh)
```

**Customization**:
```bash
CT_ID=20001                                    # Container ID (REQUIRED)
NEXTCLOUD_URL="https://nextcloud.example.com"  # Nextcloud URL (REQUIRED)
SIGNALING_URL="https://signaling.example.com"  # Signaling server URL (REQUIRED)
SIGNALING_PORT=8081                            # Internal signaling port
```

**Note**: Requires a reverse proxy to forward the signaling URL to the internal port (8081). Docker will be installed automatically if not present.

---

### Nextcloud Talk Server (Signaling + TURN)

**Script**: `proxmox-lxc-nextcloud-talk-server.sh`

Creates a dedicated LXC container with Docker-based Signaling server (NATS + Janus Gateway) and TURN server (coturn) for Nextcloud Talk video calls.

**Features**:
- 🚀 Standalone Talk server (separate from Nextcloud)
- 📡 nextcloud-spreed-signaling with NATS + Janus WebRTC gateway
- 🔄 coturn TURN server for NAT traversal
- 🐳 Docker-based deployment for easy management
- 🔐 Auto-generated secure secrets
- ⚙️ `allowall = true` with global secret (easy multi-Nextcloud setup)

**Installation**:
```bash
# Basic installation (EXTERNAL_IP required for TURN)
CT_ID=11001 EXTERNAL_IP=your.public.ip ./proxmox-lxc-nextcloud-talk-server.sh

# With custom domain
CT_ID=11001 EXTERNAL_IP=221.147.34.113 TURN_DOMAIN=turn.example.com ./proxmox-lxc-nextcloud-talk-server.sh
```

**Customization**:
```bash
CT_ID=11001                     # Container ID
CT_HOSTNAME="talk-server"       # Hostname
CT_CORES=2                      # CPU cores
CT_MEMORY=2048                  # RAM in MB
CT_DISK_SIZE=20                 # Disk size in GB
EXTERNAL_IP="1.2.3.4"           # Public IP for TURN (REQUIRED)
TURN_DOMAIN="turn.example.com"  # TURN domain (optional)
SIGNALING_PORT=8081             # Signaling server port
TURN_PORT=3478                  # TURN server port
```

**Nextcloud Configuration** (after installation):
```bash
# Add signaling server
sudo -u www-data php occ talk:signaling:add https://signal.example.com YOUR_SECRET --verify

# Add TURN server (note: no 'turn:' prefix in server field)
sudo -u www-data php occ talk:turn:add turn turn.example.com:3478 udp,tcp --secret=YOUR_TURN_SECRET
```

**Firewall Ports**:
- `8081` - Signaling (needs HTTPS reverse proxy)
- `3478` UDP/TCP - TURN
- `49152-49252` UDP - TURN relay
- `10000-10100` UDP - Janus RTP

**Important Notes**:
- Requires **reverse proxy** with SSL for signaling server (e.g., `https://signal.example.com` → `192.168.x.x:8081`)
- TURN server uses `allowall = true` with global secret - all Nextcloud instances share the same secret
- Run `pct exec 11001 -- /opt/signaling/turn-info.sh` to display configuration info

---

### ISPConfig Web Hosting Control Panel

**Script**: `proxmox-lxc-ispconfig.sh`

Automatically creates and configures ISPConfig 3 with Apache, MariaDB, Postfix, Dovecot, and BIND9 in a Debian 12 LXC container.

**Features**:
- 🚀 ISPConfig 3.2.12 - Full-featured hosting control panel
- 🌐 Apache 2 web server with PHP
- 🗄️ MariaDB database server
- 📧 Postfix + Dovecot for email hosting
- 🔒 DNS server (BIND9)
- 📁 FTP server (Pure-FTPd)
- 🛡️ Fail2ban for security
- 🔐 Auto-generated secure passwords

**Installation**:
```bash
# Basic installation
bash <(curl -s https://raw.githubusercontent.com/jeonghanyun/proxmox-lxc-shell-commands/master/proxmox-lxc-ispconfig.sh)

# With custom settings
CT_ID=210 CT_MEMORY=4096 bash <(curl -s https://raw.githubusercontent.com/jeonghanyun/proxmox-lxc-shell-commands/master/proxmox-lxc-ispconfig.sh)
```

**Customization**:
```bash
CT_ID=210                    # Container ID
CT_HOSTNAME="ispconfig"      # Hostname
CT_CORES=2                   # CPU cores
CT_MEMORY=2048               # RAM in MB (2GB recommended)
CT_DISK_SIZE=30              # Disk size in GB
CT_IP="dhcp"                 # IP (dhcp or static like 192.168.1.100/24)
CT_GATEWAY=""                # Gateway for static IP
ISPCONFIG_PORT=8080          # Control panel port
MAIL_DOMAIN="local.domain"   # Mail domain for Postfix
```

---

### CyberPanel with OpenLiteSpeed

**Script**: `proxmox-lxc-cyberpanel.sh`

Automatically creates and configures CyberPanel with OpenLiteSpeed web server in an Ubuntu 22.04 LXC container.

**Features**:
- 🚀 CyberPanel - Modern hosting control panel
- ⚡ OpenLiteSpeed - High-performance web server
- 🗄️ MariaDB database server
- 📧 Postfix mail server
- 🔒 PowerDNS for DNS management
- 📁 Pure-FTPd for FTP
- ⚡ Redis for caching
- 🔐 Auto-generated secure passwords
- 📊 Built-in phpMyAdmin, File Manager, Webmail

**Installation**:
```bash
# Basic installation
bash <(curl -s https://raw.githubusercontent.com/jeonghanyun/proxmox-lxc-shell-commands/master/proxmox-lxc-cyberpanel.sh)

# With custom settings
CT_ID=211 CT_MEMORY=4096 bash <(curl -s https://raw.githubusercontent.com/jeonghanyun/proxmox-lxc-shell-commands/master/proxmox-lxc-cyberpanel.sh)
```

**Customization**:
```bash
CT_ID=211                    # Container ID
CT_HOSTNAME="cyberpanel"     # Hostname
CT_CORES=2                   # CPU cores
CT_MEMORY=2048               # RAM in MB (2GB minimum)
CT_DISK_SIZE=30              # Disk size in GB
CT_IP="dhcp"                 # IP (dhcp or static like 192.168.1.100/24)
CT_GATEWAY=""                # Gateway for static IP
CYBERPANEL_PORT=8090         # Control panel port
INSTALL_POWERDNS="yes"       # Install PowerDNS
INSTALL_POSTFIX="yes"        # Install Postfix
INSTALL_REDIS="yes"          # Install Redis
```

---

### Mailpit Email Testing Server

**Script**: `proxmox-lxc-mailpit.sh`

Automatically creates and configures a Mailpit email testing server in a Debian 12 LXC container.

**Features**:
- 🚀 Fully automated installation
- 📧 SMTP server on port 1025
- 🌐 Web UI on port 8025
- 🔧 Systemd service auto-configuration
- 💾 Minimal resource usage (512MB RAM, 4GB disk)

**Installation**:
```bash
# Basic installation
bash <(curl -s https://raw.githubusercontent.com/jeonghanyun/proxmox-lxc-shell-commands/master/proxmox-lxc-mailpit.sh)

# With custom settings
CT_ID=250 CT_MEMORY=1024 bash <(curl -s https://raw.githubusercontent.com/jeonghanyun/proxmox-lxc-shell-commands/master/proxmox-lxc-mailpit.sh)
```

**Customization**:
```bash
CT_ID=200                    # Container ID
CT_HOSTNAME="mailpit"        # Hostname
CT_CORES=1                   # CPU cores
CT_MEMORY=512                # RAM in MB
CT_DISK_SIZE=4               # Disk size in GB
CT_IP="dhcp"                 # IP (dhcp or static like 192.168.1.100/24)
CT_GATEWAY=""                # Gateway for static IP
```

---

### Coolify Self-Hosted PaaS

**Script**: `proxmox-lxc-coolify.sh`

Automatically creates and configures Coolify - a self-hosted Heroku/Netlify alternative - with Docker in a Debian 12 LXC container.

**Features**:
- 🚀 Coolify - Self-hosted PaaS (Heroku/Netlify alternative)
- 🐳 Docker CE with Compose plugin
- 🌐 Web UI on port 8000
- 📦 Deploy apps from Git, Docker, or buildpacks
- 🔄 Automatic deployments and rollbacks
- 📊 Built-in monitoring and logging
- 🔒 Free SSL certificates with Let's Encrypt
- ⚠️ Requires **privileged container** for Docker support

**Installation**:
```bash
# Basic installation
bash <(curl -s https://raw.githubusercontent.com/jeonghanyun/proxmox-lxc-shell-commands/master/proxmox-lxc-coolify.sh)

# With custom settings
CT_ID=201 CT_MEMORY=8192 CT_DISK_SIZE=50 bash <(curl -s https://raw.githubusercontent.com/jeonghanyun/proxmox-lxc-shell-commands/master/proxmox-lxc-coolify.sh)
```

**Customization**:
```bash
CT_ID=201                    # Container ID
CT_HOSTNAME="coolify"        # Hostname
CT_CORES=2                   # CPU cores (minimum 2 recommended)
CT_MEMORY=4096               # RAM in MB (minimum 4GB recommended)
CT_DISK_SIZE=30              # Disk size in GB (minimum 30GB recommended)
CT_IP="dhcp"                 # IP (dhcp or static like 192.168.1.100/24)
CT_GATEWAY=""                # Gateway for static IP
COOLIFY_WEB_PORT=8000        # Web UI port
```

**Note**: This creates a **privileged container** which is required for Docker to function properly. The container is configured with all necessary capabilities for running Docker.

---

### CloudPanel Modern Server Control Panel

**Script**: `proxmox-lxc-cloudpanel.sh`

Automatically creates and configures CloudPanel - a modern server control panel with NGINX, PHP, and MySQL/MariaDB - in a Debian 12 LXC container.

**Features**:
- 🚀 CloudPanel 2 - Modern, lightweight control panel
- ⚡ NGINX web server (high performance)
- 🔧 Multiple PHP versions support (7.1 - 8.4)
- 🗄️ MySQL 8.4/8.0 or MariaDB 11.4/10.11
- 🔒 Free Let's Encrypt SSL certificates
- 📊 Built-in monitoring and log viewer
- 🌐 One-click WordPress, Laravel, Node.js deployments
- 📁 File Manager and phpMyAdmin included
- ⚠️ Requires **privileged container** for full functionality

**Installation**:
```bash
# Basic installation (MySQL 8.4)
bash <(curl -s https://raw.githubusercontent.com/jeonghanyun/proxmox-lxc-shell-commands/master/proxmox-lxc-cloudpanel.sh)

# With MariaDB
CT_ID=207 DB_ENGINE=MARIADB_11.4 bash <(curl -s https://raw.githubusercontent.com/jeonghanyun/proxmox-lxc-shell-commands/master/proxmox-lxc-cloudpanel.sh)

# With custom settings
CT_ID=207 CT_MEMORY=4096 CT_DISK_SIZE=50 bash <(curl -s https://raw.githubusercontent.com/jeonghanyun/proxmox-lxc-shell-commands/master/proxmox-lxc-cloudpanel.sh)
```

**Customization**:
```bash
CT_ID=207                    # Container ID
CT_HOSTNAME="cloudpanel"     # Hostname
CT_CORES=2                   # CPU cores (minimum 1)
CT_MEMORY=2048               # RAM in MB (minimum 2GB)
CT_DISK_SIZE=20              # Disk size in GB (minimum 10GB)
CT_IP="dhcp"                 # IP (dhcp or static like 192.168.1.100/24)
CT_GATEWAY=""                # Gateway for static IP
DB_ENGINE="MYSQL_8.4"        # MYSQL_8.4, MYSQL_8.0, MARIADB_11.4, MARIADB_10.11
```

**Ports**:
- `8443` - CloudPanel Admin Panel (HTTPS)
- `80` - HTTP Web Traffic
- `443` - HTTPS Web Traffic

**Note**: This creates a **privileged container**. On first access, you'll need to accept the self-signed certificate and create your admin account.

## 🔧 Requirements

- Proxmox VE 9.1+ (or compatible versions)
- Root access on Proxmox host
- Internet connection for template/software downloads

## 🤝 Contributing

Contributions welcome! Feel free to submit pull requests or open issues.

## 📚 Documentation

- **[PROMPT-EXAMPLES.md](PROMPT-EXAMPLES.md)** - AI에게 스크립트 요청하는 법 (간단!)
- **[GUIDE.md](GUIDE.md)** - 직접 만들고 싶을 때 (상세 가이드)
- **[template-script.sh](template-script.sh)** - 복사해서 바로 시작

## 📝 License

MIT License - Feel free to use and modify as needed.

## ⚠️ Disclaimer

These scripts are provided as-is. Always review scripts before running them in production environments.
