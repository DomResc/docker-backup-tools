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

# Check if script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "\033[0;31mERROR: This script must be run as root\033[0m"
    echo "Please run with sudo or as root user"
    exit 1
fi

# Default configuration
# These can be overridden by environment variables or command line arguments
DEFAULT_BACKUP_DIR="/backup/docker"
DEFAULT_RETENTION_DAYS="30"
DEFAULT_COMPRESSION="lz4" # Fastest compression
DEFAULT_ENCRYPTION="none" # Default no encryption
DOCKER_DIR="/var/lib/docker"
LOG_DIR="/var/log/docker"
LOG_FILE="${LOG_DIR}/backup.log"
DOCKER_SERVICE="docker.service"
DOCKER_SOCKET="docker.socket"
CHECK_AFTER_BACKUP=true
LOCK_FILE="/var/lock/docker_backup_full.lock"
LOCK_TIMEOUT=3600 # 1 hour timeout for lock file

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

# Flag to track Docker service states
DOCKER_STOPPED=false
DOCKER_RESTARTED=false
BACKUP_SUCCESS=false

# Parse command line arguments
usage() {
    echo -e "${COLOR_CYAN}Usage: $0 [OPTIONS]${COLOR_RESET}"
    echo -e "${COLOR_CYAN}Backup Docker volumes using Borg Backup${COLOR_RESET}"
    echo ""
    echo -e "${COLOR_CYAN}Options:${COLOR_RESET}"
    echo -e "  ${COLOR_GREEN}-d, --directory DIR${COLOR_RESET}    Backup directory (default: $DEFAULT_BACKUP_DIR)"
    echo -e "  ${COLOR_GREEN}-r, --retention DAYS${COLOR_RESET}   Number of days to keep backups (default: $DEFAULT_RETENTION_DAYS)"
    echo -e "  ${COLOR_GREEN}-c, --compression TYPE${COLOR_RESET} Compression type (lz4, zstd, zlib, none; default: $DEFAULT_COMPRESSION)"
    echo -e "  ${COLOR_GREEN}-e, --encryption TYPE${COLOR_RESET}  Encryption type (none, repokey, keyfile; default: $DEFAULT_ENCRYPTION)"
    echo -e "  ${COLOR_GREEN}-f, --force${COLOR_RESET}            Don't ask for confirmation"
    echo -e "  ${COLOR_GREEN}-s, --skip-check${COLOR_RESET}       Skip integrity check after backup"
    echo -e "  ${COLOR_GREEN}-k, --keep-old${COLOR_RESET}         Keep Docker service stopped after backup (useful for maintenance)"
    echo -e "  ${COLOR_GREEN}-h, --help${COLOR_RESET}             Display this help message"
    echo ""
    echo -e "${COLOR_CYAN}Environment variables:${COLOR_RESET}"
    echo -e "  ${COLOR_GREEN}DOCKER_BACKUP_DIR${COLOR_RESET}      Same as --directory"
    echo -e "  ${COLOR_GREEN}DOCKER_RETENTION_DAYS${COLOR_RESET}  Same as --retention"
    echo -e "  ${COLOR_GREEN}DOCKER_COMPRESSION${COLOR_RESET}     Same as --compression"
    echo -e "  ${COLOR_GREEN}DOCKER_ENCRYPTION${COLOR_RESET}      Same as --encryption"
    exit 1
}

# Get settings from environment variables or use defaults
BACKUP_DIR=${DOCKER_BACKUP_DIR:-$DEFAULT_BACKUP_DIR}
RETENTION_DAYS=${DOCKER_RETENTION_DAYS:-$DEFAULT_RETENTION_DAYS}
COMPRESSION=${DOCKER_COMPRESSION:-$DEFAULT_COMPRESSION}
ENCRYPTION=${DOCKER_ENCRYPTION:-$DEFAULT_ENCRYPTION}
FORCE=false
KEEP_DOCKER_STOPPED=false

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
    -e | --encryption)
        ENCRYPTION="$2"
        if ! [[ "$ENCRYPTION" =~ ^(none|repokey|keyfile)$ ]]; then
            echo -e "${COLOR_RED}ERROR: Encryption must be one of: none, repokey, keyfile${COLOR_RESET}"
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
    -k | --keep-old)
        KEEP_DOCKER_STOPPED=true
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

# Exit handlers
cleanup_and_exit() {
    local exit_code=$1

    # Release lock file
    if [ -f "$LOCK_FILE" ]; then
        rm -f "$LOCK_FILE"
        log "INFO" "Released lock file"
    fi

    # Ensure descriptors are closed
    exec 3>&- 4>&- 2>&- 1>&-

    exit $exit_code
}

# Handle termination signals
handle_signal() {
    log "WARNING" "Received termination signal. Cleaning up..."

    # Make sure Docker is running unless --keep-old was specified
    if [ "$DOCKER_STOPPED" = true ] && [ "$DOCKER_RESTARTED" != true ] && [ "$KEEP_DOCKER_STOPPED" != true ]; then
        log "INFO" "Restarting Docker service after interruption"
        start_docker
    fi

    cleanup_and_exit 1
}

# Set up signal handlers
trap handle_signal SIGINT SIGTERM

# Obtain a lock file to prevent multiple instances
obtain_lock() {
    log "INFO" "Attempting to obtain lock"

    # Check if lock file exists and if process is still running
    if [ -f "$LOCK_FILE" ]; then
        local pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [[ -z "$pid" ]]; then
            log "WARNING" "Lock file exists but contains no PID. Removing it."
            rm -f "$LOCK_FILE"
        elif ps -p "$pid" >/dev/null 2>&1; then
            # Check if the process has been running for too long (timeout)
            if [ -n "$LOCK_TIMEOUT" ]; then
                local lock_time=$(stat -c %Y "$LOCK_FILE" 2>/dev/null)
                local current_time=$(date +%s)

                if [ -n "$lock_time" ] && [ $((current_time - lock_time)) -gt $LOCK_TIMEOUT ]; then
                    log "WARNING" "Lock file is older than $LOCK_TIMEOUT seconds. Removing stale lock."
                    rm -f "$LOCK_FILE"
                else
                    log "ERROR" "Another backup process is already running (PID: $pid)"
                    echo -e "${COLOR_RED}ERROR: Another backup process is already running (PID: $pid)${COLOR_RESET}"
                    echo -e "${COLOR_YELLOW}If you're sure no other backup is running, remove the lock file:${COLOR_RESET}"
                    echo -e "${COLOR_CYAN}sudo rm -f $LOCK_FILE${COLOR_RESET}"
                    cleanup_and_exit 1
                fi
            else
                log "ERROR" "Another backup process is already running (PID: $pid)"
                echo -e "${COLOR_RED}ERROR: Another backup process is already running (PID: $pid)${COLOR_RESET}"
                echo -e "${COLOR_YELLOW}If you're sure no other backup is running, remove the lock file:${COLOR_RESET}"
                echo -e "${COLOR_CYAN}sudo rm -f $LOCK_FILE${COLOR_RESET}"
                cleanup_and_exit 1
            fi
        else
            log "WARNING" "Stale lock file found. Removing it."
            rm -f "$LOCK_FILE"
        fi
    fi

    # Create lock file with current PID
    echo $$ >"$LOCK_FILE"

    # Verify lock was obtained
    if [ ! -f "$LOCK_FILE" ] || [ "$(cat "$LOCK_FILE")" != "$$" ]; then
        log "ERROR" "Failed to create lock file"
        echo -e "${COLOR_RED}ERROR: Failed to create lock file${COLOR_RESET}"
        cleanup_and_exit 1
    fi

    log "INFO" "Lock obtained successfully"
}

# Setup logging
ensure_log_directory() {
    if [ ! -d "$LOG_DIR" ]; then
        mkdir -p "$LOG_DIR"
        if [ $? -ne 0 ]; then
            echo -e "${COLOR_RED}ERROR: Failed to create log directory $LOG_DIR${COLOR_RESET}"
            echo -e "${COLOR_YELLOW}Run the following command to create the directory with correct permissions:${COLOR_RESET}"
            echo -e "${COLOR_CYAN}sudo mkdir -p $LOG_DIR${COLOR_RESET}"
            cleanup_and_exit 1
        fi

        # Set proper permissions for log directory
        chmod 750 "$LOG_DIR"
    fi

    if [ ! -f "$LOG_FILE" ]; then
        touch "$LOG_FILE"
        if [ $? -ne 0 ]; then
            echo -e "${COLOR_RED}ERROR: Failed to create log file $LOG_FILE${COLOR_RESET}"
            cleanup_and_exit 1
        fi

        # Set proper permissions for log file
        chmod 640 "$LOG_FILE"
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

        # Check if installation script is available
        local install_script="/usr/local/bin/docker_install"
        local repo_install_script="./docker_install.sh"

        if [ -f "$install_script" ]; then
            echo -e "${COLOR_YELLOW}Would you like to run the installation script? ($install_script)${COLOR_RESET}"
            if [ "$FORCE" != "true" ]; then
                read -p "$(echo -e "${COLOR_YELLOW}Run installation script? (y/n): ${COLOR_RESET}")" run_install
                if [ "$run_install" == "y" ]; then
                    log "INFO" "Running installation script"
                    "$install_script"

                    # Check if installation was successful
                    if ! command_exists borg; then
                        log "ERROR" "Installation failed. Borg is still not available."
                        cleanup_and_exit 1
                    else
                        log "INFO" "Borg installed successfully"
                        return 0
                    fi
                else
                    log "INFO" "Backup canceled because Borg is not installed"
                    cleanup_and_exit 1
                fi
            else
                cleanup_and_exit 1
            fi
        elif [ -f "$repo_install_script" ]; then
            echo -e "${COLOR_YELLOW}Would you like to run the installation script? ($repo_install_script)${COLOR_RESET}"
            if [ "$FORCE" != "true" ]; then
                read -p "$(echo -e "${COLOR_YELLOW}Run installation script? (y/n): ${COLOR_RESET}")" run_install
                if [ "$run_install" == "y" ]; then
                    log "INFO" "Running installation script"
                    "$repo_install_script"

                    # Check if installation was successful
                    if ! command_exists borg; then
                        log "ERROR" "Installation failed. Borg is still not available."
                        cleanup_and_exit 1
                    else
                        log "INFO" "Borg installed successfully"
                        return 0
                    fi
                else
                    log "INFO" "Backup canceled because Borg is not installed"
                    cleanup_and_exit 1
                fi
            else
                cleanup_and_exit 1
            fi
        else
            echo -e "${COLOR_RED}Installation script not found.${COLOR_RESET}"
            echo -e "${COLOR_YELLOW}Please install Docker Volume Tools first with:${COLOR_RESET}"
            echo -e "${COLOR_CYAN}git clone https://github.com/domresc/docker-volume-tools.git${COLOR_RESET}"
            echo -e "${COLOR_CYAN}cd docker-volume-tools${COLOR_RESET}"
            echo -e "${COLOR_CYAN}sudo bash docker_install.sh${COLOR_RESET}"
            cleanup_and_exit 1
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
            echo -e "${COLOR_YELLOW}Run the following command to create the directory with correct permissions:${COLOR_RESET}"
            echo -e "${COLOR_CYAN}sudo mkdir -p $BACKUP_DIR${COLOR_RESET}"
            cleanup_and_exit 1
        fi

        # Set proper permissions
        chmod 750 "$BACKUP_DIR"
    fi

    # Check if the directory is a borg repository
    if ! borg info "$BACKUP_DIR" >/dev/null 2>&1; then
        log "INFO" "Initializing new Borg repository in $BACKUP_DIR with encryption: $ENCRYPTION"

        if [ "$FORCE" != "true" ]; then
            read -p "$(echo -e "${COLOR_YELLOW}Initialize new Borg repository in $BACKUP_DIR with encryption: $ENCRYPTION? (y/n): ${COLOR_RESET}")" init_repo
            if [ "$init_repo" != "y" ]; then
                log "INFO" "Backup canceled by user"
                cleanup_and_exit 0
            fi
        fi

        # Create repository with specified encryption
        if [ "$ENCRYPTION" = "none" ]; then
            if ! borg init --encryption=none "$BACKUP_DIR"; then
                log "ERROR" "Failed to initialize Borg repository"
                echo -e "${COLOR_RED}ERROR: Failed to initialize Borg repository${COLOR_RESET}"
                cleanup_and_exit 1
            fi
        else
            echo -e "${COLOR_YELLOW}You selected encryption type: $ENCRYPTION${COLOR_RESET}"
            echo -e "${COLOR_YELLOW}You will be prompted to create a passphrase for the repository.${COLOR_RESET}"
            echo -e "${COLOR_YELLOW}IMPORTANT: Keep your passphrase safe. If lost, backups cannot be recovered!${COLOR_RESET}"

            # Create repository with encryption
            if ! borg init --encryption=$ENCRYPTION "$BACKUP_DIR"; then
                log "ERROR" "Failed to initialize Borg repository"
                echo -e "${COLOR_RED}ERROR: Failed to initialize Borg repository${COLOR_RESET}"
                cleanup_and_exit 1
            fi
        fi

        log "INFO" "Borg repository initialized successfully"
    else
        log "INFO" "Using existing Borg repository at $BACKUP_DIR"

        # Check if repository encryption matches expected encryption
        local repo_info
        repo_info=$(borg info --json "$BACKUP_DIR" 2>/dev/null)
        local encryption_used="none"

        if echo "$repo_info" | grep -q '"encryption_keyfile"'; then
            encryption_used="keyfile"
        elif echo "$repo_info" | grep -q '"encryption_key"'; then
            encryption_used="repokey"
        fi

        if [[ "$ENCRYPTION" != "none" && "$encryption_used" == "none" ]]; then
            log "ERROR" "Repository is not encrypted but encryption was requested"
            echo -e "${COLOR_RED}ERROR: Repository at $BACKUP_DIR is not encrypted but encryption type $ENCRYPTION was requested${COLOR_RESET}"
            echo -e "${COLOR_YELLOW}Either use a different repository or set --encryption=none${COLOR_RESET}"
            cleanup_and_exit 1
        elif [[ "$ENCRYPTION" == "none" && "$encryption_used" != "none" ]]; then
            log "ERROR" "Repository is encrypted but no encryption was requested"
            echo -e "${COLOR_RED}ERROR: Repository at $BACKUP_DIR is encrypted ($encryption_used) but --encryption=none was requested${COLOR_RESET}"
            echo -e "${COLOR_YELLOW}Either use a different repository or set appropriate encryption type${COLOR_RESET}"
            cleanup_and_exit 1
        elif [[ "$ENCRYPTION" != "none" && "$encryption_used" != "$ENCRYPTION" ]]; then
            log "WARNING" "Repository uses $encryption_used encryption but $ENCRYPTION was requested"
            echo -e "${COLOR_YELLOW}WARNING: Repository uses $encryption_used encryption but $ENCRYPTION was requested${COLOR_RESET}"
            echo -e "${COLOR_YELLOW}Will continue with the repository's actual encryption type: $encryption_used${COLOR_RESET}"
            ENCRYPTION=$encryption_used
        fi
    fi
}

# Check disk space for new or incremental backup
check_disk_space() {
    log "INFO" "Checking disk space"

    # Get Docker directory size
    local docker_size=$(du -sm "$DOCKER_DIR" 2>/dev/null | cut -f1)
    if [ -z "$docker_size" ] || ! [[ "$docker_size" =~ ^[0-9]+$ ]]; then
        log "WARNING" "Could not determine Docker directory size. Make sure you have sufficient disk space."
        return 0
    fi

    # Check if previous backups exist for calculation
    local has_previous_backup=false
    if borg list --short "$BACKUP_DIR" >/dev/null 2>&1; then
        has_previous_backup=true
    fi

    # Calculate needed space based on whether this is first backup or incremental
    local needed_space
    if [ "$has_previous_backup" = true ]; then
        # For incremental backups, estimate 25% of Docker dir size, or at least 100MB
        needed_space=$((docker_size / 4))
        [[ $needed_space -lt 100 ]] && needed_space=100
        log "INFO" "Incremental backup detected - estimating space needed"
    else
        # For first backup, full size + 10% overhead
        needed_space=$((docker_size + (docker_size / 10)))
        log "INFO" "First backup detected - will need full Docker directory size"
    fi

    # Get available space
    local available_space
    available_space=$(df -m "$BACKUP_DIR" 2>/dev/null | awk 'NR==2 {print $4}')

    if [ -z "$available_space" ] || ! [[ "$available_space" =~ ^[0-9]+$ ]]; then
        log "WARNING" "Could not determine available space. Make sure you have sufficient disk space."
        return 0
    fi

    log "INFO" "Docker directory size: $docker_size MB"
    log "INFO" "Estimated space needed: $needed_space MB"
    log "INFO" "Available space: $available_space MB"

    if [ "$available_space" -lt "$needed_space" ]; then
        log "WARNING" "Available space ($available_space MB) might be insufficient for backup size ($needed_space MB)"

        if [ "$FORCE" != "true" ]; then
            read -p "$(echo -e "${COLOR_YELLOW}Available space may be insufficient. Continue anyway? (y/n): ${COLOR_RESET}")" confirm
            if [ "$confirm" != "y" ]; then
                log "INFO" "Backup canceled by user due to space concerns"
                cleanup_and_exit 0
            fi
        else
            log "WARNING" "Continuing despite potential space issues due to force flag"
        fi
    fi
}

# Check Docker service status accurately
check_docker_status() {
    # Try multiple methods to determine if Docker is running

    # Method 1: Check if daemon socket exists and is accessible
    if [ -S "/var/run/docker.sock" ] && [ -r "/var/run/docker.sock" ]; then
        # Method 2: Try docker info with timeout
        timeout 5 docker info >/dev/null 2>&1
        local result=$?

        if [ $result -eq 0 ]; then
            return 0 # Docker is running and responsive
        elif [ $result -eq 124 ]; then
            # Timeout occurred - Docker might be hanging
            log "WARNING" "Docker service seems to be hanging (timeout occurred)"
            return 2
        fi
    fi

    # Method 3: Check process existence
    if pgrep -f "dockerd" >/dev/null 2>&1; then
        log "WARNING" "Docker daemon is running but not responding"
        return 3
    fi

    # Method 4: Check service status with systemctl
    if command_exists systemctl && systemctl is-active --quiet docker; then
        log "WARNING" "Docker service is active but not responding"
        return 4
    fi

    return 1 # Docker is not running
}

# Manage Docker service (start/stop) with compatibility for different init systems
manage_docker_service() {
    local action="$1" # 'start' or 'stop'
    local max_attempts=3
    local attempt=1
    local success=false

    while [ $attempt -le $max_attempts ] && [ "$success" = false ]; do
        log "INFO" "Attempt $attempt to $action Docker service"

        # Detect init system and act accordingly
        if command_exists systemctl && systemctl --version >/dev/null 2>&1; then
            # systemd
            log "INFO" "Using systemd to $action Docker"
            if [ "$action" = "stop" ]; then
                systemctl stop $DOCKER_SOCKET 2>/dev/null || true
                systemctl stop $DOCKER_SERVICE
            else
                systemctl start $DOCKER_SERVICE
                systemctl start $DOCKER_SOCKET 2>/dev/null || true
            fi
        elif command_exists service; then
            # SysV init or upstart
            log "INFO" "Using service command to $action Docker"
            service docker $action
        elif [ -f /etc/init.d/docker ]; then
            # SysV init script direct
            log "INFO" "Using init.d script to $action Docker"
            /etc/init.d/docker $action
        else
            # Fallback to direct commands
            if [ "$action" = "stop" ]; then
                log "INFO" "Using process signals to stop Docker"
                if command_exists killall; then
                    killall -TERM dockerd 2>/dev/null || true
                    # Give it a moment to terminate gracefully
                    sleep 2
                    # Force kill if still running
                    killall -KILL dockerd 2>/dev/null || true
                else
                    pkill -TERM dockerd 2>/dev/null || true
                    sleep 2
                    pkill -KILL dockerd 2>/dev/null || true
                fi
            else
                log "INFO" "Starting Docker daemon directly"
                if command_exists dockerd; then
                    nohup dockerd >/dev/null 2>&1 &
                else
                    log "ERROR" "dockerd command not found"
                    return 1
                fi
            fi
        fi

        # Verify the operation status
        local max_wait=30
        local counter=0

        # Give Docker a moment to start/stop
        sleep 2

        while [ $counter -lt $max_wait ]; do
            if [ "$action" = "start" ]; then
                check_docker_status
                local status=$?

                if [ $status -eq 0 ]; then
                    success=true
                    break
                fi
            else # stop
                check_docker_status
                local status=$?

                if [ $status -eq 1 ]; then # Not running
                    success=true
                    break
                fi

                # If stop attempt and still running, try again with more force
                if [ $counter -gt 15 ] && ([ $status -eq 3 ] || [ $status -eq 4 ]); then
                    log "WARNING" "Docker still running after normal stop, trying force kill"
                    pkill -KILL dockerd 2>/dev/null || true
                fi
            fi

            sleep 1
            counter=$((counter + 1))
        done

        if [ "$success" = true ]; then
            log "INFO" "Docker service $action successfully"
            return 0
        else
            log "WARNING" "Failed to $action Docker service on attempt $attempt"
            attempt=$((attempt + 1))

            # Wait before retrying
            if [ $attempt -le $max_attempts ]; then
                log "INFO" "Waiting 5 seconds before next attempt..."
                sleep 5
            fi
        fi
    done

    # If we got here, all attempts failed
    log "ERROR" "Failed to $action Docker service after $max_attempts attempts"
    echo -e "${COLOR_RED}ERROR: Failed to $action Docker service${COLOR_RESET}"
    return 1
}

# Stop Docker service
stop_docker() {
    log "INFO" "Stopping Docker service"

    # Check if Docker is running
    check_docker_status
    local status=$?

    if [ $status -eq 1 ]; then
        log "INFO" "Docker service is already stopped"
        DOCKER_STOPPED=true
        return 0
    elif [ $status -gt 1 ]; then
        log "WARNING" "Docker service is in an inconsistent state. Will attempt to stop it."
    fi

    if [ "$FORCE" != "true" ]; then
        echo -e "${COLOR_YELLOW}WARNING: This will stop all Docker containers and the Docker service.${COLOR_RESET}"
        read -p "$(echo -e "${COLOR_YELLOW}Are you sure you want to continue? (y/n): ${COLOR_RESET}")" confirm
        if [ "$confirm" != "y" ]; then
            log "INFO" "Backup canceled by user"
            cleanup_and_exit 0
        fi
    fi

    log "INFO" "Stopping Docker service now"
    manage_docker_service stop
    local stop_result=$?

    if [ $stop_result -eq 0 ]; then
        DOCKER_STOPPED=true
    else
        echo -e "${COLOR_RED}ERROR: Failed to stop Docker service${COLOR_RESET}"
        cleanup_and_exit 1
    fi
}

# Start Docker service
start_docker() {
    if [ "$DOCKER_STOPPED" = true ] && [ "$KEEP_DOCKER_STOPPED" != true ]; then
        # Check if Docker is already running (it might have been started externally)
        check_docker_status
        local status=$?

        if [ $status -eq 0 ]; then
            log "INFO" "Docker service is already running"
            DOCKER_RESTARTED=true
            return 0
        fi

        log "INFO" "Starting Docker service"
        manage_docker_service start
        local start_result=$?

        if [ $start_result -ne 0 ]; then
            log "ERROR" "Failed to start Docker service"
            echo -e "${COLOR_RED}ERROR: Failed to start Docker service${COLOR_RESET}"
            echo -e "${COLOR_YELLOW}You may need to start it manually with: sudo systemctl start $DOCKER_SERVICE${COLOR_RESET}"
            return 1
        fi
        DOCKER_RESTARTED=true
        log "INFO" "Docker service started successfully"
    elif [ "$KEEP_DOCKER_STOPPED" = true ]; then
        log "INFO" "Keeping Docker service stopped as requested"
        echo -e "${COLOR_YELLOW}Docker service has been kept stopped as requested${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}You will need to start it manually with: sudo systemctl start $DOCKER_SERVICE${COLOR_RESET}"
    else
        log "INFO" "Docker was not stopped, no need to start it"
    fi

    return 0
}

# Create the backup
create_backup() {
    local start_time=$(date +%s)
    local backup_name="docker-$(date +%Y-%m-%d_%H:%M:%S)"

    log "INFO" "Creating backup $backup_name"
    echo -e "${COLOR_CYAN}${COLOR_BOLD}Creating backup in progress. This may take some time...${COLOR_RESET}"

    # Set up environment for encryption if needed
    if [ "$ENCRYPTION" != "none" ]; then
        log "INFO" "Repository is encrypted. Setting up environment."

        # If BORG_PASSPHRASE is already set in environment, use it
        if [ -z "$BORG_PASSPHRASE" ]; then
            echo -e "${COLOR_YELLOW}You will be prompted for the repository passphrase.${COLOR_RESET}"
            echo -e "${COLOR_YELLOW}Alternatively, you can set the BORG_PASSPHRASE environment variable.${COLOR_RESET}"
        else
            log "INFO" "Using BORG_PASSPHRASE from environment"
        fi
    fi

    # Create a temporary file for output capture
    local temp_output=$(mktemp)

    # Run the backup
    if ! borg create --stats --progress \
        --compression $COMPRESSION \
        "$BACKUP_DIR::$backup_name" \
        "$DOCKER_DIR" 2>&1 | tee "$temp_output"; then

        # Check for specific error messages in the output
        if grep -q "passphrase supplied in" "$temp_output"; then
            log "ERROR" "Encryption passphrase issue. Please check your passphrase."
            echo -e "${COLOR_RED}ERROR: Encryption passphrase issue. Please check your passphrase.${COLOR_RESET}"
        elif grep -q "disk space" "$temp_output"; then
            log "ERROR" "Insufficient disk space for backup."
            echo -e "${COLOR_RED}ERROR: Insufficient disk space for backup.${COLOR_RESET}"
        fi

        rm -f "$temp_output"
        log "ERROR" "Backup failed"
        return 1
    fi

    # Check for warnings in the output
    if grep -q "WARNING" "$temp_output"; then
        log "WARNING" "Borg reported warnings during backup. Check the log for details."
        echo -e "${COLOR_YELLOW}WARNING: Borg reported warnings during backup. Check the log for details.${COLOR_RESET}"
    fi

    rm -f "$temp_output"

    local backup_exit_code=$?
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    if [ $backup_exit_code -eq 0 ]; then
        log "INFO" "Backup completed successfully in $duration seconds"
        BACKUP_SUCCESS=true
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

    # Handle encryption if needed
    if [ "$ENCRYPTION" != "none" ] && [ -z "$BORG_PASSPHRASE" ]; then
        echo -e "${COLOR_YELLOW}You will be prompted for the repository passphrase.${COLOR_RESET}"
    fi

    if ! borg check --progress "$BACKUP_DIR::$backup_name"; then
        log "ERROR" "Verification failed"
        echo -e "${COLOR_RED}ERROR: Backup verification failed${COLOR_RESET}"
        return 1
    fi

    log "INFO" "Verification completed successfully"
    return 0
}

# Prune old backups
prune_old_backups() {
    if [ "$RETENTION_DAYS" -le 0 ]; then
        log "INFO" "Retention policy disabled. Not cleaning up old backups."
        return 0
    fi

    log "INFO" "Pruning backups older than $RETENTION_DAYS days"
    echo -e "${COLOR_CYAN}${COLOR_BOLD}Pruning old backups...${COLOR_RESET}"

    # Handle encryption if needed
    if [ "$ENCRYPTION" != "none" ] && [ -z "$BORG_PASSPHRASE" ]; then
        echo -e "${COLOR_YELLOW}You will be prompted for the repository passphrase.${COLOR_RESET}"
    fi

    if ! borg prune --keep-daily $RETENTION_DAYS --stats "$BACKUP_DIR"; then
        log "WARNING" "Pruning failed"
        echo -e "${COLOR_YELLOW}WARNING: Failed to prune old backups${COLOR_RESET}"
        return 1
    fi

    log "INFO" "Pruning completed successfully"
    return 0
}

# Function to ensure Docker is restarted on script exit or error
cleanup_on_exit() {
    log "INFO" "Running cleanup on exit"

    # Make sure Docker is running unless --keep-old was specified
    if [ "$DOCKER_STOPPED" = true ] && [ "$DOCKER_RESTARTED" != true ] && [ "$KEEP_DOCKER_STOPPED" != true ]; then
        log "INFO" "Restarting Docker service during cleanup"
        start_docker
    fi

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

    # Obtain lock to prevent multiple instances running
    obtain_lock

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
    local latest_backup=$(borg list --last 1 --short "$BACKUP_DIR" 2>/dev/null | head -1)

    # If no backup was found, something went wrong
    if [ -z "$latest_backup" ]; then
        log "ERROR" "Failed to find the created backup"
        echo -e "${COLOR_RED}ERROR: Failed to find the created backup${COLOR_RESET}"

        # Still try to restart Docker
        if [ "$KEEP_DOCKER_STOPPED" != true ]; then
            start_docker
        fi

        cleanup_and_exit 1
    fi

    # Start Docker unless requested to keep it stopped
    if [ "$KEEP_DOCKER_STOPPED" != true ]; then
        start_docker
    fi

    # Check backup if requested and if backup succeeded
    if [ "$CHECK_AFTER_BACKUP" = true ] && [ $create_result -eq 0 ]; then
        verify_backup "$latest_backup"
    fi

    # Prune old backups
    prune_old_backups

    # Show backup summary
    local total_backups=$(borg list "$BACKUP_DIR" 2>/dev/null | wc -l)
    local repo_info=$(borg info --json "$BACKUP_DIR" 2>/dev/null)
    local repo_size=0

    if [ -n "$repo_info" ]; then
        repo_size=$(echo "$repo_info" | grep -o '"unique_csize":[0-9]*' | grep -o '[0-9]*')
        if [ -n "$repo_size" ]; then
            repo_size=$((repo_size / 1024 / 1024)) # Convert to MB
        else
            repo_size="Unknown"
        fi
    else
        repo_size="Unknown"
    fi

    echo -e "${COLOR_CYAN}${COLOR_BOLD}"
    echo "======================================================="
    echo "                  Backup Summary"
    echo "======================================================="
    echo -e "${COLOR_RESET}"
    log "INFO" "Total backups in repository: $total_backups"
    log "INFO" "Repository size: $repo_size MB"
    log "INFO" "Latest backup: $latest_backup"
    log "INFO" "Compression: $COMPRESSION"
    log "INFO" "Encryption: $ENCRYPTION"
    log "INFO" "Retention: $RETENTION_DAYS days"

    if [ $create_result -eq 0 ]; then
        echo -e "${COLOR_GREEN}${COLOR_BOLD}Backup completed successfully!${COLOR_RESET}"
    else
        echo -e "${COLOR_RED}${COLOR_BOLD}Backup failed with errors. See log for details.${COLOR_RESET}"
    fi

    if [ $create_result -ne 0 ]; then
        cleanup_and_exit 1
    fi

    cleanup_and_exit 0
}

# Register trap for cleanup
trap cleanup_on_exit EXIT

# Ensure log directory exists
ensure_log_directory

# Run the backup
perform_backup
