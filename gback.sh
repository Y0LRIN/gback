#!/bin/bash
# gback.sh - Comprehensive backup utility with encryption and scheduling support

# Initialize DEBUG early to prevent errors
DEBUG=0

# Debug function - only prints when DEBUG is enabled
debug() {
    if [ "$DEBUG" -eq 1 ]; then
        echo "DEBUG: $*"
    fi
}

# Features:
# - Remote backup with automatic server discovery
# - Wake-on-LAN for offline servers
# - Client-side GPG encryption
# - Incremental backups with rsync
# - Scheduled backups via cron
# - Colored output and progress display
# - Multiple server support with ID selection
#
# Usage examples:
#   ./gback.sh ~/Documents                    # Simple backup
#   ./gback.sh -e -k KEY_ID ~/private         # Encrypted backup
#   ./gback.sh -r backup_name ~/restored      # Restore from backup
#   ./gback.sh -S daily -t 03:30 ~/Documents  # Schedule daily backup
#
# Dependencies: wakeonlan/etherwake, jq/Python, rsync, ssh, gpg (for encryption)
#
# Author: Y0LRIN
# Created: 2025-05-17
# Version: 1.0

# ================ LOAD CONFIGURATION ================
# Look for config files in order of preference:
# 1. User's local config in same directory as script
# 2. User's home directory
# 3. System-wide config (for AUR package)
# 4. Example config in same directory

LOCAL_CONFIG="$(dirname "$(readlink -f "$0")")/gback.config.json"
HOME_CONFIG="$HOME/.config/gback/gback.config.json" 
SYSTEM_CONFIG="/etc/gback/gback.config.json"
EXAMPLE_CONFIG="$(dirname "$(readlink -f "$0")")/example.config.json"

CONFIG_FILE=""

if [ -f "$LOCAL_CONFIG" ]; then
    CONFIG_FILE="$LOCAL_CONFIG"
elif [ -f "$HOME_CONFIG" ]; then
    CONFIG_FILE="$HOME_CONFIG"
elif [ -f "$SYSTEM_CONFIG" ]; then
    CONFIG_FILE="$SYSTEM_CONFIG"
elif [ -f "$EXAMPLE_CONFIG" ]; then
    CONFIG_FILE="$EXAMPLE_CONFIG"
else
    echo "ERROR: No configuration file found. Looked for:"
    echo "  1. $LOCAL_CONFIG"
    echo "  2. $HOME_CONFIG"
    echo "  3. $SYSTEM_CONFIG"
    echo "  4. $EXAMPLE_CONFIG"
    echo ""
    echo "Please create a configuration file. You can copy the example:"
    echo "  mkdir -p ~/.config/gback"
    echo "  cp /etc/gback/gback.config.json ~/.config/gback/gback.config.json"
    exit 1
fi

# Debug output for configuration
debug "Config file contents:"
if [ "$DEBUG" -eq 1 ] && [ -f "$CONFIG_FILE" ]; then
    head -10 "$CONFIG_FILE"
fi

# Function to read configuration values
read_config() {
  local key="$1"
  local default="$2"
  
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "$default"
    return
  fi
  
  if command -v jq &>/dev/null; then
    value=$(jq -r "$key" "$CONFIG_FILE" 2>/dev/null)
    if [[ "$value" == "null" ]]; then
      echo "$default"
    else
      echo "$value"
    fi
  else
    # Python fallback
    value=$(python3 -c "
import json, sys
try:
    with open('$CONFIG_FILE', 'r') as f:
        data = json.load(f)
    key_parts = '$key'.strip('.').split('.')
    result = data
    for part in key_parts:
        if part in result:
            result = result[part]
        else:
            result = None
            break
    if result is None:
        print('$default')
    else:
        print(result)
except Exception:
    print('$default')
")
    echo "$value"
  fi
}

# ================ DEFAULT SETTINGS ================
# Network timeouts and wait periods
PING_TIMEOUT=$(read_config ".network.ping_timeout" "1")
SSH_TIMEOUT=$(read_config ".network.ssh_timeout" "2")
BOOT_WAIT=$(read_config ".network.boot_wait" "10")

# Feature flags
DEBUG=$(read_config ".defaults.debug" "0")
[ "$DEBUG" = "true" ] && DEBUG=1 || DEBUG=0
RESTORE_MODE=0  # Always start in backup mode
ENCRYPTION_ENABLED=$(read_config ".defaults.encryption_enabled" "0")
[ "$ENCRYPTION_ENABLED" = "true" ] && ENCRYPTION_ENABLED=1 || ENCRYPTION_ENABLED=0
INCREMENTAL=$(read_config ".defaults.incremental" "0")
[ "$INCREMENTAL" = "true" ] && INCREMENTAL=1 || INCREMENTAL=0
USE_COLORS=$(read_config ".defaults.use_colors" "1")
[ "$USE_COLORS" = "true" ] && USE_COLORS=1 || USE_COLORS=0
SHOW_PROGRESS=$(read_config ".defaults.show_progress" "1")
[ "$SHOW_PROGRESS" = "true" ] && SHOW_PROGRESS=1 || SHOW_PROGRESS=0

# Manual server selection
MANUAL_IP=""        # IP address when manually specified
SERVER_ID=""        # Server ID when selecting from config file

# Encryption settings
GPG_RECIPIENT=$(read_config ".encryption.default_recipient" "")

# Backup target settings
BACKUP_ROOT=$(read_config ".backup.backup_root" "/home/adm1/backup/pc_files")
LOG_DIR=$(read_config ".backup.log_dir" "/home/adm1/backup_logs")
RETENTION_DAYS=$(read_config ".backup.retention_days" "120")
PROGRESS_WIDTH=$(read_config ".defaults.progress_width" "50")

# SSH settings
SSH_USER=$(read_config ".ssh_config.user" "adm1")
SSH_KEY=$(read_config ".ssh_config.key_path" "$HOME/.ssh/id_ed25519")
SSH_PORT=$(read_config ".ssh_config.port" "22")

# Expand SSH key path if it starts with ~
if [[ "$SSH_KEY" =~ ^~.* ]]; then
    SSH_KEY="${SSH_KEY/#~/$HOME}"
fi

debug "Configuration loaded:"
debug "  BACKUP_ROOT=$BACKUP_ROOT"
debug "  LOG_DIR=$LOG_DIR"
debug "  SSH_USER=$SSH_USER"
debug "  SSH_KEY=$SSH_KEY"
debug "  SSH_PORT=$SSH_PORT"
debug "  GPG_RECIPIENT=$GPG_RECIPIENT"
debug "  RETENTION_DAYS=$RETENTION_DAYS"

# Scheduling settings
SCHEDULE_MODE=0     # Enable schedule creation mode
SCHEDULE_INTERVAL="" # Schedule interval (daily, weekly, monthly)
SCHEDULE_TIME=$(read_config ".scheduling.default_time" "02:00")
SCHEDULE_LIST=0     # List scheduled backups mode
SCHEDULE_REMOVE=""  # ID of scheduled backup to remove

# Shell compatibility
if [ -n "$ZSH_VERSION" ]; then
    emulate -L bash
    setopt KSH_ARRAYS
fi

# Color setup based on environment
if [ "$USE_COLORS" -eq 1 ]; then
    # Check if we're running in WSL
    if grep -qi microsoft /proc/version 2>/dev/null; then
        # WSL-specific color codes
        RED=$'\e[1;31m'
        GREEN=$'\e[1;32m'
        YELLOW=$'\e[1;33m'
        BLUE=$'\e[1;34m'
        PURPLE=$'\e[1;35m'
        CYAN=$'\e[1;36m'
        BOLD=$'\e[1m'
        NC=$'\e[0m'
    else
        # Standard color codes for other environments
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        YELLOW='\033[0;33m'
        BLUE='\033[0;34m'
        PURPLE='\033[0;35m'
        CYAN='\033[0;36m'
        BOLD='\033[1m'
        NC='\033[0m'
    fi
else
    # Empty strings when colors disabled
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    PURPLE=''
    CYAN=''
    BOLD=''
    NC=''
fi

# Debug function - only prints when DEBUG is enabled
debug() {
    if [ "$DEBUG" -eq 1 ]; then
        echo "DEBUG: $*"
    fi
}

info() {
    echo -e "${BLUE}INFO:${NC} $*"
}

success() {
    echo -e "${GREEN}SUCCESS:${NC} $*"
}

warning() {
    echo -e "${YELLOW}WARNING:${NC} $*"
}

error() {
    echo -e "${RED}ERROR:${NC} $*"
}

headline() {
    echo -e "\n${BOLD}${PURPLE}$*${NC}"
    echo -e "${PURPLE}$(printf '=%.0s' {1..50})${NC}"
}

show_help() {
    cat << EOF
BACKUP SCRIPT HELP
=================

NAME
    gback.sh - Secure backup with wake-on-LAN and encryption support

SYNOPSIS
    gback.sh [-d] [-e] [-k KEY_ID] [-i ID] [-m IP] [-l] [-I] [-c] [-P] SOURCE
    gback.sh -r [-d] [-e] [-k KEY_ID] [-i ID] [-m IP] SOURCE DESTINATION
    gback.sh -h | --help

DESCRIPTION
    Backs up files and directories to a remote server with support
    for automatic server discovery, wake-on-LAN, and GPG encryption.

OPTIONS
    -d                Enable debug mode for verbose output
    -e                Enable encryption using GPG
    -k KEY_ID         Specify GPG recipient (email or key ID)
    -i ID             Select server by ID number from config file
    -l                List available backup servers with their IDs
    -m IP             Manually specify an IP address to connect to
    -r                Restore mode, requires source and destination paths
    -I                Enable incremental backup mode
    -c                Disable colored output
    -P                Disable progress display
    -S INTERVAL       Schedule a recurring backup (daily, weekly, monthly, or custom)
    -t TIME           Time for scheduled backup in HH:MM format (default: 02:00)
    --list-schedules  List all scheduled backups
    --remove-schedule=ID  Remove a scheduled backup by ID
    -h, --help        Display this help message and exit

EXAMPLES
    # Backup a directory
    gback.sh ~/Documents
    
    # Backup with encryption
    gback.sh -e -k your@email.com ~/private-files
    
    # Restore with specified server
    gback.sh -r -i 2 myfiles /home/user/restored
    
    # List available servers
    gback.sh -l

    # Incremental backup
    gback.sh -I ~/Documents

    # Schedule a daily backup at 3:30 AM
    gback.sh -S daily -t 03:30 ~/Documents
    
    # List all scheduled backups
    gback.sh --list-schedules
    
    # Remove a scheduled backup
    gback.sh --remove-schedule=1620000000

CONFIGURATION
    Server configuration is stored in gback.config.json (same directory as script)

EOF
    exit 0
}

wake_server() {
    local mac="$1"
    local ip="$2"

    echo "Attempting to wake server at $ip with MAC $mac..."
    if command -v wakeonlan &>/dev/null; then
        wakeonlan "$mac" &>/dev/null
    elif command -v etherwake &>/dev/null; then
        sudo etherwake "$mac" &>/dev/null
    else
        echo "Warning: No wake-on-LAN tool found. Install wakeonlan or etherwake."
        return 1
    fi
    
    echo "Wake-on-LAN packet sent. Waiting for server to boot..."
    sleep $BOOT_WAIT
    return 0
}

backup() {
    local source_path="$1"
    local timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
    local log_file="${LOG_DIR}/gback_${timestamp}.log"

    # Add diagnostics for debugging
    debug "Checking source path: $source_path"
    if [ "$DEBUG" -eq 1 ]; then
        ls -la "$source_path" 2>/dev/null || echo "ls cannot access the file"
    fi
    
    if [ ! -f "$CONFIG_FILE" ]; then
        error "Server configuration not found at $CONFIG_FILE"
        return 1
    fi

    if [ ! -e "$source_path" ]; then
        echo "ERROR: Source path $source_path does not exist"
        if [ "$DEBUG" -eq 1 ]; then
            echo "File test results:"
            echo "  -e (exists): $([ -e "$source_path" ] && echo "true" || echo "false")"
            echo "  -f (regular file): $([ -f "$source_path" ] && echo "true" || echo "false")"
            echo "  -d (directory): $([ -d "$source_path" ] && echo "true" || echo "false")"
            echo "  -r (readable): $([ -r "$source_path" ] && echo "true" || echo "false")"
            echo "Current directory: $(pwd)"
        fi
        return 1
    fi

    local is_directory=false
    if [ -d "$source_path" ]; then
        is_directory=true
        echo "Backing up directory: $source_path"
    else
        echo "Backing up file: $source_path"
    fi

    local possible_ips=()
    declare -A ip_to_mac
    local common_mac=""

    if command -v jq &>/dev/null; then
        common_mac=$(jq -r '.network.common_mac // ""' "$CONFIG_FILE")
        while read -r line; do
            ip=$(echo "$line" | cut -d' ' -f1)
            mac=$(echo "$line" | cut -d' ' -f2)
            possible_ips+=("$ip")
            if [ -n "$mac" ]; then
                ip_to_mac["$ip"]="$mac"
            else
                ip_to_mac["$ip"]="$common_mac"
            fi
        done < <(jq -r '.server_ips[] | "\(.ip) \(.mac // "")"' "$CONFIG_FILE")
    else
        common_mac=$(python3 -c "import json,sys; data=json.load(open('$CONFIG_FILE')); print(data.get('network', {}).get('common_mac', ''))")
        while read -r line; do
            ip=$(echo "$line" | cut -d' ' -f1)
            mac=$(echo "$line" | cut -d' ' -f2)
            possible_ips+=("$ip")
            if [ -n "$mac" ]; then
                ip_to_mac["$ip"]="$mac"
            else
                ip_to_mac["$ip"]="$common_mac"
            fi
        done < <(python3 -c "import json,sys; data=json.load(open('$CONFIG_FILE')); print('\n'.join([s['ip'] + ' ' + s.get('mac', '') for s in data['server_ips']]))")
    fi

    debug "Loaded ${#possible_ips[@]} servers from config"
    debug "Common MAC address: $common_mac"

    # Handle manual IP or ID selection
    if [ -n "$MANUAL_IP" ]; then
        echo "Using manually specified IP: $MANUAL_IP"
        target_ip="$MANUAL_IP"
        # Assign the common MAC to this IP if not already known
        if [ -z "${ip_to_mac[$target_ip]}" ]; then
            ip_to_mac["$target_ip"]="$common_mac"
        fi
    elif [ -n "$SERVER_ID" ]; then
        target_ip=$(get_server_by_id "$CONFIG_FILE" "$SERVER_ID")
        if [ $? -ne 0 ] || [ -z "$target_ip" ]; then
            echo "ERROR: Failed to get server by ID $SERVER_ID"
            return 1
        fi
        echo "Using server ID $SERVER_ID, IP: $target_ip"
    else
        # Normal server discovery logic
        local target_ip=""
        echo "Searching for backup server..."
        for ip in "${possible_ips[@]}"; do
            debug "Trying server: $ip"
            if ! ping -c $PING_TIMEOUT -W $PING_TIMEOUT "$ip" &>/dev/null; then
                debug "Server $ip not responding to ping"
                if [[ -n "${ip_to_mac[$ip]}" ]]; then
                    debug "Attempting wake-on-LAN for $ip with MAC ${ip_to_mac[$ip]}"
                    wake_server "${ip_to_mac[$ip]}" "$ip"
                fi
            else
                debug "Server $ip responded to ping"
            fi
            # Update server discovery check in backup() function
            if timeout $SSH_TIMEOUT ssh -i "$SSH_KEY" -p "$SSH_PORT" -o ConnectTimeout=$SSH_TIMEOUT -o StrictHostKeyChecking=no "${SSH_USER}@$ip" "hostname" &>/dev/null; then
                target_ip="$ip"
                echo "Found backup server at $target_ip"
                break
            fi
        done
    fi
    
    # Check if we found a server
    if [ -z "$target_ip" ]; then
        echo "ERROR: Could not find active backup server. Backup aborted."
        return 1
    fi

    # Verify server is reachable when using manual IP or ID
    if [ -n "$MANUAL_IP" ] || [ -n "$SERVER_ID" ]; then
        if ! ping -c $PING_TIMEOUT -W $PING_TIMEOUT "$target_ip" &>/dev/null; then
            echo "Server at $target_ip not responding. Attempting to wake it..."
            wake_server "${ip_to_mac[$target_ip]}" "$target_ip"
        fi
        
        if ! timeout $SSH_TIMEOUT ssh -i "$SSH_KEY" -p "$SSH_PORT" -o ConnectTimeout=$SSH_TIMEOUT -o StrictHostKeyChecking=no "${SSH_USER}@$target_ip" "hostname" &>/dev/null; then
            echo "ERROR: Could not connect to server at $target_ip"
            return 1
        fi
    fi

    # Create log directory if it doesn't exist
    ssh -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@$target_ip" "mkdir -p $LOG_DIR || sudo mkdir -p $LOG_DIR"

    # Fix the log command to properly escape variables
    hostname=$(hostname)
    source_type=$([ "$is_directory" = true ] && echo "directory" || echo "file")

    # Update all log commands
    ssh -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@$target_ip" "echo '===== Backup started at \$(date) =====' > \"$log_file\" && \
        echo 'Source: ${hostname}:${source_path} (${source_type})' >> \"$log_file\" && \
        echo 'Target: ${target_ip}:${BACKUP_ROOT}/' >> \"$log_file\"" || {
        echo "ERROR: Could not log backup operation on backup server"
    }

    echo "Backing up to server at $target_ip..."

    # Add to backup.sh - right before the rsync command in the backup function
    if [ "$ENCRYPTION_ENABLED" -eq 1 ]; then
        # Validate GPG recipient is set
        if [ -z "$GPG_RECIPIENT" ]; then
            error "Encryption enabled but no GPG recipient specified. Use -k option or set default_recipient in config."
            return 1
        fi
        
        echo "Encrypting data before backup..."
        local temp_dir=$(mktemp -d)
        local encrypted_file="${temp_dir}/$(basename "$source_path").gpg"
        
        if [ "$is_directory" = true ]; then
            # For directories, create tar archive first
            local tar_file="${temp_dir}/$(basename "$source_path").tar"
            if ! tar -cf "$tar_file" -C "$(dirname "$source_path")" "$(basename "$source_path")"; then
                echo "ERROR: Failed to create archive of directory"
                rm -rf "$temp_dir"
                return 1
            fi
            # Encrypt the tar file
            if ! gpg --batch --yes -r "$GPG_RECIPIENT" -e -o "$encrypted_file" "$tar_file"; then
                echo "ERROR: Encryption failed"
                rm -rf "$temp_dir"
                return 1
            fi
            rm "$tar_file"  # Remove the unencrypted tar file
        else
            # For single files, encrypt directly
            if ! gpg --batch --yes -r "$GPG_RECIPIENT" -e -o "$encrypted_file" "$source_path"; then
                echo "ERROR: Encryption failed"
                rm -rf "$temp_dir"
                return 1
            fi
        fi
        
        echo "Data encrypted successfully. Uploading encrypted file..."
        # Update rsync commands for encrypted backups
        if ! rsync -azv --progress -e "ssh -i '$SSH_KEY' -p '$SSH_PORT'" "$encrypted_file" "${SSH_USER}@$target_ip:${BACKUP_ROOT}/$(basename "$source_path").gpg"; then
            echo "ERROR: Backup failed"
            ssh -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@$target_ip" "echo 'ERROR: Encrypted backup failed at \$(date)' >> \"$log_file\""
            rm -rf "$temp_dir"
            return 1
        fi
        
        # Clean up
        rm -rf "$temp_dir"
        echo "Encrypted backup completed successfully"
        ssh -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@$target_ip" "echo 'SUCCESS: Encrypted backup completed at \$(date)' >> \"$log_file\""
    else
        # Original rsync command for unencrypted backup
        echo "Backing up to server at $target_ip..."
        if [ "$INCREMENTAL" -eq 1 ]; then
            # Setup for incremental backup
            local date_path=$(date +%Y-%m-%d)
            local time_path=$(date +%H-%M-%S)
            local backup_dir="${BACKUP_ROOT}/${date_path}/${time_path}"
            local latest_link="${BACKUP_ROOT}/latest"
            
            echo "Creating incremental backup directory structure on server..."
            ssh -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@$target_ip" "mkdir -p ${backup_dir}"
            
            # Check if we have a previous backup to reference
            if ssh -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@$target_ip" "[ -L ${latest_link} ]"; then
                echo "Found previous backup, performing incremental backup..."
                # Update rsync commands for incremental backups
                if ! rsync -azv --delete --progress --info=progress2 --stats \
                    --link-dest="${latest_link}" \
                    -e "ssh -i '$SSH_KEY' -p '$SSH_PORT'" \
                    "$source_path" "${SSH_USER}@$target_ip:${backup_dir}"; then
                    echo "ERROR: Incremental backup failed"
                    return 1
                fi
            else
                echo "No previous backup found, performing full backup..."
                if ! rsync -azv --delete --progress --info=progress2 --stats \
                    -e "ssh -i '$SSH_KEY' -p '$SSH_PORT'" \
                    "$source_path" "${SSH_USER}@$target_ip:${backup_dir}"; then
                    echo "ERROR: Incremental backup failed"
                    return 1
                fi
            fi
            
            # Update the latest link to point to this backup
            ssh -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@$target_ip" "rm -f ${latest_link} && ln -s ${backup_dir} ${latest_link}"
            echo "Incremental backup completed successfully"
        else
            # Update rsync commands for normal backups
            if ! rsync -azv --delete --progress -e "ssh -i '$SSH_KEY' -p '$SSH_PORT'" "$source_path" "${SSH_USER}@$target_ip:${BACKUP_ROOT}/"; then
                echo "ERROR: Backup failed"
                ssh -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@$target_ip" "echo 'ERROR: Backup failed at \$(date)' >> \"$log_file\""
                return 1
            else
                echo "Backup completed successfully"
                ssh -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@$target_ip" "echo 'SUCCESS: Backup completed at \$(date)' >> \"$log_file\""
            fi
        fi
    fi

    echo "Verifying backup..."
    # Check for correct file based on encryption
    local verify_file
    if [ "$ENCRYPTION_ENABLED" -eq 1 ]; then
        verify_file="${BACKUP_ROOT}/$(basename "$source_path").gpg"
    else
        verify_file="${BACKUP_ROOT}/$(basename "$source_path")"
    fi
    
    if ! ssh -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@$target_ip" "ls -la \"$verify_file\"" &>/dev/null; then
        echo "WARNING: Backup verification failed"
        ssh -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@$target_ip" "echo 'WARNING: Backup verification failed' >> \"$log_file\""
    else 
        echo "Backup verification successful"
        ssh -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@$target_ip" "echo 'Backup verification successful' >> \"$log_file\""
    fi

    # Log file sizes and summary
    ssh -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@$target_ip" "echo '===== Backup summary =====' >> \"$log_file\" && \
        du -sh \"$verify_file\" >> \"$log_file\" && \
        echo '===== End of backup log =====' >> \"$log_file\""

    # Clean up old log files
    ssh -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@$target_ip" "find \"$LOG_DIR\" -name \"backup_*.log\" -type f -mtime +${RETENTION_DAYS} -delete"
}

restore() {
    local backup_path="$1"
    local target_path="$2"
    local timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
    local log_file="${LOG_DIR}/restore_${timestamp}.log"

    # Check arguments
    if [ -z "$backup_path" ] || [ -z "$target_path" ]; then
        echo "ERROR: Both source backup path and destination path are required"
        echo "Usage: restore <backup_path> <destination_path>"
        return 1
    fi

    # Check if JSON configuration exists
    if [ ! -f "$CONFIG_FILE" ]; then
        error "Server ip list not found at $CONFIG_FILE"
        return 1
    fi

    # Create target directory if it doesn't exist
    if [ ! -d "$target_path" ]; then
        echo "Creating target directory: $target_path"
        mkdir -p "$target_path" || {
            echo "ERROR: Cannot create target directory"
            return 1
        }
    fi

    # Load possible server IPs and MAC addresses
    local possible_ips=()
    declare -A ip_to_mac
    local common_mac=""

    if command -v jq &>/dev/null; then
        common_mac=$(jq -r '.network.common_mac // ""' "$CONFIG_FILE")
        while read -r line; do
            ip=$(echo "$line" | cut -d' ' -f1)
            mac=$(echo "$line" | cut -d' ' -f2)
            possible_ips+=("$ip")
            if [ -n "$mac" ]; then
                ip_to_mac["$ip"]="$mac"
            else
                ip_to_mac["$ip"]="$common_mac"
            fi
        done < <(jq -r '.server_ips[] | "\(.ip) \(.mac // "")"' "$CONFIG_FILE")
    else
        common_mac=$(python3 -c "import json,sys; data=json.load(open('$CONFIG_FILE')); print(data.get('network', {}).get('common_mac', ''))")
        while read -r line; do
            ip=$(echo "$line" | cut -d' ' -f1)
            mac=$(echo "$line" | cut -d' ' -f2)
            possible_ips+=("$ip")
            if [ -n "$mac" ]; then
                ip_to_mac["$ip"]="$mac"
            else
                ip_to_mac["$ip"]="$common_mac"
            fi
        done < <(python3 -c "import json,sys; data=json.load(open('$CONFIG_FILE')); print('\n'.join([s['ip'] + ' ' + s.get('mac', '') for s in data['server_ips']]))")
    fi

    # Handle manual IP or ID selection
    if [ -n "$MANUAL_IP" ]; then
        echo "Using manually specified IP: $MANUAL_IP"
        target_ip="$MANUAL_IP"
        # Assign the common MAC to this IP if not already known
        if [ -z "${ip_to_mac[$target_ip]}" ]; then
            ip_to_mac["$target_ip"]="$common_mac"
        fi
    elif [ -n "$SERVER_ID" ]; then
        target_ip=$(get_server_by_id "$CONFIG_FILE" "$SERVER_ID")
        if [ $? -ne 0 ] || [ -z "$target_ip" ]; then
            echo "ERROR: Failed to get server by ID $SERVER_ID"
            return 1
        fi
        echo "Using server ID $SERVER_ID, IP: $target_ip"
    else
        # Normal server discovery logic
        local target_ip=""
        echo "Searching for backup server..."
        for ip in "${possible_ips[@]}"; do
            echo "Trying $ip..."
            if ! ping -c $PING_TIMEOUT -W $PING_TIMEOUT "$ip" &>/dev/null; then
                if [[ -n "${ip_to_mac[$ip]}" ]]; then
                    echo "Server not responding. Attempting to wake it..."
                    wake_server "${ip_to_mac[$ip]}" "$ip"
                fi
            fi
            # Update server discovery check in backup() function
            if timeout $SSH_TIMEOUT ssh -i "$SSH_KEY" -p "$SSH_PORT" -o ConnectTimeout=$SSH_TIMEOUT -o StrictHostKeyChecking=no "${SSH_USER}@$ip" "hostname" &>/dev/null; then
                target_ip="$ip"
                echo "Found backup server at $target_ip"
                break
            fi
        done
    fi
    
    # Check if we found a server
    if [ -z "$target_ip" ]; then
        echo "ERROR: Could not find active backup server. Restore aborted."
        return 1
    fi

    # Create log directory if it doesn't exist
    ssh -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@$target_ip" "mkdir -p $LOG_DIR || sudo mkdir -p $LOG_DIR"

    # Check if the backup exists
    echo "Verifying backup exists..."
    local backup_full_path="${BACKUP_ROOT}/$backup_path"
    if ! ssh -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@$target_ip" "test -e '$backup_full_path'"; then
        echo "ERROR: Backup '$backup_path' not found on server"
        return 1
    fi

    # Log start of restore
    hostname=$(hostname)
    ssh -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@$target_ip" "echo '===== Restore started at \$(date) =====' > \"$log_file\" && \
        echo 'Source: ${target_ip}:${backup_full_path}' >> \"$log_file\" && \
        echo 'Target: ${hostname}:${target_path}' >> \"$log_file\"" || {
        echo "ERROR: Could not log restore operation on backup server"
    }

    # Perform the restore
    echo "Restoring from server at $target_ip..."
    if [ "$ENCRYPTION_ENABLED" -eq 1 ]; then
        echo "Downloading encrypted backup from server..."
        local temp_dir=$(mktemp -d)
        local encrypted_file="${temp_dir}/$(basename "$backup_path")"
        local server_file_path="$backup_full_path"
        
        # Check if backup_path already ends with .gpg (for previously encrypted files)
        if [[ ! "$backup_path" == *.gpg ]]; then
            server_file_path="${server_file_path}.gpg"
            encrypted_file="${encrypted_file}.gpg"
        fi
        
        echo "Looking for encrypted file: $server_file_path"
        # Download the encrypted file
        if ! rsync -azv --progress -e "ssh -i '$SSH_KEY' -p '$SSH_PORT'" "${SSH_USER}@$target_ip:$server_file_path" "$encrypted_file"; then
            echo "ERROR: Failed to download encrypted backup"
            rm -rf "$temp_dir"
            return 1
        fi
        
        echo "Decrypting backup data..."
        # If it's a tar archive (directory backup)
        if [[ "$backup_path" != *.* ]] || [[ "$backup_path" == *.tar.gpg ]]; then
            # Decrypt the tar file
            local tar_file="${temp_dir}/$(basename "$backup_path").tar"
            if ! gpg --batch --yes -d -o "$tar_file" "$encrypted_file"; then
                echo "ERROR: Decryption failed"
                rm -rf "$temp_dir"
                return 1
            fi
            
            # Extract the tar file
            if ! tar -xf "$tar_file" -C "$target_path"; then
                echo "ERROR: Failed to extract archive"
                rm -rf "$temp_dir"
                return 1
            fi
        else
            # For single file, decrypt directly to the target
            local output_filename=$(basename "$backup_path")
            # Remove .gpg extension if present
            output_filename=${output_filename%.gpg}
            
            if ! gpg --batch --yes -d -o "$target_path/$output_filename" "$encrypted_file"; then
                echo "ERROR: Decryption failed"
                rm -rf "$temp_dir"
                return 1
            fi
        fi
        
        # Clean up
        rm -rf "$temp_dir"
        echo "Encrypted restore completed successfully"
    else
        # Original restore command for unencrypted backups
        echo "Restoring from server at $target_ip..."
        # Update rsync commands for normal backups
        if ! rsync -azv --progress -e "ssh -i '$SSH_KEY' -p '$SSH_PORT'" "${SSH_USER}@$target_ip:$backup_full_path" "$target_path"; then
            echo "ERROR: Restore failed"
            ssh -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@$target_ip" "echo 'ERROR: Restore failed at \$(date)' >> \"$log_file\""
            return 1
        else
            echo "Restore completed successfully"
            ssh -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@$target_ip" "echo 'SUCCESS: Restore completed at \$(date)' >> \"$log_file\""
        fi
    fi

    # Verify the restore
    echo "Verifying restore..."
    local verify_path=""
    if [ "$ENCRYPTION_ENABLED" -eq 1 ]; then
        verify_path="$target_path/$(basename "${backup_path%.gpg}")"
    else
        verify_path="$target_path/$(basename "$backup_path")"
    fi

    if [ ! -e "$verify_path" ]; then
        echo "WARNING: Restore verification failed"
        ssh -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@$target_ip" "echo 'WARNING: Restore verification failed' >> \"$log_file\""
    else 
        echo "Restore verification successful"
        ssh -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@$target_ip" "echo 'Restore verification successful' >> \"$log_file\""
    fi

    # Update the log file sizes command to use the correct verify_path
    # First verify log directory exists
    ssh -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@$target_ip" "mkdir -p \$(dirname \"$log_file\")"
    
    # Log the restore summary
    ssh -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@$target_ip" "echo '===== Restore summary =====' >> \"$log_file\""
    ssh -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@$target_ip" "echo 'Local size:' >> \"$log_file\""
    
    # Get the local size and send to log
    if [ -e "$verify_path" ]; then
        local size_output=$(du -sh "$verify_path" 2>/dev/null)
        if [ -n "$size_output" ]; then
            ssh -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@$target_ip" "echo '$size_output' >> \"$log_file\""
        else
            ssh -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@$target_ip" "echo 'Unable to determine size' >> \"$log_file\""
        fi
    else
        ssh -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@$target_ip" "echo 'File not found' >> \"$log_file\""
    fi
    
    # Complete the log
    ssh -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@$target_ip" "echo '===== End of restore log =====' >> \"$log_file\""
}

# Add this new function to get server IP by ID
get_server_by_id() {
    local json_file="$1"
    local id="$2"
    local ip=""
    
    if [ ! -f "$json_file" ]; then
        echo "ERROR: Server IP list not found at $json_file"
        return 1
    fi
    
    if command -v jq &>/dev/null; then
        # Count total entries to validate ID
        local num_entries=$(jq '.server_ips | length' "$json_file")
        if [ "$id" -lt 1 ] || [ "$id" -gt "$num_entries" ]; then
            echo "ERROR: Server ID must be between 1 and $num_entries"
            return 1
        fi
        
        # Get the IP by ID (jq is 0-indexed, so subtract 1)
        ip=$(jq -r ".server_ips[$(($id-1))].ip" "$json_file")
    else
        # Using Python as fallback
        ip=$(python3 -c "
import json, sys
try:
    with open('$json_file', 'r') as f:
        data = json.load(f)
    if $id < 1 or $id > len(data['server_ips']):
        print('ERROR: Server ID must be between 1 and ' + str(len(data['server_ips'])))
        sys.exit(1)
    ip = data['server_ips'][$id-1]['ip']
    print(ip)
except Exception as e:
    print('ERROR: ' + str(e))
    sys.exit(1)
")
    fi
    
    # Check if IP was found
    if [ -z "$ip" ]; then
        echo "ERROR: No IP found for server ID $id"
        return 1
    fi
    
    echo "$ip"
    return 0
}

# Add this new function to list servers
list_servers() {
        # Use the global CONFIG_FILE variable instead of hardcoding
        
        if [ ! -f "$CONFIG_FILE" ]; then
            echo "ERROR: Server IP list not found at $CONFIG_FILE"
            return 1
        fi
        
        echo "Available backup servers:"
        echo "------------------------"
        
        if command -v jq &>/dev/null; then
            local counter=1
            while read -r line; do
                ip=$(echo "$line" | cut -d'|' -f1)
                desc=$(echo "$line" | cut -d'|' -f2)
                echo "  $counter) $ip - $desc"
                ((counter++))
            done < <(jq -r '.server_ips[] | "\(.ip)|\(.desc)"' "$CONFIG_FILE")
        else
            local counter=1
            while read -r line; do
                ip=$(echo "$line" | cut -d'|' -f1)
                desc=$(echo "$line" | cut -d'|' -f2)
                echo "  $counter) $ip - $desc"
                ((counter++))
            done < <(python3 -c "import json,sys; data=json.load(open('$CONFIG_FILE')); print('\n'.join([s['ip'] + '|' + s.get('desc', '') for s in data['server_ips']]))")
        fi
}

# Add this new function for handling scheduled backups
setup_scheduled_backup() {
    local source_path="$1"
    local interval="$2"
    local time="$3"
    local options="$4"
    local cron_file="/tmp/backup_cron.$$"
    
    # Validate time format (HH:MM)
    if ! [[ "$time" =~ ^([0-1][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        error "Invalid time format. Please use HH:MM (24-hour format)"
        return 1
    fi
    
    # Extract hour and minute
    local hour="${time%%:*}"
    local minute="${time##*:}"
    
    # Create cron expression based on interval
    local cron_expr=""
    case "$interval" in
        daily)
            cron_expr="$minute $hour * * *"
            ;;
        weekly)
            cron_expr="$minute $hour * * 0"  # Sunday
            ;;
        monthly)
            cron_expr="$minute $hour 1 * *"  # 1st of month
            ;;
        *)
            # Custom interval should be a valid cron expression
            if [[ "$interval" =~ ^[0-9*,-/]+( [0-9*,-/]+){4}$ ]]; then
                cron_expr="$interval"
            else
                error "Invalid interval. Use 'daily', 'weekly', 'monthly', or a valid cron expression"
                return 1
            fi
            ;;
    esac
    
    # Absolute path to script
    local script_path=$(readlink -f "$0")
    
    # Get existing crontab
    crontab -l > "$cron_file" 2>/dev/null || echo "" > "$cron_file"
    
    # Add our new scheduled backup
    echo "# BACKUP_JOB_ID:$(date +%s) - $interval backup of $source_path" >> "$cron_file"
    echo "$cron_expr $script_path $options \"$source_path\" # Managed by gback.sh" >> "$cron_file"
    
    # Install new crontab
    if crontab "$cron_file"; then
        success "Scheduled backup created: $interval at $time"
        success "Command: $script_path $options \"$source_path\""
        
        # Clean up
        rm -f "$cron_file"
        return 0
    else
        error "Failed to create scheduled backup"
        rm -f "$cron_file"
        return 1
    fi
}

# Function to list scheduled backups
list_scheduled_backups() {
    local cron_file="/tmp/backup_cron.$$"
    
    # Get existing crontab
    crontab -l > "$cron_file" 2>/dev/null || echo "" > "$cron_file"
    
    headline "SCHEDULED BACKUPS"
    
    # Check if there are any backup jobs
    if ! grep -q "# BACKUP_JOB_ID:" "$cron_file"; then
        echo "No scheduled backups found."
        rm -f "$cron_file"
        return 0
    fi
    
    echo -e "ID\tSCHEDULE\t\tSOURCE PATH"
    echo "-----------------------------------------------------------"
    
    # Parse and display backup jobs
    while IFS= read -r line; do
        if [[ "$line" =~ ^#\ BACKUP_JOB_ID:([0-9]+)\ -\ (.*)$ ]]; then
            local job_id="${BASH_REMATCH[1]}"
            local description="${BASH_REMATCH[2]}"
            
            # Read the next line which contains the actual cron job
            read -r cron_line
            
            # Extract cron schedule
            local schedule=$(echo "$cron_line" | awk '{print $1, $2, $3, $4, $5}')
            
            # Human-readable schedule
            local human_schedule=""
            if [[ "$schedule" =~ ^[0-9]+\ [0-9]+\ \*\ \*\ \*$ ]]; then
                human_schedule="Daily"
            elif [[ "$schedule" =~ ^[0-9]+\ [0-9]+\ \*\ \*\ 0$ ]]; then
                human_schedule="Weekly"
            elif [[ "$schedule" =~ ^[0-9]+\ [0-9]+\ 1\ \*\ \*$ ]]; then
                human_schedule="Monthly"
            else
                human_schedule="Custom"
            fi
            
            echo -e "$job_id\t$human_schedule ($schedule)\t$description"
        fi
    done < "$cron_file"
    
    rm -f "$cron_file"
}

# Function to remove a scheduled backup
remove_scheduled_backup() {
    local job_id="$1"
    local cron_file="/tmp/backup_cron.$$"
    local new_cron_file="/tmp/backup_cron_new.$$"
    
    # Get existing crontab
    crontab -l > "$cron_file" 2>/dev/null || echo "" > "$cron_file"
    
    # Check if job exists
    if ! grep -q "# BACKUP_JOB_ID:$job_id" "$cron_file"; then
        error "No scheduled backup with ID $job_id found."
        rm -f "$cron_file"
        return 1
    fi
    
    # Remove the backup job and its command
    awk -v id="$job_id" '
    BEGIN { skip = 0; }
    /^# BACKUP_JOB_ID:'"$job_id"' / { skip = 1; next; }
    { if (!skip) print; else skip = 0; }
    ' "$cron_file" > "$new_cron_file"
    
    # Install new crontab
    if crontab "$new_cron_file"; then
        success "Scheduled backup with ID $job_id removed."
        rm -f "$cron_file" "$new_cron_file"
        return 0
    else
        error "Failed to remove scheduled backup"
        rm -f "$cron_file" "$new_cron_file"
        return 1
    fi
}

# Default modes
RESTORE_MODE=0

# Parse command line arguments using getopts
if [[ "$1" == "--help" ]]; then
    show_help
fi

while getopts "hdri:m:lek:IcPS:-:t:" opt; do
    case ${opt} in
        d )
            DEBUG=1
            echo "Debug mode enabled"
            ;;
        r )
            RESTORE_MODE=1
            echo "Restore mode enabled"
            ;;
        i )
            SERVER_ID="$OPTARG"
            echo "Server ID selection mode enabled, using ID: $SERVER_ID"
            ;;
        m )
            MANUAL_IP="$OPTARG"
            echo "Manual IP mode enabled, using IP: $MANUAL_IP"
            ;;
        l )
            list_servers
            exit 0
            ;;
        e )
            ENCRYPTION_ENABLED=1
            echo "Encryption enabled"
            ;;
        k )
            GPG_RECIPIENT="$OPTARG"
            echo "Using GPG recipient: $GPG_RECIPIENT"
            ;;
        I )
            INCREMENTAL=1
            info "Incremental backup mode enabled"
            ;;
        c )
            USE_COLORS=0
            # Don't use color to say colors are disabled!
            echo "Colored output disabled"
            ;;
        P )
            SHOW_PROGRESS=0
            echo "Progress display disabled"
            ;;
        S )
            SCHEDULE_MODE=1
            SCHEDULE_INTERVAL="$OPTARG"
            info "Schedule mode enabled with interval: $SCHEDULE_INTERVAL"
            ;;
        t )
            SCHEDULE_TIME="$OPTARG"
            ;;
        - )
            case "${OPTARG}" in
                help)
                    show_help
                    ;;
                schedule=*)
                    SCHEDULE_MODE=1
                    SCHEDULE_INTERVAL="${OPTARG#*=}"
                    info "Schedule mode enabled with interval: $SCHEDULE_INTERVAL"
                    ;;
                time=*)
                    SCHEDULE_TIME="${OPTARG#*=}"
                    ;;
                list-schedules)
                    SCHEDULE_LIST=1
                    ;;
                remove-schedule=*)
                    SCHEDULE_REMOVE="${OPTARG#*=}"
                    ;;
                *)
                    error "Invalid option: --${OPTARG}"
                    echo "Usage: $0 [-d] [-r] [-i ID] [-m IP] [-l] [-e] [-k KEY_ID] [-S INTERVAL] [-t TIME] /path/to/source [/path/to/destination]"
                    exit 1
                    ;;
            esac
            ;;
        h )
            show_help
            ;;
        \? )
            echo "Invalid option: $OPTARG" 1>&2
            echo "Usage: $0 [-d] [-r] [-i ID] [-m IP] [-l] [-e] [-k KEY_ID] /path/to/source [/path/to/destination]" 1>&2
            echo "  -l: List available servers with their IDs" 1>&2
            echo "  -e: Enable encryption" 1>&2
            echo "  -k: Specify GPG recipient (email or key ID)" 1>&2
            exit 1
            ;;
    esac
done
shift $((OPTIND -1))  # Remove processed options

# Check args based on mode
if [ "$RESTORE_MODE" -eq 1 ]; then
    # Restore mode requires two paths
    if [ $# -ne 2 ]; then
        echo "Error: Restore mode requires source and destination paths"
        echo "Usage: $0 [-d] [-r] [-i ID] [-m IP] [-l] <backup_path> <destination_path>"
        exit 1
    fi
else
    # Backup mode requires one path
    if [ $# -ne 1 ]; then
        echo "Error: Missing source path for backup"
        echo "Usage: $0 [-d] [-i ID] [-m IP] [-l] <source_path>"
        exit 1
    fi
fi

# Validate encryption settings
if [ "$ENCRYPTION_ENABLED" -eq 1 ] && [ -z "$GPG_RECIPIENT" ]; then
    error "Encryption enabled but no GPG recipient specified. Use -k option or set default_recipient in config."
    exit 1
fi

# Execute based on mode
if [ "$RESTORE_MODE" -eq 1 ]; then
    # Restore mode requires two paths
    if [ $# -ne 2 ]; then
        echo "Error: Restore mode requires source and destination paths"
        echo "Usage: $0 [-d] [-r] [-i ID] [-m IP] [-l] <backup_path> <destination_path>"
        exit 1
    fi
    
    backup_path="$1"
    target_path="$2"
    
    # Call restore function
    debug "Restoring from '$backup_path' to '$target_path'"
    restore "$backup_path" "$target_path"
else
    # Backup mode requires one path
    if [ $# -ne 1 ]; then
        echo "Error: Missing source path for backup"
        echo "Usage: $0 [-d] [-i ID] [-m IP] [-l] <source_path>"
        exit 1
    fi
    
    source_path="$1"
    
    # Handle relative paths
    if [[ ! "$source_path" = /* ]]; then
        debug "Converting to absolute path..."
        source_path="$(readlink -f "$source_path")"
    else
        debug "Using absolute path: $source_path"
    fi
    
    debug "Using path: $source_path"
    backup "$source_path"
fi

# Handle scheduling options
if [ "$SCHEDULE_LIST" -eq 1 ]; then
    list_scheduled_backups
    exit 0
fi

if [ -n "$SCHEDULE_REMOVE" ]; then
    remove_scheduled_backup "$SCHEDULE_REMOVE"
    exit $?
fi

if [ "$SCHEDULE_MODE" -eq 1 ]; then
    # Validate required parameters
    if [ -z "$SCHEDULE_INTERVAL" ]; then
        error "Schedule interval is required. Use: daily, weekly, monthly, or custom cron expression"
        exit 1
    fi
    
    if [ -z "$SCHEDULE_TIME" ]; then
        SCHEDULE_TIME="02:00"  # Default to 2 AM if not specified
        info "No time specified, using default: 2:00 AM"
    fi
    
    # Build options string excluding scheduling options themselves
    options=""
    [ "$DEBUG" -eq 1 ] && options+=" -d"
    [ "$RESTORE_MODE" -eq 1 ] && options+=" -r"
    [ -n "$SERVER_ID" ] && options+=" -i $SERVER_ID"
    [ -n "$MANUAL_IP" ] && options+=" -m $MANUAL_IP"
    [ "$ENCRYPTION_ENABLED" -eq 1 ] && options+=" -e"
    [ -n "$GPG_RECIPIENT" ] && options+=" -k $GPG_RECIPIENT"
    [ "$INCREMENTAL" -eq 1 ] && options+=" -I"
    [ "$USE_COLORS" -eq 0 ] && options+=" -c"
    [ "$SHOW_PROGRESS" -eq 0 ] && options+=" -P"
    
    # Create scheduled job
    if [ "$RESTORE_MODE" -eq 1 ]; then
        error "Cannot schedule restore operations"
        exit 1
    else
        setup_scheduled_backup "$1" "$SCHEDULE_INTERVAL" "$SCHEDULE_TIME" "$options"
        exit $?
    fi
fi