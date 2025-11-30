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
# Download and run
curl -sL https://raw.githubusercontent.com/YOUR_USERNAME/proxmox-lxc-shell-commands/main/proxmox-lxc-mailpit.sh | bash

# Or with custom settings
curl -sL https://raw.githubusercontent.com/YOUR_USERNAME/proxmox-lxc-shell-commands/main/proxmox-lxc-mailpit.sh -o mailpit.sh
chmod +x mailpit.sh
CT_ID=250 CT_MEMORY=1024 ./mailpit.sh
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

### Method 1: Direct Download and Execute
```bash
curl -sL https://raw.githubusercontent.com/YOUR_USERNAME/proxmox-lxc-shell-commands/main/proxmox-lxc-mailpit.sh | bash
```

### Method 2: Clone Repository
```bash
git clone https://github.com/YOUR_USERNAME/proxmox-lxc-shell-commands.git
cd proxmox-lxc-shell-commands
chmod +x *.sh
./proxmox-lxc-mailpit.sh
```

### Method 3: wget
```bash
wget https://raw.githubusercontent.com/YOUR_USERNAME/proxmox-lxc-shell-commands/main/proxmox-lxc-mailpit.sh
chmod +x proxmox-lxc-mailpit.sh
./proxmox-lxc-mailpit.sh
```

## 🎯 Tested On

- Proxmox VE 9.1.1
- Debian 12 (Bookworm) LXC templates

## 🤝 Contributing

Contributions welcome! Feel free to submit pull requests or open issues.

## 📝 License

MIT License - Feel free to use and modify as needed.

## ⚠️ Disclaimer

These scripts are provided as-is. Always review scripts before running them in production environments.
