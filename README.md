# Proxmox LXC Shell Commands

Collection of automated shell scripts for creating and configuring LXC containers in Proxmox VE.

## 📋 Available Scripts

### Mailpit Email Testing Server

**Script**: `proxmox-lxc-mailpit.sh`

Automatically creates and configures a Mailpit email testing server in a Debian 12 LXC container.

**Features**:
- 🚀 Fully automated installation
- 📧 SMTP server on port 1025
- 🌐 Web UI on port 8025
- 🔧 Systemd service auto-configuration
- 💾 Minimal resource usage (512MB RAM, 4GB disk)

**Quick Start**:
```bash
# One-line installation (recommended)
bash <(curl -s https://raw.githubusercontent.com/jeonghanyun/proxmox-lxc-shell-commands/master/proxmox-lxc-mailpit.sh)

# With custom settings
CT_ID=250 CT_MEMORY=1024 bash <(curl -s https://raw.githubusercontent.com/jeonghanyun/proxmox-lxc-shell-commands/master/proxmox-lxc-mailpit.sh)

# Alternative: Download and run
curl -sL https://raw.githubusercontent.com/jeonghanyun/proxmox-lxc-shell-commands/master/proxmox-lxc-mailpit.sh | bash
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

## 📖 Usage

### Method 1: One-Line Installation (Recommended)
```bash
bash <(curl -s https://raw.githubusercontent.com/jeonghanyun/proxmox-lxc-shell-commands/master/proxmox-lxc-mailpit.sh)
```

**If experiencing cache issues, use this version:**
```bash
wget -O /tmp/mailpit.sh "https://raw.githubusercontent.com/jeonghanyun/proxmox-lxc-shell-commands/master/proxmox-lxc-mailpit.sh?$(date +%s)"
bash /tmp/mailpit.sh
```

### Method 2: One-Line with Custom Settings
```bash
CT_ID=250 CT_MEMORY=1024 CT_IP="192.168.1.100/24" CT_GATEWAY="192.168.1.1" \
bash <(curl -s https://raw.githubusercontent.com/jeonghanyun/proxmox-lxc-shell-commands/master/proxmox-lxc-mailpit.sh)
```

### Method 3: Clone Repository
```bash
git clone https://github.com/jeonghanyun/proxmox-lxc-shell-commands.git
cd proxmox-lxc-shell-commands
./proxmox-lxc-mailpit.sh
```

### Method 4: wget
```bash
wget https://raw.githubusercontent.com/jeonghanyun/proxmox-lxc-shell-commands/master/proxmox-lxc-mailpit.sh
chmod +x proxmox-lxc-mailpit.sh
./proxmox-lxc-mailpit.sh
```

## 🎯 Tested On

- Proxmox VE 9.1.1
- Debian 12 (Bookworm) LXC templates

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
