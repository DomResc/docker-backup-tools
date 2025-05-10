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

# Flag to track if we stopped docker
DOCKER_STOPPED=false

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
  echo -e "  ${COLOR_GREEN}-h, --help${COLOR_RESET}           Display this help message"
  echo ""
  echo -e "${COLOR_CYAN}Environment variables:${COLOR_RESET}"
  echo -e "  ${COLOR_GREEN}DOCKER_BACKUP_DIR${COLOR_RESET}    Same as --directory"
  exit 1
}

# Get settings from environment variables or use defaults
BACKUP_DIR=${DOCKER_BACKUP_DIR:-$DEFAULT_BACKUP_DIR}
FORCE=false
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

    # Verifica se lo script di installazione è disponibile
    local install_script="/usr/local/bin/docker_install.sh"
    local repo_install_script="./docker_install.sh"

    if [ -f "$install_script" ]; then
      echo -e "${COLOR_YELLOW}Would you like to run the installation script? ($install_script)${COLOR_RESET}"
      if [ "$FORCE" != "true" ]; then
        read -p "$(echo -e "${COLOR_YELLOW}Run installation script? (y/n): ${COLOR_RESET}")" run_install
        if [ "$run_install" == "y" ]; then
          log "INFO" "Running installation script"
          "$install_script"

          # Verifica se l'installazione ha avuto successo
          if ! command_exists borg; then
            log "ERROR" "Installation failed. Borg is still not available."
            exit 1
          else
            log "INFO" "Borg installed successfully"
            return 0
          fi
        else
          log "INFO" "Restoration canceled because Borg is not installed"
          exit 1
        fi
      else
        exit 1
      fi
    elif [ -f "$repo_install_script" ]; then
      echo -e "${COLOR_YELLOW}Would you like to run the installation script? ($repo_install_script)${COLOR_RESET}"
      if [ "$FORCE" != "true" ]; then
        read -p "$(echo -e "${COLOR_YELLOW}Run installation script? (y/n): ${COLOR_RESET}")" run_install
        if [ "$run_install" == "y" ]; then
          log "INFO" "Running installation script"
          "$repo_install_script"

          # Verifica se l'installazione ha avuto successo
          if ! command_exists borg; then
            log "ERROR" "Installation failed. Borg is still not available."
            exit 1
          else
            log "INFO" "Borg installed successfully"
            return 0
          fi
        else
          log "INFO" "Restoration canceled because Borg is not installed"
          exit 1
        fi
      else
        exit 1
      fi
    else
      echo -e "${COLOR_RED}Installation script not found.${COLOR_RESET}"
      echo -e "${COLOR_YELLOW}Please install Docker Volume Tools first with:${COLOR_RESET}"
      echo -e "${COLOR_CYAN}git clone https://github.com/domresc/docker-volume-tools.git${COLOR_RESET}"
      echo -e "${COLOR_CYAN}cd docker-volume-tools${COLOR_RESET}"
      echo -e "${COLOR_CYAN}sudo bash docker_install.sh${COLOR_RESET}"
      exit 1
    fi
  fi

  log "INFO" "Borg Backup is installed"

  # Check borg version
  local borg_version=$(borg --version | cut -d' ' -f2)
  log "INFO" "Borg version: $borg_version"

  return 0
}

# Check if the repository exists
check_repository() {
  if ! [ -d "$BACKUP_DIR" ]; then
    log "ERROR" "Backup directory $BACKUP_DIR does not exist"
    echo -e "${COLOR_RED}ERROR: Backup directory $BACKUP_DIR does not exist${COLOR_RESET}"
    exit 1
  fi

  # Check if it's a valid borg repository
  if ! borg info "$BACKUP_DIR" >/dev/null 2>&1; then
    log "ERROR" "Directory $BACKUP_DIR is not a valid Borg repository"
    echo -e "${COLOR_RED}ERROR: Directory $BACKUP_DIR is not a valid Borg repository${COLOR_RESET}"
    exit 1
  fi

  log "INFO" "Valid Borg repository found at $BACKUP_DIR"
}

# Check disk space for restoration
check_disk_space() {
  local archive="$1"
  log "INFO" "Checking disk space for restoration"

  # Get archive info
  local archive_info=$(borg info --json "$BACKUP_DIR::$archive" 2>/dev/null)
  local archive_size=$(echo "$archive_info" | grep -o '"original_size": [0-9]*' | cut -d' ' -f2)

  if [ -z "$archive_size" ]; then
    log "WARNING" "Could not determine archive size. Make sure you have sufficient disk space."
    return 0
  fi

  # Add 10% overhead
  local needed_space=$((archive_size + (archive_size / 10)))
  needed_space=$((needed_space / 1024 / 1024)) # Convert to MB

  # Get available space in /var/lib
  local available_space=$(df -m "$(dirname "$DOCKER_DIR")" | awk 'NR==2 {print $4}')

  log "INFO" "Archive size: $((archive_size / 1024 / 1024)) MB"
  log "INFO" "Estimated space needed: $needed_space MB"
  log "INFO" "Available space: $available_space MB"

  if [ "$available_space" -lt "$needed_space" ]; then
    log "WARNING" "Available space ($available_space MB) might be insufficient for restoration ($needed_space MB)"

    if [ "$FORCE" != "true" ]; then
      read -p "$(echo -e "${COLOR_YELLOW}Available space may be insufficient. Continue anyway? (y/n): ${COLOR_RESET}")" confirm
      if [ "$confirm" != "y" ]; then
        log "INFO" "Restoration canceled by user due to space concerns"
        exit 0
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
  local archives=($(borg list --short "$BACKUP_DIR"))

  if [ ${#archives[@]} -eq 0 ]; then
    log "ERROR" "No archives found in repository"
    echo -e "${COLOR_RED}No archives found in repository $BACKUP_DIR${COLOR_RESET}"
    exit 1
  fi

  # Print archives with numbers
  local i=1
  for archive in "${archives[@]}"; do
    local info=$(borg info --json "$BACKUP_DIR::$archive" 2>/dev/null)
    local date=$(echo "$info" | grep -o '"time": "[^"]*"' | cut -d'"' -f4 | cut -d'.' -f1 | sed 's/T/ /')
    local size=$(echo "$info" | grep -o '"original_size": [0-9]*' | cut -d' ' -f2)

    # Convert size to human-readable format
    if [ "$size" -ge $((1024 * 1024 * 1024)) ]; then
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

    echo -e "  ${COLOR_YELLOW}$i)${COLOR_RESET} $archive ${COLOR_CYAN}(Created: $date, Size: $size)${COLOR_RESET}"
    i=$((i + 1))
  done

  echo ""

  # Return the array of archive names
  echo "${archives[@]}"
}

# Manage Docker service (start/stop) with compatibility for different init systems
manage_docker_service() {
  local action="$1" # 'start' or 'stop'

  # Verify which init system is in use
  if command -v systemctl >/dev/null 2>&1 && systemctl --version >/dev/null 2>&1; then
    # systemd
    log "INFO" "Using systemd to $action Docker"
    if [ "$action" = "stop" ]; then
      systemctl $action $DOCKER_SOCKET
      systemctl $action $DOCKER_SERVICE
    else
      systemctl $action $DOCKER_SERVICE
      systemctl $action $DOCKER_SOCKET
    fi
  elif command -v service >/dev/null 2>&1; then
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
      log "INFO" "Using killall to stop Docker"
      killall -TERM dockerd
    else
      log "INFO" "Starting Docker daemon directly"
      dockerd &
    fi
  fi

  # Verify the operation status
  local max_wait=30
  local counter=0
  local expected_status=$([[ "$action" = "start" ]] && echo "running" || echo "stopped")

  while true; do
    sleep 1
    counter=$((counter + 1))

    if docker info >/dev/null 2>&1; then
      local current_status="running"
    else
      local current_status="stopped"
    fi

    if [ "$current_status" = "$expected_status" ]; then
      break
    fi

    if [ $counter -ge $max_wait ]; then
      log "ERROR" "Failed to $action Docker service within $max_wait seconds"
      echo -e "${COLOR_RED}ERROR: Failed to $action Docker service${COLOR_RESET}"
      return 1
    fi
  done

  log "INFO" "Docker service $action successfully"
  return 0
}

# Stop Docker service
stop_docker() {
  log "INFO" "Stopping Docker service"

  # Check if Docker is running
  if ! docker info >/dev/null 2>&1; then
    log "INFO" "Docker service is already stopped"
    return 0
  fi

  if [ "$FORCE" != "true" ]; then
    echo -e "${COLOR_YELLOW}WARNING: This will stop all Docker containers and the Docker service.${COLOR_RESET}"
    read -p "$(echo -e "${COLOR_YELLOW}Are you sure you want to continue? (y/n): ${COLOR_RESET}")" confirm
    if [ "$confirm" != "y" ]; then
      log "INFO" "Restoration canceled by user"
      exit 0
    fi
  fi

  log "INFO" "Stopping Docker service now"
  manage_docker_service stop
  local stop_result=$?

  if [ $stop_result -eq 0 ]; then
    DOCKER_STOPPED=true
  else
    echo -e "${COLOR_RED}ERROR: Failed to stop Docker service${COLOR_RESET}"
    exit 1
  fi
}

# Start Docker service
start_docker() {
  if [ "$DOCKER_STOPPED" = true ]; then
    log "INFO" "Starting Docker service"
    manage_docker_service start
    local start_result=$?

    if [ $start_result -ne 0 ]; then
      log "ERROR" "Failed to start Docker service"
      echo -e "${COLOR_RED}ERROR: Failed to start Docker service${COLOR_RESET}"
      echo -e "${COLOR_YELLOW}You may need to start it manually with: sudo systemctl start $DOCKER_SERVICE${COLOR_RESET}"
      return 1
    fi
  else
    log "INFO" "Docker was not stopped, no need to start it"
  fi

  return 0
}

# Function to ensure Docker is restarted on script exit or error
cleanup_on_exit() {
  log "INFO" "Running cleanup on exit"

  # Make sure Docker is running
  start_docker

  log "INFO" "Cleanup completed"
}

# Backup the current Docker directory before restoring
backup_docker_dir() {
  if [ ! -d "$DOCKER_DIR" ]; then
    log "WARNING" "Docker directory $DOCKER_DIR does not exist, nothing to backup"
    return 0
  fi

  local backup_dir="${DOCKER_DIR}.bak.$(date +%Y%m%d%H%M%S)"
  log "INFO" "Creating backup of current Docker directory to $backup_dir"

  if [ -d "$backup_dir" ]; then
    log "ERROR" "Backup directory $backup_dir already exists"
    echo -e "${COLOR_RED}ERROR: Backup directory $backup_dir already exists${COLOR_RESET}"
    exit 1
  fi

  echo -e "${COLOR_CYAN}${COLOR_BOLD}Backing up current Docker directory...${COLOR_RESET}"

  if ! mv "$DOCKER_DIR" "$backup_dir"; then
    log "ERROR" "Failed to backup Docker directory"
    echo -e "${COLOR_RED}ERROR: Failed to backup Docker directory${COLOR_RESET}"
    exit 1
  fi

  # Create an empty Docker directory
  if ! mkdir -p "$DOCKER_DIR"; then
    log "ERROR" "Failed to create new Docker directory"
    echo -e "${COLOR_RED}ERROR: Failed to create new Docker directory${COLOR_RESET}"
    # Try to restore the original directory
    mv "$backup_dir" "$DOCKER_DIR"
    exit 1
  fi

  log "INFO" "Current Docker directory backed up successfully to $backup_dir"
  echo -e "${COLOR_GREEN}Current Docker directory backed up to: $backup_dir${COLOR_RESET}"

  return 0
}

# Set Docker permissions correctly
set_docker_permissions() {
  log "INFO" "Setting proper permissions on Docker directory"

  # Imposta proprietà di base
  chown -R root:root "$DOCKER_DIR"

  # Imposta permessi specifici per sottodirectory Docker
  if [ -d "$DOCKER_DIR/volumes" ]; then
    chmod 711 "$DOCKER_DIR/volumes"
    # Imposta permessi ricorsivi per le sottodirectory dei volumi
    find "$DOCKER_DIR/volumes" -type d -exec chmod 755 {} \;
  fi

  # Imposta permessi per i file di configurazione
  if [ -d "$DOCKER_DIR/containers" ]; then
    chmod 710 "$DOCKER_DIR/containers"
    find "$DOCKER_DIR/containers" -type f -name "*.json" -exec chmod 640 {} \;
  fi

  log "INFO" "Docker permissions set successfully"
}

# Restore an archive
restore_archive() {
  local archive="$1"
  local start_time=$(date +%s)

  log "INFO" "Starting restoration of archive $archive"

  # Verify the archive exists
  if ! borg info "$BACKUP_DIR::$archive" >/dev/null 2>&1; then
    log "ERROR" "Archive $archive not found in repository"
    echo -e "${COLOR_RED}ERROR: Archive $archive not found in repository${COLOR_RESET}"
    exit 1
  fi

  # Check disk space
  check_disk_space "$archive"

  # Stop Docker service
  stop_docker

  # Backup current Docker directory
  backup_docker_dir

  # Extract the archive - FIXED: specifying correct extraction path and strategy
  log "INFO" "Extracting archive $archive to $DOCKER_DIR"
  echo -e "${COLOR_CYAN}${COLOR_BOLD}Extracting backup archive... This may take some time.${COLOR_RESET}"

  # Cambia directory alla radice e limita l'estrazione a /var/lib/docker
  cd /
  if ! borg extract --progress "$BACKUP_DIR::$archive" var/lib/docker; then
    log "ERROR" "Failed to extract archive"
    echo -e "${COLOR_RED}ERROR: Failed to extract archive${COLOR_RESET}"
    start_docker
    exit 1
  fi

  local end_time=$(date +%s)
  local duration=$((end_time - start_time))

  log "INFO" "Archive extracted successfully in $duration seconds"

  # Set proper permissions on Docker directory
  set_docker_permissions

  # Start Docker service
  start_docker

  # Verify Docker is running properly
  log "INFO" "Verifying Docker restored correctly"
  if ! docker info >/dev/null 2>&1; then
    log "ERROR" "Docker failed to start properly after restoration"
    echo -e "${COLOR_RED}ERROR: Docker failed to start properly after restoration${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}You may need to restore from a different backup or check Docker logs${COLOR_RESET}"
    return 1
  fi

  log "INFO" "Restore operation completed successfully"
  echo -e "${COLOR_GREEN}${COLOR_BOLD}Restore completed successfully!${COLOR_RESET}"
  echo -e "${COLOR_CYAN}Your previous Docker directory was backed up to: ${DOCKER_DIR}.bak.*${COLOR_RESET}"

  return 0
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

  # Check prerequisites
  check_borg_installation
  check_repository

  # Determine which archive to restore
  local archive_to_restore=""

  if [ ! -z "$ARCHIVE_ARG" ]; then
    # Archive specified as argument
    archive_to_restore="$ARCHIVE_ARG"
    log "INFO" "Using specified archive: $archive_to_restore"
  else
    # Show menu of available archives
    read -ra ARCHIVES <<<$(show_archives)

    # Ask user to select an archive
    read -p "$(echo -e "${COLOR_YELLOW}Select archive to restore (1-${#ARCHIVES[@]}, 0 to exit): ${COLOR_RESET}")" choice

    if [ "$choice" -eq 0 ]; then
      log "INFO" "Restore canceled by user"
      echo -e "${COLOR_GREEN}Restore canceled.${COLOR_RESET}"
      exit 0
    fi

    if [ "$choice" -lt 1 ] || [ "$choice" -gt "${#ARCHIVES[@]}" ]; then
      log "ERROR" "Invalid selection: $choice"
      echo -e "${COLOR_RED}ERROR: Invalid selection${COLOR_RESET}"
      exit 1
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
      exit 0
    fi
  fi

  # Perform the restoration
  restore_archive "$archive_to_restore"

  return 0
}

# Register trap for cleanup
trap cleanup_on_exit EXIT INT TERM

# Ensure log directory exists
ensure_log_directory

# Run the main function
main
exit $?
