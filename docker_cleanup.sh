#!/bin/bash
# Docker Volume Tools - A utility to clean Docker resources and Borg backups
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
LOG_FILE="${LOG_DIR}/cleanup.log"
LOCK_FILE="/var/lock/docker_cleanup.lock"
LOCK_TIMEOUT=3600 # 1 hour timeout for lock file
DOCKER_COMPOSE_FILES=()

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
    echo -e "${COLOR_CYAN}Usage: $0 [OPTIONS]${COLOR_RESET}"
    echo -e "${COLOR_CYAN}Clean up Docker resources and Borg backups${COLOR_RESET}"
    echo ""
    echo -e "${COLOR_CYAN}Options:${COLOR_RESET}"
    echo -e "  ${COLOR_GREEN}-v, --volumes${COLOR_RESET}         Clean unused volumes"
    echo -e "  ${COLOR_GREEN}-i, --images${COLOR_RESET}          Clean dangling images"
    echo -e "  ${COLOR_GREEN}-c, --containers${COLOR_RESET}      Remove stopped containers"
    echo -e "  ${COLOR_GREEN}-n, --networks${COLOR_RESET}        Remove unused networks"
    echo -e "  ${COLOR_GREEN}-b, --builder${COLOR_RESET}         Clean up builder cache"
    echo -e "  ${COLOR_GREEN}-B, --borg${COLOR_RESET}            Clean and compact Borg repository"
    echo -e "  ${COLOR_GREEN}-o, --old-backups DAYS${COLOR_RESET} Remove backups older than DAYS days"
    echo -e "  ${COLOR_GREEN}-a, --all${COLOR_RESET}             Clean all Docker resources (not Borg)"
    echo -e "  ${COLOR_GREEN}-A, --all-borg${COLOR_RESET}        Clean all Borg backups (DANGER: removes ALL backups)"
    echo -e "  ${COLOR_GREEN}-x, --prune-all${COLOR_RESET}       Run Docker system prune with all options"
    echo -e "  ${COLOR_GREEN}-d, --dry-run${COLOR_RESET}         Show what would be removed without actually removing"
    echo -e "  ${COLOR_GREEN}-f, --force${COLOR_RESET}           Don't ask for confirmation"
    echo -e "  ${COLOR_GREEN}-l, --backup-dir DIR${COLOR_RESET}  Custom backup directory (default: $DEFAULT_BACKUP_DIR)"
    echo -e "  ${COLOR_GREEN}-C, --compose-file FILE${COLOR_RESET} Path to docker-compose.yml file to check for used resources"
    echo -e "  ${COLOR_GREEN}-j, --json${COLOR_RESET}            Output results in JSON format"
    echo -e "  ${COLOR_GREEN}-S, --smart${COLOR_RESET}           Smart cleanup (check for resources used in compose files)"
    echo -e "  ${COLOR_GREEN}-h, --help${COLOR_RESET}            Display this help message"
    echo ""
    echo -e "${COLOR_CYAN}Environment variables:${COLOR_RESET}"
    echo -e "  ${COLOR_GREEN}DOCKER_BACKUP_DIR${COLOR_RESET}     Same as --backup-dir"
    exit 1
}

# Initialize options
CLEAN_VOLUMES=false
CLEAN_IMAGES=false
CLEAN_CONTAINERS=false
CLEAN_NETWORKS=false
CLEAN_BUILDER=false
CLEAN_BORG=false
CLEAN_ALL=false
CLEAN_ALL_BORG=false
PRUNE_ALL=false
DRY_RUN=false
FORCE=false
BACKUP_DIR=${DOCKER_BACKUP_DIR:-$DEFAULT_BACKUP_DIR}
OLD_BACKUPS_DAYS=0
JSON_OUTPUT=false
SMART_CLEANUP=false

# Parse command line options
while [[ $# -gt 0 ]]; do
    case $1 in
    -v | --volumes)
        CLEAN_VOLUMES=true
        shift
        ;;
    -i | --images)
        CLEAN_IMAGES=true
        shift
        ;;
    -c | --containers)
        CLEAN_CONTAINERS=true
        shift
        ;;
    -n | --networks)
        CLEAN_NETWORKS=true
        shift
        ;;
    -b | --builder)
        CLEAN_BUILDER=true
        shift
        ;;
    -B | --borg)
        CLEAN_BORG=true
        shift
        ;;
    -o | --old-backups)
        if [[ "$2" =~ ^[0-9]+$ ]]; then
            OLD_BACKUPS_DAYS="$2"
            shift 2
        else
            echo -e "${COLOR_RED}ERROR: --old-backups requires a number of days${COLOR_RESET}"
            exit 1
        fi
        ;;
    -a | --all)
        CLEAN_ALL=true
        shift
        ;;
    -A | --all-borg)
        CLEAN_ALL_BORG=true
        shift
        ;;
    -x | --prune-all)
        PRUNE_ALL=true
        shift
        ;;
    -d | --dry-run)
        DRY_RUN=true
        shift
        ;;
    -f | --force)
        FORCE=true
        shift
        ;;
    -l | --backup-dir)
        BACKUP_DIR="$2"
        shift 2
        ;;
    -C | --compose-file)
        if [ -f "$2" ]; then
            DOCKER_COMPOSE_FILES+=("$2")
            SMART_CLEANUP=true
        else
            echo -e "${COLOR_RED}ERROR: Compose file not found: $2${COLOR_RESET}"
            exit 1
        fi
        shift 2
        ;;
    -j | --json)
        JSON_OUTPUT=true
        shift
        ;;
    -S | --smart)
        SMART_CLEANUP=true
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
                    log "ERROR" "Another cleanup process is already running (PID: $pid)"
                    echo -e "${COLOR_RED}ERROR: Another cleanup process is already running (PID: $pid)${COLOR_RESET}"
                    echo -e "${COLOR_YELLOW}If you're sure no other cleanup is running, remove the lock file:${COLOR_RESET}"
                    echo -e "${COLOR_CYAN}sudo rm -f $LOCK_FILE${COLOR_RESET}"
                    cleanup_and_exit 1
                fi
            else
                log "ERROR" "Another cleanup process is already running (PID: $pid)"
                echo -e "${COLOR_RED}ERROR: Another cleanup process is already running (PID: $pid)${COLOR_RESET}"
                echo -e "${COLOR_YELLOW}If you're sure no other cleanup is running, remove the lock file:${COLOR_RESET}"
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

    # Skip messages in JSON mode unless explicitly requested
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

# Verify Docker access
verify_docker_access() {
    # Check if the user can execute docker commands
    if ! docker ps >/dev/null 2>&1; then
        log "ERROR" "Current user cannot execute Docker commands."
        echo -e "${COLOR_RED}ERROR: Current user cannot execute Docker commands.${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}Make sure you are in the 'docker' group or are root:${COLOR_RESET}"
        echo -e "${COLOR_CYAN}sudo usermod -aG docker $USER${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}After adding to the group, restart your session (logout/login).${COLOR_RESET}"
        cleanup_and_exit 1
    fi

    log "INFO" "Docker access verified."
}

# Check if Borg is installed
check_borg_installation() {
    if [ "$CLEAN_BORG" = true ] || [ "$CLEAN_ALL_BORG" = true ] || [ "$OLD_BACKUPS_DAYS" -gt 0 ]; then
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
                        log "INFO" "Cleanup canceled because Borg is not installed"
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
                        log "INFO" "Cleanup canceled because Borg is not installed"
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

        # Check if it's a valid borg repository
        if ! borg info "$BACKUP_DIR" >/dev/null 2>&1; then
            log "ERROR" "Directory $BACKUP_DIR is not a valid Borg repository"
            echo -e "${COLOR_RED}ERROR: Directory $BACKUP_DIR is not a valid Borg repository${COLOR_RESET}"
            cleanup_and_exit 1
        fi

        log "INFO" "Borg Backup is installed and repository is valid"

        # Check if repository is encrypted
        local repo_info=$(borg info --json "$BACKUP_DIR" 2>/dev/null)
        if echo "$repo_info" | grep -q '"encryption_keyfile"'; then
            log "INFO" "Repository is encrypted with keyfile"
            echo -e "${COLOR_YELLOW}Repository is encrypted with keyfile. You will be prompted for the passphrase during operations.${COLOR_RESET}"

            # Verify if BORG_PASSPHRASE is set
            if [ -n "$BORG_PASSPHRASE" ]; then
                log "INFO" "Using BORG_PASSPHRASE from environment"
            fi
        elif echo "$repo_info" | grep -q '"encryption_key"'; then
            log "INFO" "Repository is encrypted with repokey"
            echo -e "${COLOR_YELLOW}Repository is encrypted with repokey. You will be prompted for the passphrase during operations.${COLOR_RESET}"

            # Verify if BORG_PASSPHRASE is set
            if [ -n "$BORG_PASSPHRASE" ]; then
                log "INFO" "Using BORG_PASSPHRASE from environment"
            fi
        else
            log "INFO" "Repository is not encrypted"
        fi
    fi
}

# Helper function to ask for confirmation
confirm_action() {
    local message="$1"
    local require_yes="${2:-false}"

    if [ "$FORCE" = true ]; then
        return 0
    fi

    if [ "$require_yes" = true ]; then
        read -p "$(echo -e "${COLOR_YELLOW}$message (yes/no): ${COLOR_RESET}")" confirm
        if [ "$confirm" = "yes" ]; then
            return 0
        else
            return 1
        fi
    else
        read -p "$(echo -e "${COLOR_YELLOW}$message (y/n): ${COLOR_RESET}")" confirm
        if [ "$confirm" = "y" ]; then
            return 0
        else
            return 1
        fi
    fi
}

# Find resources used in Docker Compose files
parse_docker_compose_files() {
    local compose_volumes=()
    local compose_networks=()
    local compose_images=()

    log "INFO" "Scanning for Docker Compose files"

    # First, auto-discover compose files in standard locations if smart cleanup is enabled
    if [ "$SMART_CLEANUP" = true ] && [ ${#DOCKER_COMPOSE_FILES[@]} -eq 0 ]; then
        log "INFO" "Searching for Docker Compose files in standard locations"

        # Common locations for docker-compose files
        local common_locations=(
            "/opt/docker/docker-compose.yml"
            "/opt/docker/docker-compose.yaml"
            "/root/docker-compose.yml"
            "/root/docker-compose.yaml"
            "/home/*/docker-compose.yml"
            "/home/*/docker-compose.yaml"
            "/srv/docker/*/docker-compose.yml"
            "/srv/docker/*/docker-compose.yaml"
        )

        for location in "${common_locations[@]}"; do
            # Handle wildcard paths correctly
            if [[ "$location" == *"*"* ]]; then
                # Extract the base path before the wildcard
                local base_path="${location%/*}"
                # Extract the filename pattern after the last /
                local file_pattern="${location##*/}"

                # Use find to locate matching files
                if [ -d "$base_path" ]; then
                    while IFS= read -r file; do
                        if [ -f "$file" ]; then
                            log "INFO" "Found compose file: $file"
                            DOCKER_COMPOSE_FILES+=("$file")
                        fi
                    done < <(find "$base_path" -name "$file_pattern" 2>/dev/null)
                fi
            else
                # Direct file check
                if [ -f "$location" ]; then
                    log "INFO" "Found compose file: $location"
                    DOCKER_COMPOSE_FILES+=("$location")
                fi
            fi
        done
    fi

    # Parse each found compose file
    for compose_file in "${DOCKER_COMPOSE_FILES[@]}"; do
        log "INFO" "Parsing compose file: $compose_file"

        # Check if the file is valid YAML before attempting to parse it
        if command_exists python3; then
            if ! python3 -c "import yaml; yaml.safe_load(open('$compose_file'))" 2>/dev/null; then
                log "WARNING" "File $compose_file does not appear to be valid YAML, skipping"
                continue
            fi
        fi

        # Try to use yq if available for more reliable YAML parsing
        if command_exists yq; then
            log "INFO" "Using yq for compose file parsing"

            # Get volumes from top-level volumes definition
            local volumes_output
            volumes_output=$(yq e '.volumes | keys' "$compose_file" 2>/dev/null)
            if [ $? -eq 0 ]; then
                while IFS= read -r volume; do
                    if [ -n "$volume" ] && [ "$volume" != "null" ]; then
                        compose_volumes+=("$volume")
                        log "INFO" "Found volume in compose file: $volume"
                    fi
                done <<<"$volumes_output"
            fi

            # Get volumes from service definitions
            local services_output
            services_output=$(yq e '.services | keys' "$compose_file" 2>/dev/null)
            if [ $? -eq 0 ]; then
                while IFS= read -r service; do
                    if [ -n "$service" ] && [ "$service" != "null" ]; then
                        local service_volumes_output
                        service_volumes_output=$(yq e ".services.$service.volumes[]" "$compose_file" 2>/dev/null)

                        while IFS= read -r vol; do
                            if [ -n "$vol" ] && [ "$vol" != "null" ]; then
                                # Check if it's a named volume (not a bind mount)
                                if [[ "$vol" != /* ]] && [[ "$vol" != .* ]] && [[ "$vol" == *":"* ]]; then
                                    local vol_name="${vol%%:*}"
                                    compose_volumes+=("$vol_name")
                                    log "INFO" "Found volume in service $service: $vol_name"
                                fi
                            fi
                        done <<<"$service_volumes_output"
                    fi
                done <<<"$services_output"
            fi

            # Get networks
            local networks_output
            networks_output=$(yq e '.networks | keys' "$compose_file" 2>/dev/null)
            if [ $? -eq 0 ]; then
                while IFS= read -r network; do
                    if [ -n "$network" ] && [ "$network" != "null" ]; then
                        compose_networks+=("$network")
                        log "INFO" "Found network in compose file: $network"
                    fi
                done <<<"$networks_output"
            fi

            # Get images
            local images_output
            images_output=$(yq e '.services[].image' "$compose_file" 2>/dev/null)
            while IFS= read -r image; do
                if [ -n "$image" ] && [ "$image" != "null" ]; then
                    compose_images+=("$image")
                    log "INFO" "Found image in compose file: $image"
                fi
            done <<<"$images_output"

        else
            log "INFO" "Using grep/sed for compose file parsing (less reliable)"

            # Extract volumes (both named and anonymous)
            if grep -q "volumes:" "$compose_file"; then
                # Use awk to try to handle indentation better
                local in_volumes_section=0
                local indent_level=0

                while IFS= read -r line; do
                    # Skip empty lines and comments
                    if [[ -z "$line" ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
                        continue
                    fi

                    # Check for volumes: section at the top level
                    if [[ "$line" =~ ^volumes: ]]; then
                        in_volumes_section=1
                        indent_level=$(echo "$line" | awk '{ match($0, /^[ \t]*/); printf("%d", RLENGTH); }')
                        continue
                    fi

                    # Exit volumes section when we hit another top-level key
                    if [[ $in_volumes_section -eq 1 ]] && [[ "$line" =~ ^[a-zA-Z_-]+ ]]; then
                        in_volumes_section=0
                    fi

                    # Process lines within volumes section
                    if [[ $in_volumes_section -eq 1 ]]; then
                        # Get line indentation
                        local line_indent=$(echo "$line" | awk '{ match($0, /^[ \t]*/); printf("%d", RLENGTH); }')

                        # Volume name is one level deeper than 'volumes:'
                        if [[ $line_indent -gt $indent_level ]] && [[ "$line" =~ ^[[:space:]]+[a-zA-Z0-9_.-]+: ]]; then
                            local vol=$(echo "$line" | sed -E 's/^[[:space:]]+([a-zA-Z0-9_.-]+):.*/\1/')
                            compose_volumes+=("$vol")
                            log "INFO" "Found volume in compose file: $vol"
                        fi
                    fi
                done <"$compose_file"

                # Also check for volumes in service definitions
                local service_volumes=()
                while IFS= read -r line; do
                    if [[ "$line" =~ [[:space:]]+volumes: ]]; then
                        # Get the indentation of the volumes line
                        local vol_indent=$(echo "$line" | awk '{ match($0, /^[ \t]*/); printf("%d", RLENGTH); }')
                        # Read the next lines until we hit a line with less or equal indentation
                        while IFS= read -r vol_line; do
                            local line_indent=$(echo "$vol_line" | awk '{ match($0, /^[ \t]*/); printf("%d", RLENGTH); }')
                            if [[ $line_indent -le $vol_indent ]] && [[ ! "$vol_line" =~ ^[[:space:]]*$ ]] && [[ ! "$vol_line" =~ ^[[:space:]]*# ]]; then
                                break
                            fi
                            # Extract volume if it's in the format name:path
                            if [[ "$vol_line" =~ [[:space:]]+- ]]; then
                                local vol_entry=$(echo "$vol_line" | sed -E 's/^[[:space:]]+- //')
                                # If it's not a bind mount and has a colon
                                if [[ "$vol_entry" != /* ]] && [[ "$vol_entry" != .* ]] && [[ "$vol_entry" == *":"* ]]; then
                                    local vol_name="${vol_entry%%:*}"
                                    if [[ -n "$vol_name" ]]; then
                                        service_volumes+=("$vol_name")
                                    fi
                                fi
                            fi
                        done < <(grep -A20 -E "^[[:space:]]+volumes:" "$compose_file" | tail -n +2)
                    fi
                done <"$compose_file"

                for vol in "${service_volumes[@]}"; do
                    compose_volumes+=("$vol")
                    log "INFO" "Found volume in service: $vol"
                done
            fi

            # Extract networks
            if grep -q "networks:" "$compose_file"; then
                local in_networks_section=0
                local indent_level=0

                while IFS= read -r line; do
                    # Skip empty lines and comments
                    if [[ -z "$line" ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
                        continue
                    fi

                    # Check for networks: section at the top level
                    if [[ "$line" =~ ^networks: ]]; then
                        in_networks_section=1
                        indent_level=$(echo "$line" | awk '{ match($0, /^[ \t]*/); printf("%d", RLENGTH); }')
                        continue
                    fi

                    # Exit networks section when we hit another top-level key
                    if [[ $in_networks_section -eq 1 ]] && [[ "$line" =~ ^[a-zA-Z_-]+ ]]; then
                        in_networks_section=0
                    fi

                    # Process lines within networks section
                    if [[ $in_networks_section -eq 1 ]]; then
                        # Get line indentation
                        local line_indent=$(echo "$line" | awk '{ match($0, /^[ \t]*/); printf("%d", RLENGTH); }')

                        # Network name is one level deeper than 'networks:'
                        if [[ $line_indent -gt $indent_level ]] && [[ "$line" =~ ^[[:space:]]+[a-zA-Z0-9_.-]+: ]]; then
                            local net=$(echo "$line" | sed -E 's/^[[:space:]]+([a-zA-Z0-9_.-]+):.*/\1/')
                            compose_networks+=("$net")
                            log "INFO" "Found network in compose file: $net"
                        fi
                    fi
                done <"$compose_file"
            fi

            # Extract images
            local file_images=$(grep -E "image:[[:space:]]*" "$compose_file" | sed -E 's/[[:space:]]*image:[[:space:]]*//' | tr -d ' ' | tr -d '"' | tr -d "'" | grep -v "^$")

            for img in $file_images; do
                compose_images+=("$img")
                log "INFO" "Found image in compose file: $img"
            done
        fi
    done

    # Deduplicate results
    if [ ${#compose_volumes[@]} -gt 0 ]; then
        compose_volumes=($(echo "${compose_volumes[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))
    fi

    if [ ${#compose_networks[@]} -gt 0 ]; then
        compose_networks=($(echo "${compose_networks[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))
    fi

    if [ ${#compose_images[@]} -gt 0 ]; then
        compose_images=($(echo "${compose_images[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))
    fi

    # Return the arrays of resources
    echo "${compose_volumes[@]}"
    echo "${compose_networks[@]}"
    echo "${compose_images[@]}"
}

# Clean unused volumes with improved Docker Compose awareness
clean_volumes() {
    log "INFO" "Checking for unused volumes..."

    # Get list of all volumes
    local all_volumes=$(docker volume ls -q)
    local unused_volumes=()

    if [ -z "$all_volumes" ]; then
        log "INFO" "No Docker volumes found."

        # Output JSON if requested
        if [ "$JSON_OUTPUT" = true ]; then
            echo '{"operation":"clean_volumes","status":"success","message":"No Docker volumes found","removed":0,"failed":0}'
        else
            echo -e "${COLOR_GREEN}No Docker volumes to clean.${COLOR_RESET}"
        fi

        return 0
    fi

    # Get volumes used in Docker Compose files if smart cleanup is enabled
    local compose_volumes=()
    if [ "$SMART_CLEANUP" = true ]; then
        local compose_resources=$(parse_docker_compose_files)
        if [ -n "$compose_resources" ]; then
            readarray -t compose_volumes < <(echo "$compose_resources" | head -1)
            log "INFO" "Found ${#compose_volumes[@]} volumes in Docker Compose files"
        fi
    fi

    # Find unused volumes
    for volume in $all_volumes; do
        # Skip if the volume is used by any container
        local used_by=$(docker ps -a --filter volume=$volume -q)

        # Skip if volume is in Docker Compose files
        local in_compose=false
        if [ "${#compose_volumes[@]}" -gt 0 ]; then
            for cv in "${compose_volumes[@]}"; do
                if [ "$cv" = "$volume" ]; then
                    in_compose=true
                    break
                fi
            done
        fi

        if [ -z "$used_by" ] && [ "$in_compose" = false ]; then
            unused_volumes+=("$volume")
        else
            if [ -n "$used_by" ]; then
                log "INFO" "Volume $volume is used by containers, skipping"
            fi
            if [ "$in_compose" = true ]; then
                log "INFO" "Volume $volume is defined in Docker Compose files, skipping"
            fi
        fi
    done

    if [ ${#unused_volumes[@]} -eq 0 ]; then
        log "INFO" "No unused volumes found."

        # Output JSON if requested
        if [ "$JSON_OUTPUT" = true ]; then
            echo '{"operation":"clean_volumes","status":"success","message":"No unused volumes to remove","removed":0,"failed":0}'
        else
            echo -e "${COLOR_GREEN}No unused volumes to remove.${COLOR_RESET}"
        fi

        return 0
    fi

    # Output found unused volumes
    if [ "$JSON_OUTPUT" != true ]; then
        echo -e "${COLOR_CYAN}Found ${#unused_volumes[@]} unused volumes:${COLOR_RESET}"
        for volume in "${unused_volumes[@]}"; do
            echo -e "  ${COLOR_YELLOW}*${COLOR_RESET} $volume"
        done
    fi

    # Exit here if dry run
    if [ "$DRY_RUN" = true ]; then
        log "INFO" "Dry run: would have removed ${#unused_volumes[@]} volumes"

        # Output JSON if requested
        if [ "$JSON_OUTPUT" = true ]; then
            echo '{"operation":"clean_volumes","status":"success","dry_run":true,"would_remove":'"${#unused_volumes[@]}"',"volumes":["'$(printf '%s","' "${unused_volumes[@]}" | sed 's/","$//')'"]}'
        else
            echo -e "${COLOR_GREEN}Dry run: would have removed ${#unused_volumes[@]} volumes${COLOR_RESET}"
        fi

        return 0
    fi

    # Ask for confirmation
    if ! confirm_action "Remove ${#unused_volumes[@]} unused volumes?" && [ "$JSON_OUTPUT" != true ]; then
        log "INFO" "Volume cleanup canceled by user"

        if [ "$JSON_OUTPUT" = true ]; then
            echo '{"operation":"clean_volumes","status":"canceled","message":"User canceled operation","removed":0,"failed":0}'
        else
            echo -e "${COLOR_GREEN}Volume cleanup canceled.${COLOR_RESET}"
        fi

        return 0
    fi

    # Remove unused volumes
    local removed=0
    local failed=0
    local failed_volumes=()

    for volume in "${unused_volumes[@]}"; do
        log "INFO" "Removing unused volume: $volume"
        if docker volume rm "$volume" >/dev/null 2>&1; then
            log "INFO" "Volume $volume removed successfully"
            removed=$((removed + 1))
        else
            log "ERROR" "Failed to remove volume $volume"
            failed=$((failed + 1))
            failed_volumes+=("$volume")
        fi
    done

    log "INFO" "Volume cleanup completed. Removed: $removed, Failed: $failed"

    # Output results
    if [ "$JSON_OUTPUT" = true ]; then
        local failed_json=""
        if [ ${#failed_volumes[@]} -gt 0 ]; then
            failed_json=',"failed_volumes":["'$(printf '%s","' "${failed_volumes[@]}" | sed 's/","$//')'"]'
        fi
        echo '{"operation":"clean_volumes","status":"success","removed":'$removed',"failed":'$failed''$failed_json'}'
    else
        echo -e "${COLOR_GREEN}Volume cleanup completed. Removed: $removed, Failed: $failed${COLOR_RESET}"

        if [ $failed -gt 0 ]; then
            echo -e "${COLOR_YELLOW}Failed to remove these volumes:${COLOR_RESET}"
            for volume in "${failed_volumes[@]}"; do
                echo -e "  ${COLOR_YELLOW}*${COLOR_RESET} $volume"
            done
        fi
    fi
}

# Clean dangling images with improved Docker Compose awareness
clean_images() {
    log "INFO" "Checking for dangling images..."

    # Get list of dangling images
    local dangling_images=$(docker images -f "dangling=true" -q)

    if [ -z "$dangling_images" ]; then
        log "INFO" "No dangling images found."

        # Output JSON if requested
        if [ "$JSON_OUTPUT" = true ]; then
            echo '{"operation":"clean_images","status":"success","message":"No dangling images found","removed":0,"failed":0}'
        else
            echo -e "${COLOR_GREEN}No dangling images to remove.${COLOR_RESET}"
        fi

        return 0
    fi

    local image_count=$(echo "$dangling_images" | wc -l)

    if [ "$JSON_OUTPUT" != true ]; then
        echo -e "${COLOR_CYAN}Found $image_count dangling image(s)${COLOR_RESET}"
    fi

    # Exit here if dry run
    if [ "$DRY_RUN" = true ]; then
        log "INFO" "Dry run: would have removed $image_count dangling images"

        # Output JSON if requested
        if [ "$JSON_OUTPUT" = true ]; then
            echo '{"operation":"clean_images","status":"success","dry_run":true,"would_remove":'$image_count'}'
        else
            echo -e "${COLOR_GREEN}Dry run: would have removed $image_count dangling images${COLOR_RESET}"
        fi

        return 0
    fi

    # Ask for confirmation
    if ! confirm_action "Remove $image_count dangling images?" && [ "$JSON_OUTPUT" != true ]; then
        log "INFO" "Image cleanup canceled by user"

        if [ "$JSON_OUTPUT" = true ]; then
            echo '{"operation":"clean_images","status":"canceled","message":"User canceled operation","removed":0,"failed":0}'
        else
            echo -e "${COLOR_GREEN}Image cleanup canceled.${COLOR_RESET}"
        fi

        return 0
    fi

    # Remove dangling images
    log "INFO" "Removing dangling images..."
    local output=$(docker rmi $dangling_images 2>&1)
    local result=$?

    # Count successful and failed removals
    local removed=0
    local failed=0

    if [ $result -eq 0 ]; then
        removed=$image_count
        log "INFO" "Successfully removed $image_count dangling images"

        if [ "$JSON_OUTPUT" = true ]; then
            echo '{"operation":"clean_images","status":"success","removed":'$removed',"failed":0}'
        else
            echo -e "${COLOR_GREEN}Successfully removed $image_count dangling images${COLOR_RESET}"
        fi
    else
        # Parse the output to determine how many were removed vs failed
        local successful_count=$(echo "$output" | grep -c "Deleted")
        removed=$successful_count
        failed=$((image_count - successful_count))

        log "WARNING" "$successful_count images removed, $failed images could not be removed"

        if [ "$JSON_OUTPUT" = true ]; then
            echo '{"operation":"clean_images","status":"partial","removed":'$removed',"failed":'$failed',"message":"Some images could not be removed"}'
        else
            echo -e "${COLOR_YELLOW}$successful_count images removed, $failed images could not be removed${COLOR_RESET}"
            echo -e "${COLOR_YELLOW}Some images may be in use or referenced by other images${COLOR_RESET}"
        fi
    fi
}

# Clean stopped containers
clean_containers() {
    log "INFO" "Checking for stopped containers..."

    # Get list of stopped containers
    local stopped_containers=$(docker ps -a -f "status=exited" -q)

    if [ -z "$stopped_containers" ]; then
        log "INFO" "No stopped containers found."

        # Output JSON if requested
        if [ "$JSON_OUTPUT" = true ]; then
            echo '{"operation":"clean_containers","status":"success","message":"No stopped containers found","removed":0,"failed":0}'
        else
            echo -e "${COLOR_GREEN}No stopped containers to remove.${COLOR_RESET}"
        fi

        return 0
    fi

    local container_count=$(echo "$stopped_containers" | wc -l)

    if [ "$JSON_OUTPUT" != true ]; then
        echo -e "${COLOR_CYAN}Found $container_count stopped container(s)${COLOR_RESET}"

        # Show more details about the containers
        if [ "$container_count" -gt 0 ]; then
            echo -e "${COLOR_CYAN}Details of stopped containers:${COLOR_RESET}"
            docker ps -a -f "status=exited" --format "  ${COLOR_YELLOW}*${COLOR_RESET} {{.Names}} (ID: {{.ID}}, Image: {{.Image}}, Exited: {{.Status}})"
        fi
    fi

    # Exit here if dry run
    if [ "$DRY_RUN" = true ]; then
        log "INFO" "Dry run: would have removed $container_count stopped containers"

        # Output JSON if requested
        if [ "$JSON_OUTPUT" = true ]; then
            local containers_json="["
            local first=true
            local containers_output=$(docker ps -a -f "status=exited" --format '{"id":"{{.ID}}","name":"{{.Names}}","image":"{{.Image}}","status":"{{.Status}}"}')

            # Format the output into a JSON array
            while IFS= read -r container; do
                if [ "$first" = true ]; then
                    containers_json+="$container"
                    first=false
                else
                    containers_json+=",$container"
                fi
            done <<<"$containers_output"

            containers_json+="]"

            echo '{"operation":"clean_containers","status":"success","dry_run":true,"would_remove":'$container_count',"containers":'$containers_json'}'
        else
            echo -e "${COLOR_GREEN}Dry run: would have removed $container_count stopped containers${COLOR_RESET}"
        fi

        return 0
    fi

    # Ask for confirmation
    if ! confirm_action "Remove $container_count stopped containers?" && [ "$JSON_OUTPUT" != true ]; then
        log "INFO" "Container cleanup canceled by user"

        if [ "$JSON_OUTPUT" = true ]; then
            echo '{"operation":"clean_containers","status":"canceled","message":"User canceled operation","removed":0,"failed":0}'
        else
            echo -e "${COLOR_GREEN}Container cleanup canceled.${COLOR_RESET}"
        fi

        return 0
    fi

    # Remove stopped containers
    log "INFO" "Removing stopped containers..."
    local output=$(docker rm $stopped_containers 2>&1)
    local result=$?

    # Count successful and failed removals
    local removed=0
    local failed=0

    if [ $result -eq 0 ]; then
        removed=$container_count
        log "INFO" "Successfully removed $container_count stopped containers"

        if [ "$JSON_OUTPUT" = true ]; then
            echo '{"operation":"clean_containers","status":"success","removed":'$removed',"failed":0}'
        else
            echo -e "${COLOR_GREEN}Successfully removed $container_count stopped containers${COLOR_RESET}"
        fi
    else
        # Try to count how many were actually removed
        local successful_ids=$(echo "$output" | grep -v "Error" | tr -d ' ')
        local successful_count=$(echo "$successful_ids" | grep -c ".")
        removed=$successful_count
        failed=$((container_count - successful_count))

        log "WARNING" "$successful_count containers removed, $failed containers could not be removed"

        if [ "$JSON_OUTPUT" = true ]; then
            echo '{"operation":"clean_containers","status":"partial","removed":'$removed',"failed":'$failed',"message":"Some containers could not be removed"}'
        else
            echo -e "${COLOR_YELLOW}$successful_count containers removed, $failed containers could not be removed${COLOR_RESET}"
            echo -e "${COLOR_YELLOW}Some containers may have resource dependencies or other issues${COLOR_RESET}"
        fi
    fi
}

# Clean unused networks with improved Docker Compose awareness
clean_networks() {
    log "INFO" "Checking for unused networks..."

    # Get list of custom networks
    local all_networks=$(docker network ls --filter "type=custom" -q)

    if [ -z "$all_networks" ]; then
        log "INFO" "No custom networks found."

        # Output JSON if requested
        if [ "$JSON_OUTPUT" = true ]; then
            echo '{"operation":"clean_networks","status":"success","message":"No custom networks found","removed":0,"failed":0}'
        else
            echo -e "${COLOR_GREEN}No custom networks to check.${COLOR_RESET}"
        fi

        return 0
    fi

    # Get networks used in Docker Compose files if smart cleanup is enabled
    local compose_networks=()
    if [ "$SMART_CLEANUP" = true ]; then
        local compose_resources=$(parse_docker_compose_files)
        if [ -n "$compose_resources" ]; then
            readarray -t compose_networks < <(echo "$compose_resources" | sed -n '2p')
            log "INFO" "Found ${#compose_networks[@]} networks in Docker Compose files"
        fi
    fi

    # Find unused networks
    local unused_networks=()

    for network in $all_networks; do
        # Get the network name
        local name=$(docker network inspect --format='{{.Name}}' "$network")

        # Skip default networks (bridge, host, none)
        if [[ "$name" == "bridge" || "$name" == "host" || "$name" == "none" ]]; then
            continue
        fi

        # Check if network is used by any container
        local containers=$(docker network inspect --format='{{range .Containers}}{{.Name}} {{end}}' "$network" | awk '{$1=$1};1')

        # Skip if network is in Docker Compose files
        local in_compose=false
        if [ "${#compose_networks[@]}" -gt 0 ]; then
            for cn in "${compose_networks[@]}"; do
                if [ "$cn" = "$name" ]; then
                    in_compose=true
                    break
                fi
            done
        fi

        if [ -z "$containers" ] && [ "$in_compose" = false ]; then
            unused_networks+=("$network:$name")
        else
            if [ -n "$containers" ]; then
                log "INFO" "Network $name is used by containers, skipping"
            fi
            if [ "$in_compose" = true ]; then
                log "INFO" "Network $name is defined in Docker Compose files, skipping"
            fi
        fi
    done

    if [ ${#unused_networks[@]} -eq 0 ]; then
        log "INFO" "No unused networks found."

        # Output JSON if requested
        if [ "$JSON_OUTPUT" = true ]; then
            echo '{"operation":"clean_networks","status":"success","message":"No unused networks to remove","removed":0,"failed":0}'
        else
            echo -e "${COLOR_GREEN}No unused networks to remove.${COLOR_RESET}"
        fi

        return 0
    fi

    # Output found unused networks
    if [ "$JSON_OUTPUT" != true ]; then
        echo -e "${COLOR_CYAN}Found ${#unused_networks[@]} unused network(s):${COLOR_RESET}"
        for network_info in "${unused_networks[@]}"; do
            local id=$(echo "$network_info" | cut -d':' -f1)
            local name=$(echo "$network_info" | cut -d':' -f2)
            echo -e "  ${COLOR_YELLOW}*${COLOR_RESET} $name ($id)"
        done
    fi

    # Exit here if dry run
    if [ "$DRY_RUN" = true ]; then
        log "INFO" "Dry run: would have removed ${#unused_networks[@]} networks"

        # Output JSON if requested
        if [ "$JSON_OUTPUT" = true ]; then
            # Build networks JSON array
            local networks_json="["
            local first=true

            for network_info in "${unused_networks[@]}"; do
                local id=$(echo "$network_info" | cut -d':' -f1)
                local name=$(echo "$network_info" | cut -d':' -f2)

                if [ "$first" = true ]; then
                    networks_json+='{"id":"'$id'","name":"'$name'"}'
                    first=false
                else
                    networks_json+=',{"id":"'$id'","name":"'$name'"}'
                fi
            done

            networks_json+="]"

            echo '{"operation":"clean_networks","status":"success","dry_run":true,"would_remove":'${#unused_networks[@]}',"networks":'$networks_json'}'
        else
            echo -e "${COLOR_GREEN}Dry run: would have removed ${#unused_networks[@]} networks${COLOR_RESET}"
        fi

        return 0
    fi

    # Ask for confirmation
    if ! confirm_action "Remove ${#unused_networks[@]} unused networks?" && [ "$JSON_OUTPUT" != true ]; then
        log "INFO" "Network cleanup canceled by user"

        if [ "$JSON_OUTPUT" = true ]; then
            echo '{"operation":"clean_networks","status":"canceled","message":"User canceled operation","removed":0,"failed":0}'
        else
            echo -e "${COLOR_GREEN}Network cleanup canceled.${COLOR_RESET}"
        fi

        return 0
    fi

    # Remove unused networks
    local removed=0
    local failed=0
    local failed_networks=()

    for network_info in "${unused_networks[@]}"; do
        local id=$(echo "$network_info" | cut -d':' -f1)
        local name=$(echo "$network_info" | cut -d':' -f2)

        log "INFO" "Removing unused network: $name"
        if docker network rm "$id" >/dev/null 2>&1; then
            log "INFO" "Network $name removed successfully"
            removed=$((removed + 1))
        else
            log "ERROR" "Failed to remove network $name"
            failed=$((failed + 1))
            failed_networks+=("$name")
        fi
    done

    log "INFO" "Network cleanup completed. Removed: $removed, Failed: $failed"

    # Output results
    if [ "$JSON_OUTPUT" = true ]; then
        local failed_json=""
        if [ ${#failed_networks[@]} -gt 0 ]; then
            failed_json=',"failed_networks":["'$(printf '%s","' "${failed_networks[@]}" | sed 's/","$//')'"]'
        fi
        echo '{"operation":"clean_networks","status":"success","removed":'$removed',"failed":'$failed''$failed_json'}'
    else
        echo -e "${COLOR_GREEN}Network cleanup completed. Removed: $removed, Failed: $failed${COLOR_RESET}"

        if [ $failed -gt 0 ]; then
            echo -e "${COLOR_YELLOW}Failed to remove these networks:${COLOR_RESET}"
            for network in "${failed_networks[@]}"; do
                echo -e "  ${COLOR_YELLOW}*${COLOR_RESET} $network"
            done
        fi
    fi
}

# Clean builder cache
clean_builder() {
    log "INFO" "Cleaning Docker builder cache..."

    # Get builder cache size first
    local cache_info=$(docker builder prune --force --dry-run 2>&1)
    local cache_size=$(echo "$cache_info" | grep -o "would be removed: .*" | sed 's/would be removed: //')

    if [[ "$cache_size" == "0B" ]]; then
        log "INFO" "No builder cache to clean"

        # Output JSON if requested
        if [ "$JSON_OUTPUT" = true ]; then
            echo '{"operation":"clean_builder","status":"success","message":"No builder cache to clean","size_freed":"0B"}'
        else
            echo -e "${COLOR_GREEN}No builder cache to clean.${COLOR_RESET}"
        fi

        return 0
    fi

    if [ "$JSON_OUTPUT" != true ]; then
        echo -e "${COLOR_CYAN}Found approximately $cache_size of builder cache that can be cleaned${COLOR_RESET}"
    fi

    # Exit here if dry run
    if [ "$DRY_RUN" = true ]; then
        log "INFO" "Dry run: would have cleaned builder cache ($cache_size)"

        # Output JSON if requested
        if [ "$JSON_OUTPUT" = true ]; then
            echo '{"operation":"clean_builder","status":"success","dry_run":true,"would_free":"'$cache_size'"}'
        else
            echo -e "${COLOR_GREEN}Dry run: would have cleaned builder cache ($cache_size)${COLOR_RESET}"
        fi

        return 0
    fi

    # Ask for confirmation
    if ! confirm_action "Clean Docker builder cache ($cache_size)?" && [ "$JSON_OUTPUT" != true ]; then
        log "INFO" "Builder cache cleanup canceled by user"

        if [ "$JSON_OUTPUT" = true ]; then
            echo '{"operation":"clean_builder","status":"canceled","message":"User canceled operation"}'
        else
            echo -e "${COLOR_GREEN}Builder cache cleanup canceled.${COLOR_RESET}"
        fi

        return 0
    fi

    # Clean builder cache
    local clean_output=$(docker builder prune --force 2>&1)
    local clean_result=$?

    if [ $clean_result -eq 0 ]; then
        local reclaimed=$(echo "$clean_output" | grep -o "Total reclaimed space: .*" | sed 's/Total reclaimed space: //')
        log "INFO" "Successfully cleaned builder cache, reclaimed: $reclaimed"

        if [ "$JSON_OUTPUT" = true ]; then
            echo '{"operation":"clean_builder","status":"success","size_freed":"'$reclaimed'"}'
        else
            echo -e "${COLOR_GREEN}Successfully cleaned builder cache, reclaimed: $reclaimed${COLOR_RESET}"
        fi
    else
        log "ERROR" "Failed to clean builder cache"

        if [ "$JSON_OUTPUT" = true ]; then
            echo '{"operation":"clean_builder","status":"error","message":"Failed to clean builder cache"}'
        else
            echo -e "${COLOR_RED}Failed to clean builder cache${COLOR_RESET}"
        fi

        return 1
    fi
}

# Clean and compact Borg repository
clean_borg() {
    log "INFO" "Cleaning and compacting Borg repository..."

    if [ "$JSON_OUTPUT" != true ]; then
        echo -e "${COLOR_CYAN}Cleaning and compacting Borg repository at $BACKUP_DIR...${COLOR_RESET}"
    fi

    # Exit here if dry run
    if [ "$DRY_RUN" = true ]; then
        log "INFO" "Dry run: would have compacted Borg repository"

        if [ "$JSON_OUTPUT" = true ]; then
            echo '{"operation":"clean_borg","status":"success","dry_run":true,"message":"Would have compacted Borg repository"}'
        else
            echo -e "${COLOR_GREEN}Dry run: would have compacted Borg repository${COLOR_RESET}"
        fi

        return 0
    fi

    # Ask for confirmation
    if ! confirm_action "Compact Borg repository? This can take a long time for large repositories." && [ "$JSON_OUTPUT" != true ]; then
        log "INFO" "Borg compaction canceled by user"

        if [ "$JSON_OUTPUT" = true ]; then
            echo '{"operation":"clean_borg","status":"canceled","message":"User canceled operation"}'
        else
            echo -e "${COLOR_GREEN}Borg compaction canceled.${COLOR_RESET}"
        fi

        return 0
    fi

    # First prune any locks that might exist
    log "INFO" "Checking for stale locks..."
    borg break-lock "$BACKUP_DIR" 2>/dev/null

    # Verify repository integrity before compaction
    log "INFO" "Checking repository integrity before compaction..."

    if ! borg check --repository-only "$BACKUP_DIR" >/dev/null 2>&1; then
        log "ERROR" "Repository integrity check failed, cannot proceed with compaction"

        if [ "$JSON_OUTPUT" = true ]; then
            echo '{"operation":"clean_borg","status":"error","message":"Repository integrity check failed, cannot proceed with compaction"}'
        else
            echo -e "${COLOR_RED}ERROR: Repository integrity check failed, cannot proceed with compaction${COLOR_RESET}"
            echo -e "${COLOR_YELLOW}Try running 'docker_verify' first to diagnose issues.${COLOR_RESET}"
        fi

        return 1
    fi

    # Compact the repository
    log "INFO" "Compacting repository (this may take a while)..."

    if [ "$JSON_OUTPUT" != true ]; then
        echo -e "${COLOR_CYAN}${COLOR_BOLD}Compacting repository... This may take a long time for large repositories.${COLOR_RESET}"
    fi

    local start_time=$(date +%s)

    if [ "$JSON_OUTPUT" = true ]; then
        local output=$(borg compact "$BACKUP_DIR" 2>&1)
        local compact_result=$?
    else
        borg compact --progress "$BACKUP_DIR"
        local compact_result=$?
    fi

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    if [ $compact_result -eq 0 ]; then
        log "INFO" "Repository compaction completed successfully in $duration seconds"

        if [ "$JSON_OUTPUT" = true ]; then
            echo '{"operation":"clean_borg","status":"success","duration_seconds":'$duration'}'
        else
            echo -e "${COLOR_GREEN}Repository compaction completed successfully in $duration seconds${COLOR_RESET}"
        fi
    else
        log "ERROR" "Repository compaction failed with exit code $compact_result"

        if [ "$JSON_OUTPUT" = true ]; then
            # Escape output for JSON
            if [ -n "$output" ]; then
                output=$(echo "$output" | sed 's/"/\\"/g')
                echo '{"operation":"clean_borg","status":"error","exit_code":'$compact_result',"duration_seconds":'$duration',"output":"'"$output"'"}'
            else
                echo '{"operation":"clean_borg","status":"error","exit_code":'$compact_result',"duration_seconds":'$duration'}'
            fi
        else
            echo -e "${COLOR_RED}Repository compaction failed${COLOR_RESET}"
        fi

        return 1
    fi

    return 0
}

# Clean old Borg backups
clean_old_backups() {
    local days="$1"
    log "INFO" "Removing backups older than $days days..."

    if [ "$JSON_OUTPUT" != true ]; then
        echo -e "${COLOR_CYAN}Removing backups older than $days days...${COLOR_RESET}"
    fi

    # Check how many backups would be affected
    local dry_run_output
    dry_run_output=$(borg prune --dry-run --keep-within ${days}d --list "$BACKUP_DIR" 2>&1)
    local dry_run_result=$?

    if [ $dry_run_result -ne 0 ]; then
        log "ERROR" "Failed to check for old backups"
        if [ "$JSON_OUTPUT" = true ]; then
            echo '{"operation":"clean_old_backups","days":'$days',"status":"error","message":"Failed to check for old backups","error":"Borg dry run failed"}'
        else
            echo -e "${COLOR_RED}ERROR: Failed to check for old backups${COLOR_RESET}"
        fi
        return 1
    fi

    local affected_count=$(echo "$dry_run_output" | grep -c "Would prune:")

    if [ $affected_count -eq 0 ]; then
        log "INFO" "No backups older than $days days found"

        if [ "$JSON_OUTPUT" = true ]; then
            echo '{"operation":"clean_old_backups","days":'$days',"status":"success","message":"No backups older than '$days' days found","removed":0}'
        else
            echo -e "${COLOR_GREEN}No backups older than $days days found.${COLOR_RESET}"
        fi

        return 0
    fi

    # Get the list of affected archives
    local affected_archives=()
    while IFS= read -r line; do
        if [[ "$line" =~ Would\ prune:\ (.+) ]]; then
            affected_archives+=("${BASH_REMATCH[1]}")
        fi
    done <<<"$dry_run_output"

    if [ "$JSON_OUTPUT" != true ]; then
        echo -e "${COLOR_CYAN}Found $affected_count backups older than $days days:${COLOR_RESET}"
        for archive in "${affected_archives[@]}"; do
            echo -e "  ${COLOR_YELLOW}*${COLOR_RESET} $archive"
        done
    fi

    # Exit here if dry run
    if [ "$DRY_RUN" = true ]; then
        log "INFO" "Dry run: would have pruned $affected_count backups older than $days days"

        if [ "$JSON_OUTPUT" = true ]; then
            echo '{"operation":"clean_old_backups","days":'$days',"status":"success","dry_run":true,"would_remove":'$affected_count',"archives":["'$(printf '%s","' "${affected_archives[@]}" | sed 's/","$//')'"]}'
        else
            echo -e "${COLOR_GREEN}Dry run: would have pruned $affected_count backups older than $days days${COLOR_RESET}"
        fi

        return 0
    fi

    # Ask for confirmation
    if ! confirm_action "Remove $affected_count backups older than $days days?" && [ "$JSON_OUTPUT" != true ]; then
        log "INFO" "Backup pruning canceled by user"

        if [ "$JSON_OUTPUT" = true ]; then
            echo '{"operation":"clean_old_backups","days":'$days',"status":"canceled","message":"User canceled operation","removed":0}'
        else
            echo -e "${COLOR_GREEN}Backup pruning canceled.${COLOR_RESET}"
        fi

        return 0
    fi

    # Prune old backups
    local start_time=$(date +%s)

    if [ "$JSON_OUTPUT" = true ]; then
        local output=$(borg prune --stats --keep-within ${days}d "$BACKUP_DIR" 2>&1)
        local prune_result=$?
    else
        borg prune --stats --progress --keep-within ${days}d "$BACKUP_DIR"
        local prune_result=$?
    fi

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    if [ $prune_result -eq 0 ]; then
        log "INFO" "Successfully pruned backups older than $days days (removed $affected_count archives) in $duration seconds"

        if [ "$JSON_OUTPUT" = true ]; then
            echo '{"operation":"clean_old_backups","days":'$days',"status":"success","removed":'$affected_count',"duration_seconds":'$duration'}'
        else
            echo -e "${COLOR_GREEN}Successfully pruned backups older than $days days (removed $affected_count archives)${COLOR_RESET}"

            # Suggest compacting repository if not already done
            if [ "$CLEAN_BORG" != true ]; then
                echo -e "${COLOR_YELLOW}Note: To reclaim disk space, consider running with --borg to compact the repository.${COLOR_RESET}"
            fi
        fi
    else
        log "ERROR" "Failed to prune old backups with exit code $prune_result"

        if [ "$JSON_OUTPUT" = true ]; then
            # Escape output for JSON
            if [ -n "$output" ]; then
                output=$(echo "$output" | sed 's/"/\\"/g')
                echo '{"operation":"clean_old_backups","days":'$days',"status":"error","exit_code":'$prune_result',"duration_seconds":'$duration',"output":"'"$output"'"}'
            else
                echo '{"operation":"clean_old_backups","days":'$days',"status":"error","exit_code":'$prune_result',"duration_seconds":'$duration'}'
            fi
        else
            echo -e "${COLOR_RED}Failed to prune old backups${COLOR_RESET}"
        fi

        return 1
    fi

    return 0
}

# Clean all Borg backups
clean_all_borg() {
    log "INFO" "Preparing to remove ALL Borg backups..."

    if [ "$JSON_OUTPUT" != true ]; then
        echo -e "${COLOR_RED}${COLOR_BOLD}WARNING: This will remove ALL backups in the repository!${COLOR_RESET}"
    fi

    # Get count of archives for reporting
    local archives
    local archive_list
    archive_list=$(borg list --short "$BACKUP_DIR" 2>/dev/null)

    if [ $? -ne 0 ]; then
        log "ERROR" "Failed to list archives in repository"
        if [ "$JSON_OUTPUT" = true ]; then
            echo '{"operation":"clean_all_borg","status":"error","message":"Failed to list archives in repository"}'
        else
            echo -e "${COLOR_RED}ERROR: Failed to list archives in repository${COLOR_RESET}"
        fi
        return 1
    fi

    readarray -t archives <<<"$archive_list"
    local archive_count=${#archives[@]}

    if [ $archive_count -eq 0 ]; then
        log "INFO" "No archives found in repository"

        if [ "$JSON_OUTPUT" = true ]; then
            echo '{"operation":"clean_all_borg","status":"success","message":"No archives found in repository","removed":0}'
        else
            echo -e "${COLOR_GREEN}No archives found in repository.${COLOR_RESET}"
        fi

        return 0
    fi

    # Exit here if dry run
    if [ "$DRY_RUN" = true ]; then
        log "INFO" "Dry run: would have removed ALL $archive_count Borg backups"

        if [ "$JSON_OUTPUT" = true ]; then
            echo '{"operation":"clean_all_borg","status":"success","dry_run":true,"would_remove":'$archive_count',"archives":["'$(printf '%s","' "${archives[@]}" | sed 's/","$//')'"]}'
        else
            echo -e "${COLOR_GREEN}Dry run: would have removed ALL $archive_count Borg backups${COLOR_RESET}"
        fi

        return 0
    fi

    # Ask for extra confirmation for this dangerous operation
    if [ "$JSON_OUTPUT" != true ]; then
        echo -e "${COLOR_RED}${COLOR_BOLD}DANGER: This operation will delete ALL $archive_count backups and CANNOT be undone!${COLOR_RESET}"
    fi

    if ! confirm_action "Are you ABSOLUTELY SURE you want to delete ALL backups?" true && [ "$JSON_OUTPUT" != true ]; then
        log "INFO" "Complete backup deletion canceled by user"

        if [ "$JSON_OUTPUT" = true ]; then
            echo '{"operation":"clean_all_borg","status":"canceled","message":"User canceled operation","removed":0}'
        else
            echo -e "${COLOR_GREEN}Complete backup deletion canceled.${COLOR_RESET}"
        fi

        return 0
    fi

    # Double-check with an extra confirmation
    if ! confirm_action "Last chance! Are you really sure you want to delete ALL $archive_count Docker backups?" true && [ "$JSON_OUTPUT" != true ]; then
        log "INFO" "Complete backup deletion canceled by user"

        if [ "$JSON_OUTPUT" = true ]; then
            echo '{"operation":"clean_all_borg","status":"canceled","message":"User canceled second confirmation","removed":0}'
        else
            echo -e "${COLOR_GREEN}Complete backup deletion canceled.${COLOR_RESET}"
        fi

        return 0
    fi

    # Remove all backups
    log "INFO" "Removing ALL $archive_count Borg backups..."
    local start_time=$(date +%s)

    # First remove all the archives using prune with keep-nothing
    if [ "$JSON_OUTPUT" = true ]; then
        local output=$(borg prune --stats --keep-within 0d "$BACKUP_DIR" 2>&1)
        local prune_result=$?
    else
        borg prune --stats --progress --keep-within 0d "$BACKUP_DIR"
        local prune_result=$?
    fi

    if [ $prune_result -eq 0 ]; then
        log "INFO" "Successfully removed all backup archives"

        # Then compact the repository
        if [ "$JSON_OUTPUT" = true ]; then
            local compact_output=$(borg compact "$BACKUP_DIR" 2>&1)
            local compact_result=$?
        else
            borg compact --progress "$BACKUP_DIR"
            local compact_result=$?
        fi

        local end_time=$(date +%s)
        local duration=$((end_time - start_time))

        if [ $compact_result -eq 0 ]; then
            log "INFO" "Repository compaction completed successfully"

            if [ "$JSON_OUTPUT" = true ]; then
                echo '{"operation":"clean_all_borg","status":"success","removed":'$archive_count',"duration_seconds":'$duration'}'
            else
                echo -e "${COLOR_GREEN}All $archive_count backups removed and repository compacted successfully${COLOR_RESET}"
            fi
        else
            log "ERROR" "Repository compaction failed after removing all backups"

            if [ "$JSON_OUTPUT" = true ]; then
                echo '{"operation":"clean_all_borg","status":"partial","removed":'$archive_count',"duration_seconds":'$duration',"message":"All backups removed but repository compaction failed"}'
            else
                echo -e "${COLOR_YELLOW}All backups removed but repository compaction failed${COLOR_RESET}"
            fi
        fi
    else
        log "ERROR" "Failed to remove all backups"
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))

        if [ "$JSON_OUTPUT" = true ]; then
            # Escape output for JSON
            if [ -n "$output" ]; then
                output=$(echo "$output" | sed 's/"/\\"/g')
                echo '{"operation":"clean_all_borg","status":"error","exit_code":'$prune_result',"duration_seconds":'$duration',"output":"'"$output"'"}'
            else
                echo '{"operation":"clean_all_borg","status":"error","exit_code":'$prune_result',"duration_seconds":'$duration'}'
            fi
        else
            echo -e "${COLOR_RED}Failed to remove all backups${COLOR_RESET}"
        fi

        return 1
    fi

    return 0
}

# Run Docker system prune
run_system_prune() {
    log "INFO" "Running Docker system prune (all)..."

    # Exit here if dry run
    if [ "$DRY_RUN" = true ]; then
        # Get an estimate of what would be removed
        local volumes_size=$(docker system df --format '{{json .}}' | grep -o '"TotalSize":"[^"]*"' | cut -d'"' -f4)
        local images_size=$(docker system df --format '{{json .Images}}' | grep -o '"Size":"[^"]*"' | head -1 | cut -d'"' -f4)
        local build_cache_size=$(docker system df --format '{{json .BuildCache}}' | grep -o '"Size":"[^"]*"' | head -1 | cut -d'"' -f4)

        log "INFO" "Dry run: would have run system prune with all options"

        if [ "$JSON_OUTPUT" = true ]; then
            echo '{"operation":"system_prune","status":"success","dry_run":true,"would_free":{"volumes":"'$volumes_size'","images":"'$images_size'","build_cache":"'$build_cache_size'"}}'
        else
            echo -e "${COLOR_GREEN}Dry run: would have run system prune with all options${COLOR_RESET}"
            echo -e "${COLOR_GREEN}Estimated space that would be freed:${COLOR_RESET}"
            echo -e "  ${COLOR_CYAN}Volumes:${COLOR_RESET} $volumes_size"
            echo -e "  ${COLOR_CYAN}Images:${COLOR_RESET} $images_size"
            echo -e "  ${COLOR_CYAN}Build Cache:${COLOR_RESET} $build_cache_size"
        fi

        return 0
    fi

    # Ask for confirmation
    if [ "$JSON_OUTPUT" != true ]; then
        echo -e "${COLOR_YELLOW}${COLOR_BOLD}CAUTION: Docker system prune with --all --volumes will remove:${COLOR_RESET}"
        echo -e "  ${COLOR_YELLOW}* All stopped containers${COLOR_RESET}"
        echo -e "  ${COLOR_YELLOW}* All networks not used by at least one container${COLOR_RESET}"
        echo -e "  ${COLOR_YELLOW}* All volumes not used by at least one container${COLOR_RESET}"
        echo -e "  ${COLOR_YELLOW}* All images without at least one container associated to them${COLOR_RESET}"
        echo -e "  ${COLOR_YELLOW}* All build cache${COLOR_RESET}"
    fi

    if ! confirm_action "This operation cannot be undone. Continue?" true && [ "$JSON_OUTPUT" != true ]; then
        log "INFO" "System prune canceled by user"

        if [ "$JSON_OUTPUT" = true ]; then
            echo '{"operation":"system_prune","status":"canceled","message":"User canceled operation"}'
        else
            echo -e "${COLOR_GREEN}System prune canceled.${COLOR_RESET}"
        fi

        return 0
    fi

    # Run system prune
    log "INFO" "Executing system prune..."

    if [ "$JSON_OUTPUT" != true ]; then
        echo -e "${COLOR_CYAN}${COLOR_BOLD}Executing system prune...${COLOR_RESET}"
    fi

    local start_time=$(date +%s)

    if [ "$JSON_OUTPUT" = true ]; then
        local output=$(docker system prune --all --volumes --force 2>&1)
        local prune_result=$?

        # Extract the amount of space reclaimed
        local total_reclaimed=$(echo "$output" | grep -o "Total reclaimed space: .*" | sed 's/Total reclaimed space: //')
    else
        docker system prune --all --volumes --force
        local prune_result=$?

        # Try to extract the amount of space reclaimed
        local total_reclaimed=$(docker system df --format '{{json .}}' | grep -o '"TotalSize":"[^"]*"' | cut -d'"' -f4)
    fi

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    if [ $prune_result -eq 0 ]; then
        log "INFO" "System prune completed successfully in $duration seconds"

        if [ "$JSON_OUTPUT" = true ]; then
            echo '{"operation":"system_prune","status":"success","duration_seconds":'$duration',"space_freed":"'$total_reclaimed'"}'
        else
            echo -e "${COLOR_GREEN}System prune completed successfully${COLOR_RESET}"
            if [ -n "$total_reclaimed" ]; then
                echo -e "${COLOR_GREEN}Total space reclaimed: $total_reclaimed${COLOR_RESET}"
            fi
        fi
    else
        log "ERROR" "System prune failed with exit code $prune_result"

        if [ "$JSON_OUTPUT" = true ]; then
            # Escape output for JSON
            if [ -n "$output" ]; then
                output=$(echo "$output" | sed 's/"/\\"/g')
                echo '{"operation":"system_prune","status":"error","exit_code":'$prune_result',"duration_seconds":'$duration',"output":"'"$output"'"}'
            else
                echo '{"operation":"system_prune","status":"error","exit_code":'$prune_result',"duration_seconds":'$duration'}'
            fi
        else
            echo -e "${COLOR_RED}System prune failed${COLOR_RESET}"
        fi

        return 1
    fi
}

# Parse JSON for Docker system information
parse_json_value() {
    local json="$1"
    local key="$2"

    if [ -z "$json" ]; then
        echo "Unknown"
        return 1
    fi

    # Use jq if available
    if command_exists jq; then
        local value
        value=$(echo "$json" | jq -r ".$key" 2>/dev/null)
        if [ $? -eq 0 ] && [ "$value" != "null" ] && [ -n "$value" ]; then
            echo "$value"
            return 0
        fi
    fi

    # Fallback to grep/sed
    local value
    value=$(echo "$json" | grep -o "\"$key\":\"[^\"]*\"" | cut -d':' -f2 | tr -d '"')
    if [ -n "$value" ]; then
        echo "$value"
    else
        echo "Unknown"
    fi
}

# Display system information
show_system_information() {
    log "INFO" "Collecting Docker system information..."

    if [ "$JSON_OUTPUT" = true ]; then
        # Build a comprehensive JSON object for system info
        local system_info="{"

        # Docker version info
        local docker_version_json
        docker_version_json=$(docker version --format '{{json .}}' 2>/dev/null)
        local client_version
        local server_version

        if [ $? -eq 0 ] && [ -n "$docker_version_json" ]; then
            client_version=$(parse_json_value "$docker_version_json" "Version")
            server_version=$(parse_json_value "$docker_version_json" "Version")
        else
            # Fallback if --format not supported
            client_version=$(docker version | grep -A2 "Client:" | grep "Version:" | sed 's/.*Version:[[:space:]]*//')
            server_version=$(docker version | grep -A2 "Server:" | grep "Version:" | sed 's/.*Version:[[:space:]]*//')
        fi

        system_info+='"docker":{"client_version":"'$client_version'","server_version":"'$server_version'"},'

        # System disk usage - handle potential Docker System API errors gracefully
        local system_df
        system_df=$(docker system df --format '{{json .}}' 2>/dev/null)
        if [ $? -eq 0 ] && [ -n "$system_df" ]; then
            system_info+='"disk_usage":'$system_df','
        else
            system_info+='"disk_usage":{"error":"Could not retrieve system disk usage"},'
        fi

        # Current resources - count safely with || true to handle errors
        local images_count=$(docker images -q | wc -l || echo "0")
        local containers_all=$(docker ps -a -q | wc -l || echo "0")
        local containers_running=$(docker ps -q | wc -l || echo "0")
        local volumes_count=$(docker volume ls -q | wc -l || echo "0")
        local networks_count=$(docker network ls -q | wc -l || echo "0")

        system_info+='"resources":{"images":'$images_count',"containers_all":'$containers_all',"containers_running":'$containers_running',"volumes":'$volumes_count',"networks":'$networks_count'},'

        # Borg repository info if available
        if command_exists borg && borg info "$BACKUP_DIR" >/dev/null 2>&1; then
            local archive_count=$(borg list --short "$BACKUP_DIR" 2>/dev/null | wc -l)
            local repo_info=$(borg info --json "$BACKUP_DIR" 2>/dev/null)

            if [ -n "$repo_info" ]; then
                system_info+='"borg_repository":{"path":"'$BACKUP_DIR'","archives":'$archive_count','

                # Get repository size info
                local total_size=$(echo "$repo_info" | grep -o '"total_size":[0-9]*' | grep -o '[0-9]*')
                local total_unique=$(echo "$repo_info" | grep -o '"unique_size":[0-9]*' | grep -o '[0-9]*')

                if [ -n "$total_size" ] && [ -n "$total_unique" ]; then
                    # Convert to MB
                    total_size=$(echo "scale=2; $total_size/1024/1024" | bc)
                    total_unique=$(echo "scale=2; $total_unique/1024/1024" | bc)

                    system_info+='"total_size_mb":'$total_size',"unique_data_mb":'$total_unique

                    # Calculate deduplication ratio if possible
                    if [ "$(echo "$total_unique > 0" | bc)" -eq 1 ]; then
                        local dedup_ratio=$(echo "scale=2; $total_size / $total_unique" | bc)
                        system_info+=',"deduplication_ratio":'$dedup_ratio
                    fi
                fi

                system_info+='},'
            else
                system_info+='"borg_repository":{"path":"'$BACKUP_DIR'","archives":'$archive_count',"error":"Could not retrieve repository info"},'
            fi
        fi

        # Host disk usage
        if command -v df >/dev/null 2>&1; then
            local docker_root
            docker_root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo "/var/lib/docker")
            local df_output
            df_output=$(df -h "$docker_root" | awk 'NR==2 {print $1","$2","$3","$4","$5","$6}')

            if [ -n "$df_output" ]; then
                local IFS=','
                read -ra df_fields <<<"$df_output"

                system_info+='"host_disk_usage":{"filesystem":"'${df_fields[0]}'","size":"'${df_fields[1]}'","used":"'${df_fields[2]}'","available":"'${df_fields[3]}'","use_percent":"'${df_fields[4]}'","mounted_on":"'${df_fields[5]}'"}'
            else
                system_info+='"host_disk_usage":{"error":"Could not retrieve host disk usage"}'
            fi
        fi

        system_info+="}"

        # Output the complete JSON
        echo "$system_info"
    else
        echo ""
        echo -e "${COLOR_CYAN}${COLOR_BOLD}Docker System Information:${COLOR_RESET}"
        echo -e "${COLOR_CYAN}-------------------------${COLOR_RESET}"

        # Docker version info
        echo -e "${COLOR_BLUE}Docker Version:${COLOR_RESET}"
        docker version --format "Client: ${COLOR_GREEN}{{.Client.Version}}${COLOR_RESET}, Server: ${COLOR_GREEN}{{.Server.Version}}${COLOR_RESET}" 2>/dev/null || {
            local client_ver=$(docker version | grep -A2 "Client:" | grep "Version:" | sed 's/.*Version:[[:space:]]*//')
            local server_ver=$(docker version | grep -A2 "Server:" | grep "Version:" | sed 's/.*Version:[[:space:]]*//')
            echo -e "Client: ${COLOR_GREEN}$client_ver${COLOR_RESET}, Server: ${COLOR_GREEN}$server_ver${COLOR_RESET}"
        }

        # System disk usage
        echo ""
        echo -e "${COLOR_BLUE}Docker Disk Usage Summary:${COLOR_RESET}"
        docker system df 2>/dev/null || echo -e "${COLOR_YELLOW}  Could not retrieve disk usage information${COLOR_RESET}"

        # Current resources
        echo ""
        echo -e "${COLOR_BLUE}Current Resources:${COLOR_RESET}"
        echo -e "  ${COLOR_GREEN}Images:${COLOR_RESET} $(docker images -q | wc -l)"
        echo -e "  ${COLOR_GREEN}Containers (all):${COLOR_RESET} $(docker ps -a -q | wc -l)"
        echo -e "  ${COLOR_GREEN}Containers (running):${COLOR_RESET} $(docker ps -q | wc -l)"
        echo -e "  ${COLOR_GREEN}Volumes:${COLOR_RESET} $(docker volume ls -q | wc -l)"
        echo -e "  ${COLOR_GREEN}Networks:${COLOR_RESET} $(docker network ls -q | wc -l)"

        # Show Borg repository info if available
        if command_exists borg && borg info "$BACKUP_DIR" >/dev/null 2>&1; then
            echo ""
            echo -e "${COLOR_BLUE}Borg Repository Information:${COLOR_RESET}"

            # Get number of archives
            local archive_count=$(borg list --short "$BACKUP_DIR" 2>/dev/null | wc -l)
            echo -e "  ${COLOR_GREEN}Repository:${COLOR_RESET} $BACKUP_DIR"
            echo -e "  ${COLOR_GREEN}Archives:${COLOR_RESET} $archive_count"

            # Get repository size
            local repo_info=$(borg info --json "$BACKUP_DIR" 2>/dev/null)
            if [ -n "$repo_info" ]; then
                local total_size=$(echo "$repo_info" | grep -o '"total_size":[0-9]*' | grep -o '[0-9]*')
                local total_unique=$(echo "$repo_info" | grep -o '"unique_size":[0-9]*' | grep -o '[0-9]*')

                # Convert to human-readable format
                if [ -n "$total_size" ] && [ -n "$total_unique" ]; then
                    # Convert to MB
                    total_size=$((total_size / 1024 / 1024))
                    total_unique=$((total_unique / 1024 / 1024))
                    echo -e "  ${COLOR_GREEN}Total Size:${COLOR_RESET} ${total_size}MB"
                    echo -e "  ${COLOR_GREEN}Unique Data:${COLOR_RESET} ${total_unique}MB"

                    # Calculate deduplication ratio if possible
                    if [ "$total_unique" -gt 0 ]; then
                        local dedup_ratio=$(echo "scale=2; $total_size / $total_unique" | bc)
                        echo -e "  ${COLOR_GREEN}Deduplication Ratio:${COLOR_RESET} ${dedup_ratio}x"
                    fi
                fi
            fi
        fi

        # Show host disk usage
        if command -v df >/dev/null 2>&1; then
            echo ""
            echo -e "${COLOR_BLUE}Host Disk Usage:${COLOR_RESET}"
            # Get Docker root directory safely
            local docker_root
            docker_root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo "/var/lib/docker")
            df -h "$docker_root" | head -2
        fi

        echo ""
    fi
}

# Function to display a nice header
display_header() {
    if [ "$JSON_OUTPUT" != true ]; then
        echo -e "${COLOR_CYAN}${COLOR_BOLD}"
        echo "======================================================="
        echo "        Docker Volume Tools - Cleanup"
        echo "======================================================="
        echo -e "${COLOR_RESET}"
    fi
}

# Main execution
main() {
    # Skip header in JSON mode
    if [ "$JSON_OUTPUT" != true ]; then
        display_header
    fi

    log "INFO" "Starting Docker cleanup process"

    # Obtain lock to prevent multiple instances running
    obtain_lock

    # Verify permissions
    verify_docker_access

    # Check Borg installation if needed
    check_borg_installation

    # Display dry run warning if enabled
    if [ "$DRY_RUN" = true ] && [ "$JSON_OUTPUT" != true ]; then
        echo -e "${COLOR_YELLOW}DRY RUN MODE: No resources will be removed${COLOR_RESET}"
        log "INFO" "Running in dry run mode"
    fi

    # Show system information first, unless in JSON mode
    if [ "$JSON_OUTPUT" != true ]; then
        show_system_information
    fi

    # Run selected cleanup operations
    if [ "$PRUNE_ALL" = true ]; then
        run_system_prune
    else
        if [ "$CLEAN_ALL" = true ]; then
            CLEAN_VOLUMES=true
            CLEAN_IMAGES=true
            CLEAN_CONTAINERS=true
            CLEAN_NETWORKS=true
            CLEAN_BUILDER=true
        fi

        if [ "$CLEAN_VOLUMES" = true ]; then
            clean_volumes
        fi

        if [ "$CLEAN_IMAGES" = true ]; then
            clean_images
        fi

        if [ "$CLEAN_CONTAINERS" = true ]; then
            clean_containers
        fi

        if [ "$CLEAN_NETWORKS" = true ]; then
            clean_networks
        fi

        if [ "$CLEAN_BUILDER" = true ]; then
            clean_builder
        fi

        if [ "$CLEAN_BORG" = true ]; then
            clean_borg
        fi

        if [ "$OLD_BACKUPS_DAYS" -gt 0 ]; then
            clean_old_backups "$OLD_BACKUPS_DAYS"
        fi

        if [ "$CLEAN_ALL_BORG" = true ]; then
            clean_all_borg
        fi
    fi

    log "INFO" "Docker cleanup process completed"

    # Print cleanup summary, unless in JSON mode
    if [ "$JSON_OUTPUT" != true ]; then
        if [ "$DRY_RUN" = true ]; then
            echo -e "${COLOR_YELLOW}Dry run completed. No resources were removed.${COLOR_RESET}"
        else
            echo -e "${COLOR_GREEN}${COLOR_BOLD}Cleanup completed successfully!${COLOR_RESET}"
        fi

        # Display total disk space reclaimed (if available)
        if command -v df >/dev/null 2>&1; then
            echo -e "${COLOR_BLUE}Current disk usage:${COLOR_RESET}"
            local docker_root
            docker_root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo "/var/lib/docker")
            df -h "$docker_root"
        fi
    else
        # Get current disk usage for JSON output
        if command -v df >/dev/null 2>&1; then
            local docker_root
            docker_root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo "/var/lib/docker")
            local df_output
            df_output=$(df -h "$docker_root" | awk 'NR==2 {print $1","$2","$3","$4","$5","$6}')

            if [ -n "$df_output" ]; then
                local IFS=','
                read -ra df_fields <<<"$df_output"

                echo '{"status":"completed","message":"Docker cleanup process completed","dry_run":'$DRY_RUN',"current_disk_usage":{"filesystem":"'${df_fields[0]}'","size":"'${df_fields[1]}'","used":"'${df_fields[2]}'","available":"'${df_fields[3]}'","use_percent":"'${df_fields[4]}'","mounted_on":"'${df_fields[5]}'"}}'
            else
                echo '{"status":"completed","message":"Docker cleanup process completed","dry_run":'$DRY_RUN'}'
            fi
        else
            echo '{"status":"completed","message":"Docker cleanup process completed","dry_run":'$DRY_RUN'}'
        fi
    fi

    # Release lock before exit
    if [ -f "$LOCK_FILE" ]; then
        rm -f "$LOCK_FILE"
        log "INFO" "Lock file released"
    fi
}

# Register trap for cleanup
trap handle_signal EXIT INT TERM

# Ensure log directory exists
ensure_log_directory

# Run the main function
main
