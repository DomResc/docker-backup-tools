#!/bin/bash
# Docker Volume Tools - Installation script for Docker full backup with Borg
# https://github.com/domresc/docker-volume-tools
#
# MIT License
#
# Copyright (c) 2025 Domenico Rescigno
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# Color definitions
COLOR_RESET="\033[0m"
COLOR_RED="\033[0;31m"
COLOR_GREEN="\033[0;32m"
COLOR_YELLOW="\033[0;33m"
COLOR_BLUE="\033[0;34m"
COLOR_MAGENTA="\033[0;35m"
COLOR_CYAN="\033[0;36m"
COLOR_WHITE="\033[0;37m"
COLOR_BOLD="\033[1m"

# Destination directories
INSTALL_DIR="/usr/local/bin"
DEFAULT_BACKUP_DIR="/backup/docker"
DEFAULT_LOG_DIR="/var/log/docker"
BACKUP_DIR=""
LOG_DIR=""
SCRIPT_NAMES=("docker_backup_full.sh" "docker_restore_full.sh" "docker_verify.sh" "docker_cleanup.sh")
ENCRYPTION="none"
CRON_ENABLED=false
CUSTOM_LOCATION=false

# Function to display usage information
usage() {
    echo -e "${COLOR_CYAN}Usage: $0 [OPTIONS]${COLOR_RESET}"
    echo -e "${COLOR_CYAN}Install Docker Volume Tools for backup and restore${COLOR_RESET}"
    echo ""
    echo -e "${COLOR_CYAN}Options:${COLOR_RESET}"
    echo -e "  ${COLOR_GREEN}-b, --backup-dir DIR${COLOR_RESET}  Custom backup directory (default: $DEFAULT_BACKUP_DIR)"
    echo -e "  ${COLOR_GREEN}-l, --log-dir DIR${COLOR_RESET}     Custom log directory (default: $DEFAULT_LOG_DIR)"
    echo -e "  ${COLOR_GREEN}-e, --encryption TYPE${COLOR_RESET} Repository encryption (none, repokey, keyfile; default: none)"
    echo -e "  ${COLOR_GREEN}-c, --cron${COLOR_RESET}            Set up automatic backup cron job"
    echo -e "  ${COLOR_GREEN}-C, --cron-time EXPR${COLOR_RESET}  Custom cron time expression (e.g. '0 2 * * *')"
    echo -e "  ${COLOR_GREEN}-f, --force${COLOR_RESET}           Don't ask for confirmation"
    echo -e "  ${COLOR_GREEN}-i, --install-dir DIR${COLOR_RESET} Custom installation directory (default: $INSTALL_DIR)"
    echo -e "  ${COLOR_GREEN}-h, --help${COLOR_RESET}            Display this help message"
    exit 1
}

# Parse command line options
FORCE=false
CRON_TIME=""

while [[ $# -gt 0 ]]; do
    case $1 in
    -b | --backup-dir)
        BACKUP_DIR="$2"
        shift 2
        ;;
    -l | --log-dir)
        LOG_DIR="$2"
        shift 2
        ;;
    -e | --encryption)
        ENCRYPTION="$2"
        if ! [[ "$ENCRYPTION" =~ ^(none|repokey|keyfile)$ ]]; then
            echo -e "${COLOR_RED}ERROR: Encryption must be one of: none, repokey, keyfile${COLOR_RESET}"
            exit 1
        fi
        shift 2
        ;;
    -c | --cron)
        CRON_ENABLED=true
        shift
        ;;
    -C | --cron-time)
        CRON_TIME="$2"
        CRON_ENABLED=true
        shift 2
        ;;
    -f | --force)
        FORCE=true
        shift
        ;;
    -i | --install-dir)
        INSTALL_DIR="$2"
        CUSTOM_LOCATION=true
        shift 2
        ;;
    -h | --help)
        usage
        ;;
    *)
        echo -e "${COLOR_RED}Unknown option: $1${COLOR_RESET}"
        usage
        ;;
    esac
done

# Check if script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${COLOR_RED}ERROR: This script must be run as root${COLOR_RESET}"
    echo "Please run with sudo or as root user"
    exit 1
fi

# Set default values if not specified
if [ -z "$BACKUP_DIR" ]; then
    BACKUP_DIR="$DEFAULT_BACKUP_DIR"
fi

if [ -z "$LOG_DIR" ]; then
    LOG_DIR="$DEFAULT_LOG_DIR"
fi

# Function to get user confirmation
confirm_action() {
    local message="$1"

    if [ "$FORCE" = true ]; then
        return 0
    fi

    read -p "$(echo -e "${COLOR_YELLOW}$message (y/n): ${COLOR_RESET}")" confirm
    if [ "$confirm" = "y" ]; then
        return 0
    else
        return 1
    fi
}

# Function to check cron time format
validate_cron_time() {
    local cron_expr="$1"

    if [ -z "$cron_expr" ]; then
        return 1
    fi

    # Basic validation for cron format (5 fields)
    if ! [[ "$cron_expr" =~ ^[0-9*,-/]+[[:space:]][0-9*,-/]+[[:space:]][0-9*,-/]+[[:space:]][0-9*,-/]+[[:space:]][0-9*,-/]+$ ]]; then
        echo -e "${COLOR_RED}ERROR: Invalid cron expression format. Should be like '0 2 * * *'${COLOR_RESET}"
        return 1
    fi

    return 0
}

# Function to check command existence
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Display header
echo -e "${COLOR_CYAN}${COLOR_BOLD}"
echo "======================================================="
echo "        Docker Volume Tools - Installer"
echo "======================================================="
echo -e "${COLOR_RESET}"

# Check Docker installation
echo -e "${COLOR_BLUE}Checking Docker installation...${COLOR_RESET}"
if ! command_exists docker; then
    echo -e "${COLOR_YELLOW}WARNING: Docker does not appear to be installed on this system.${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}These tools require Docker to be installed and working properly.${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}Please install Docker before using Docker Volume Tools.${COLOR_RESET}"

    if ! confirm_action "Continue installation anyway?"; then
        echo -e "${COLOR_RED}Installation canceled.${COLOR_RESET}"
        exit 1
    fi

    echo -e "${COLOR_YELLOW}Continuing installation without Docker. Make sure to install Docker later.${COLOR_RESET}"
else
    echo -e "${COLOR_GREEN}Docker is installed.${COLOR_RESET}"
    echo -e "${COLOR_BLUE}Docker version: $(docker --version)${COLOR_RESET}"

    # Test Docker functionality
    if ! docker info >/dev/null 2>&1; then
        echo -e "${COLOR_YELLOW}WARNING: Docker service doesn't seem to be running or accessible.${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}Make sure the Docker daemon is running and you have proper permissions.${COLOR_RESET}"

        if ! confirm_action "Continue installation anyway?"; then
            echo -e "${COLOR_RED}Installation canceled.${COLOR_RESET}"
            exit 1
        fi
    fi
fi

# Detect the init system
echo -e "${COLOR_BLUE}Detecting init system...${COLOR_RESET}"
if command_exists systemctl && systemctl --version >/dev/null 2>&1; then
    echo -e "${COLOR_GREEN}Detected init system: systemd${COLOR_RESET}"
    INIT_SYSTEM="systemd"
elif command_exists service; then
    echo -e "${COLOR_GREEN}Detected init system: sysvinit/upstart${COLOR_RESET}"
    INIT_SYSTEM="sysv"
elif [ -f /etc/init.d/docker ]; then
    echo -e "${COLOR_GREEN}Detected init system: sysvinit${COLOR_RESET}"
    INIT_SYSTEM="sysv"
else
    echo -e "${COLOR_YELLOW}Could not detect init system. Will use fallback mechanisms for Docker service control.${COLOR_RESET}"
    INIT_SYSTEM="unknown"
fi

# Check if borg is installed
echo -e "${COLOR_BLUE}Checking for Borg Backup...${COLOR_RESET}"
if ! command_exists borg; then
    echo -e "${COLOR_YELLOW}Borg Backup is not installed. Installing...${COLOR_RESET}"

    # Detect OS and install Borg
    if command_exists apt-get; then
        echo -e "${COLOR_BLUE}Debian/Ubuntu detected. Installing Borg using apt-get...${COLOR_RESET}"
        apt-get update
        apt-get install -y borgbackup
    elif command_exists yum; then
        echo -e "${COLOR_BLUE}CentOS/RHEL detected. Installing Borg using yum...${COLOR_RESET}"
        yum install -y epel-release
        yum install -y borgbackup
    elif command_exists dnf; then
        echo -e "${COLOR_BLUE}Fedora detected. Installing Borg using dnf...${COLOR_RESET}"
        dnf install -y borgbackup
    elif command_exists apk; then
        echo -e "${COLOR_BLUE}Alpine detected. Installing Borg using apk...${COLOR_RESET}"
        apk add borgbackup
    else
        echo -e "${COLOR_RED}Unable to detect package manager.${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}Please install Borg manually: https://borgbackup.org/install.html${COLOR_RESET}"

        if ! confirm_action "Continue installation without Borg?"; then
            echo -e "${COLOR_RED}Installation canceled.${COLOR_RESET}"
            exit 1
        fi

        echo -e "${COLOR_YELLOW}Continuing installation without Borg. You'll need to install it manually later.${COLOR_RESET}"
    fi

    # Check if installation was successful
    if ! command_exists borg; then
        echo -e "${COLOR_RED}Failed to install Borg automatically.${COLOR_RESET}"
        if ! confirm_action "Continue installation without Borg?"; then
            echo -e "${COLOR_RED}Installation canceled.${COLOR_RESET}"
            exit 1
        fi
        echo -e "${COLOR_YELLOW}Continuing installation without Borg. You'll need to install it manually later.${COLOR_RESET}"
    else
        echo -e "${COLOR_GREEN}Borg installed successfully!${COLOR_RESET}"
    fi
else
    echo -e "${COLOR_GREEN}Borg Backup is already installed.${COLOR_RESET}"
    echo -e "${COLOR_BLUE}Borg version: $(borg --version)${COLOR_RESET}"
fi

# Check jq for JSON handling (optional but recommended)
echo -e "${COLOR_BLUE}Checking for jq (JSON processor)...${COLOR_RESET}"
if ! command_exists jq; then
    echo -e "${COLOR_YELLOW}jq is not installed. Installing...${COLOR_RESET}"

    # Detect OS and install jq
    if command_exists apt-get; then
        apt-get update
        apt-get install -y jq
    elif command_exists yum; then
        yum install -y jq
    elif command_exists dnf; then
        dnf install -y jq
    elif command_exists apk; then
        apk add jq
    else
        echo -e "${COLOR_YELLOW}Cannot automatically install jq. JSON output parsing may be limited.${COLOR_RESET}"
    fi

    if command_exists jq; then
        echo -e "${COLOR_GREEN}jq installed successfully!${COLOR_RESET}"
    else
        echo -e "${COLOR_YELLOW}jq installation failed. This is not critical but may limit some functionality.${COLOR_RESET}"
    fi
else
    echo -e "${COLOR_GREEN}jq is already installed.${COLOR_RESET}"
    echo -e "${COLOR_BLUE}jq version: $(jq --version)${COLOR_RESET}"
fi

# Create directories
echo -e "${COLOR_BLUE}Creating directories...${COLOR_RESET}"

mkdir -p "$BACKUP_DIR"
mkdir -p "$LOG_DIR"

# Set permissions
chown root:root "$BACKUP_DIR"
chmod 750 "$BACKUP_DIR"
chown root:root "$LOG_DIR"
chmod 750 "$LOG_DIR"

echo -e "${COLOR_GREEN}Directories created and permissions set.${COLOR_RESET}"

# Check if scripts are in the current directory
echo -e "${COLOR_BLUE}Checking for scripts...${COLOR_RESET}"

missing_scripts=false
for script in "${SCRIPT_NAMES[@]}"; do
    if [ ! -f "./$script" ]; then
        echo -e "${COLOR_RED}Script not found: $script${COLOR_RESET}"
        missing_scripts=true
    fi
done

if [ "$missing_scripts" = true ]; then
    echo -e "${COLOR_RED}One or more scripts are missing from the current directory.${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}Please make sure all required scripts are in the current directory:${COLOR_RESET}"
    for script in "${SCRIPT_NAMES[@]}"; do
        echo "  - $script"
    done
    exit 1
fi

# Install scripts
echo -e "${COLOR_BLUE}Installing scripts to $INSTALL_DIR...${COLOR_RESET}"

# Make sure install directory exists
if [ ! -d "$INSTALL_DIR" ]; then
    mkdir -p "$INSTALL_DIR"
    if [ $? -ne 0 ]; then
        echo -e "${COLOR_RED}ERROR: Failed to create installation directory $INSTALL_DIR${COLOR_RESET}"
        exit 1
    fi
fi

for script in "${SCRIPT_NAMES[@]}"; do
    base_name=$(basename "$script" .sh)

    # Check if script already exists and is different
    if [ -f "$INSTALL_DIR/$base_name" ]; then
        if ! cmp -s "./$script" "$INSTALL_DIR/$base_name"; then
            echo -e "${COLOR_YELLOW}Script $base_name already exists but is different.${COLOR_RESET}"
            if [ "$FORCE" != true ] && ! confirm_action "Overwrite existing script?"; then
                echo -e "${COLOR_YELLOW}Skipping $base_name installation.${COLOR_RESET}"
                continue
            fi
        else
            echo -e "${COLOR_BLUE}Script $base_name already installed and is identical.${COLOR_RESET}"
        fi
    fi

    cp "./$script" "$INSTALL_DIR/$base_name"
    chmod +x "$INSTALL_DIR/$base_name"
    echo -e "${COLOR_GREEN}Installed: $INSTALL_DIR/$base_name${COLOR_RESET}"
done

# Also install the install script itself
cp "./docker_install.sh" "$INSTALL_DIR/docker_install"
chmod +x "$INSTALL_DIR/docker_install"
echo -e "${COLOR_GREEN}Installed: $INSTALL_DIR/docker_install${COLOR_RESET}"

# Create configuration file with default settings
CONFIG_DIR="/etc/docker-volume-tools"
CONFIG_FILE="$CONFIG_DIR/config"

echo -e "${COLOR_BLUE}Creating configuration file...${COLOR_RESET}"

mkdir -p "$CONFIG_DIR"
if [ ! -f "$CONFIG_FILE" ] || [ "$FORCE" = true ]; then
    cat >"$CONFIG_FILE" <<EOF
# Docker Volume Tools configuration
# Created: $(date)

# Backup directory
DOCKER_BACKUP_DIR="$BACKUP_DIR"

# Log directory
DOCKER_LOG_DIR="$LOG_DIR"

# Default encryption
DOCKER_ENCRYPTION="$ENCRYPTION"

# Default retention days (30 days)
DOCKER_RETENTION_DAYS="30"

# Default compression (lz4)
DOCKER_COMPRESSION="lz4"
EOF
    echo -e "${COLOR_GREEN}Configuration file created: $CONFIG_FILE${COLOR_RESET}"
else
    echo -e "${COLOR_YELLOW}Configuration file already exists. Updating...${COLOR_RESET}"

    # Update only specific values
    sed -i "s|^DOCKER_BACKUP_DIR=.*|DOCKER_BACKUP_DIR=\"$BACKUP_DIR\"|" "$CONFIG_FILE"
    sed -i "s|^DOCKER_LOG_DIR=.*|DOCKER_LOG_DIR=\"$LOG_DIR\"|" "$CONFIG_FILE"
    sed -i "s|^DOCKER_ENCRYPTION=.*|DOCKER_ENCRYPTION=\"$ENCRYPTION\"|" "$CONFIG_FILE"

    echo -e "${COLOR_GREEN}Configuration file updated: $CONFIG_FILE${COLOR_RESET}"
fi

chmod 640 "$CONFIG_FILE"

# Setup shell profiles to load settings
PROFILE_SCRIPT="/etc/profile.d/docker-volume-tools.sh"

cat >"$PROFILE_SCRIPT" <<EOF
# Docker Volume Tools environment variables
# Source configuration
if [ -f "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE"
    export DOCKER_BACKUP_DIR
    export DOCKER_LOG_DIR
    export DOCKER_ENCRYPTION
    export DOCKER_RETENTION_DAYS
    export DOCKER_COMPRESSION
fi
EOF

chmod 644 "$PROFILE_SCRIPT"
echo -e "${COLOR_GREEN}System-wide environment configuration created: $PROFILE_SCRIPT${COLOR_RESET}"

# Setup cron job for automated backups
if [ "$CRON_ENABLED" = true ]; then
    echo -e "${COLOR_BLUE}Setting up cron job for automated backups...${COLOR_RESET}"

    # If cron time not specified, ask for frequency
    if [ -z "$CRON_TIME" ]; then
        echo -e "${COLOR_BLUE}Choose backup frequency:${COLOR_RESET}"
        echo -e "  ${COLOR_CYAN}1) Daily${COLOR_RESET}"
        echo -e "  ${COLOR_CYAN}2) Weekly${COLOR_RESET}"
        echo -e "  ${COLOR_CYAN}3) Monthly${COLOR_RESET}"
        echo -e "  ${COLOR_CYAN}4) Custom${COLOR_RESET}"

        read -p "$(echo -e "${COLOR_YELLOW}Enter your choice (1-4): ${COLOR_RESET}")" cron_choice

        case $cron_choice in
        1)
            # Daily at 1:00 AM
            CRON_TIME="0 1 * * *"
            cron_desc="daily at 1:00 AM"
            ;;
        2)
            # Weekly on Sunday at 1:00 AM
            CRON_TIME="0 1 * * 0"
            cron_desc="weekly on Sunday at 1:00 AM"
            ;;
        3)
            # Monthly on the 1st at 1:00 AM
            CRON_TIME="0 1 1 * *"
            cron_desc="monthly on the 1st at 1:00 AM"
            ;;
        4)
            # Custom
            echo -e "${COLOR_YELLOW}Enter custom cron schedule (e.g., '0 1 * * *' for daily at 1:00 AM):${COLOR_RESET}"
            read custom_cron
            CRON_TIME="$custom_cron"
            cron_desc="custom schedule: $CRON_TIME"

            # Validate cron time
            if ! validate_cron_time "$CRON_TIME"; then
                echo -e "${COLOR_RED}Invalid cron expression. Using default (daily at 1:00 AM).${COLOR_RESET}"
                CRON_TIME="0 1 * * *"
                cron_desc="daily at 1:00 AM"
            fi
            ;;
        *)
            echo -e "${COLOR_RED}Invalid choice. Using default (daily at 1:00 AM).${COLOR_RESET}"
            CRON_TIME="0 1 * * *"
            cron_desc="daily at 1:00 AM"
            ;;
        esac
    else
        # Validate provided cron time
        if ! validate_cron_time "$CRON_TIME"; then
            echo -e "${COLOR_RED}Invalid cron expression provided. Using default (daily at 1:00 AM).${COLOR_RESET}"
            CRON_TIME="0 1 * * *"
            cron_desc="daily at 1:00 AM"
        else
            cron_desc="custom schedule: $CRON_TIME"
        fi
    fi

    # Create cron job
    CRON_FILE="/etc/cron.d/docker-volume-tools"

    cat >"$CRON_FILE" <<EOF
# Docker Volume Tools automated backup
# Installed on: $(date)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
MAILTO=root

# Run docker backup
$CRON_TIME root $INSTALL_DIR/docker_backup_full --force > $LOG_DIR/cron_backup.log 2>&1
EOF

    chmod 644 "$CRON_FILE"
    echo -e "${COLOR_GREEN}Cron job set up successfully: $cron_desc${COLOR_RESET}"
    echo -e "${COLOR_GREEN}Cron file created: $CRON_FILE${COLOR_RESET}"
else
    echo -e "${COLOR_BLUE}Skipping cron job setup.${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}You can set up automated backups later with:${COLOR_RESET}"
    echo -e "${COLOR_CYAN}sudo docker_install --cron${COLOR_RESET}"
fi

# Initialize Borg repository if Borg is installed
if command_exists borg; then
    echo -e "${COLOR_BLUE}Would you like to initialize a Borg repository now?${COLOR_RESET}"

    if [ "$FORCE" = true ] || confirm_action "Initialize repository at $BACKUP_DIR?"; then
        if ! borg info "$BACKUP_DIR" >/dev/null 2>&1; then
            echo -e "${COLOR_BLUE}Initializing Borg repository at $BACKUP_DIR with encryption: $ENCRYPTION${COLOR_RESET}"

            if [ "$ENCRYPTION" = "none" ]; then
                if borg init --encryption=none "$BACKUP_DIR"; then
                    echo -e "${COLOR_GREEN}Repository initialized successfully!${COLOR_RESET}"
                else
                    echo -e "${COLOR_RED}Failed to initialize repository.${COLOR_RESET}"
                    echo -e "${COLOR_YELLOW}You can initialize it later with: sudo borg init --encryption=none $BACKUP_DIR${COLOR_RESET}"
                fi
            else
                echo -e "${COLOR_YELLOW}You selected encryption type: $ENCRYPTION${COLOR_RESET}"
                echo -e "${COLOR_YELLOW}You will be prompted to create a passphrase for the repository.${COLOR_RESET}"
                echo -e "${COLOR_YELLOW}IMPORTANT: Keep your passphrase safe. If lost, backups cannot be recovered!${COLOR_RESET}"

                if borg init --encryption=$ENCRYPTION "$BACKUP_DIR"; then
                    echo -e "${COLOR_GREEN}Repository initialized successfully with encryption!${COLOR_RESET}"
                    echo -e "${COLOR_YELLOW}REMEMBER YOUR PASSPHRASE! It will be required for all backup and restore operations.${COLOR_RESET}"
                else
                    echo -e "${COLOR_RED}Failed to initialize repository with encryption.${COLOR_RESET}"
                    echo -e "${COLOR_YELLOW}You can initialize it later with: sudo borg init --encryption=$ENCRYPTION $BACKUP_DIR${COLOR_RESET}"
                fi
            fi
        else
            echo -e "${COLOR_GREEN}Repository already exists at $BACKUP_DIR.${COLOR_RESET}"
        fi
    else
        echo -e "${COLOR_BLUE}Skipping repository initialization.${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}You can initialize it later with: sudo borg init --encryption=$ENCRYPTION $BACKUP_DIR${COLOR_RESET}"
    fi
fi

# Create systemd service file if systemd is detected
if [ "$INIT_SYSTEM" = "systemd" ]; then
    echo -e "${COLOR_BLUE}Would you like to create a systemd service for scheduled backups?${COLOR_RESET}"

    if [ "$FORCE" = true ] || confirm_action "Create systemd service and timer?"; then
        # Create service file
        SERVICE_FILE="/etc/systemd/system/docker-volume-backup.service"

        cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=Docker Volume Backup Service
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/docker_backup_full --force
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

        chmod 644 "$SERVICE_FILE"

        # Create timer file
        TIMER_FILE="/etc/systemd/system/docker-volume-backup.timer"

        cat >"$TIMER_FILE" <<EOF
[Unit]
Description=Run Docker Volume Backup Daily

[Timer]
OnCalendar=*-*-* 01:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

        chmod 644 "$TIMER_FILE"

        # Reload systemd and enable timer
        systemctl daemon-reload
        systemctl enable docker-volume-backup.timer
        systemctl start docker-volume-backup.timer

        echo -e "${COLOR_GREEN}Systemd service and timer created and enabled.${COLOR_RESET}"
        echo -e "${COLOR_GREEN}Backup will run daily at 1:00 AM.${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}You can check the timer status with: systemctl status docker-volume-backup.timer${COLOR_RESET}"
    else
        echo -e "${COLOR_BLUE}Skipping systemd service creation.${COLOR_RESET}"
    fi
fi

# Ask if user wants to run a backup now
echo -e "${COLOR_BLUE}Would you like to run a backup now?${COLOR_RESET}"

if [ "$FORCE" = true ] || confirm_action "Run initial backup?"; then
    echo -e "${COLOR_BLUE}Running initial backup...${COLOR_RESET}"
    $INSTALL_DIR/docker_backup_full

    if [ $? -eq 0 ]; then
        echo -e "${COLOR_GREEN}Initial backup completed successfully!${COLOR_RESET}"
    else
        echo -e "${COLOR_RED}Initial backup failed. Please check logs for details.${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}Log file: $LOG_DIR/backup.log${COLOR_RESET}"
    fi
else
    echo -e "${COLOR_BLUE}Skipping initial backup.${COLOR_RESET}"
fi

# Installation completed
echo -e "${COLOR_CYAN}${COLOR_BOLD}"
echo "======================================================="
echo "        Docker Volume Tools - Installation Complete"
echo "======================================================="
echo -e "${COLOR_RESET}"
echo -e "${COLOR_GREEN}${COLOR_BOLD}Installation completed successfully!${COLOR_RESET}"
echo ""
echo -e "${COLOR_BLUE}Available commands:${COLOR_RESET}"
echo -e "  ${COLOR_GREEN}docker_backup_full${COLOR_RESET}    - Backup all Docker data"
echo -e "  ${COLOR_GREEN}docker_restore_full${COLOR_RESET}   - Restore Docker from backup"
echo -e "  ${COLOR_GREEN}docker_verify${COLOR_RESET}         - Verify backup integrity"
echo -e "  ${COLOR_GREEN}docker_cleanup${COLOR_RESET}        - Clean Docker resources and backups"
echo -e "  ${COLOR_GREEN}docker_install${COLOR_RESET}        - Reinstall or update these tools"
echo ""
echo -e "${COLOR_BLUE}Configuration:${COLOR_RESET}"
echo -e "  ${COLOR_CYAN}Backup directory:${COLOR_RESET} $BACKUP_DIR"
echo -e "  ${COLOR_CYAN}Log directory:${COLOR_RESET} $LOG_DIR"
echo -e "  ${COLOR_CYAN}Encryption:${COLOR_RESET} $ENCRYPTION"
echo -e "  ${COLOR_CYAN}Config file:${COLOR_RESET} $CONFIG_FILE"
if [ "$CRON_ENABLED" = true ]; then
    echo -e "  ${COLOR_CYAN}Cron schedule:${COLOR_RESET} $cron_desc"
fi
echo ""
echo -e "${COLOR_YELLOW}Important: All commands must be run with root privileges.${COLOR_RESET}"
echo -e "${COLOR_YELLOW}For example: sudo docker_backup_full${COLOR_RESET}"
echo ""
echo -e "${COLOR_YELLOW}Try running 'sudo docker_backup_full --help' to see all available options.${COLOR_RESET}"

exit 0
