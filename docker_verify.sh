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

# Check if script is run as root
if [ "$(id -u)" -ne 0 ]; then
  echo -e "\033[0;31mERROR: This script must be run as root\033[0m"
  echo "Please run with sudo or as root user"
  exit 1
fi

# Default configuration
DEFAULT_BACKUP_DIR="/backup/docker"
LOG_DIR="/var/log/docker"
LOG_FILE="${LOG_DIR}/verify.log"
LOCK_FILE="/var/lock/docker_verify.lock"
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
  echo -e "  ${COLOR_GREEN}-p, --path PATH${COLOR_RESET}      Verify only specific paths within archives"
  echo -e "  ${COLOR_GREEN}-j, --json${COLOR_RESET}           Output results in JSON format"
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
JSON_OUTPUT=false
SPECIFIC_PATH=""

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
  -p | --path)
    SPECIFIC_PATH="$2"
    shift 2
    ;;
  -j | --json)
    JSON_OUTPUT=true
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
          log "ERROR" "Another verify process is already running (PID: $pid)"
          echo -e "${COLOR_RED}ERROR: Another verify process is already running (PID: $pid)${COLOR_RESET}"
          echo -e "${COLOR_YELLOW}If you're sure no other verify is running, remove the lock file:${COLOR_RESET}"
          echo -e "${COLOR_CYAN}sudo rm -f $LOCK_FILE${COLOR_RESET}"
          cleanup_and_exit 1
        fi
      else
        log "ERROR" "Another verify process is already running (PID: $pid)"
        echo -e "${COLOR_RED}ERROR: Another verify process is already running (PID: $pid)${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}If you're sure no other verify is running, remove the lock file:${COLOR_RESET}"
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

  # Skip non-error messages in quiet mode
  if [ "$QUIET_MODE" = true ] && [ "$level" != "ERROR" ]; then
    # Still log to file
    echo "[$timestamp] [$level] $message" >>"$LOG_FILE"
    return
  fi

  # Skip all messages in JSON mode unless explicitly requested
  if [ "$JSON_OUTPUT" = true ] && [ "$3" != "force" ]; then
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

    # Check if installation script is available
    local install_script="/usr/local/bin/docker_install"
    local repo_install_script="./docker_install.sh"

    if [ -f "$install_script" ]; then
      echo -e "${COLOR_YELLOW}Would you like to run the installation script? ($install_script)${COLOR_RESET}"
      if [ "$QUIET_MODE" != "true" ]; then
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
          log "INFO" "Verification canceled because Borg is not installed"
          cleanup_and_exit 1
        fi
      else
        cleanup_and_exit 1
      fi
    elif [ -f "$repo_install_script" ]; then
      echo -e "${COLOR_YELLOW}Would you like to run the installation script? ($repo_install_script)${COLOR_RESET}"
      if [ "$QUIET_MODE" != "true" ]; then
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
          log "INFO" "Verification canceled because Borg is not installed"
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
    if [ "$JSON_OUTPUT" != true ]; then
      echo -e "${COLOR_YELLOW}Repository is encrypted with keyfile. You will be prompted for the passphrase during verification.${COLOR_RESET}"
    fi

    # Verify if BORG_PASSPHRASE is set
    if [ -n "$BORG_PASSPHRASE" ]; then
      log "INFO" "Using BORG_PASSPHRASE from environment"
    fi
  elif echo "$repo_info" | grep -q '"encryption_key"'; then
    log "INFO" "Repository is encrypted with repokey"
    if [ "$JSON_OUTPUT" != true ]; then
      echo -e "${COLOR_YELLOW}Repository is encrypted with repokey. You will be prompted for the passphrase during verification.${COLOR_RESET}"
    fi

    # Verify if BORG_PASSPHRASE is set
    if [ -n "$BORG_PASSPHRASE" ]; then
      log "INFO" "Using BORG_PASSPHRASE from environment"
    fi
  else
    log "INFO" "Repository is not encrypted"
  fi
}

# Get list of all archives
get_archives() {
  local archives=()
  local result=$(borg list --short "$BACKUP_DIR" 2>/dev/null)

  if [ $? -ne 0 ]; then
    log "ERROR" "Failed to list archives. Check your repository or passphrase."
    if [ "$JSON_OUTPUT" = true ]; then
      echo '{"status":"error","message":"Failed to list archives","error":"Repository access failed"}'
    else
      echo -e "${COLOR_RED}ERROR: Failed to list archives. Check your repository or passphrase.${COLOR_RESET}"
    fi
    return 1
  fi

  # Return empty if no archives
  if [ -z "$result" ]; then
    return 0
  fi

  echo "$result"
  return 0
}

# Parse JSON from borg with improved error handling
parse_borg_json() {
  local json_data="$1"
  local field="$2"

  if [ -z "$json_data" ]; then
    echo "Unknown"
    return 1
  fi

  # Use jq if available for reliable JSON parsing
  if command_exists jq; then
    local value
    value=$(echo "$json_data" | jq -r ".$field" 2>/dev/null)
    if [ $? -eq 0 ] && [ "$value" != "null" ] && [ -n "$value" ]; then
      echo "$value"
      return 0
    fi
    echo "Unknown"
    return 1
  fi

  # Fallback to grep with improved pattern matching
  # Try different patterns based on the field type
  if [[ "$field" == *"size"* ]] || [[ "$field" == *"count"* ]]; then
    # Numeric field
    local value
    value=$(echo "$json_data" | grep -o "\"$field\":[[:space:]]*[0-9]*" | grep -o '[0-9]*')
    if [ -n "$value" ]; then
      echo "$value"
      return 0
    fi
  elif [[ "$field" == "time" ]]; then
    # Date/time field (quoted)
    local value
    value=$(echo "$json_data" | grep -o "\"$field\":[[:space:]]*\"[^\"]*\"" | grep -o '"[^"]*"$' | tr -d '"')
    if [ -n "$value" ]; then
      echo "$value"
      return 0
    fi
  else
    # Generic field (could be quoted string or other)
    local value
    value=$(echo "$json_data" | grep -o "\"$field\":[[:space:]]*[^,}]*" |
      sed -E "s/\"$field\":[[:space:]]*(\"[^\"]*\"|[0-9]+|true|false|null)/\1/" |
      sed 's/^"//;s/"$//')
    if [ -n "$value" ]; then
      echo "$value"
      return 0
    fi
  fi

  echo "Unknown"
  return 1
}

# Format size in human-readable format
format_size() {
  local size="$1"

  if [ -z "$size" ] || ! [[ "$size" =~ ^[0-9]+$ ]]; then
    echo "Unknown"
    return
  fi

  if [ "$size" -ge $((1024 * 1024 * 1024 * 1024)) ]; then
    size=$(echo "scale=2; $size/1024/1024/1024/1024" | bc)
    echo "${size}T"
  elif [ "$size" -ge $((1024 * 1024 * 1024)) ]; then
    size=$(echo "scale=2; $size/1024/1024/1024" | bc)
    echo "${size}G"
  elif [ "$size" -ge $((1024 * 1024)) ]; then
    size=$(echo "scale=2; $size/1024/1024" | bc)
    echo "${size}M"
  elif [ "$size" -ge 1024 ]; then
    size=$(echo "scale=2; $size/1024" | bc)
    echo "${size}K"
  else
    echo "${size}B"
  fi
}

# List archives with details
list_archives() {
  log "INFO" "Listing available archives"

  # Get list of archives
  local archives_output
  archives_output=$(get_archives)
  if [ $? -ne 0 ]; then
    return 1
  fi

  local archives=()
  if [ -n "$archives_output" ]; then
    readarray -t archives <<<"$archives_output"
  fi

  if [ ${#archives[@]} -eq 0 ]; then
    log "WARNING" "No archives found in repository"

    if [ "$JSON_OUTPUT" = true ]; then
      echo '{"status":"success","message":"No archives found in repository","archives":[]}'
    else
      echo -e "${COLOR_YELLOW}No archives found in repository $BACKUP_DIR${COLOR_RESET}"
    fi
    return 0
  fi

  # Output in JSON format if requested
  if [ "$JSON_OUTPUT" = true ]; then
    echo -n '{"status":"success","count":'${#archives[@]}',"archives":['

    local first=true
    for archive in "${archives[@]}"; do
      # Add comma for all but first entry
      if [ "$first" = true ]; then
        first=false
      else
        echo -n ','
      fi

      local info
      info=$(borg info --json "$BACKUP_DIR::$archive" 2>/dev/null)
      if [ $? -ne 0 ]; then
        # Handle error accessing this specific archive
        echo -n '{"name":"'$archive'","error":"Failed to get archive info"}'
        continue
      fi

      local date=$(parse_borg_json "$info" "time")
      local original_size=$(parse_borg_json "$info" "original_size")
      local compressed_size=$(parse_borg_json "$info" "compressed_size")

      echo -n '{"name":"'$archive'","date":"'$date'","original_size":'

      if [ "$original_size" = "Unknown" ]; then
        echo -n '"Unknown"'
      else
        echo -n $original_size
      fi

      echo -n ',"compressed_size":'

      if [ "$compressed_size" = "Unknown" ]; then
        echo -n '"Unknown"'
      else
        echo -n $compressed_size
      fi

      echo -n '}'
    done

    echo ']}'
    return 0
  fi

  # Regular formatted output
  echo -e "${COLOR_CYAN}${COLOR_BOLD}Available backup archives:${COLOR_RESET}"
  echo -e "${COLOR_CYAN}------------------------------------------------------${COLOR_RESET}"

  # Print archives with details
  for archive in "${archives[@]}"; do
    local info
    info=$(borg info --json "$BACKUP_DIR::$archive" 2>/dev/null)
    if [ $? -ne 0 ]; then
      echo -e "  ${COLOR_YELLOW}*${COLOR_RESET} ${COLOR_GREEN}$archive${COLOR_RESET} ${COLOR_RED}(Error: Could not access archive info)${COLOR_RESET}"
      continue
    fi

    local date=$(parse_borg_json "$info" "time")
    # Format date for better readability
    if [ "$date" != "Unknown" ]; then
      date=$(echo "$date" | cut -d'.' -f1 | sed 's/T/ /')
    fi

    local original_size=$(parse_borg_json "$info" "original_size")
    local compressed_size=$(parse_borg_json "$info" "compressed_size")

    # Format sizes for human display
    local size_h=$(format_size "$original_size")
    local compressed_size_h=$(format_size "$compressed_size")

    echo -e "  ${COLOR_YELLOW}*${COLOR_RESET} ${COLOR_GREEN}$archive${COLOR_RESET}"
    echo -e "    ${COLOR_BLUE}Created:${COLOR_RESET} $date"
    echo -e "    ${COLOR_BLUE}Size:${COLOR_RESET} $size_h (Compressed: $compressed_size_h)"
  done

  echo ""
  log "INFO" "Total archives: ${#archives[@]}"
  return 0
}

# Verify repository integrity
verify_repository() {
  log "INFO" "Verifying repository integrity"

  if [ "$JSON_OUTPUT" != true ]; then
    echo -e "${COLOR_CYAN}${COLOR_BOLD}Verifying repository integrity...${COLOR_RESET}"
  fi

  local start_time=$(date +%s)

  # Capture the output for JSON mode and error analysis
  local output
  output=$(borg check --repository-only "$BACKUP_DIR" 2>&1)
  local check_result=$?

  if [ "$JSON_OUTPUT" != true ]; then
    # Print the output for the user
    echo "$output"
  fi

  local end_time=$(date +%s)
  local duration=$((end_time - start_time))

  if [ $check_result -eq 0 ]; then
    log "INFO" "Repository integrity check completed successfully in $duration seconds"

    if [ "$JSON_OUTPUT" = true ]; then
      echo '{"status":"success","operation":"repository_check","duration_seconds":'$duration',"result":"pass"}'
    else
      echo -e "${COLOR_GREEN}${COLOR_BOLD}Repository integrity check passed!${COLOR_RESET}"
    fi

    return 0
  else
    log "ERROR" "Repository integrity check failed with exit code $check_result"

    if [ "$JSON_OUTPUT" = true ]; then
      # Escape any double quotes in the output
      output=$(echo "$output" | sed 's/"/\\"/g')
      echo '{"status":"error","operation":"repository_check","duration_seconds":'$duration',"result":"fail","exit_code":'$check_result',"output":"'"$output"'"}'
    else
      echo -e "${COLOR_RED}${COLOR_BOLD}Repository integrity check failed!${COLOR_RESET}"

      # Try to extract and show the error message
      local error_msg
      error_msg=$(echo "$output" | grep -i "error" | head -1)
      if [ -n "$error_msg" ]; then
        echo -e "${COLOR_RED}Error: $error_msg${COLOR_RESET}"
      fi
    fi

    return $check_result
  fi
}

# Verify a specific archive
verify_archive() {
  local archive="$1"
  log "INFO" "Verifying archive $archive"

  if [ "$JSON_OUTPUT" != true ]; then
    echo -e "${COLOR_CYAN}${COLOR_BOLD}Verifying archive: $archive${COLOR_RESET}"
  fi

  # Verify the archive exists
  if ! borg info "$BACKUP_DIR::$archive" >/dev/null 2>&1; then
    log "ERROR" "Archive $archive not found in repository"

    if [ "$JSON_OUTPUT" = true ]; then
      echo '{"status":"error","operation":"archive_check","archive":"'$archive'","error":"Archive not found in repository"}'
    else
      echo -e "${COLOR_RED}ERROR: Archive $archive not found in repository${COLOR_RESET}"
    fi

    return 1
  fi

  local start_time=$(date +%s)

  # Add path filtering if specified
  local path_args=""
  if [ ! -z "$SPECIFIC_PATH" ]; then
    path_args="$SPECIFIC_PATH"
    log "INFO" "Verifying only path: $SPECIFIC_PATH"
  fi

  # Capture the output for JSON mode and error analysis
  local output
  output=$(borg check "$BACKUP_DIR::$archive" $path_args 2>&1)
  local check_result=$?

  if [ "$JSON_OUTPUT" != true ]; then
    # Print the output for the user
    echo "$output"
  fi

  local end_time=$(date +%s)
  local duration=$((end_time - start_time))

  if [ $check_result -eq 0 ]; then
    log "INFO" "Archive $archive verified successfully in $duration seconds"

    if [ "$JSON_OUTPUT" = true ]; then
      echo '{"status":"success","operation":"archive_check","archive":"'$archive'","duration_seconds":'$duration',"result":"pass"}'
    else
      echo -e "${COLOR_GREEN}${COLOR_BOLD}Archive $archive integrity check passed!${COLOR_RESET}"
    fi

    return 0
  else
    log "ERROR" "Archive $archive verification failed with exit code $check_result"

    if [ "$JSON_OUTPUT" = true ]; then
      # Escape any double quotes in the output
      output=$(echo "$output" | sed 's/"/\\"/g')
      echo '{"status":"error","operation":"archive_check","archive":"'$archive'","duration_seconds":'$duration',"result":"fail","exit_code":'$check_result',"output":"'"$output"'"}'
    else
      echo -e "${COLOR_RED}${COLOR_BOLD}Archive $archive integrity check failed!${COLOR_RESET}"

      # Try to extract and show the error message
      local error_msg
      error_msg=$(echo "$output" | grep -i "error" | head -1)
      if [ -n "$error_msg" ]; then
        echo -e "${COLOR_RED}Error: $error_msg${COLOR_RESET}"
      fi
    fi

    return $check_result
  fi
}

# Verify all archives
verify_all_archives() {
  log "INFO" "Verifying all archives"

  if [ "$JSON_OUTPUT" != true ]; then
    echo -e "${COLOR_CYAN}${COLOR_BOLD}Verifying all archives in repository...${COLOR_RESET}"
  fi

  # Get list of archives
  local archives_output
  archives_output=$(get_archives)
  if [ $? -ne 0 ]; then
    return 1
  fi

  local archives=()
  if [ -n "$archives_output" ]; then
    readarray -t archives <<<"$archives_output"
  fi

  if [ ${#archives[@]} -eq 0 ]; then
    log "WARNING" "No archives found in repository"

    if [ "$JSON_OUTPUT" = true ]; then
      echo '{"status":"success","operation":"verify_all","message":"No archives found in repository","archives":[]}'
    else
      echo -e "${COLOR_YELLOW}No archives found in repository $BACKUP_DIR${COLOR_RESET}"
    fi

    return 0
  fi

  local total=${#archives[@]}
  local passed=0
  local failed=0
  local failed_archives=()
  local results=()

  # Verify each archive
  local i=1
  for archive in "${archives[@]}"; do
    if [ "$JSON_OUTPUT" != true ]; then
      echo -e "\n${COLOR_CYAN}${COLOR_BOLD}[$i/$total] Verifying archive: $archive${COLOR_RESET}"
    fi

    local start_time=$(date +%s)

    # Add path filtering if specified
    local path_args=""
    if [ ! -z "$SPECIFIC_PATH" ]; then
      path_args="$SPECIFIC_PATH"
    fi

    # Capture the output for JSON mode and error analysis
    local output
    output=$(borg check "$BACKUP_DIR::$archive" $path_args 2>&1)
    local check_result=$?

    if [ "$JSON_OUTPUT" != true ]; then
      # Print a summary of the output for the user (not the full output to avoid clutter)
      if [ $check_result -eq 0 ]; then
        echo -e "${COLOR_GREEN}Completed verification without errors${COLOR_RESET}"
      else
        echo "$output" | grep -i "error"
      fi
    fi

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    # Store result for JSON output
    if [ "$JSON_OUTPUT" = true ]; then
      if [ $check_result -eq 0 ]; then
        results+=('{"archive":"'$archive'","result":"pass","duration_seconds":'$duration'}')
      else
        # Escape any double quotes in the output
        local error_output
        error_output=$(echo "$output" | grep -i "error" | head -1 | sed 's/"/\\"/g')
        results+=('{"archive":"'$archive'","result":"fail","exit_code":'$check_result',"duration_seconds":'$duration',"error":"'"$error_output"'"}')
      fi
    fi

    if [ $check_result -eq 0 ]; then
      log "INFO" "Archive $archive verified successfully in $duration seconds"

      if [ "$JSON_OUTPUT" != true ]; then
        echo -e "${COLOR_GREEN}Archive $archive integrity check passed!${COLOR_RESET}"
      fi

      passed=$((passed + 1))
    else
      log "ERROR" "Archive $archive verification failed with exit code $check_result"

      if [ "$JSON_OUTPUT" != true ]; then
        echo -e "${COLOR_RED}Archive $archive integrity check failed!${COLOR_RESET}"
      fi

      failed=$((failed + 1))
      failed_archives+=("$archive")
    fi

    i=$((i + 1))
  done

  # Output results
  if [ "$JSON_OUTPUT" = true ]; then
    echo '{"status":"completed","operation":"verify_all","total":'$total',"passed":'$passed',"failed":'$failed',"archives":['

    # Join the results array with commas
    local first=true
    for result in "${results[@]}"; do
      if [ "$first" = true ]; then
        echo -n "$result"
        first=false
      else
        echo -n ",$result"
      fi
    done

    echo ']}'
  else
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
    fi
  fi

  if [ $failed -gt 0 ]; then
    return 1
  else
    return 0
  fi
}

# Function to display a nice header
display_header() {
  if [ "$JSON_OUTPUT" != true ]; then
    echo -e "${COLOR_CYAN}${COLOR_BOLD}"
    echo "======================================================="
    echo "        Docker Volume Tools - Verify"
    echo "======================================================="
    echo -e "${COLOR_RESET}"
  fi
}

# Main function
main() {
  display_header

  log "INFO" "Starting Docker backup verification process"

  # Obtain lock to prevent multiple instances running
  obtain_lock

  # Check prerequisites
  check_borg_installation
  check_repository

  # If list only, just show archives and exit
  if [ "$LIST_ONLY" = true ]; then
    list_archives
    cleanup_and_exit 0
  fi

  # Determine what to verify
  if [ ! -z "$ARCHIVE_ARG" ]; then
    # Verify specific archive
    verify_archive "$ARCHIVE_ARG"
    local verify_result=$?
    cleanup_and_exit $verify_result
  elif [ "$VERIFY_ALL" = true ]; then
    # Verify all archives
    verify_all_archives
    local verify_result=$?
    cleanup_and_exit $verify_result
  else
    # Verify repository integrity
    verify_repository
    local verify_result=$?
    cleanup_and_exit $verify_result
  fi
}

# Register trap for cleanup
trap handle_signal EXIT INT TERM

# Ensure log directory exists
ensure_log_directory

# Run the main function
main
