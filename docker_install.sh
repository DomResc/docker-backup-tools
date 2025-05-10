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
BACKUP_DIR="/backup/docker"
LOG_DIR="/var/log/docker"
SCRIPT_NAMES=("docker_backup_full.sh" "docker_restore_full.sh" "docker_verify.sh" "docker_cleanup.sh")

# Detect if Docker is installed
check_docker_installation() {
    if ! command -v docker &>/dev/null; then
        echo -e "${COLOR_YELLOW}WARNING: Docker does not appear to be installed on this system.${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}These tools require Docker to be installed and working properly.${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}Please install Docker before using Docker Volume Tools.${COLOR_RESET}"

        read -p "$(echo -e "${COLOR_YELLOW}Continue installation anyway? (y/n): ${COLOR_RESET}")" continue_anyway
        if [ "$continue_anyway" != "y" ]; then
            echo -e "${COLOR_RED}Installation canceled.${COLOR_RESET}"
            exit 1
        fi

        echo -e "${COLOR_YELLOW}Continuing installation without Docker. Make sure to install Docker later.${COLOR_RESET}"
    else
        echo -e "${COLOR_GREEN}Docker is installed.${COLOR_RESET}"
        echo -e "${COLOR_BLUE}Docker version: $(docker --version)${COLOR_RESET}"
    fi
}

# Detect the init system
detect_init_system() {
    if command -v systemctl &>/dev/null && systemctl --version &>/dev/null; then
        echo -e "${COLOR_GREEN}Detected init system: systemd${COLOR_RESET}"
        INIT_SYSTEM="systemd"
    elif command -v service &>/dev/null; then
        echo -e "${COLOR_GREEN}Detected init system: sysvinit/upstart${COLOR_RESET}"
        INIT_SYSTEM="sysv"
    elif [ -f /etc/init.d/docker ]; then
        echo -e "${COLOR_GREEN}Detected init system: sysvinit${COLOR_RESET}"
        INIT_SYSTEM="sysv"
    else
        echo -e "${COLOR_YELLOW}Could not detect init system. Will use fallback mechanisms for Docker service control.${COLOR_RESET}"
        INIT_SYSTEM="unknown"
    fi
}

# Check if script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${COLOR_RED}ERROR: This script must be run as root${COLOR_RESET}"
    echo "Please run with sudo or as root user"
    exit 1
fi

# Display header
echo -e "${COLOR_CYAN}${COLOR_BOLD}"
echo "======================================================="
echo "        Docker Volume Tools - Installer"
echo "======================================================="
echo -e "${COLOR_RESET}"

# Check Docker installation
check_docker_installation

# Detect init system
detect_init_system

# Check if borg is installed
if ! command -v borg &>/dev/null; then
    echo -e "${COLOR_YELLOW}Borg Backup is not installed. Installing...${COLOR_RESET}"

    # Detect OS and install Borg
    if command -v apt-get &>/dev/null; then
        echo -e "${COLOR_BLUE}Debian/Ubuntu detected. Installing Borg using apt-get...${COLOR_RESET}"
        apt-get update && apt-get install -y borgbackup
    elif command -v yum &>/dev/null; then
        echo -e "${COLOR_BLUE}CentOS/RHEL detected. Installing Borg using yum...${COLOR_RESET}"
        yum install -y borgbackup
    elif command -v dnf &>/dev/null; then
        echo -e "${COLOR_BLUE}Fedora detected. Installing Borg using dnf...${COLOR_RESET}"
        dnf install -y borgbackup
    elif command -v apk &>/dev/null; then
        echo -e "${COLOR_BLUE}Alpine detected. Installing Borg using apk...${COLOR_RESET}"
        apk add borgbackup
    else
        echo -e "${COLOR_RED}Unable to detect package manager.${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}Please install Borg manually: https://borgbackup.org/install.html${COLOR_RESET}"

        read -p "$(echo -e "${COLOR_YELLOW}Continue installation without Borg? (y/n): ${COLOR_RESET}")" continue_without_borg
        if [ "$continue_without_borg" != "y" ]; then
            echo -e "${COLOR_RED}Installation canceled.${COLOR_RESET}"
            exit 1
        fi

        echo -e "${COLOR_YELLOW}Continuing installation without Borg. You'll need to install it manually later.${COLOR_RESET}"
    fi

    # Check if installation was successful
    if ! command -v borg &>/dev/null; then
        echo -e "${COLOR_RED}Failed to install Borg automatically.${COLOR_RESET}"
        read -p "$(echo -e "${COLOR_YELLOW}Continue installation without Borg? (y/n): ${COLOR_RESET}")" continue_without_borg
        if [ "$continue_without_borg" != "y" ]; then
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
echo -e "${COLOR_BLUE}Installing scripts...${COLOR_RESET}"

for script in "${SCRIPT_NAMES[@]}"; do
    cp "./$script" "$INSTALL_DIR/"
    chmod +x "$INSTALL_DIR/$script"
    echo -e "${COLOR_GREEN}Installed: $INSTALL_DIR/$script${COLOR_RESET}"
done

# Also install the install script itself
cp "./docker_install.sh" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/docker_install.sh"
echo -e "${COLOR_GREEN}Installed: $INSTALL_DIR/docker_install.sh${COLOR_RESET}"

# Create symlinks without .sh extension
echo -e "${COLOR_BLUE}Creating symlinks without .sh extension...${COLOR_RESET}"

for script in "${SCRIPT_NAMES[@]}"; do
    base_name=$(basename "$script" .sh)
    ln -sf "$INSTALL_DIR/$script" "$INSTALL_DIR/$base_name"
    echo -e "${COLOR_GREEN}Created symlink: $INSTALL_DIR/$base_name${COLOR_RESET}"
done

# Create symlink for install script
ln -sf "$INSTALL_DIR/docker_install.sh" "$INSTALL_DIR/docker_install"
echo -e "${COLOR_GREEN}Created symlink: $INSTALL_DIR/docker_install${COLOR_RESET}"

# Setup cron job for automated backups
echo -e "${COLOR_BLUE}Setting up cron job for automated backups...${COLOR_RESET}"
read -p "$(echo -e "${COLOR_YELLOW}Would you like to setup a cron job for automated backups? (y/n): ${COLOR_RESET}")" setup_cron

if [ "$setup_cron" = "y" ]; then
    echo -e "${COLOR_BLUE}Choose backup frequency:${COLOR_RESET}"
    echo -e "  ${COLOR_CYAN}1) Daily${COLOR_RESET}"
    echo -e "  ${COLOR_CYAN}2) Weekly${COLOR_RESET}"
    echo -e "  ${COLOR_CYAN}3) Monthly${COLOR_RESET}"
    echo -e "  ${COLOR_CYAN}4) Custom${COLOR_RESET}"

    read -p "$(echo -e "${COLOR_YELLOW}Enter your choice (1-4): ${COLOR_RESET}")" cron_choice

    case $cron_choice in
    1)
        # Daily at 1:00 AM
        cron_time="0 1 * * *"
        cron_desc="daily at 1:00 AM"
        ;;
    2)
        # Weekly on Sunday at 1:00 AM
        cron_time="0 1 * * 0"
        cron_desc="weekly on Sunday at 1:00 AM"
        ;;
    3)
        # Monthly on the 1st at 1:00 AM
        cron_time="0 1 1 * *"
        cron_desc="monthly on the 1st at 1:00 AM"
        ;;
    4)
        # Custom
        echo -e "${COLOR_YELLOW}Enter custom cron schedule (e.g., '0 1 * * *' for daily at 1:00 AM):${COLOR_RESET}"
        read custom_cron
        cron_time="$custom_cron"
        cron_desc="custom schedule: $cron_time"
        ;;
    *)
        echo -e "${COLOR_RED}Invalid choice. Skipping cron setup.${COLOR_RESET}"
        cron_time=""
        ;;
    esac

    if [ ! -z "$cron_time" ]; then
        # Create cron job
        cron_line="$cron_time $INSTALL_DIR/docker_backup_full.sh --force >/dev/null 2>&1"
        (crontab -l 2>/dev/null || echo "") | grep -v "docker_backup_full.sh" | {
            cat
            echo "$cron_line"
        } | crontab -

        echo -e "${COLOR_GREEN}Cron job set up successfully: $cron_desc${COLOR_RESET}"
    fi
else
    echo -e "${COLOR_BLUE}Skipping cron job setup.${COLOR_RESET}"
fi

# Initialize Borg repository if Borg is installed
if command -v borg &>/dev/null; then
    echo -e "${COLOR_BLUE}Would you like to initialize a Borg repository now?${COLOR_RESET}"
    read -p "$(echo -e "${COLOR_YELLOW}Initialize repository at $BACKUP_DIR? (y/n): ${COLOR_RESET}")" init_repo

    if [ "$init_repo" = "y" ]; then
        if ! borg info "$BACKUP_DIR" >/dev/null 2>&1; then
            echo -e "${COLOR_BLUE}Initializing Borg repository at $BACKUP_DIR...${COLOR_RESET}"
            if borg init --encryption=none "$BACKUP_DIR"; then
                echo -e "${COLOR_GREEN}Repository initialized successfully!${COLOR_RESET}"
            else
                echo -e "${COLOR_RED}Failed to initialize repository.${COLOR_RESET}"
                echo -e "${COLOR_YELLOW}You can initialize it later with: borg init --encryption=none $BACKUP_DIR${COLOR_RESET}"
            fi
        else
            echo -e "${COLOR_GREEN}Repository already exists at $BACKUP_DIR.${COLOR_RESET}"
        fi
    else
        echo -e "${COLOR_BLUE}Skipping repository initialization.${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}You can initialize it later with: borg init --encryption=none $BACKUP_DIR${COLOR_RESET}"
    fi
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
echo -e "  ${COLOR_GREEN}docker_backup_full${COLOR_RESET} - Backup all Docker data"
echo -e "  ${COLOR_GREEN}docker_restore_full${COLOR_RESET} - Restore Docker from backup"
echo -e "  ${COLOR_GREEN}docker_verify${COLOR_RESET} - Verify backup integrity"
echo -e "  ${COLOR_GREEN}docker_cleanup${COLOR_RESET} - Clean Docker resources and backups"
echo ""
echo -e "${COLOR_BLUE}Backup directory:${COLOR_RESET} $BACKUP_DIR"
echo -e "${COLOR_BLUE}Log directory:${COLOR_RESET} $LOG_DIR"
echo ""
echo -e "${COLOR_YELLOW}Try running 'docker_backup_full' to create your first backup!${COLOR_RESET}"
echo -e "${COLOR_YELLOW}If you need to reinstall or update, run 'docker_install'.${COLOR_RESET}"

exit 0
