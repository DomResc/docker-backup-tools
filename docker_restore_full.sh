#!/bin/bash
# Docker Volume Tools - A utility for full Docker restore using Borg Backup
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
DEFAULT_BACKUP_DIR="/backup/docker"
DOCKER_DIR="/var/lib/docker"
LOG_DIR="/var/log/docker"
LOG_FILE="${LOG_DIR}/restore.log"
DOCKER_SERVICE="docker.service"
DOCKER_SOCKET="docker.socket"
LOCK_FILE="/var/lock/docker_restore_full.lock"
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

# Flag to track Docker and backup states
DOCKER_STOPPED=false
DOCKER_RESTARTED=false
DOCKER_DIR_BACKED_UP=false
BACKUP_DIR_NAME=""
RESTORE_SUCCESS=false

# Parse command line arguments
usage() {
  echo -e "${COLOR_CYAN}Usage: $0 [OPTIONS] [ARCHIVE]${COLOR_RESET}"
  echo -e "${COLOR_CYAN}Restore Docker from Borg backup${COLOR_RESET}"
  echo ""
  echo -e "${COLOR_CYAN}Arguments:${COLOR_RESET}"
  echo -e "  ${COLOR_GREEN}ARCHIVE${COLOR_RESET}              Optional: specific archive to restore (if omitted, will show menu)"
  echo ""
  echo -e "${COLOR_CYAN}Options:${COLOR_RESET}"
  echo -e "  ${COLOR_GREEN}-d, --directory DIR${COLOR_RESET}  Backup directory (default: $DEFAULT_BACKUP_DIR)"
  echo -e "  ${COLOR_GREEN}-f, --force${COLOR_RESET}          Don't ask for confirmation"
  echo -e "  ${COLOR_GREEN}-k, --keep-backup${COLOR_RESET}    Keep backup of current Docker directory after successful restore"
  echo -e "  ${COLOR_GREEN}-h, --help${COLOR_RESET}           Display this help message"
  echo ""
  echo -e "${COLOR_CYAN}Environment variables:${COLOR_RESET}"
  echo -e "  ${COLOR_GREEN}DOCKER_BACKUP_DIR${COLOR_RESET}    Same as --directory"
  exit 1
}

# Get settings from environment variables or use defaults
BACKUP_DIR=${DOCKER_BACKUP_DIR:-$DEFAULT_BACKUP_DIR}
FORCE=false
KEEP_BACKUP=false
ARCHIVE_ARG=""

# Parse command line options
while [[ $# -gt 0 ]]; do
  case $1 in
  -d | --directory)
    BACKUP_DIR="$2"
    shift 2
    ;;
  -f | --force)
    FORCE=true
    shift
    ;;
  -k | --keep-backup)
    KEEP_BACKUP=true
    shift
    ;;
  -h | --help)
    usage
    ;;
  -*)
    echo -e "${COLOR_RED}Unknown option: $1${COLOR_RESET}"
    usage
    ;;
  *)
    ARCHIVE_ARG="$1"
    shift
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

  # If Docker was stopped, try to restart it
  if [ "$DOCKER_STOPPED" = true ] && [ "$DOCKER_RESTARTED" != true ]; then
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
          log "ERROR" "Another restore process is already running (PID: $pid)"
          echo -e "${COLOR_RED}ERROR: Another restore process is already running (PID: $pid)${COLOR_RESET}"
          echo -e "${COLOR_YELLOW}If you're sure no other restore is running, remove the lock file:${COLOR_RESET}"
          echo -e "${COLOR_CYAN}sudo rm -f $LOCK_FILE${COLOR_RESET}"
          cleanup_and_exit 1
        fi
      else
        log "ERROR" "Another restore process is already running (PID: $pid)"
        echo -e "${COLOR_RED}ERROR: Another restore process is already running (PID: $pid)${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}If you're sure no other restore is running, remove the lock file:${COLOR_RESET}"
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
          log "INFO" "Restoration canceled because Borg is not installed"
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
          log "INFO" "Restoration canceled because Borg is not installed"
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

# Check if the repository exists and is a valid Borg repository
check_repository() {
  if ! [ -d "$BACKUP_DIR" ]; then
    log "ERROR" "Backup directory $BACKUP_DIR does not exist"
    echo -e "${COLOR_RED}ERROR: Backup directory $BACKUP_DIR does not exist${COLOR_RESET}"
    cleanup_and_exit 1
  fi

  # Check if it's a valid borg repository
  if ! borg info "$BACKUP_DIR" >/dev/null 2>&1; then
    log "ERROR" "Directory $BACKUP_DIR is not a valid Borg repository"
    echo -e "${COLOR_RED}ERROR: Directory $BACKUP_DIR is not a valid Borg repository${COLOR_RESET}"
    cleanup_and_exit 1
  fi

  log "INFO" "Valid Borg repository found at $BACKUP_DIR"

  # Check if repository is encrypted
  local repo_info=$(borg info --json "$BACKUP_DIR" 2>/dev/null)
  if echo "$repo_info" | grep -q '"encryption_keyfile"'; then
    log "INFO" "Repository is encrypted with keyfile"
    echo -e "${COLOR_YELLOW}Repository is encrypted with keyfile. You will be prompted for the passphrase during restore.${COLOR_RESET}"

    # Verify if BORG_PASSPHRASE is set
    if [ -n "$BORG_PASSPHRASE" ]; then
      log "INFO" "Using BORG_PASSPHRASE from environment"
    fi
  elif echo "$repo_info" | grep -q '"encryption_key"'; then
    log "INFO" "Repository is encrypted with repokey"
    echo -e "${COLOR_YELLOW}Repository is encrypted with repokey. You will be prompted for the passphrase during restore.${COLOR_RESET}"

    # Verify if BORG_PASSPHRASE is set
    if [ -n "$BORG_PASSPHRASE" ]; then
      log "INFO" "Using BORG_PASSPHRASE from environment"
    fi
  else
    log "INFO" "Repository is not encrypted"
  fi
}

# Check disk space for restoration
check_disk_space() {
  local archive="$1"
  log "INFO" "Checking disk space for restoration"

  # Get archive info
  local archive_info=$(borg info --json "$BACKUP_DIR::$archive" 2>/dev/null)
  if [ $? -ne 0 ]; then
    log "ERROR" "Failed to get archive info. Check your repository or passphrase."
    echo -e "${COLOR_RED}ERROR: Failed to get archive info. Check your repository or passphrase.${COLOR_RESET}"
    cleanup_and_exit 1
  fi

  local archive_size=$(echo "$archive_info" | grep -o '"original_size":[0-9]*' | grep -o '[0-9]*')

  if [ -z "$archive_size" ] || ! [[ "$archive_size" =~ ^[0-9]+$ ]]; then
    log "WARNING" "Could not determine archive size. Make sure you have sufficient disk space."
    return 0
  fi

  # Add 10% overhead
  local needed_space=$((archive_size + (archive_size / 10)))
  needed_space=$((needed_space / 1024 / 1024)) # Convert to MB

  # Get available space in /var/lib
  local available_space=$(df -m "$(dirname "$DOCKER_DIR")" 2>/dev/null | awk 'NR==2 {print $4}')

  if [ -z "$available_space" ] || ! [[ "$available_space" =~ ^[0-9]+$ ]]; then
    log "WARNING" "Could not determine available space. Make sure you have sufficient disk space."
    return 0
  fi

  log "INFO" "Archive size: $((archive_size / 1024 / 1024)) MB"
  log "INFO" "Estimated space needed: $needed_space MB"
  log "INFO" "Available space: $available_space MB"

  if [ "$available_space" -lt "$needed_space" ]; then
    log "WARNING" "Available space ($available_space MB) might be insufficient for restoration ($needed_space MB)"

    if [ "$FORCE" != "true" ]; then
      read -p "$(echo -e "${COLOR_YELLOW}Available space may be insufficient. Continue anyway? (y/n): ${COLOR_RESET}")" confirm
      if [ "$confirm" != "y" ]; then
        log "INFO" "Restoration canceled by user due to space concerns"
        cleanup_and_exit 0
      fi
    else
      log "WARNING" "Continuing despite potential space issues due to force flag"
    fi
  fi
}

# Show list of available archives
show_archives() {
  log "INFO" "Listing available archives"

  echo -e "${COLOR_CYAN}${COLOR_BOLD}Available backup archives:${COLOR_RESET}"
  echo -e "${COLOR_CYAN}------------------------------------------------------${COLOR_RESET}"

  # Get list of archives with creation date
  local archives=()
  readarray -t archives < <(borg list --short "$BACKUP_DIR" 2>/dev/null)

  if [ ${#archives[@]} -eq 0 ]; then
    log "ERROR" "No archives found in repository"
    echo -e "${COLOR_RED}No archives found in repository $BACKUP_DIR${COLOR_RESET}"
    cleanup_and_exit 1
  fi

  # Print archives with numbers
  local i=1
  for archive in "${archives[@]}"; do
    local info=$(borg info --json "$BACKUP_DIR::$archive" 2>/dev/null)
    if [ $? -ne 0 ]; then
      log "ERROR" "Failed to get archive info for $archive. Check your repository or passphrase."
      echo -e "${COLOR_RED}ERROR: Failed to get archive info for $archive${COLOR_RESET}"
      cleanup_and_exit 1
    fi

    local date=$(echo "$info" | grep -o '"time":[[:space:]]*"[^"]*"' | grep -o '"[^"]*"$' | tr -d '"' | cut -d'.' -f1 | sed 's/T/ /')
    local size=$(echo "$info" | grep -o '"original_size":[0-9]*' | grep -o '[0-9]*')

    # Convert size to human-readable format
    if [ -n "$size" ]; then
      if [ "$size" -ge $((1024 * 1024 * 1024 * 1024)) ]; then
        size=$(echo "scale=2; $size/1024/1024/1024/1024" | bc)
        size="${size}T"
      elif [ "$size" -ge $((1024 * 1024 * 1024)) ]; then
        size=$(echo "scale=2; $size/1024/1024/1024" | bc)
        size="${size}G"
      elif [ "$size" -ge $((1024 * 1024)) ]; then
        size=$(echo "scale=2; $size/1024/1024" | bc)
        size="${size}M"
      elif [ "$size" -ge 1024 ]; then
        size=$(echo "scale=2; $size/1024" | bc)
        size="${size}K"
      else
        size="${size}B"
      fi
    else
      size="Unknown"
    fi

    echo -e "  ${COLOR_YELLOW}$i)${COLOR_RESET} $archive ${COLOR_CYAN}(Created: $date, Size: $size)${COLOR_RESET}"
    i=$((i + 1))
  done

  echo ""

  # Return the array of archive names
  echo "${archives[@]}"
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
      log "INFO" "Restoration canceled by user"
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
  if [ "$DOCKER_STOPPED" = true ]; then
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
  else
    log "INFO" "Docker was not stopped, no need to start it"
  fi

  return 0
}

# Function to ensure Docker is restarted on script exit or error
cleanup_on_exit() {
  local exit_code=$1

  log "INFO" "Running cleanup on exit"

  # If backup was successful, prompt for cleanup of the old backup
  if [ "$RESTORE_SUCCESS" = true ] && [ "$DOCKER_DIR_BACKED_UP" = true ] && [ "$KEEP_BACKUP" != true ]; then
    if [ -d "$BACKUP_DIR_NAME" ]; then
      log "INFO" "Restore was successful. Removing backup of previous Docker directory"
      rm -rf "$BACKUP_DIR_NAME"
      log "INFO" "Previous Docker directory backup removed"
    fi
  elif [ "$RESTORE_SUCCESS" != true ] && [ "$DOCKER_DIR_BACKED_UP" = true ]; then
    # Restore failed, offer to rollback to previous state
    if [ -d "$BACKUP_DIR_NAME" ] && [ -d "$DOCKER_DIR" ]; then
      log "WARNING" "Restore failed. Would you like to rollback to the previous Docker state?"
      if [ "$FORCE" != "true" ]; then
        read -p "$(echo -e "${COLOR_YELLOW}Rollback to previous Docker state? (y/n): ${COLOR_RESET}")" confirm
        if [ "$confirm" = "y" ]; then
          log "INFO" "Rolling back to previous Docker state"
          stop_docker
          rm -rf "$DOCKER_DIR"
          mv "$BACKUP_DIR_NAME" "$DOCKER_DIR"
          log "INFO" "Rollback completed"
          start_docker
        else
          log "INFO" "Rollback canceled by user"
        fi
      fi
    fi
  elif [ "$DOCKER_DIR_BACKED_UP" = true ] && [ "$KEEP_BACKUP" = true ]; then
    log "INFO" "Keeping backup of previous Docker directory as requested: $BACKUP_DIR_NAME"
    echo -e "${COLOR_YELLOW}Previous Docker directory was backed up to: $BACKUP_DIR_NAME${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}This backup has been kept as requested.${COLOR_RESET}"
  fi

  # Make sure Docker is running
  if [ "$DOCKER_STOPPED" = true ] && [ "$DOCKER_RESTARTED" != true ]; then
    start_docker
  fi

  # Cleanup lock file before exit
  if [ -f "$LOCK_FILE" ]; then
    rm -f "$LOCK_FILE"
    log "INFO" "Lock file released"
  fi

  log "INFO" "Cleanup completed"
}

# Backup the current Docker directory before restoring
backup_docker_dir() {
  if [ ! -d "$DOCKER_DIR" ]; then
    log "WARNING" "Docker directory $DOCKER_DIR does not exist, nothing to backup"
    mkdir -p "$DOCKER_DIR"
    chmod 755 "$DOCKER_DIR"
    return 0
  fi

  BACKUP_DIR_NAME="${DOCKER_DIR}.bak.$(date +%Y%m%d%H%M%S)"
  log "INFO" "Creating backup of current Docker directory to $BACKUP_DIR_NAME"

  if [ -d "$BACKUP_DIR_NAME" ]; then
    log "ERROR" "Backup directory $BACKUP_DIR_NAME already exists"
    echo -e "${COLOR_RED}ERROR: Backup directory $BACKUP_DIR_NAME already exists${COLOR_RESET}"
    cleanup_and_exit 1
  fi

  echo -e "${COLOR_CYAN}${COLOR_BOLD}Backing up current Docker directory...${COLOR_RESET}"

  # First check if there's enough space to make a backup
  local docker_size=$(du -sm "$DOCKER_DIR" 2>/dev/null | cut -f1)
  if [ -n "$docker_size" ] && [[ "$docker_size" =~ ^[0-9]+$ ]]; then
    local available_space=$(df -m "$(dirname "$DOCKER_DIR")" | awk 'NR==2 {print $4}')

    if [ -n "$available_space" ] && [[ "$available_space" =~ ^[0-9]+$ ]] && [ "$available_space" -lt "$docker_size" ]; then
      log "ERROR" "Not enough space to backup the current Docker directory"
      echo -e "${COLOR_RED}ERROR: Not enough space to backup the current Docker directory${COLOR_RESET}"
      echo -e "${COLOR_YELLOW}Required: $docker_size MB, Available: $available_space MB${COLOR_RESET}"
      cleanup_and_exit 1
    fi
  fi

  # Move the directory instead of copying to save time and space
  if ! mv "$DOCKER_DIR" "$BACKUP_DIR_NAME"; then
    log "ERROR" "Failed to backup Docker directory"
    echo -e "${COLOR_RED}ERROR: Failed to backup Docker directory${COLOR_RESET}"
    cleanup_and_exit 1
  fi

  # Create an empty Docker directory
  if ! mkdir -p "$DOCKER_DIR"; then
    log "ERROR" "Failed to create new Docker directory"
    echo -e "${COLOR_RED}ERROR: Failed to create new Docker directory${COLOR_RESET}"
    # Try to restore the original directory
    if [ -d "$BACKUP_DIR_NAME" ]; then
      log "INFO" "Attempting to restore from backup directory"
      if rm -rf "$DOCKER_DIR" && mv "$BACKUP_DIR_NAME" "$DOCKER_DIR"; then
        log "INFO" "Successfully restored original Docker directory"
      else
        log "ERROR" "Failed to restore original Docker directory. Manual intervention required."
        echo -e "${COLOR_RED}CRITICAL ERROR: Failed to restore original Docker directory.${COLOR_RESET}"
        echo -e "${COLOR_RED}Your Docker installation may be in an inconsistent state.${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}You may need to manually restore from: $BACKUP_DIR_NAME${COLOR_RESET}"
      fi
    fi
    cleanup_and_exit 1
  fi

  log "INFO" "Current Docker directory backed up successfully to $BACKUP_DIR_NAME"
  echo -e "${COLOR_GREEN}Current Docker directory backed up to: $BACKUP_DIR_NAME${COLOR_RESET}"
  DOCKER_DIR_BACKED_UP=true

  return 0
}

# Set Docker permissions correctly
set_docker_permissions() {
  log "INFO" "Setting proper permissions on Docker directory"

  # Check if directory exists first
  if [ ! -d "$DOCKER_DIR" ]; then
    log "ERROR" "Docker directory $DOCKER_DIR does not exist"
    echo -e "${COLOR_RED}ERROR: Docker directory $DOCKER_DIR does not exist${COLOR_RESET}"
    return 1
  fi

  # Set basic ownership
  chown -R root:root "$DOCKER_DIR"

  # Set specific permissions for Docker subdirectories
  if [ -d "$DOCKER_DIR/volumes" ]; then
    chmod 711 "$DOCKER_DIR/volumes"
    # Set recursive permissions for volume subdirectories
    find "$DOCKER_DIR/volumes" -type d -exec chmod 755 {} \;
  fi

  # Set permissions for configuration files
  if [ -d "$DOCKER_DIR/containers" ]; then
    chmod 710 "$DOCKER_DIR/containers"
    find "$DOCKER_DIR/containers" -type f -name "*.json" -exec chmod 640 {} \; 2>/dev/null || true
  fi

  log "INFO" "Docker permissions set successfully"
  return 0
}

# Verify Docker is working after restore
verify_docker_functionality() {
  log "INFO" "Verifying Docker functionality after restore"

  # Check if Docker info command works
  if ! docker info >/dev/null 2>&1; then
    log "ERROR" "Docker failed to start properly after restoration"
    echo -e "${COLOR_RED}ERROR: Docker failed to start properly after restoration${COLOR_RESET}"
    return 1
  fi

  # Try to run a simple container with timeout
  log "INFO" "Testing Docker by running hello-world container"
  if ! timeout 30 docker run --rm hello-world >/dev/null 2>&1; then
    # Try to get more information about the issue
    docker info

    log "WARNING" "Docker is running but failed to start a test container"
    echo -e "${COLOR_YELLOW}WARNING: Docker is running but failed to start a test container.${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}This could be due to network issues or registry problems.${COLOR_RESET}"

    # Check if there are any running containers
    if docker ps -q | grep -q .; then
      log "INFO" "However, Docker reports running containers, so it may be functional"
      echo -e "${COLOR_GREEN}However, Docker reports running containers, so it may be functional.${COLOR_RESET}"
      return 0
    else
      echo -e "${COLOR_YELLOW}Docker service is running but may not be fully functional.${COLOR_RESET}"
      echo -e "${COLOR_YELLOW}You should check Docker logs for errors.${COLOR_RESET}"
      return 1
    fi
  fi

  log "INFO" "Docker is functioning correctly after restore"
  echo -e "${COLOR_GREEN}Docker is functioning correctly after restore${COLOR_RESET}"
  return 0
}

# Validate an archive by checking its structure
validate_archive() {
  local archive="$1"
  log "INFO" "Validating archive structure: $archive"

  # Check if the archive exists
  if ! borg info "$BACKUP_DIR::$archive" >/dev/null 2>&1; then
    log "ERROR" "Archive $archive not found in repository"
    echo -e "${COLOR_RED}ERROR: Archive $archive not found in repository${COLOR_RESET}"
    return 1
  fi

  # Check archive integrity
  log "INFO" "Checking archive integrity"
  if ! borg check "$BACKUP_DIR::$archive" >/dev/null 2>&1; then
    log "ERROR" "Archive integrity check failed"
    echo -e "${COLOR_RED}ERROR: Archive integrity check failed${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}The archive may be corrupted or incomplete.${COLOR_RESET}"
    return 1
  fi

  # List archive contents to check for Docker directory structure
  log "INFO" "Checking if archive contains Docker data"
  local has_docker_data=false

  local contents=$(borg list --format="{path}{NL}" "$BACKUP_DIR::$archive" 2>/dev/null | grep -E '(docker|var/lib/docker)' || echo "")
  if [ -n "$contents" ]; then
    has_docker_data=true
  fi

  if [ "$has_docker_data" != "true" ]; then
    log "ERROR" "Archive does not appear to contain Docker data"
    echo -e "${COLOR_RED}ERROR: Archive does not appear to contain Docker data${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}This archive may not be suitable for Docker restoration.${COLOR_RESET}"

    if [ "$FORCE" != "true" ]; then
      read -p "$(echo -e "${COLOR_YELLOW}Continue with restoration anyway? (y/n): ${COLOR_RESET}")" confirm
      if [ "$confirm" != "y" ]; then
        log "INFO" "Restoration canceled by user"
        return 1
      fi
    else
      log "WARNING" "Continuing despite archive validation concerns due to force flag"
    fi
  else
    log "INFO" "Archive appears to contain valid Docker data"
  fi

  return 0
}

# Restore an archive with improved path handling
restore_archive() {
  local archive="$1"
  local start_time=$(date +%s)

  log "INFO" "Starting restoration of archive $archive"

  # Validate the archive first
  if ! validate_archive "$archive"; then
    return 1
  fi

  # Check disk space
  check_disk_space "$archive"

  # Stop Docker service
  stop_docker

  # Backup current Docker directory
  backup_docker_dir

  # Extract the archive with improved path handling
  log "INFO" "Extracting archive $archive to $DOCKER_DIR"
  echo -e "${COLOR_CYAN}${COLOR_BOLD}Extracting backup archive... This may take some time.${COLOR_RESET}"

  # First, determine the archive structure by examining the paths
  log "INFO" "Determining archive structure"
  local archive_contents=$(borg list --format="{path}{NL}" "$BACKUP_DIR::$archive" 2>/dev/null | head -n 100)

  # Create a temporary extraction directory
  local temp_extract_dir=$(mktemp -d)
  log "INFO" "Created temporary extraction directory: $temp_extract_dir"

  # Find a small file/directory to test the extraction structure
  local test_path=$(echo "$archive_contents" | grep -m1 -E '(var/lib/docker|docker)' || echo "")

  if [ -z "$test_path" ]; then
    log "ERROR" "Failed to find any Docker-related paths in the archive"
    echo -e "${COLOR_RED}ERROR: Failed to find any Docker-related paths in the archive${COLOR_RESET}"
    rmdir "$temp_extract_dir"
    start_docker
    cleanup_and_exit 1
  fi

  # Try to extract the test path to determine the structure
  log "INFO" "Testing extraction of a small part of the archive to determine structure"
  if ! borg extract --stdout "$BACKUP_DIR::$archive" "$test_path" >/dev/null 2>&1; then
    log "WARNING" "Failed to extract test path. Will try alternative extraction methods."
  fi

  # Determine the extraction method based on path structure
  local extraction_method=""
  if echo "$archive_contents" | grep -q "^var/lib/docker"; then
    # Archive contains paths with leading directories
    log "INFO" "Archive contains absolute paths. Will extract from root directory."
    extraction_method="absolute"
  elif echo "$archive_contents" | grep -q "^docker"; then
    # Archive contains paths with leading 'docker' directory
    log "INFO" "Archive contains relative paths starting with 'docker'. Will strip components."
    extraction_method="strip_docker"
  else
    # Assume direct docker directory structure
    log "INFO" "Archive appears to contain direct Docker directory structure."
    extraction_method="direct"
  fi

  # Clean up the temporary directory
  rmdir "$temp_extract_dir"

  # Perform the extraction based on the determined method
  local extraction_success=false

  case "$extraction_method" in
  "absolute")
    log "INFO" "Extracting with absolute paths from root directory"
    cd /
    if borg extract --progress "$BACKUP_DIR::$archive" "var/lib/docker"; then
      extraction_success=true
    fi
    ;;

  "strip_docker")
    log "INFO" "Extracting with strip components for 'docker' prefix"
    if borg extract --progress --strip-components 1 "$BACKUP_DIR::$archive" "docker" --target-dir "$DOCKER_DIR"; then
      extraction_success=true
    fi
    ;;

  "direct")
    log "INFO" "Extracting directly to Docker directory"
    if borg extract --progress "$BACKUP_DIR::$archive" --target-dir "$DOCKER_DIR"; then
      extraction_success=true
    fi
    ;;
  esac

  if [ "$extraction_success" != "true" ]; then
    log "ERROR" "All extraction methods failed"
    echo -e "${COLOR_RED}ERROR: Failed to extract archive${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}Trying emergency fallback extraction...${COLOR_RESET}"

    # Last resort: try extracting everything and then manually fixing paths
    local emergency_temp=$(mktemp -d)

    if borg extract --progress "$BACKUP_DIR::$archive" --target-dir "$emergency_temp"; then
      log "INFO" "Emergency extraction succeeded. Looking for Docker data..."

      # Look for Docker data in various possible locations
      if [ -d "$emergency_temp/var/lib/docker" ]; then
        log "INFO" "Found Docker data at var/lib/docker, moving to target location"
        rm -rf "$DOCKER_DIR"
        mv "$emergency_temp/var/lib/docker" "$DOCKER_DIR"
        extraction_success=true
      elif [ -d "$emergency_temp/docker" ]; then
        log "INFO" "Found Docker data at docker, moving to target location"
        rm -rf "$DOCKER_DIR"
        mv "$emergency_temp/docker" "$DOCKER_DIR"
        extraction_success=true
      elif find "$emergency_temp" -name "volumes" -o -name "containers" | grep -q .; then
        # Found typical Docker subdirectories somewhere
        log "INFO" "Found Docker subdirectories, copying to target location"
        mkdir -p "$DOCKER_DIR"

        # Copy found Docker subdirectories
        find "$emergency_temp" -name "volumes" -o -name "containers" -o -name "image" -o -name "network" |
          while read dir; do
            cp -a "$dir" "$DOCKER_DIR/"
            log "INFO" "Copied $dir to $DOCKER_DIR/"
          done

        extraction_success=true
      fi
    fi

    # Clean up emergency temp directory
    rm -rf "$emergency_temp"

    if [ "$extraction_success" != "true" ]; then
      log "ERROR" "All extraction methods including emergency fallback failed"
      echo -e "${COLOR_RED}ERROR: Failed to extract archive${COLOR_RESET}"
      start_docker
      cleanup_and_exit 1
    fi
  fi

  local end_time=$(date +%s)
  local duration=$((end_time - start_time))

  log "INFO" "Archive extracted successfully in $duration seconds"

  # Set proper permissions on Docker directory
  set_docker_permissions
  if [ $? -ne 0 ]; then
    log "WARNING" "Failed to set permissions correctly"
    echo -e "${COLOR_YELLOW}WARNING: Failed to set permissions correctly${COLOR_RESET}"
  fi

  # Start Docker service
  start_docker

  # Verify Docker is running properly
  log "INFO" "Verifying Docker restored correctly"
  if verify_docker_functionality; then
    log "INFO" "Restore operation completed successfully"
    echo -e "${COLOR_GREEN}${COLOR_BOLD}Restore completed successfully!${COLOR_RESET}"
    RESTORE_SUCCESS=true

    if [ "$KEEP_BACKUP" = true ]; then
      echo -e "${COLOR_CYAN}Your previous Docker directory was backed up to: $BACKUP_DIR_NAME${COLOR_RESET}"
    else
      echo -e "${COLOR_CYAN}Your previous Docker directory backup will be removed automatically${COLOR_RESET}"
    fi

    return 0
  else
    log "ERROR" "Docker is not functioning correctly after restore"
    echo -e "${COLOR_RED}ERROR: Docker is not functioning correctly after restore${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}You may need to restore from a different backup or check Docker logs${COLOR_RESET}"
    return 1
  fi
}

# Function to display a nice header
display_header() {
  echo -e "${COLOR_CYAN}${COLOR_BOLD}"
  echo "======================================================="
  echo "        Docker Volume Tools - Restore"
  echo "======================================================="
  echo -e "${COLOR_RESET}"
}

# Main function
main() {
  display_header

  log "INFO" "Starting Docker full restore process"

  # Obtain lock to prevent multiple instances running
  obtain_lock

  # Check prerequisites
  check_borg_installation
  check_repository

  # Determine which archive to restore
  local archive_to_restore=""

  if [ ! -z "$ARCHIVE_ARG" ]; then
    # Archive specified as argument
    archive_to_restore="$ARCHIVE_ARG"
    log "INFO" "Using specified archive: $archive_to_restore"

    # Check if the archive exists
    if ! borg info "$BACKUP_DIR::$archive_to_restore" >/dev/null 2>&1; then
      log "ERROR" "Specified archive not found: $archive_to_restore"
      echo -e "${COLOR_RED}ERROR: Archive $archive_to_restore not found in repository${COLOR_RESET}"
      cleanup_and_exit 1
    fi
  else
    # Show menu of available archives
    local ARCHIVES_STRING=$(show_archives)
    if [ -z "$ARCHIVES_STRING" ]; then
      log "ERROR" "Failed to get archives list"
      echo -e "${COLOR_RED}ERROR: Failed to get archives list${COLOR_RESET}"
      cleanup_and_exit 1
    fi

    readarray -t ARCHIVES <<<"$ARCHIVES_STRING"

    # Ask user to select an archive
    read -p "$(echo -e "${COLOR_YELLOW}Select archive to restore (1-${#ARCHIVES[@]}, 0 to exit): ${COLOR_RESET}")" choice

    if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
      log "ERROR" "Invalid selection: not a number"
      echo -e "${COLOR_RED}ERROR: Invalid selection. Please enter a number.${COLOR_RESET}"
      cleanup_and_exit 1
    fi

    if [ "$choice" -eq 0 ]; then
      log "INFO" "Restore canceled by user"
      echo -e "${COLOR_GREEN}Restore canceled.${COLOR_RESET}"
      cleanup_and_exit 0
    fi

    if [ "$choice" -lt 1 ] || [ "$choice" -gt "${#ARCHIVES[@]}" ]; then
      log "ERROR" "Invalid selection: $choice"
      echo -e "${COLOR_RED}ERROR: Invalid selection${COLOR_RESET}"
      cleanup_and_exit 1
    fi

    archive_to_restore="${ARCHIVES[$((choice - 1))]}"
    log "INFO" "Selected archive: $archive_to_restore"
  fi

  # Confirm restoration
  if [ "$FORCE" != "true" ]; then
    echo -e "${COLOR_YELLOW}${COLOR_BOLD}WARNING: This will replace your entire Docker installation!${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}Your current Docker directory will be backed up to ${DOCKER_DIR}.bak.*${COLOR_RESET}"
    read -p "$(echo -e "${COLOR_YELLOW}Are you absolutely sure you want to continue? (yes/no): ${COLOR_RESET}")" confirm
    if [ "$confirm" != "yes" ]; then
      log "INFO" "Restore canceled by user"
      echo -e "${COLOR_GREEN}Restore canceled.${COLOR_RESET}"
      cleanup_and_exit 0
    fi
  fi

  # Perform the restoration
  restore_archive "$archive_to_restore"
  local restore_status=$?

  # Cleanup based on the restore result
  cleanup_on_exit $restore_status
  exit $restore_status
}

# Register trap for cleanup
trap 'handle_signal' INT TERM

# Ensure log directory exists
ensure_log_directory

# Run the main function
main
