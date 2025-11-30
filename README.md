# Proxmox LXC Shell Commands

Collection of automated shell scripts for creating and configuring LXC containers in Proxmox VE.

## 📋 Available Scripts

### Nextcloud File Hosting & Collaboration

**Script**: `proxmox-lxc-nextcloud.sh`

Automatically creates and configures Nextcloud 32.0.1 with PHP 8.3, MariaDB, and Redis in a Debian 12 LXC container.

**Features**:
- 🚀 Latest Nextcloud 32.0.1 (Hub 25 Autumn)
- 🔧 PHP 8.3 with optimized settings
- 🗄️ MariaDB with Nextcloud-optimized configuration
- ⚡ Redis for caching and file locking
- 🔐 Auto-generated secure passwords
- 📝 Complete with OCC command setup

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
CT_MEMORY=2048               # RAM in MB (2GB recommended)
CT_DISK_SIZE=20              # Disk size in GB
CT_IP="dhcp"                 # IP (dhcp or static like 192.168.1.100/24)
CT_GATEWAY=""                # Gateway for static IP
NEXTCLOUD_ADMIN_USER="admin" # Admin username
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
