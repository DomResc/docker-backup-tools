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

# Verify Docker access
verify_docker_access() {
    # Check if the user can execute docker commands
    if ! docker ps >/dev/null 2>&1; then
        log "ERROR" "Current user cannot execute Docker commands."
        echo -e "${COLOR_RED}ERROR: Current user cannot execute Docker commands.${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}Make sure you are in the 'docker' group or are root:${COLOR_RESET}"
        echo -e "${COLOR_CYAN}sudo usermod -aG docker $USER${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}After adding to the group, restart your session (logout/login).${COLOR_RESET}"
        exit 1
    fi

    log "INFO" "Docker access verified."
}

# Check if Borg is installed
check_borg_installation() {
    if [ "$CLEAN_BORG" = true ] || [ "$CLEAN_ALL_BORG" = true ] || [ "$OLD_BACKUPS_DAYS" -gt 0 ]; then
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
                        log "INFO" "Cleanup canceled because Borg is not installed"
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
                        log "INFO" "Cleanup canceled because Borg is not installed"
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

        # Check if it's a valid borg repository
        if ! borg info "$BACKUP_DIR" >/dev/null 2>&1; then
            log "ERROR" "Directory $BACKUP_DIR is not a valid Borg repository"
            echo -e "${COLOR_RED}ERROR: Directory $BACKUP_DIR is not a valid Borg repository${COLOR_RESET}"
            exit 1
        fi

        log "INFO" "Borg Backup is installed and repository is valid"
    fi
}

# Helper function to ask for confirmation
confirm_action() {
    local message="$1"
    local require_yes="${2:-false}" # se true, richiede "yes" invece di "y"

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

# Clean unused volumes
clean_volumes() {
    log "INFO" "Checking for unused volumes..."

    # Get list of all volumes
    local all_volumes=$(docker volume ls -q)
    local unused_volumes=()

    if [ -z "$all_volumes" ]; then
        log "INFO" "No Docker volumes found."
        return 0
    fi

    # Find unused volumes
    for volume in $all_volumes; do
        # Skip if the volume is used by any container
        local used_by=$(docker ps -a --filter volume=$volume -q)
        if [ -z "$used_by" ]; then
            unused_volumes+=("$volume")
        fi
    done

    if [ ${#unused_volumes[@]} -eq 0 ]; then
        log "INFO" "No unused volumes found."
        echo -e "${COLOR_GREEN}No unused volumes to remove.${COLOR_RESET}"
        return 0
    fi

    echo -e "${COLOR_CYAN}Found ${#unused_volumes[@]} unused volumes:${COLOR_RESET}"
    for volume in "${unused_volumes[@]}"; do
        echo -e "  ${COLOR_YELLOW}*${COLOR_RESET} $volume"
    done

    # Exit here if dry run
    if [ "$DRY_RUN" = true ]; then
        log "INFO" "Dry run: would have removed ${#unused_volumes[@]} volumes"
        return 0
    fi

    # Ask for confirmation
    if ! confirm_action "Remove ${#unused_volumes[@]} unused volumes?"; then
        log "INFO" "Volume cleanup canceled by user"
        echo -e "${COLOR_GREEN}Volume cleanup canceled.${COLOR_RESET}"
        return 0
    fi

    # Remove unused volumes
    local removed=0
    local failed=0

    for volume in "${unused_volumes[@]}"; do
        log "INFO" "Removing unused volume: $volume"
        if docker volume rm "$volume" >/dev/null 2>&1; then
            log "INFO" "Volume $volume removed successfully"
            removed=$((removed + 1))
        else
            log "ERROR" "Failed to remove volume $volume"
            failed=$((failed + 1))
        fi
    done

    log "INFO" "Volume cleanup completed. Removed: $removed, Failed: $failed"
    echo -e "${COLOR_GREEN}Volume cleanup completed. Removed: $removed, Failed: $failed${COLOR_RESET}"
}

# Clean dangling images
clean_images() {
    log "INFO" "Checking for dangling images..."

    # Get list of dangling images
    local dangling_images=$(docker images -f "dangling=true" -q)

    if [ -z "$dangling_images" ]; then
        log "INFO" "No dangling images found."
        echo -e "${COLOR_GREEN}No dangling images to remove.${COLOR_RESET}"
        return 0
    fi

    local image_count=$(echo "$dangling_images" | wc -l)
    echo -e "${COLOR_CYAN}Found $image_count dangling image(s)${COLOR_RESET}"

    # Exit here if dry run
    if [ "$DRY_RUN" = true ]; then
        log "INFO" "Dry run: would have removed $image_count dangling images"
        return 0
    fi

    # Ask for confirmation
    if ! confirm_action "Remove $image_count dangling images?"; then
        log "INFO" "Image cleanup canceled by user"
        echo -e "${COLOR_GREEN}Image cleanup canceled.${COLOR_RESET}"
        return 0
    fi

    # Remove dangling images
    log "INFO" "Removing dangling images..."
    if docker rmi $dangling_images >/dev/null 2>&1; then
        log "INFO" "Successfully removed $image_count dangling images"
        echo -e "${COLOR_GREEN}Successfully removed $image_count dangling images${COLOR_RESET}"
    else
        log "WARNING" "Some dangling images could not be removed"
        echo -e "${COLOR_YELLOW}Some dangling images could not be removed${COLOR_RESET}"
    fi
}

# Clean stopped containers
clean_containers() {
    log "INFO" "Checking for stopped containers..."

    # Get list of stopped containers
    local stopped_containers=$(docker ps -a -f "status=exited" -q)

    if [ -z "$stopped_containers" ]; then
        log "INFO" "No stopped containers found."
        echo -e "${COLOR_GREEN}No stopped containers to remove.${COLOR_RESET}"
        return 0
    fi

    local container_count=$(echo "$stopped_containers" | wc -l)
    echo -e "${COLOR_CYAN}Found $container_count stopped container(s)${COLOR_RESET}"

    # Show more details about the containers
    if [ "$container_count" -gt 0 ]; then
        echo -e "${COLOR_CYAN}Details of stopped containers:${COLOR_RESET}"
        docker ps -a -f "status=exited" --format "  ${COLOR_YELLOW}*${COLOR_RESET} {{.Names}} (ID: {{.ID}}, Image: {{.Image}}, Exited: {{.Status}})"
    fi

    # Exit here if dry run
    if [ "$DRY_RUN" = true ]; then
        log "INFO" "Dry run: would have removed $container_count stopped containers"
        return 0
    fi

    # Ask for confirmation
    if ! confirm_action "Remove $container_count stopped containers?"; then
        log "INFO" "Container cleanup canceled by user"
        echo -e "${COLOR_GREEN}Container cleanup canceled.${COLOR_RESET}"
        return 0
    fi

    # Remove stopped containers
    log "INFO" "Removing stopped containers..."
    if docker rm $stopped_containers >/dev/null 2>&1; then
        log "INFO" "Successfully removed $container_count stopped containers"
        echo -e "${COLOR_GREEN}Successfully removed $container_count stopped containers${COLOR_RESET}"
    else
        log "WARNING" "Some stopped containers could not be removed"
        echo -e "${COLOR_YELLOW}Some stopped containers could not be removed${COLOR_RESET}"
    fi
}

# Clean unused networks
clean_networks() {
    log "INFO" "Checking for unused networks..."

    # Get list of custom networks
    local all_networks=$(docker network ls --filter "type=custom" -q)

    if [ -z "$all_networks" ]; then
        log "INFO" "No custom networks found."
        echo -e "${COLOR_GREEN}No custom networks to check.${COLOR_RESET}"
        return 0
    fi

    # Find unused networks
    local unused_networks=()

    for network in $all_networks; do
        # Check if network is used by any container
        local containers=$(docker network inspect --format='{{range .Containers}}{{.Name}} {{end}}' "$network" | awk '{$1=$1};1')
        if [ -z "$containers" ]; then
            local name=$(docker network inspect --format='{{.Name}}' "$network")
            unused_networks+=("$network:$name")
        fi
    done

    if [ ${#unused_networks[@]} -eq 0 ]; then
        log "INFO" "No unused networks found."
        echo -e "${COLOR_GREEN}No unused networks to remove.${COLOR_RESET}"
        return 0
    fi

    echo -e "${COLOR_CYAN}Found ${#unused_networks[@]} unused network(s):${COLOR_RESET}"
    for network_info in "${unused_networks[@]}"; do
        local id=$(echo "$network_info" | cut -d':' -f1)
        local name=$(echo "$network_info" | cut -d':' -f2)
        echo -e "  ${COLOR_YELLOW}*${COLOR_RESET} $name ($id)"
    done

    # Exit here if dry run
    if [ "$DRY_RUN" = true ]; then
        log "INFO" "Dry run: would have removed ${#unused_networks[@]} networks"
        return 0
    fi

    # Ask for confirmation
    if ! confirm_action "Remove ${#unused_networks[@]} unused networks?"; then
        log "INFO" "Network cleanup canceled by user"
        echo -e "${COLOR_GREEN}Network cleanup canceled.${COLOR_RESET}"
        return 0
    fi

    # Remove unused networks
    local removed=0
    local failed=0

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
        fi
    done

    log "INFO" "Network cleanup completed. Removed: $removed, Failed: $failed"
    echo -e "${COLOR_GREEN}Network cleanup completed. Removed: $removed, Failed: $failed${COLOR_RESET}"
}

# Clean builder cache
clean_builder() {
    log "INFO" "Cleaning Docker builder cache..."

    # Exit here if dry run
    if [ "$DRY_RUN" = true ]; then
        log "INFO" "Dry run: would have cleaned builder cache"
        echo -e "${COLOR_GREEN}Dry run: would have cleaned builder cache${COLOR_RESET}"
        return 0
    fi

    # Ask for confirmation
    if ! confirm_action "Clean Docker builder cache?"; then
        log "INFO" "Builder cache cleanup canceled by user"
        echo -e "${COLOR_GREEN}Builder cache cleanup canceled.${COLOR_RESET}"
        return 0
    fi

    # Clean builder cache
    if docker builder prune -f >/dev/null 2>&1; then
        log "INFO" "Successfully cleaned builder cache"
        echo -e "${COLOR_GREEN}Successfully cleaned builder cache${COLOR_RESET}"
    else
        log "ERROR" "Failed to clean builder cache"
        echo -e "${COLOR_RED}Failed to clean builder cache${COLOR_RESET}"
    fi
}

# Clean and compact Borg repository
clean_borg() {
    log "INFO" "Cleaning and compacting Borg repository..."
    echo -e "${COLOR_CYAN}Cleaning and compacting Borg repository at $BACKUP_DIR...${COLOR_RESET}"

    # Exit here if dry run
    if [ "$DRY_RUN" = true ]; then
        log "INFO" "Dry run: would have compacted Borg repository"
        echo -e "${COLOR_GREEN}Dry run: would have compacted Borg repository${COLOR_RESET}"
        return 0
    fi

    # Ask for confirmation
    if ! confirm_action "Compact Borg repository? This can take a long time for large repositories."; then
        log "INFO" "Borg compaction canceled by user"
        echo -e "${COLOR_GREEN}Borg compaction canceled.${COLOR_RESET}"
        return 0
    fi

    # First prune any locks that might exist
    log "INFO" "Checking for stale locks..."
    borg break-lock "$BACKUP_DIR" 2>/dev/null

    # Compact the repository
    log "INFO" "Compacting repository (this may take a while)..."
    echo -e "${COLOR_CYAN}${COLOR_BOLD}Compacting repository... This may take a long time for large repositories.${COLOR_RESET}"

    if borg compact --progress "$BACKUP_DIR"; then
        log "INFO" "Repository compaction completed successfully"
        echo -e "${COLOR_GREEN}Repository compaction completed successfully${COLOR_RESET}"
    else
        log "ERROR" "Repository compaction failed"
        echo -e "${COLOR_RED}Repository compaction failed${COLOR_RESET}"
        return 1
    fi

    return 0
}

# Clean old Borg backups
clean_old_backups() {
    local days="$1"
    log "INFO" "Removing backups older than $days days..."
    echo -e "${COLOR_CYAN}Removing backups older than $days days...${COLOR_RESET}"

    # Exit here if dry run
    if [ "$DRY_RUN" = true ]; then
        log "INFO" "Dry run: would have pruned backups older than $days days"
        borg prune --dry-run --keep-within ${days}d --list "$BACKUP_DIR"
        return 0
    fi

    # Ask for confirmation
    if ! confirm_action "Remove backups older than $days days?"; then
        log "INFO" "Backup pruning canceled by user"
        echo -e "${COLOR_GREEN}Backup pruning canceled.${COLOR_RESET}"
        return 0
    fi

    # Prune old backups
    if borg prune --stats --progress --keep-within ${days}d "$BACKUP_DIR"; then
        log "INFO" "Successfully pruned backups older than $days days"
        echo -e "${COLOR_GREEN}Successfully pruned backups older than $days days${COLOR_RESET}"
    else
        log "ERROR" "Failed to prune old backups"
        echo -e "${COLOR_RED}Failed to prune old backups${COLOR_RESET}"
        return 1
    fi

    return 0
}

# Clean all Borg backups
clean_all_borg() {
    log "INFO" "Preparing to remove ALL Borg backups..."
    echo -e "${COLOR_RED}${COLOR_BOLD}WARNING: This will remove ALL backups in the repository!${COLOR_RESET}"

    # Exit here if dry run
    if [ "$DRY_RUN" = true ]; then
        log "INFO" "Dry run: would have removed ALL Borg backups"
        echo -e "${COLOR_GREEN}Dry run: would have removed ALL Borg backups${COLOR_RESET}"
        return 0
    fi

    # Ask for extra confirmation for this dangerous operation
    echo -e "${COLOR_RED}${COLOR_BOLD}DANGER: This operation will delete ALL backups and CANNOT be undone!${COLOR_RESET}"
    if ! confirm_action "Are you ABSOLUTELY SURE you want to delete ALL backups?" true; then
        log "INFO" "Complete backup deletion canceled by user"
        echo -e "${COLOR_GREEN}Complete backup deletion canceled.${COLOR_RESET}"
        return 0
    fi

    # Double-check with an extra confirmation
    if ! confirm_action "Last chance! Are you really sure you want to delete ALL Docker backups?" true; then
        log "INFO" "Complete backup deletion canceled by user"
        echo -e "${COLOR_GREEN}Complete backup deletion canceled.${COLOR_RESET}"
        return 0
    fi

    # Remove all backups
    log "INFO" "Removing ALL Borg backups..."

    # First remove all the archives
    if borg prune --stats --progress --keep-within 0d "$BACKUP_DIR"; then
        log "INFO" "Successfully removed all backup archives"

        # Then compact the repository
        if borg compact --progress "$BACKUP_DIR"; then
            log "INFO" "Repository compaction completed successfully"
            echo -e "${COLOR_GREEN}All backups removed and repository compacted successfully${COLOR_RESET}"
        else
            log "ERROR" "Repository compaction failed after removing all backups"
            echo -e "${COLOR_YELLOW}All backups removed but repository compaction failed${COLOR_RESET}"
        fi
    else
        log "ERROR" "Failed to remove all backups"
        echo -e "${COLOR_RED}Failed to remove all backups${COLOR_RESET}"
        return 1
    fi

    return 0
}

# Run Docker system prune
run_system_prune() {
    log "INFO" "Running Docker system prune (all)..."

    # Exit here if dry run
    if [ "$DRY_RUN" = true ]; then
        log "INFO" "Dry run: would have run system prune with all options"
        echo -e "${COLOR_GREEN}Dry run: would have run system prune with all options${COLOR_RESET}"
        return 0
    fi

    # Ask for confirmation
    echo -e "${COLOR_YELLOW}${COLOR_BOLD}CAUTION: Docker system prune with --all --volumes will remove:${COLOR_RESET}"
    echo -e "  ${COLOR_YELLOW}* All stopped containers${COLOR_RESET}"
    echo -e "  ${COLOR_YELLOW}* All networks not used by at least one container${COLOR_RESET}"
    echo -e "  ${COLOR_YELLOW}* All volumes not used by at least one container${COLOR_RESET}"
    echo -e "  ${COLOR_YELLOW}* All images without at least one container associated to them${COLOR_RESET}"
    echo -e "  ${COLOR_YELLOW}* All build cache${COLOR_RESET}"

    if ! confirm_action "This operation cannot be undone. Continue?" true; then
        log "INFO" "System prune canceled by user"
        echo -e "${COLOR_GREEN}System prune canceled.${COLOR_RESET}"
        return 0
    fi

    # Run system prune
    log "INFO" "Executing system prune..."
    echo -e "${COLOR_CYAN}${COLOR_BOLD}Executing system prune...${COLOR_RESET}"
    docker system prune --all --volumes --force

    log "INFO" "System prune completed"
    echo -e "${COLOR_GREEN}System prune completed${COLOR_RESET}"
}

# Display system information
show_system_information() {
    log "INFO" "Collecting Docker system information..."
    echo ""
    echo -e "${COLOR_CYAN}${COLOR_BOLD}Docker System Information:${COLOR_RESET}"
    echo -e "${COLOR_CYAN}-------------------------${COLOR_RESET}"

    # Docker version info
    echo -e "${COLOR_BLUE}Docker Version:${COLOR_RESET}"
    docker version --format "Client: ${COLOR_GREEN}{{.Client.Version}}${COLOR_RESET}, Server: ${COLOR_GREEN}{{.Server.Version}}${COLOR_RESET}"

    # System disk usage
    echo ""
    echo -e "${COLOR_BLUE}Docker Disk Usage Summary:${COLOR_RESET}"
    docker system df

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
        local archive_count=$(borg list --short "$BACKUP_DIR" | wc -l)
        echo -e "  ${COLOR_GREEN}Repository:${COLOR_RESET} $BACKUP_DIR"
        echo -e "  ${COLOR_GREEN}Archives:${COLOR_RESET} $archive_count"

        # Get repository size
        local repo_info=$(borg info --json "$BACKUP_DIR" 2>/dev/null)
        if [ -n "$repo_info" ]; then
            local total_size=$(echo "$repo_info" | grep -o '"total_size":[0-9]*' | cut -d':' -f2)
            local total_unique=$(echo "$repo_info" | grep -o '"unique_size":[0-9]*' | cut -d':' -f2)

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
        df -h $(docker info --format '{{.DockerRootDir}}' | cut -d':' -f1) | head -2
    fi

    echo ""
}

# Function to display a nice header
display_header() {
    echo -e "${COLOR_CYAN}${COLOR_BOLD}"
    echo "======================================================="
    echo "        Docker Volume Tools - Cleanup"
    echo "======================================================="
    echo -e "${COLOR_RESET}"
}

# Main execution
main() {
    display_header

    log "INFO" "Starting Docker cleanup process"

    # Verify permissions
    verify_docker_access

    # Check Borg installation if needed
    check_borg_installation

    # Display dry run warning if enabled
    if [ "$DRY_RUN" = true ]; then
        echo -e "${COLOR_YELLOW}DRY RUN MODE: No resources will be removed${COLOR_RESET}"
        log "INFO" "Running in dry run mode"
    fi

    # Show system information first
    show_system_information

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

    # Print cleanup summary
    if [ "$DRY_RUN" = true ]; then
        echo -e "${COLOR_YELLOW}Dry run completed. No resources were removed.${COLOR_RESET}"
    else
        echo -e "${COLOR_GREEN}${COLOR_BOLD}Cleanup completed successfully!${COLOR_RESET}"
    fi

    # Display total disk space reclaimed (if available)
    if command -v df >/dev/null 2>&1; then
        echo -e "${COLOR_BLUE}Current disk usage:${COLOR_RESET}"
        df -h $(docker info --format '{{.DockerRootDir}}' | cut -d':' -f1)
    fi
}

# Ensure log directory exists
ensure_log_directory

# Run the main function
main
exit $?
