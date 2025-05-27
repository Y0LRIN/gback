# 🚀 gback - Comprehensive Backup Utility

> **Secure, automated backups with Wake-on-LAN, encryption, and scheduling support**

[![License](https://img.shields.io/badge/license-MIT-blue.svg)]()
[![Shell](https://img.shields.io/badge/shell-bash-green.svg)]()
[![Version](https://img.shields.io/badge/version-1.0-orange.svg)]()

## 📋 Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Server Setup](#server-setup)
- [Configuration](#configuration)
- [Usage](#usage)
- [Examples](#examples)
- [Scheduling](#scheduling)
- [Encryption](#encryption)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)

---

## 🎯 Overview

**gback** is a powerful backup utility designed for seamless remote backups with advanced features like automatic server discovery, Wake-on-LAN support, client-side GPG encryption, and flexible scheduling. Perfect for home networks, small offices, or personal backup solutions.

### Key Highlights

- 🌐 **Remote Backup**: Automatically discovers and connects to backup servers
- ⚡ **Wake-on-LAN**: Automatically wakes up sleeping backup servers
- 🔐 **Encryption**: Client-side GPG encryption for sensitive data
- 📅 **Scheduling**: Built-in cron integration for automated backups
- 🔄 **Incremental**: Support for space-efficient incremental backups
- 🎨 **User-Friendly**: Colored output and progress indicators
- 🔧 **Flexible**: Multiple server support with ID-based selection

---

## ✨ Features

### Core Functionality
- **Automated Server Discovery** - Finds available backup servers on your network
- **Wake-on-LAN Integration** - Automatically wakes sleeping servers before backup
- **Multiple Server Support** - Configure and select from multiple backup destinations
- **Backup Verification** - Ensures data integrity after transfer

### Advanced Features
- **GPG Encryption** - Client-side encryption before network transfer
- **Incremental Backups** - Save space with rsync-based incremental backups
- **Scheduled Backups** - Built-in cron integration with management commands
- **Restore Functionality** - Full restore support with decryption
- **Progress Monitoring** - Real-time progress bars and detailed logging

### Network Features
- **Automatic Wake-up** - Uses Wake-on-LAN to start powered-off servers
- **Connection Timeouts** - Configurable timeouts for reliable operation
- **SSH Key Authentication** - Secure, password-less authentication
- **Multiple Network Support** - Works across different network segments

---

## 📦 Prerequisites

### Client Requirements

#### Required Dependencies
```bash
# Ubuntu/Debian
sudo apt update
sudo apt install rsync ssh openssh-client wakeonlan

# CentOS/RHEL/Fedora
sudo dnf install rsync openssh-clients wakeonlan

# Arch Linux
sudo pacman -S rsync openssh wakeonlan
```

#### Optional Dependencies
```bash
# For JSON configuration parsing (recommended)
sudo apt install jq  # Ubuntu/Debian
sudo dnf install jq  # CentOS/RHEL/Fedora
sudo pacman -S jq    # Arch Linux

# For encryption support
sudo apt install gnupg  # Ubuntu/Debian
sudo dnf install gnupg2 # CentOS/RHEL/Fedora
sudo pacman -S gnupg    # Arch Linux

# Alternative to wakeonlan
sudo apt install etherwake  # Ubuntu/Debian only
```

### Server Requirements

#### Server Software
- SSH server (OpenSSH)
- rsync
- Sufficient storage space
- Network connectivity

#### Network Requirements
- SSH access (default port 22)
- Wake-on-LAN support (if using auto-wake feature)
- Static IP or DHCP reservation recommended

---

## 🔧 Installation

### 1. Download and Setup

```bash
# Clone or download the project
git clone https://github.com/Y0LRIN/gback.git
cd gback

# Make the script executable
chmod +x gback.sh

# Copy example configuration
cp example.config.json gback.config.json
```

### 2. SSH Key Setup

```bash
# Generate SSH key if you don't have one
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519

# Copy public key to backup server(s)
ssh-copy-id -i ~/.ssh/id_ed25519.pub user@backup-server-ip
```

### 3. GPG Setup (Optional, for encryption)

```bash
# Generate GPG key if needed
gpg --gen-key

# List available keys
gpg --list-keys

# Export public key for sharing
gpg --export --armor your@email.com > public-key.asc
```

---

## 🖥️ Server Setup

### Basic Server Configuration

#### 1. Create Backup User
```bash
# On the backup server
sudo useradd -m -s /bin/bash backup-user
sudo mkdir -p /home/backup-user/.ssh
sudo chown backup-user:backup-user /home/backup-user/.ssh
sudo chmod 700 /home/backup-user/.ssh
```

#### 2. Setup SSH Access
```bash
# Add client's public key to authorized_keys
sudo nano /home/backup-user/.ssh/authorized_keys
# Paste the content of client's ~/.ssh/id_ed25519.pub

sudo chown backup-user:backup-user /home/backup-user/.ssh/authorized_keys
sudo chmod 600 /home/backup-user/.ssh/authorized_keys
```

#### 3. Create Backup Directories
```bash
# Create backup and log directories
sudo mkdir -p /home/backup-user/backup
sudo mkdir -p /home/backup-user/backup_logs
sudo chown -R backup-user:backup-user /home/backup-user/backup*
```

### Wake-on-LAN Setup

#### 1. Enable in BIOS/UEFI
- Boot into BIOS/UEFI settings
- Enable "Wake on LAN" or "Wake on Network"
- Enable "Power on by PCI-E device" if available

#### 2. Configure Network Interface
```bash
# Check current settings
sudo ethtool eth0

# Enable Wake-on-LAN
sudo ethtool -s eth0 wol g

# Make permanent (Ubuntu/Debian)
echo 'post-up ethtool -s eth0 wol g' | sudo tee -a /etc/network/interfaces

# Or create systemd service
sudo tee /etc/systemd/system/wol.service << EOF
[Unit]
Description=Enable Wake-on-LAN
After=network.target

[Service]
Type=oneshot
ExecStart=/sbin/ethtool -s eth0 wol g
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable wol.service
```

#### 3. Find MAC Address
```bash
# Get MAC address
ip link show eth0
# or
cat /sys/class/net/eth0/address
```

---

## ⚙️ Configuration

### Configuration File Structure

Edit `gback.config.json` to match your environment:

```json
{
  "network": {
    "common_mac": "08:00:27:73:3B:D8",     // Default MAC for Wake-on-LAN
    "ping_timeout": 1,                      // Ping timeout in seconds
    "ssh_timeout": 2,                       // SSH connection timeout
    "boot_wait": 10                         // Time to wait after WoL packet
  },
  "defaults": {
    "debug": false,                         // Enable debug output
    "encryption_enabled": false,            // Default encryption state
    "incremental": false,                   // Default incremental mode
    "use_colors": true,                     // Colored output
    "show_progress": true,                  // Progress indicators
    "progress_width": 50                    // Progress bar width
  },
  "backup": {
    "backup_root": "/home/user/backup",     // Backup destination path
    "log_dir": "/home/user/backup_logs",    // Log file location
    "retention_days": 120                   // Log retention period
  },
  "encryption": {
    "default_recipient": "your@email.com"   // Default GPG recipient
  },
  "ssh_config": {
    "user": "backup-user",                  // SSH username
    "key_path": "~/.ssh/id_ed25519",       // SSH private key path
    "port": 22                              // SSH port
  },
  "scheduling": {
    "default_time": "02:00"                 // Default backup time
  },
  "server_ips": [
    {
      "ip": "192.168.1.100",               // Server IP address
      "desc": "Main Backup Server",         // Description
      "mac": "11:22:33:44:55:66"           // Optional: server-specific MAC
    },
    {
      "ip": "192.168.1.101",
      "desc": "Secondary Server"            // Uses common_mac if no MAC specified
    }
  ]
}
```

### Configuration Options Explained

#### Network Settings
- **common_mac**: Default MAC address used for Wake-on-LAN when server-specific MAC isn't provided
- **ping_timeout**: How long to wait for ping response (seconds)
- **ssh_timeout**: SSH connection timeout (seconds)
- **boot_wait**: Time to wait after sending Wake-on-LAN packet (seconds)

#### Default Behavior
- **debug**: Enable verbose debugging output
- **encryption_enabled**: Enable encryption by default
- **incremental**: Use incremental backups by default
- **use_colors**: Enable colored terminal output
- **show_progress**: Display progress bars during transfer

#### Server Configuration
Each server entry supports:
- **ip**: Server IP address (required)
- **desc**: Human-readable description (optional)
- **mac**: Server-specific MAC address (optional, uses common_mac if not specified)

---

## 🚀 Usage

### Basic Syntax

```bash
./gback.sh [OPTIONS] SOURCE [DESTINATION]
```

### Command Line Options

| Option | Description | Example |
|--------|-------------|---------|
| `-d` | Enable debug mode | `./gback.sh -d ~/Documents` |
| `-e` | Enable encryption | `./gback.sh -e ~/private` |
| `-k KEY_ID` | Specify GPG recipient | `./gback.sh -e -k user@email.com ~/data` |
| `-i ID` | Select server by ID | `./gback.sh -i 2 ~/Documents` |
| `-m IP` | Use specific IP address | `./gback.sh -m 192.168.1.100 ~/data` |
| `-l` | List available servers | `./gback.sh -l` |
| `-r` | Restore mode | `./gback.sh -r backup_name ~/restored` |
| `-I` | Incremental backup | `./gback.sh -I ~/Documents` |
| `-c` | Disable colored output | `./gback.sh -c ~/Documents` |
| `-P` | Disable progress display | `./gback.sh -P ~/Documents` |
| `-S INTERVAL` | Schedule backup | `./gback.sh -S daily ~/Documents` |
| `-t TIME` | Set schedule time | `./gback.sh -S daily -t 03:30 ~/Documents` |
| `--list-schedules` | List scheduled backups | `./gback.sh --list-schedules` |
| `--remove-schedule=ID` | Remove scheduled backup | `./gback.sh --remove-schedule=123456` |
| `-h, --help` | Show help message | `./gback.sh --help` |

---

## 💡 Examples

### Basic Operations

#### Simple Backup
```bash
# Backup a directory to automatically discovered server
./gback.sh ~/Documents

# Backup a single file
./gback.sh ~/important-file.txt
```

#### Server Selection
```bash
# List available servers
./gback.sh -l

# Select server by ID
./gback.sh -i 1 ~/Documents

# Use specific IP address
./gback.sh -m 192.168.1.100 ~/Documents
```

#### Backup with Options
```bash
# Debug mode for troubleshooting
./gback.sh -d ~/Documents

# Incremental backup
./gback.sh -I ~/Documents

# Quiet mode (no colors, no progress)
./gback.sh -c -P ~/Documents
```

### Encryption Examples

#### Basic Encryption
```bash
# Enable encryption with default recipient
./gback.sh -e ~/private-documents

# Specify GPG recipient
./gback.sh -e -k alice@example.com ~/confidential

# Encrypted incremental backup
./gback.sh -e -I -k bob@company.com ~/work-files
```

### Restore Operations

#### Basic Restore
```bash
# Restore from automatic server discovery
./gback.sh -r Documents /home/user/restored

# Restore from specific server
./gback.sh -r -i 2 important-file.txt /home/user/recovered

# Restore encrypted backup
./gback.sh -r -e -k your@email.com encrypted-backup /home/user/decrypted
```

#### Advanced Restore
```bash
# Debug restore operation
./gback.sh -d -r -e Documents /home/user/debug-restore

# Restore using manual IP
./gback.sh -r -m 192.168.1.100 project-backup /home/user/projects
```

---

## 📅 Scheduling

### Schedule Management

#### Create Scheduled Backups
```bash
# Daily backup at 2:00 AM (default)
./gback.sh -S daily ~/Documents

# Weekly backup at 3:30 AM
./gback.sh -S weekly -t 03:30 ~/important-files

# Monthly backup with encryption
./gback.sh -S monthly -t 01:00 -e ~/sensitive-data

# Custom cron schedule (every 6 hours)
./gback.sh -S "0 */6 * * *" ~/frequent-changes
```

#### Manage Scheduled Backups
```bash
# List all scheduled backups
./gback.sh --list-schedules

# Remove a scheduled backup (use ID from list)
./gback.sh --remove-schedule=1640995200
```

### Schedule Types

| Type | Description | Cron Expression |
|------|-------------|-----------------|
| `daily` | Every day at specified time | `MM HH * * *` |
| `weekly` | Every Sunday at specified time | `MM HH * * 0` |
| `monthly` | 1st of every month at specified time | `MM HH 1 * *` |
| Custom | Your own cron expression | `* * * * *` |

### Schedule Examples
```bash
# Business hours backup (Monday-Friday, 6 PM)
./gback.sh -S "0 18 * * 1-5" ~/work

# Twice daily backup
./gback.sh -S "0 2,14 * * *" ~/critical-data

# Weekend backup only
./gback.sh -S "0 3 * * 6,0" ~/personal-files
```

---

## 🔐 Encryption

### GPG Setup

#### Generate New Key
```bash
# Interactive key generation
gpg --gen-key

# Advanced key generation
gpg --full-gen-key
```

#### Key Management
```bash
# List keys
gpg --list-keys

# Export public key
gpg --export --armor your@email.com > public-key.asc

# Import someone's public key
gpg --import public-key.asc

# Trust a key
gpg --edit-key your@email.com
# Type: trust, select level, quit
```

### Encryption Examples

#### File Encryption
```bash
# Encrypt single file
./gback.sh -e -k recipient@email.com ~/secret.txt

# Encrypt directory
./gback.sh -e -k team@company.com ~/project-folder
```

#### Restore Encrypted Data
```bash
# Restore requires same GPG key that encrypted the data
./gback.sh -r -e secret.txt.gpg ~/restored-secret.txt

# Restore encrypted directory
./gback.sh -r -e project-folder.gpg ~/restored-project
```

### Security Best Practices

1. **Key Security**: Keep private keys secure and backed up
2. **Passphrase**: Use strong passphrases for GPG keys
3. **Key Expiry**: Set expiration dates on keys
4. **Key Rotation**: Regularly rotate encryption keys
5. **Testing**: Regularly test restore procedures

---

## 🛠️ Troubleshooting

### Common Issues

#### Connection Problems
```bash
# Test SSH connection manually
ssh -i ~/.ssh/id_ed25519 -p 22 user@server-ip

# Check SSH key permissions
ls -la ~/.ssh/id_ed25519*
# Should be: -rw------- (600) for private key
#           -rw-r--r-- (644) for public key

# Fix SSH key permissions
chmod 600 ~/.ssh/id_ed25519
chmod 644 ~/.ssh/id_ed25519.pub
```

#### Wake-on-LAN Issues
```bash
# Test Wake-on-LAN manually
wakeonlan 08:00:27:73:3B:D8

# Check if server supports WoL
sudo ethtool eth0 | grep Wake

# Verify MAC address
ip link show eth0
```

#### Server Discovery Problems
```bash
# Enable debug mode
./gback.sh -d ~/test-backup

# Test ping manually
ping -c 1 192.168.1.100

# Check network connectivity
traceroute 192.168.1.100
```

#### Permission Issues
```bash
# Check backup directory permissions on server
ssh user@server "ls -la /home/user/"

# Create backup directory if missing
ssh user@server "mkdir -p /home/user/backup"

# Fix ownership
ssh user@server "sudo chown -R user:user /home/user/backup"
```

### Debug Mode

Enable debug mode for detailed troubleshooting:
```bash
./gback.sh -d ~/Documents
```

Debug output includes:
- Configuration loading details
- Server discovery process
- Network connectivity tests
- File transfer progress
- Error messages with context

### Log Files

Check log files on the backup server:
```bash
# View recent backup logs
ssh user@server "ls -la /home/user/backup_logs/"

# Check latest log
ssh user@server "tail -f /home/user/backup_logs/gback_*.log"
```

### Performance Issues

#### Slow Transfers
```bash
# Use compression (default in script)
# Check network bandwidth
iperf3 -c server-ip

# Monitor transfer progress
./gback.sh -P ~/large-directory  # Disable progress for faster transfer
```

#### Large Backups
```bash
# Use incremental backups
./gback.sh -I ~/large-directory

# Split large directories
./gback.sh ~/directory/part1
./gback.sh ~/directory/part2
```

---

## 🤝 Contributing

### Development Setup

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly
5. Submit a pull request

### Testing

```bash
# Test basic functionality
./gback.sh -d ~/small-test-dir

# Test with different configurations
./gback.sh -e -I -k test@example.com ~/test-data

# Test scheduling
./gback.sh -S daily -t 23:59 ~/test-backup
./gback.sh --list-schedules
./gback.sh --remove-schedule=<id>
```

### Code Style

- Use clear variable names
- Add comments for complex logic
- Follow existing indentation
- Test all features before committing

---

## 📝 License

This project is licensed under the MIT License - see the LICENSE file for details.

---

## 🆘 Support

If you encounter issues:

1. Check the [Troubleshooting](#troubleshooting) section
2. Enable debug mode with `-d` flag
3. Check log files on the backup server
4. Verify network connectivity and permissions
5. Create an issue with debug output

---

**Happy Backing Up! 🎉**

> Remember: The best backup is the one you actually use regularly!