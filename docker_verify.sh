#!/bin/bash
# Docker Volume Tools - A utility for verifying Docker backups with Borg
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
DEFAULT_BACKUP_DIR="/backup/docker"
LOG_DIR="/var/log/docker"
LOG_FILE="${LOG_DIR}/verify.log"

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

# Parse command line arguments
usage() {
  echo -e "${COLOR_CYAN}Usage: $0 [OPTIONS] [ARCHIVE]${COLOR_RESET}"
  echo -e "${COLOR_CYAN}Verify Docker backup archives${COLOR_RESET}"
  echo ""
  echo -e "${COLOR_CYAN}Arguments:${COLOR_RESET}"
  echo -e "  ${COLOR_GREEN}ARCHIVE${COLOR_RESET}              Optional: specific archive to verify (if omitted, will verify repository integrity)"
  echo ""
  echo -e "${COLOR_CYAN}Options:${COLOR_RESET}"
  echo -e "  ${COLOR_GREEN}-d, --directory DIR${COLOR_RESET}  Backup directory (default: $DEFAULT_BACKUP_DIR)"
  echo -e "  ${COLOR_GREEN}-a, --all${COLOR_RESET}            Verify all archives individually"
  echo -e "  ${COLOR_GREEN}-l, --list${COLOR_RESET}           List available archives"
  echo -e "  ${COLOR_GREEN}-q, --quiet${COLOR_RESET}          Only output errors"
  echo -e "  ${COLOR_GREEN}-h, --help${COLOR_RESET}           Display this help message"
  echo ""
  echo -e "${COLOR_CYAN}Environment variables:${COLOR_RESET}"
  echo -e "  ${COLOR_GREEN}DOCKER_BACKUP_DIR${COLOR_RESET}    Same as --directory"
  exit 1
}

# Get settings from environment variables or use defaults
BACKUP_DIR=${DOCKER_BACKUP_DIR:-$DEFAULT_BACKUP_DIR}
ARCHIVE_ARG=""
VERIFY_ALL=false
LIST_ONLY=false
QUIET_MODE=false

# Parse command line options
while [[ $# -gt 0 ]]; do
  case $1 in
  -d | --directory)
    BACKUP_DIR="$2"
    shift 2
    ;;
  -a | --all)
    VERIFY_ALL=true
    shift
    ;;
  -l | --list)
    LIST_ONLY=true
    shift
    ;;
  -q | --quiet)
    QUIET_MODE=true
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

  # Skip non-error messages in quiet mode
  if [ "$QUIET_MODE" = true ] && [ "$level" != "ERROR" ]; then
    # Still log to file
    echo "[$timestamp] [$level] $message" >>"$LOG_FILE"
    return
  fi

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
    exit 1
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

# Get list of all archives
get_archives() {
  borg list --short "$BACKUP_DIR"
}

# List archives with details
list_archives() {
  log "INFO" "Listing available archives"

  echo -e "${COLOR_CYAN}${COLOR_BOLD}Available backup archives:${COLOR_RESET}"
  echo -e "${COLOR_CYAN}------------------------------------------------------${COLOR_RESET}"

  # Get list of archives
  local archives=($(get_archives))

  if [ ${#archives[@]} -eq 0 ]; then
    log "ERROR" "No archives found in repository"
    echo -e "${COLOR_RED}No archives found in repository $BACKUP_DIR${COLOR_RESET}"
    exit 1
  fi

  # Print archives with details
  for archive in "${archives[@]}"; do
    local info=$(borg info --json "$BACKUP_DIR::$archive" 2>/dev/null)
    local date=$(echo "$info" | grep -o '"time": "[^"]*"' | cut -d'"' -f4 | cut -d'.' -f1 | sed 's/T/ /')
    local size=$(echo "$info" | grep -o '"original_size": [0-9]*' | cut -d' ' -f2)
    local compressed_size=$(echo "$info" | grep -o '"compressed_size": [0-9]*' | cut -d' ' -f2)

    # Convert sizes to human-readable format
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

    if [ "$compressed_size" -ge $((1024 * 1024 * 1024)) ]; then
      compressed_size=$(echo "scale=2; $compressed_size/1024/1024/1024" | bc)
      compressed_size="${compressed_size}G"
    elif [ "$compressed_size" -ge $((1024 * 1024)) ]; then
      compressed_size=$(echo "scale=2; $compressed_size/1024/1024" | bc)
      compressed_size="${compressed_size}M"
    elif [ "$compressed_size" -ge 1024 ]; then
      compressed_size=$(echo "scale=2; $compressed_size/1024" | bc)
      compressed_size="${compressed_size}K"
    else
      compressed_size="${compressed_size}B"
    fi

    echo -e "  ${COLOR_YELLOW}*${COLOR_RESET} ${COLOR_GREEN}$archive${COLOR_RESET}"
    echo -e "    ${COLOR_BLUE}Created:${COLOR_RESET} $date"
    echo -e "    ${COLOR_BLUE}Size:${COLOR_RESET} $size (Compressed: $compressed_size)"
  done

  echo ""
  log "INFO" "Total archives: ${#archives[@]}"
}

# Verify repository integrity
verify_repository() {
  log "INFO" "Verifying repository integrity"
  echo -e "${COLOR_CYAN}${COLOR_BOLD}Verifying repository integrity...${COLOR_RESET}"

  local start_time=$(date +%s)
  borg check --repository-only --progress "$BACKUP_DIR"
  local check_result=$?
  local end_time=$(date +%s)
  local duration=$((end_time - start_time))

  if [ $check_result -eq 0 ]; then
    log "INFO" "Repository integrity check completed successfully in $duration seconds"
    echo -e "${COLOR_GREEN}${COLOR_BOLD}Repository integrity check passed!${COLOR_RESET}"
    return 0
  else
    log "ERROR" "Repository integrity check failed with exit code $check_result"
    echo -e "${COLOR_RED}${COLOR_BOLD}Repository integrity check failed!${COLOR_RESET}"
    return $check_result
  fi
}

# Verify a specific archive
verify_archive() {
  local archive="$1"
  log "INFO" "Verifying archive $archive"
  echo -e "${COLOR_CYAN}${COLOR_BOLD}Verifying archive: $archive${COLOR_RESET}"

  # Verify the archive exists
  if ! borg info "$BACKUP_DIR::$archive" >/dev/null 2>&1; then
    log "ERROR" "Archive $archive not found in repository"
    echo -e "${COLOR_RED}ERROR: Archive $archive not found in repository${COLOR_RESET}"
    return 1
  fi

  local start_time=$(date +%s)
  borg check --progress "$BACKUP_DIR::$archive"
  local check_result=$?
  local end_time=$(date +%s)
  local duration=$((end_time - start_time))

  if [ $check_result -eq 0 ]; then
    log "INFO" "Archive $archive verified successfully in $duration seconds"
    echo -e "${COLOR_GREEN}${COLOR_BOLD}Archive $archive integrity check passed!${COLOR_RESET}"
    return 0
  else
    log "ERROR" "Archive $archive verification failed with exit code $check_result"
    echo -e "${COLOR_RED}${COLOR_BOLD}Archive $archive integrity check failed!${COLOR_RESET}"
    return $check_result
  fi
}

# Verify all archives
verify_all_archives() {
  log "INFO" "Verifying all archives"
  echo -e "${COLOR_CYAN}${COLOR_BOLD}Verifying all archives in repository...${COLOR_RESET}"

  # Get list of archives
  local archives=($(get_archives))

  if [ ${#archives[@]} -eq 0 ]; then
    log "ERROR" "No archives found in repository"
    echo -e "${COLOR_RED}No archives found in repository $BACKUP_DIR${COLOR_RESET}"
    return 1
  fi

  local total=${#archives[@]}
  local passed=0
  local failed=0
  local failed_archives=()

  # Verify each archive
  local i=1
  for archive in "${archives[@]}"; do
    echo -e "\n${COLOR_CYAN}${COLOR_BOLD}[$i/$total] Verifying archive: $archive${COLOR_RESET}"

    local start_time=$(date +%s)
    borg check --progress "$BACKUP_DIR::$archive"
    local check_result=$?
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    if [ $check_result -eq 0 ]; then
      log "INFO" "Archive $archive verified successfully in $duration seconds"
      echo -e "${COLOR_GREEN}Archive $archive integrity check passed!${COLOR_RESET}"
      passed=$((passed + 1))
    else
      log "ERROR" "Archive $archive verification failed with exit code $check_result"
      echo -e "${COLOR_RED}Archive $archive integrity check failed!${COLOR_RESET}"
      failed=$((failed + 1))
      failed_archives+=("$archive")
    fi

    i=$((i + 1))
  done

  # Show summary
  echo -e "\n${COLOR_CYAN}${COLOR_BOLD}Verification Summary:${COLOR_RESET}"
  echo -e "${COLOR_CYAN}------------------------------------------------------${COLOR_RESET}"
  log "INFO" "Total archives: $total, Passed: $passed, Failed: $failed"
  echo -e "${COLOR_BLUE}Total archives:${COLOR_RESET} $total"
  echo -e "${COLOR_GREEN}Passed:${COLOR_RESET} $passed"
  echo -e "${COLOR_RED}Failed:${COLOR_RESET} $failed"

  if [ $failed -gt 0 ]; then
    echo -e "\n${COLOR_RED}${COLOR_BOLD}Failed archives:${COLOR_RESET}"
    for archive in "${failed_archives[@]}"; do
      echo -e "  ${COLOR_RED}*${COLOR_RESET} $archive"
    done
    return 1
  fi

  return 0
}

# Function to display a nice header
display_header() {
  echo -e "${COLOR_CYAN}${COLOR_BOLD}"
  echo "======================================================="
  echo "        Docker Volume Tools - Verify"
  echo "======================================================="
  echo -e "${COLOR_RESET}"
}

# Main function
main() {
  display_header

  log "INFO" "Starting Docker backup verification process"

  # Check prerequisites
  check_borg_installation
  check_repository

  # If list only, just show archives and exit
  if [ "$LIST_ONLY" = true ]; then
    list_archives
    exit 0
  fi

  # Determine what to verify
  if [ ! -z "$ARCHIVE_ARG" ]; then
    # Verify specific archive
    verify_archive "$ARCHIVE_ARG"
    exit $?
  elif [ "$VERIFY_ALL" = true ]; then
    # Verify all archives
    verify_all_archives
    exit $?
  else
    # Verify repository integrity
    verify_repository
    exit $?
  fi

  return 0
}

# Ensure log directory exists
ensure_log_directory

# Run the main function
main
exit $?
