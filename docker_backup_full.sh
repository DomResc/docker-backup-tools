#!/bin/bash
# Docker Volume Tools - A utility for full Docker backup using Borg Backup
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

# Default configuration
# These can be overridden by environment variables or command line arguments
DEFAULT_BACKUP_DIR="/backup/docker"
DEFAULT_RETENTION_DAYS="30"
DEFAULT_COMPRESSION="lz4" # Fastest compression
DOCKER_DIR="/var/lib/docker"
LOG_DIR="/var/log/docker"
LOG_FILE="${LOG_DIR}/backup.log"
DOCKER_SERVICE="docker.service"
CHECK_AFTER_BACKUP=true

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

# Flag to track if we restarted docker
DOCKER_RESTARTED=false

# Parse command line arguments
usage() {
    echo -e "${COLOR_CYAN}Usage: $0 [OPTIONS]${COLOR_RESET}"
    echo -e "${COLOR_CYAN}Backup Docker volumes using Borg Backup${COLOR_RESET}"
    echo ""
    echo -e "${COLOR_CYAN}Options:${COLOR_RESET}"
    echo -e "  ${COLOR_GREEN}-d, --directory DIR${COLOR_RESET}    Backup directory (default: $DEFAULT_BACKUP_DIR)"
    echo -e "  ${COLOR_GREEN}-r, --retention DAYS${COLOR_RESET}   Number of days to keep backups (default: $DEFAULT_RETENTION_DAYS)"
    echo -e "  ${COLOR_GREEN}-c, --compression TYPE${COLOR_RESET} Compression type (lz4, zstd, zlib, none; default: $DEFAULT_COMPRESSION)"
    echo -e "  ${COLOR_GREEN}-f, --force${COLOR_RESET}            Don't ask for confirmation"
    echo -e "  ${COLOR_GREEN}-s, --skip-check${COLOR_RESET}       Skip integrity check after backup"
    echo -e "  ${COLOR_GREEN}-h, --help${COLOR_RESET}             Display this help message"
    echo ""
    echo -e "${COLOR_CYAN}Environment variables:${COLOR_RESET}"
    echo -e "  ${COLOR_GREEN}DOCKER_BACKUP_DIR${COLOR_RESET}      Same as --directory"
    echo -e "  ${COLOR_GREEN}DOCKER_RETENTION_DAYS${COLOR_RESET}  Same as --retention"
    echo -e "  ${COLOR_GREEN}DOCKER_COMPRESSION${COLOR_RESET}     Same as --compression"
    exit 1
}

# Get settings from environment variables or use defaults
BACKUP_DIR=${DOCKER_BACKUP_DIR:-$DEFAULT_BACKUP_DIR}
RETENTION_DAYS=${DOCKER_RETENTION_DAYS:-$DEFAULT_RETENTION_DAYS}
COMPRESSION=${DOCKER_COMPRESSION:-$DEFAULT_COMPRESSION}
FORCE=false

# Parse command line options
while [[ $# -gt 0 ]]; do
    case $1 in
    -d | --directory)
        BACKUP_DIR="$2"
        shift 2
        ;;
    -r | --retention)
        RETENTION_DAYS="$2"
        if ! [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
            echo -e "${COLOR_RED}ERROR: Retention days must be a positive integer or 0${COLOR_RESET}"
            exit 1
        fi
        shift 2
        ;;
    -c | --compression)
        COMPRESSION="$2"
        if ! [[ "$COMPRESSION" =~ ^(lz4|zstd|zlib|none)$ ]]; then
            echo -e "${COLOR_RED}ERROR: Compression must be one of: lz4, zstd, zlib, none${COLOR_RESET}"
            exit 1
        fi
        shift 2
        ;;
    -f | --force)
        FORCE=true
        shift
        ;;
    -s | --skip-check)
        CHECK_AFTER_BACKUP=false
        shift
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

# Setup logging
ensure_log_directory() {
    if [ ! -d "$LOG_DIR" ]; then
        mkdir -p "$LOG_DIR"
        if [ $? -ne 0 ]; then
            echo -e "${COLOR_RED}ERROR: Failed to create log directory $LOG_DIR${COLOR_RESET}"
            echo -e "${COLOR_YELLOW}Run the following commands to create the directory with correct permissions:${COLOR_RESET}"
            echo -e "${COLOR_CYAN}sudo mkdir -p $LOG_DIR${COLOR_RESET}"
            echo -e "${COLOR_CYAN}sudo chown $USER:$USER $LOG_DIR${COLOR_RESET}"
            exit 1
        fi
    fi

    if [ ! -f "$LOG_FILE" ]; then
        touch "$LOG_FILE"
        if [ $? -ne 0 ]; then
            echo -e "${COLOR_RED}ERROR: Failed to create log file $LOG_FILE${COLOR_RESET}"
            exit 1
        fi
    fi
}

# Logging function
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    local color=""

    case "$level" in
    "INFO")
        color=$COLOR_GREEN
        ;;
    "WARNING")
        color=$COLOR_YELLOW
        ;;
    "ERROR")
        color=$COLOR_RED
        ;;
    *)
        color=$COLOR_RESET
        ;;
    esac

    # Log to console with colors
    echo -e "[$timestamp] [${color}${level}${COLOR_RESET}] $message"

    # Log to file without colors
    echo "[$timestamp] [$level] $message" >>"$LOG_FILE"
}

# Check if a command is available
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check if borg is installed
check_borg_installation() {
    if ! command_exists borg; then
        log "ERROR" "Borg Backup is not installed"
        echo -e "${COLOR_YELLOW}Borg Backup is required for this script.${COLOR_RESET}"
        echo ""
        echo -e "${COLOR_CYAN}To install Borg:${COLOR_RESET}"
        echo -e "  - On Debian/Ubuntu: ${COLOR_GREEN}sudo apt-get install borgbackup${COLOR_RESET}"
        echo -e "  - On CentOS/RHEL: ${COLOR_GREEN}sudo yum install borgbackup${COLOR_RESET}"
        echo -e "  - On Alpine Linux: ${COLOR_GREEN}apk add borgbackup${COLOR_RESET}"
        echo -e "  - On macOS: ${COLOR_GREEN}brew install borgbackup${COLOR_RESET}"
        echo ""
        echo -e "For other systems, see: ${COLOR_BLUE}https://borgbackup.org/install.html${COLOR_RESET}"

        if [ "$FORCE" != "true" ]; then
            read -p "$(echo -e "${COLOR_YELLOW}Would you like to try to install Borg now? (y/n): ${COLOR_RESET}")" install_borg
            if [ "$install_borg" == "y" ]; then
                # Try to detect OS and install
                if command_exists apt-get; then
                    log "INFO" "Attempting to install Borg using apt-get"
                    sudo apt-get update && sudo apt-get install -y borgbackup
                elif command_exists yum; then
                    log "INFO" "Attempting to install Borg using yum"
                    sudo yum install -y borgbackup
                elif command_exists apk; then
                    log "INFO" "Attempting to install Borg using apk"
                    sudo apk add borgbackup
                elif command_exists brew; then
                    log "INFO" "Attempting to install Borg using brew"
                    brew install borgbackup
                else
                    log "ERROR" "Could not detect package manager to install Borg"
                    echo -e "${COLOR_RED}Please install Borg manually and try again.${COLOR_RESET}"
                    exit 1
                fi

                if ! command_exists borg; then
                    log "ERROR" "Failed to install Borg"
                    exit 1
                else
                    log "INFO" "Borg installed successfully"
                fi
            else
                log "INFO" "Backup canceled because Borg is not installed"
                exit 1
            fi
        else
            # In force mode, fail if borg not installed
            exit 1
        fi
    fi

    log "INFO" "Borg Backup is installed"

    # Check borg version
    local borg_version=$(borg --version | cut -d' ' -f2)
    log "INFO" "Borg version: $borg_version"

    return 0
}

# Initialize borg repository if it doesn't exist
initialize_repository() {
    if ! [ -d "$BACKUP_DIR" ]; then
        log "INFO" "Creating backup directory $BACKUP_DIR"
        mkdir -p "$BACKUP_DIR"
        if [ $? -ne 0 ]; then
            log "ERROR" "Failed to create backup directory $BACKUP_DIR"
            echo -e "${COLOR_RED}ERROR: Failed to create backup directory $BACKUP_DIR${COLOR_RESET}"
            echo -e "${COLOR_YELLOW}Run the following commands to create the directory with correct permissions:${COLOR_RESET}"
            echo -e "${COLOR_CYAN}sudo mkdir -p $BACKUP_DIR${COLOR_RESET}"
            echo -e "${COLOR_CYAN}sudo chown $USER:$USER $BACKUP_DIR${COLOR_RESET}"
            exit 1
        fi
    fi

    # Check if the directory is a borg repository
    if ! borg info "$BACKUP_DIR" >/dev/null 2>&1; then
        log "INFO" "Initializing new Borg repository in $BACKUP_DIR"

        if [ "$FORCE" != "true" ]; then
            read -p "$(echo -e "${COLOR_YELLOW}Initialize new Borg repository in $BACKUP_DIR? (y/n): ${COLOR_RESET}")" init_repo
            if [ "$init_repo" != "y" ]; then
                log "INFO" "Backup canceled by user"
                exit 0
            fi
        fi

        borg init --encryption=none "$BACKUP_DIR"
        if [ $? -ne 0 ]; then
            log "ERROR" "Failed to initialize Borg repository"
            echo -e "${COLOR_RED}ERROR: Failed to initialize Borg repository${COLOR_RESET}"
            exit 1
        fi
        log "INFO" "Borg repository initialized successfully"
    else
        log "INFO" "Using existing Borg repository at $BACKUP_DIR"
    fi
}

# Check disk space
check_disk_space() {
    local docker_size=$(du -sm "$DOCKER_DIR" 2>/dev/null | cut -f1)
    if [ -z "$docker_size" ]; then
        log "WARNING" "Could not determine Docker directory size. Make sure you have sufficient disk space."
        return 0
    fi

    # Add 10% overhead
    local needed_space=$((docker_size + (docker_size / 10)))

    # Get available space
    local available_space=$(df -m "$BACKUP_DIR" | awk 'NR==2 {print $4}')

    log "INFO" "Docker directory size: $docker_size MB"
    log "INFO" "Estimated space needed: $needed_space MB"
    log "INFO" "Available space: $available_space MB"

    if [ "$available_space" -lt "$needed_space" ]; then
        log "WARNING" "Available space ($available_space MB) might be insufficient for backup size ($needed_space MB)"

        if [ "$FORCE" != "true" ]; then
            read -p "$(echo -e "${COLOR_YELLOW}Available space may be insufficient. Continue anyway? (y/n): ${COLOR_RESET}")" confirm
            if [ "$confirm" != "y" ]; then
                log "INFO" "Backup canceled by user due to space concerns"
                exit 0
            fi
        else
            log "WARNING" "Continuing despite potential space issues due to force flag"
        fi
    fi
}

# Stop Docker service
stop_docker() {
    log "INFO" "Stopping Docker service"

    # Check if Docker is running
    if ! systemctl is-active --quiet $DOCKER_SERVICE; then
        log "INFO" "Docker service is already stopped"
        return 0
    fi

    if [ "$FORCE" != "true" ]; then
        echo -e "${COLOR_YELLOW}WARNING: This will stop all Docker containers and the Docker service.${COLOR_RESET}"
        read -p "$(echo -e "${COLOR_YELLOW}Are you sure you want to continue? (y/n): ${COLOR_RESET}")" confirm
        if [ "$confirm" != "y" ]; then
            log "INFO" "Backup canceled by user"
            exit 0
        fi
    fi

    log "INFO" "Stopping Docker service now"
    sudo systemctl stop $DOCKER_SERVICE

    # Wait for Docker to stop
    local max_wait=30
    local counter=0
    while systemctl is-active --quiet $DOCKER_SERVICE; do
        sleep 1
        counter=$((counter + 1))
        if [ $counter -ge $max_wait ]; then
            log "ERROR" "Failed to stop Docker service within $max_wait seconds"
            echo -e "${COLOR_RED}ERROR: Failed to stop Docker service${COLOR_RESET}"
            exit 1
        fi
    done

    DOCKER_RESTARTED=true
    log "INFO" "Docker service stopped successfully"
}

# Start Docker service
start_docker() {
    if [ "$DOCKER_RESTARTED" = true ]; then
        log "INFO" "Starting Docker service"
        sudo systemctl start $DOCKER_SERVICE

        # Wait for Docker to start
        local max_wait=60
        local counter=0
        while ! systemctl is-active --quiet $DOCKER_SERVICE; do
            sleep 1
            counter=$((counter + 1))
            if [ $counter -ge $max_wait ]; then
                log "ERROR" "Failed to start Docker service within $max_wait seconds"
                echo -e "${COLOR_RED}ERROR: Failed to start Docker service${COLOR_RESET}"
                echo -e "${COLOR_YELLOW}You may need to start it manually with: sudo systemctl start $DOCKER_SERVICE${COLOR_RESET}"
                return 1
            fi
        done

        log "INFO" "Docker service started successfully"
    else
        log "INFO" "Docker was not restarted, no need to start it"
    fi

    return 0
}

# Create the backup
create_backup() {
    local start_time=$(date +%s)
    local backup_name="docker-$(date +%Y-%m-%d_%H:%M:%S)"

    log "INFO" "Creating backup $backup_name"
    echo -e "${COLOR_CYAN}${COLOR_BOLD}Creating backup in progress. This may take some time...${COLOR_RESET}"

    # Run the backup
    borg create \
        --stats \
        --progress \
        --compression $COMPRESSION \
        "$BACKUP_DIR::$backup_name" \
        "$DOCKER_DIR"

    local backup_exit_code=$?
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    if [ $backup_exit_code -eq 0 ]; then
        log "INFO" "Backup completed successfully in $duration seconds"
        return 0
    else
        log "ERROR" "Backup failed with exit code $backup_exit_code"
        return $backup_exit_code
    fi
}

# Verify the backup
verify_backup() {
    local backup_name="$1"

    log "INFO" "Verifying backup $backup_name"
    echo -e "${COLOR_CYAN}${COLOR_BOLD}Verifying backup...${COLOR_RESET}"

    borg check --progress "$BACKUP_DIR::$backup_name"

    local verify_exit_code=$?

    if [ $verify_exit_code -eq 0 ]; then
        log "INFO" "Verification completed successfully"
        return 0
    else
        log "ERROR" "Verification failed with exit code $verify_exit_code"
        return $verify_exit_code
    fi
}

# Prune old backups
prune_old_backups() {
    if [ "$RETENTION_DAYS" -le 0 ]; then
        log "INFO" "Retention policy disabled. Not cleaning up old backups."
        return 0
    fi

    log "INFO" "Pruning backups older than $RETENTION_DAYS days"
    echo -e "${COLOR_CYAN}${COLOR_BOLD}Pruning old backups...${COLOR_RESET}"

    borg prune \
        --keep-daily $RETENTION_DAYS \
        --stats \
        "$BACKUP_DIR"

    local prune_exit_code=$?

    if [ $prune_exit_code -eq 0 ]; then
        log "INFO" "Pruning completed successfully"
        return 0
    else
        log "WARNING" "Pruning failed with exit code $prune_exit_code"
        return $prune_exit_code
    fi
}

# Function to ensure Docker is restarted on script exit or error
cleanup_on_exit() {
    log "INFO" "Running cleanup on exit"

    # Make sure Docker is running
    start_docker

    log "INFO" "Cleanup completed"
}

# Function to display a nice header
display_header() {
    echo -e "${COLOR_CYAN}${COLOR_BOLD}"
    echo "======================================================="
    echo "        Docker Volume Tools - $(date +%Y-%m-%d)"
    echo "======================================================="
    echo -e "${COLOR_RESET}"
}

# Main function to perform backup
perform_backup() {
    display_header

    log "INFO" "Starting Docker Volume Full Backup"

    # Check prerequisites
    check_borg_installation
    initialize_repository
    check_disk_space

    # Stop Docker
    stop_docker

    # Create backup
    local create_result=0
    create_backup
    create_result=$?

    # Get the name of the latest backup
    local latest_backup=$(borg list --last 1 --short "$BACKUP_DIR" | cut -d' ' -f1)

    # Start Docker regardless of backup success/failure
    start_docker

    # Check backup if requested and if backup succeeded
    if [ "$CHECK_AFTER_BACKUP" = true ] && [ $create_result -eq 0 ]; then
        verify_backup "$latest_backup"
    fi

    # Prune old backups
    prune_old_backups

    # Show backup summary
    local total_backups=$(borg list "$BACKUP_DIR" | wc -l)
    local repo_size=$(borg info --json "$BACKUP_DIR" | grep -o '"unique_csize":[0-9]*' | cut -d':' -f2)
    repo_size=$((repo_size / 1024 / 1024)) # Convert to MB

    echo -e "${COLOR_CYAN}${COLOR_BOLD}"
    echo "======================================================="
    echo "                  Backup Summary"
    echo "======================================================="
    echo -e "${COLOR_RESET}"
    log "INFO" "Total backups in repository: $total_backups"
    log "INFO" "Repository size: $repo_size MB"
    log "INFO" "Latest backup: $latest_backup"
    log "INFO" "Compression: $COMPRESSION"
    log "INFO" "Retention: $RETENTION_DAYS days"

    if [ $create_result -eq 0 ]; then
        echo -e "${COLOR_GREEN}${COLOR_BOLD}Backup completed successfully!${COLOR_RESET}"
    else
        echo -e "${COLOR_RED}${COLOR_BOLD}Backup failed with errors. See log for details.${COLOR_RESET}"
    fi

    if [ $create_result -ne 0 ]; then
        return 1
    fi

    return 0
}

# Register trap for cleanup
trap cleanup_on_exit EXIT INT TERM

# Ensure log directory exists
ensure_log_directory

# Run the backup
perform_backup
exit $?
