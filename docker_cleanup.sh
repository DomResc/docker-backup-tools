#!/bin/bash
# Docker Cleanup - A utility to clean unused Docker resources
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
DEFAULT_LOG_DIR="/backup/docker"
LOG_FILE="${DEFAULT_LOG_DIR}/docker_cleanup.log"

# Global container ID for the Alpine container used for cleanup operations
ALPINE_CONTAINER_ID=""

# Parse command line arguments
usage() {
  echo "Usage: $0 [OPTIONS]"
  echo "Clean up unused Docker resources"
  echo ""
  echo "Options:"
  echo "  -v, --volumes          Clean unused volumes"
  echo "  -i, --images           Clean dangling images"
  echo "  -c, --containers       Remove stopped containers"
  echo "  -n, --networks         Remove unused networks"
  echo "  -b, --builder          Clean up builder cache"
  echo "  -t, --temp             Clean temporary restore volumes"
  echo "  -a, --all              Clean all of the above"
  echo "  -x, --prune-all        Run Docker system prune with all options (CAUTION: removes ALL unused objects)"
  echo "  -d, --dry-run          Show what would be removed without actually removing"
  echo "  -f, --force            Don't ask for confirmation"
  echo "  -l, --log-dir DIR      Custom log directory (default: ${DEFAULT_LOG_DIR})"
  echo "  -h, --help             Display this help message"
  exit 1
}

# Initialize flags
CLEAN_VOLUMES=false
CLEAN_IMAGES=false
CLEAN_CONTAINERS=false
CLEAN_NETWORKS=false
CLEAN_BUILDER=false
CLEAN_TEMP_VOLUMES=false
CLEAN_ALL=false
PRUNE_ALL=false
DRY_RUN=false
FORCE=false
LOG_DIR=$DEFAULT_LOG_DIR

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
  -t | --temp)
    CLEAN_TEMP_VOLUMES=true
    shift
    ;;
  -a | --all)
    CLEAN_ALL=true
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
  -l | --log-dir)
    LOG_DIR="$2"
    LOG_FILE="${LOG_DIR}/docker_cleanup.log"
    shift 2
    ;;
  -h | --help)
    usage
    ;;
  *)
    echo "Unknown option: $1"
    usage
    ;;
  esac
done

# Set up logging
if [ ! -d "$LOG_DIR" ]; then
  mkdir -p "$LOG_DIR"
fi

if [ ! -f "$LOG_FILE" ]; then
  touch "$LOG_FILE"
fi

# Logging function
log() {
  local level="$1"
  local message="$2"
  local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Function to create and prepare Alpine container (if needed for volume operations)
create_alpine_container() {
  log "INFO" "Creating Alpine container for cleanup helper operations..."

  # Create a unique name for the container based on date and a random string
  local container_name="docker_volume_cleanup_$(date +%Y%m%d%H%M%S)_$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 6 | head -n 1)"

  # Create a long-running container with useful tools installed
  ALPINE_CONTAINER_ID=$(docker run -d \
    --name "$container_name" \
    alpine sh -c "apk add --no-cache coreutils findutils && tail -f /dev/null")

  if [ -z "$ALPINE_CONTAINER_ID" ] || ! docker ps -q --filter "id=$ALPINE_CONTAINER_ID" >/dev/null 2>&1; then
    log "ERROR" "Failed to create Alpine container for cleanup operations"
    echo "ERROR: Failed to create Alpine container"
    return 1
  fi

  log "INFO" "Alpine container created: $container_name ($ALPINE_CONTAINER_ID)"
  return 0
}

# Function to remove Alpine container
remove_alpine_container() {
  if [ -n "$ALPINE_CONTAINER_ID" ] && docker ps -q --filter "id=$ALPINE_CONTAINER_ID" >/dev/null 2>&1; then
    log "INFO" "Removing Alpine container..."
    if ! docker rm -f "$ALPINE_CONTAINER_ID" >/dev/null 2>&1; then
      log "WARNING" "Failed to remove Alpine container $ALPINE_CONTAINER_ID"
    else
      log "INFO" "Alpine container removed successfully"
    fi
  fi
}

# Function to ensure the Alpine container is removed on script exit or error
cleanup_on_exit() {
  log "INFO" "Running cleanup on exit..."
  remove_alpine_container
  log "INFO" "Cleanup completed"
}

# Register trap for cleanup
trap cleanup_on_exit EXIT INT TERM

# If no options provided, show usage
if [ "$CLEAN_VOLUMES" = false ] && [ "$CLEAN_IMAGES" = false ] && [ "$CLEAN_CONTAINERS" = false ] && [ "$CLEAN_NETWORKS" = false ] && [ "$CLEAN_BUILDER" = false ] && [ "$CLEAN_TEMP_VOLUMES" = false ] && [ "$CLEAN_ALL" = false ] && [ "$PRUNE_ALL" = false ]; then
  echo "No cleanup options specified."
  usage
fi

# If all is selected, set all options to true
if [ "$CLEAN_ALL" = true ]; then
  CLEAN_VOLUMES=true
  CLEAN_IMAGES=true
  CLEAN_CONTAINERS=true
  CLEAN_NETWORKS=true
  CLEAN_BUILDER=true
  CLEAN_TEMP_VOLUMES=true
fi

# Verify Docker access
verify_permissions() {
  # Check if the user can execute docker commands
  if ! docker ps >/dev/null 2>&1; then
    log "ERROR" "Current user cannot execute Docker commands."
    echo "ERROR: Current user cannot execute Docker commands."
    echo "Make sure you are in the 'docker' group or are root:"
    echo "sudo usermod -aG docker $USER"
    echo "After adding to the group, restart your session (logout/login)."
    exit 1
  fi

  log "INFO" "Docker access verified."
}

# Helper function to ask for confirmation
confirm_action() {
  local message="$1"

  if [ "$FORCE" = true ]; then
    return 0
  fi

  read -p "$message (y/n): " confirm
  if [ "$confirm" = "y" ]; then
    return 0
  else
    return 1
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
    echo "No unused volumes to remove."
    return 0
  fi

  echo "Found ${#unused_volumes[@]} unused volumes:"
  for volume in "${unused_volumes[@]}"; do
    echo "  - $volume"
  done

  # Exit here if dry run
  if [ "$DRY_RUN" = true ]; then
    log "INFO" "Dry run: would have removed ${#unused_volumes[@]} volumes"
    return 0
  fi

  # Ask for confirmation
  if ! confirm_action "Remove ${#unused_volumes[@]} unused volumes?"; then
    log "INFO" "Volume cleanup canceled by user"
    echo "Volume cleanup canceled."
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
  echo "Volume cleanup completed. Removed: $removed, Failed: $failed"
}

# Clean temporary restore volumes
clean_temp_volumes() {
  log "INFO" "Checking for temporary restore volumes..."

  # Get list of temporary restore volumes
  local temp_volumes=$(docker volume ls -q | grep "^temp_restore_")

  if [ -z "$temp_volumes" ]; then
    log "INFO" "No temporary restore volumes found."
    echo "No temporary restore volumes to remove."
    return 0
  fi

  local temp_volume_count=$(echo "$temp_volumes" | wc -l)
  echo "Found $temp_volume_count temporary restore volume(s):"
  echo "$temp_volumes"

  # Exit here if dry run
  if [ "$DRY_RUN" = true ]; then
    log "INFO" "Dry run: would have removed $temp_volume_count temporary volumes"
    return 0
  fi

  # Ask for confirmation
  if ! confirm_action "Remove $temp_volume_count temporary volumes?"; then
    log "INFO" "Temporary volume cleanup canceled by user"
    echo "Temporary volume cleanup canceled."
    return 0
  fi

  # Create Alpine container if needed for volume inspection
  if [ "$DRY_RUN" != true ]; then
    create_alpine_container
  fi

  # Remove temporary volumes
  local removed=0
  local failed=0

  for volume in $temp_volumes; do
    # Display volume information if available
    if [ -n "$ALPINE_CONTAINER_ID" ]; then
      # Mount volume to container and check contents
      local file_count=$(docker run --rm -v "$volume:/vol_to_check" alpine sh -c "find /vol_to_check -type f | wc -l")
      local size=$(docker run --rm -v "$volume:/vol_to_check" alpine sh -c "du -sh /vol_to_check | cut -f1")
      log "INFO" "Temporary volume: $volume, Size: $size, Files: $file_count"
      echo "  - $volume (Size: $size, Files: $file_count)"
    fi

    log "INFO" "Removing temporary volume: $volume"
    if docker volume rm "$volume" >/dev/null 2>&1; then
      log "INFO" "Temporary volume $volume removed successfully"
      removed=$((removed + 1))
    else
      log "ERROR" "Failed to remove temporary volume $volume"
      failed=$((failed + 1))
    fi
  done

  log "INFO" "Temporary volume cleanup completed. Removed: $removed, Failed: $failed"
  echo "Temporary volume cleanup completed. Removed: $removed, Failed: $failed"
}

# Clean dangling images
clean_images() {
  log "INFO" "Checking for dangling images..."

  # Get list of dangling images
  local dangling_images=$(docker images -f "dangling=true" -q)

  if [ -z "$dangling_images" ]; then
    log "INFO" "No dangling images found."
    echo "No dangling images to remove."
    return 0
  fi

  local image_count=$(echo "$dangling_images" | wc -l)
  echo "Found $image_count dangling image(s)"

  # Exit here if dry run
  if [ "$DRY_RUN" = true ]; then
    log "INFO" "Dry run: would have removed $image_count dangling images"
    return 0
  fi

  # Ask for confirmation
  if ! confirm_action "Remove $image_count dangling images?"; then
    log "INFO" "Image cleanup canceled by user"
    echo "Image cleanup canceled."
    return 0
  fi

  # Remove dangling images
  log "INFO" "Removing dangling images..."
  if docker rmi $dangling_images >/dev/null 2>&1; then
    log "INFO" "Successfully removed $image_count dangling images"
    echo "Successfully removed $image_count dangling images"
  else
    log "WARNING" "Some dangling images could not be removed"
    echo "Some dangling images could not be removed"
  fi
}

# Clean stopped containers
clean_containers() {
  log "INFO" "Checking for stopped containers..."

  # Get list of stopped containers
  local stopped_containers=$(docker ps -a -f "status=exited" -q)

  if [ -z "$stopped_containers" ]; then
    log "INFO" "No stopped containers found."
    echo "No stopped containers to remove."
    return 0
  fi

  local container_count=$(echo "$stopped_containers" | wc -l)
  echo "Found $container_count stopped container(s)"

  # Show more details about the containers
  if [ "$container_count" -gt 0 ]; then
    echo "Details of stopped containers:"
    docker ps -a -f "status=exited" --format "  - {{.Names}} (ID: {{.ID}}, Image: {{.Image}}, Exited: {{.Status}})"
  fi

  # Exit here if dry run
  if [ "$DRY_RUN" = true ]; then
    log "INFO" "Dry run: would have removed $container_count stopped containers"
    return 0
  fi

  # Ask for confirmation
  if ! confirm_action "Remove $container_count stopped containers?"; then
    log "INFO" "Container cleanup canceled by user"
    echo "Container cleanup canceled."
    return 0
  fi

  # Remove stopped containers
  log "INFO" "Removing stopped containers..."
  if docker rm $stopped_containers >/dev/null 2>&1; then
    log "INFO" "Successfully removed $container_count stopped containers"
    echo "Successfully removed $container_count stopped containers"
  else
    log "WARNING" "Some stopped containers could not be removed"
    echo "Some stopped containers could not be removed"

    # Try to show which ones failed
    local remaining=$(docker ps -a -f "status=exited" -q)
    if [ -n "$remaining" ]; then
      local remaining_count=$(echo "$remaining" | wc -l)
      echo "Containers that could not be removed ($remaining_count):"
      docker ps -a -f "status=exited" --format "  - {{.Names}} (ID: {{.ID}}, Image: {{.Image}})"
    fi
  fi
}

# Clean unused networks
clean_networks() {
  log "INFO" "Checking for unused networks..."

  # Get list of custom networks
  local all_networks=$(docker network ls --filter "type=custom" -q)

  if [ -z "$all_networks" ]; then
    log "INFO" "No custom networks found."
    echo "No custom networks to check."
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
    echo "No unused networks to remove."
    return 0
  fi

  echo "Found ${#unused_networks[@]} unused network(s):"
  for network_info in "${unused_networks[@]}"; do
    local id=$(echo "$network_info" | cut -d':' -f1)
    local name=$(echo "$network_info" | cut -d':' -f2)
    echo "  - $name ($id)"
  done

  # Exit here if dry run
  if [ "$DRY_RUN" = true ]; then
    log "INFO" "Dry run: would have removed ${#unused_networks[@]} networks"
    return 0
  fi

  # Ask for confirmation
  if ! confirm_action "Remove ${#unused_networks[@]} unused networks?"; then
    log "INFO" "Network cleanup canceled by user"
    echo "Network cleanup canceled."
    return 0
  fi

  # Remove unused networks
  local removed=0
  local failed=0

  for network_info in "${unused_networks[@]}"; do
    local id=$(echo "$network_info" | cut -d':' -f1)
    local name=$(echo "$network_info" | cut -d':' -f2)

    log "INFO" "Removing unused network: $name"
    local error_output
    if error_output=$(docker network rm "$id" 2>&1); then
      log "INFO" "Network $name removed successfully"
      removed=$((removed + 1))
    else
      log "ERROR" "Failed to remove network $name: $error_output"
      echo "Failed to remove network $name: $error_output"
      failed=$((failed + 1))
      if echo "$error_output" | grep -q "has active endpoints"; then
        log "WARNING" "Network $name has active endpoints or dependencies that prevent removal"
        echo "WARNING: Network $name has active endpoints or dependencies that prevent removal"
      fi
    fi
  done

  log "INFO" "Network cleanup completed. Removed: $removed, Failed: $failed"
  echo "Network cleanup completed. Removed: $removed, Failed: $failed"
}

# Clean builder cache
clean_builder() {
  log "INFO" "Cleaning Docker builder cache..."

  # Exit here if dry run
  if [ "$DRY_RUN" = true ]; then
    log "INFO" "Dry run: would have cleaned builder cache"
    echo "Dry run: would have cleaned builder cache"
    return 0
  fi

  # Ask for confirmation
  if ! confirm_action "Clean Docker builder cache?"; then
    log "INFO" "Builder cache cleanup canceled by user"
    echo "Builder cache cleanup canceled."
    return 0
  fi

  # Clean builder cache
  if docker builder prune -f >/dev/null 2>&1; then
    log "INFO" "Successfully cleaned builder cache"
    echo "Successfully cleaned builder cache"
  else
    log "ERROR" "Failed to clean builder cache"
    echo "Failed to clean builder cache"
  fi
}

# Run Docker system prune
run_system_prune() {
  log "INFO" "Running Docker system prune (all)..."

  # Exit here if dry run
  if [ "$DRY_RUN" = true ]; then
    log "INFO" "Dry run: would have run system prune with all options"
    echo "Dry run: would have run system prune with all options"
    return 0
  fi

  # Ask for confirmation
  echo "CAUTION: Docker system prune with --all --volumes will remove:"
  echo "  - all stopped containers"
  echo "  - all networks not used by at least one container"
  echo "  - all volumes not used by at least one container"
  echo "  - all images without at least one container associated to them"
  echo "  - all build cache"

  if ! confirm_action "This operation cannot be undone. Continue?"; then
    log "INFO" "System prune canceled by user"
    echo "System prune canceled."
    return 0
  fi

  # Run system prune
  log "INFO" "Executing system prune..."
  docker system prune --all --volumes --force

  log "INFO" "System prune completed"
  echo "System prune completed"
}

# Display system information
show_system_information() {
  log "INFO" "Collecting Docker system information..."
  echo ""
  echo "Docker System Information:"
  echo "-------------------------"

  # Docker version info
  echo "Docker Version:"
  docker version --format 'Client: {{.Client.Version}}, Server: {{.Server.Version}}'

  # System disk usage
  echo ""
  echo "Docker Disk Usage Summary:"
  docker system df

  # Current resources
  echo ""
  echo "Current Resources:"
  echo "  Images: $(docker images -q | wc -l)"
  echo "  Containers (all): $(docker ps -a -q | wc -l)"
  echo "  Containers (running): $(docker ps -q | wc -l)"
  echo "  Volumes: $(docker volume ls -q | wc -l)"
  echo "  Networks: $(docker network ls -q | wc -l)"

  if command -v df >/dev/null 2>&1; then
    echo ""
    echo "Host Disk Usage:"
    df -h $(docker info --format '{{.DockerRootDir}}' | cut -d':' -f1) | head -2
  fi

  echo ""
}

# Main execution
log "INFO" "==========================================="
log "INFO" "Starting Docker cleanup process"
log "INFO" "==========================================="

# Verify permissions
verify_permissions

# Display dry run warning if enabled
if [ "$DRY_RUN" = true ]; then
  echo "DRY RUN MODE: No resources will be removed"
  log "INFO" "Running in dry run mode"
fi

# Show system information first
show_system_information

# Run selected cleanup operations
if [ "$PRUNE_ALL" = true ]; then
  run_system_prune
else
  if [ "$CLEAN_VOLUMES" = true ]; then
    clean_volumes
  fi

  if [ "$CLEAN_TEMP_VOLUMES" = true ]; then
    clean_temp_volumes
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
fi

log "INFO" "==========================================="
log "INFO" "Docker cleanup process completed"
log "INFO" "==========================================="

# Print cleanup summary
if [ "$DRY_RUN" = true ]; then
  echo "Dry run completed. No resources were removed."
else
  echo "Cleanup completed successfully!"
fi

# Display total disk space reclaimed (if available)
if command -v df >/dev/null 2>&1; then
  echo "Current disk usage:"
  df -h $(docker info --format '{{.DockerRootDir}}' | cut -d':' -f1)
fi

exit 0
