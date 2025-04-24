#!/bin/bash
# Docker Volume Restore - A utility to restore Docker volumes
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
MINIMUM_FREE_SPACE_MB=500 # Minimum required free space in MB

# Global container ID for the Alpine container used for restore operations
ALPINE_CONTAINER_ID=""

# Parse command line arguments
usage() {
  echo "Usage: $0 [OPTIONS] [VOLUME_NAME]"
  echo "Restore Docker volumes from backups"
  echo ""
  echo "Arguments:"
  echo "  VOLUME_NAME           Optional: Name of volume to restore (if omitted, will show menu)"
  echo ""
  echo "Options:"
  echo "  -d, --directory DIR   Backup directory (default: $DEFAULT_BACKUP_DIR)"
  echo "  -b, --backup DATE     Specific backup date to restore from (format: YYYY-MM-DD)"
  echo "                        If not specified, will show a menu of available dates"
  echo "  -f, --force           Don't ask for confirmation before stopping containers"
  echo "  -h, --help            Display this help message"
  echo ""
  echo "Environment variables:"
  echo "  DOCKER_BACKUP_DIR     Same as --directory"
  exit 1
}

# Get settings from environment variables or use defaults
BACKUP_DIR=${DOCKER_BACKUP_DIR:-$DEFAULT_BACKUP_DIR}
SPECIFIC_DATE=""
FORCE=false
VOLUME_ARG=""

# Map for tracking containers to restart
declare -A STOPPED_CONTAINERS

# Parse command line options
while [[ $# -gt 0 ]]; do
  case $1 in
  -d | --directory)
    BACKUP_DIR="$2"
    shift 2
    ;;
  -b | --backup)
    SPECIFIC_DATE="$2"
    # Validate date format (YYYY-MM-DD)
    if ! [[ "$SPECIFIC_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
      echo "ERROR: Invalid date format. Please use YYYY-MM-DD format."
      exit 1
    fi
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
    echo "Unknown option: $1"
    usage
    ;;
  *)
    VOLUME_ARG="$1"
    shift
    ;;
  esac
done

LOG_FILE="$BACKUP_DIR/docker_restore.log"

# Logging function
log() {
  local level="$1"
  local message="$2"
  local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Function to create and prepare Alpine container
create_alpine_container() {
  log "INFO" "Creating Alpine container for restore operations..."

  # Create a unique name for the container based on date and a random string
  local container_name="docker_volume_restore_$(date +%Y%m%d%H%M%S)_$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 6 | head -n 1)"

  # Create a long-running container with pigz installed
  ALPINE_CONTAINER_ID=$(docker run -d \
    --name "$container_name" \
    -v "$BACKUP_DIR:/backup" \
    alpine sh -c "apk add --no-cache pigz && tail -f /dev/null")

  if [ -z "$ALPINE_CONTAINER_ID" ] || ! docker ps -q --filter "id=$ALPINE_CONTAINER_ID" >/dev/null 2>&1; then
    log "ERROR" "Failed to create Alpine container for restore operations"
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

# Verify that the script is executed with necessary permissions
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

  # Check if backup directory exists
  if [ ! -d "$BACKUP_DIR" ]; then
    log "ERROR" "Backup directory $BACKUP_DIR does not exist."
    echo "ERROR: Backup directory $BACKUP_DIR does not exist."
    echo "Please check the path or create it first."
    exit 1
  fi

  log "INFO" "Necessary permissions verified."
}

# Check available disk space for restoration
check_disk_space() {
  local volume="$1"
  local backup_file="$2"

  log "INFO" "Checking available disk space for restoration"

  # Get backup file size in MB
  local backup_size_mb=$(du -m "$backup_file" | cut -f1)

  # Add 30% overhead for extraction
  local needed_space=$((backup_size_mb + (backup_size_mb * 30 / 100)))

  # Get available space
  local docker_root=$(docker info --format '{{.DockerRootDir}}')
  local available_space=$(df -m "$docker_root" | awk 'NR==2 {print $4}')

  log "INFO" "Backup size: $backup_size_mb MB"
  log "INFO" "Estimated space needed: $needed_space MB"
  log "INFO" "Available space: $available_space MB"

  if [ "$available_space" -lt "$needed_space" ]; then
    log "ERROR" "Insufficient disk space for restoration"
    echo "ERROR: Insufficient disk space for restoration"
    echo "Backup size: $backup_size_mb MB"
    echo "Estimated space needed: $needed_space MB"
    echo "Available space: $available_space MB"

    if [ "$FORCE" != "true" ]; then
      read -p "Available space may be insufficient. Continue anyway? (y/n): " confirm
      if [ "$confirm" != "y" ]; then
        log "INFO" "Restoration canceled by user due to space concerns"
        return 1
      fi
    fi

    log "WARNING" "Continuing restoration despite potential space issues"
  fi

  return 0
}

# Create log file if it doesn't exist
if [ ! -f "$LOG_FILE" ]; then
  mkdir -p $(dirname "$LOG_FILE")
  touch "$LOG_FILE"
  log "INFO" "Log file created at $LOG_FILE"
fi

# Verify permissions
verify_permissions

# Function to verify backup integrity
verify_backup() {
  local backup_file="$1"
  local backup_rel_path=$(basename "$backup_file")
  local backup_dir=$(dirname "$backup_file")

  log "INFO" "Verifying backup integrity: $backup_file"

  # Check if file exists
  if [ ! -f "$backup_file" ]; then
    log "ERROR" "Backup file not found: $backup_file"
    return 1
  fi

  # Verify the backup file is not empty
  local file_size=$(stat -c%s "$backup_file")
  if [ "$file_size" -eq 0 ]; then
    log "ERROR" "Backup file is empty: $backup_file"
    return 1
  fi

  # Use the Alpine container to verify backup integrity
  # First check gzip integrity
  if ! docker exec "$ALPINE_CONTAINER_ID" sh -c "pigz -t /backup/$(echo "$backup_file" | sed "s|^$BACKUP_DIR/||") 2>/dev/null"; then
    log "ERROR" "Integrity verification failed. The backup might be corrupted."
    return 1
  fi

  # Then check tar structure and content
  local backup_path_in_container="/backup/$(echo "$backup_file" | sed "s|^$BACKUP_DIR/||")"
  local file_count=$(docker exec "$ALPINE_CONTAINER_ID" sh -c "pigz -dc $backup_path_in_container 2>/dev/null | tar -t 2>/dev/null | wc -l")

  if [ "$file_count" -lt 1 ]; then
    log "ERROR" "Backup archive appears to be empty (no files found inside)"
    return 1
  fi

  log "INFO" "Integrity verification completed successfully (found $file_count files/directories)"
  return 0
}

# Function to show available backup dates
show_available_dates() {
  log "INFO" "Searching for available backup dates"

  # Find all backup directories sorted by date (most recent first)
  local backup_dates=()
  while IFS= read -r date_dir; do
    if [ -d "$date_dir" ]; then
      backup_dates+=("$date_dir")
    fi
  done < <(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d | sort -r)

  if [ ${#backup_dates[@]} -eq 0 ]; then
    log "WARNING" "No backup directories found in $BACKUP_DIR"
    echo "No backups found in $BACKUP_DIR"
    exit 1
  fi

  # Show dates with numbers
  echo "Available backup dates:"
  echo "-------------------------"
  local count=1
  for date_dir in "${backup_dates[@]}"; do
    local date_name=$(basename "$date_dir")
    echo "$count) Backup from $date_name"
    count=$((count + 1))
  done

  # Return the array of backup dates
  echo "${backup_dates[@]}"
}

# Function to show list of available volumes for restoration on a specific date
show_available_volumes() {
  local backup_date_dir="$1"

  log "INFO" "Searching for available volumes for restoration in $backup_date_dir"

  # Extract unique volume names from backup files
  local available_volumes=()
  while IFS= read -r volume_file; do
    if [ -f "$volume_file" ]; then
      local volume_name=$(basename "$volume_file" .tar.gz)
      available_volumes+=("$volume_name")
    fi
  done < <(find "$backup_date_dir" -name "*.tar.gz" -type f | sort)

  if [ ${#available_volumes[@]} -eq 0 ]; then
    log "WARNING" "No backups found in $backup_date_dir"
    echo "No backups found in $backup_date_dir"
    exit 1
  fi

  # Show volumes with numbers
  local backup_date=$(basename "$backup_date_dir")
  echo "Volumes available for restoration from $backup_date:"
  echo "------------------------------------"
  local count=1
  for vol in "${available_volumes[@]}"; do
    # Get file size
    local size=$(du -h "$backup_date_dir/$vol.tar.gz" | cut -f1)
    echo "$count) $vol (Size: $size)"
    count=$((count + 1))
  done

  # Return the array of available volumes
  echo "${available_volumes[@]}"
}

# Function to stop containers using a volume
stop_containers() {
  local volume="$1"

  # Find all containers using this volume
  local containers=$(docker ps -a --filter volume="$volume" --format "{{.Names}}")

  if [ -z "$containers" ]; then
    log "INFO" "No containers are using volume $volume"
    return 0
  fi

  # Find running containers
  local running_containers=$(docker ps --filter volume="$volume" --format "{{.Names}}")

  if [ -z "$running_containers" ]; then
    log "INFO" "No running containers are using volume $volume"
    return 0
  fi

  log "INFO" "Running containers using volume $volume: $running_containers"
  echo "Running containers using volume $volume: $running_containers"

  # Ask for confirmation unless force mode is enabled
  if [ "$FORCE" != "true" ]; then
    read -p "These containers will be stopped during restoration. Continue? (y/n): " confirm
    if [ "$confirm" != "y" ]; then
      log "INFO" "Restoration canceled by user"
      echo "Restoration canceled."
      exit 0
    fi
  else
    log "INFO" "Force mode enabled, skipping container stop confirmation"
  fi

  # Stop containers
  log "INFO" "Stopping containers..."
  echo "Stopping containers..."

  for container in $running_containers; do
    if docker stop "$container"; then
      log "INFO" "Container $container stopped"
      echo "Container $container stopped"
      # Add to the list of containers to restart
      STOPPED_CONTAINERS["$container"]=1
    else
      log "ERROR" "Unable to stop container $container"
      echo "Error: unable to stop container $container"

      # If force is enabled, continue anyway
      if [ "$FORCE" != "true" ]; then
        read -p "Continue anyway? (y/n): " confirm
        if [ "$confirm" != "y" ]; then
          log "INFO" "Restoration canceled by user"
          echo "Restoration canceled."
          exit 0
        fi
      fi
    fi
  done

  return 0
}

# Function to restart containers that were stopped
restart_containers() {
  if [ ${#STOPPED_CONTAINERS[@]} -eq 0 ]; then
    return 0
  fi

  log "INFO" "Restarting containers..."
  echo "Restarting containers..."

  for container in "${!STOPPED_CONTAINERS[@]}"; do
    if docker start "$container"; then
      log "INFO" "Container $container restarted"
      echo "Container $container restarted"
      unset STOPPED_CONTAINERS["$container"]
    else
      log "ERROR" "Unable to restart container $container"
      echo "Error: unable to restart container $container"
      log "WARNING" "Manual intervention required to restart container: $container"
    fi
  done
}

# Function to ensure containers are restarted on script exit or error
cleanup_on_exit() {
  log "INFO" "Running cleanup on exit..."

  # Restart any stopped containers
  restart_containers

  # Check if exist a temp volumes
  if [ -n "$temp_volume" ] && docker volume inspect "$temp_volume" >/dev/null 2>&1; then
    log "INFO" "Removing temporary volume $temp_volume..."
    if docker volume rm "$temp_volume" >/dev/null 2>&1; then
      log "INFO" "Temporary volume $temp_volume removed successfully"
    else
      log "WARNING" "Could not remove temporary volume $temp_volume. Manual cleanup may be required."
    fi
  fi

  # Remove the Alpine container if it exists
  remove_alpine_container

  log "INFO" "Cleanup completed"
}

# Register trap for cleanup
trap cleanup_on_exit EXIT INT TERM

temp_volume=""

# Function to restore a volume
restore_volume() {
  local volume="$1"
  local backup_file="$2"

  log "INFO" "==========================================="
  log "INFO" "Starting restoration procedure"
  log "INFO" "Volume: $volume"
  log "INFO" "Backup file: $backup_file"

  # Verify backup integrity before restoration
  if ! verify_backup "$backup_file"; then
    log "ERROR" "Integrity verification failed. Restoration canceled."
    echo "Integrity verification failed. Restoration canceled."
    exit 1
  fi

  # Check disk space
  if ! check_disk_space "$volume" "$backup_file"; then
    exit 1
  fi

  log "INFO" "Restoring volume $volume from backup: $backup_file"
  echo "Restoring volume $volume from backup: $backup_file"

  # Stop containers using the volume
  stop_containers "$volume"

  # Create volume if it doesn't exist
  if ! docker volume inspect "$volume" >/dev/null 2>&1; then
    log "INFO" "Volume $volume does not exist. Creating..."
    echo "Volume $volume does not exist. Creating..."
    if docker volume create "$volume"; then
      log "INFO" "Volume $volume created successfully"
      echo "Volume $volume created successfully"
    else
      log "ERROR" "Unable to create volume $volume"
      echo "Error: unable to create volume $volume"
      exit 1
    fi
  fi

  # Timestamp for start of restoration
  START_TIME=$(date +%s)

  # Get the directory containing the backup file
  BACKUP_DIR_PATH=$(dirname "$backup_file")
  BACKUP_FILENAME=$(basename "$backup_file")

  # Create a temporary volume for safety
  temp_volume="temp_restore_${volume}_$(date +%s)"
  log "INFO" "Creating temporary volume for safe restoration: $temp_volume"

  if ! docker volume create "$temp_volume"; then
    log "ERROR" "Unable to create temporary volume $temp_volume"
    echo "Error: unable to create temporary volume for safe restoration"
    exit 1
  fi

  # Get the relative path in the container
  local backup_path_in_container="/backup/$(echo "$backup_file" | sed "s|^$BACKUP_DIR/||")"

  # First restore to temporary volume using our Alpine container
  log "INFO" "First restoring to temporary volume..."
  if ! docker run --rm \
    -v "$temp_volume:/target" \
    --volumes-from "$ALPINE_CONTAINER_ID" \
    alpine sh -c "pigz -dc $backup_path_in_container | tar -xf - -C /target"; then

    log "ERROR" "Error during test restoration to temporary volume"
    echo "Error during test restoration to temporary volume"

    # Clean up temporary volume
    docker volume rm "$temp_volume"
    exit 1
  fi

  # Verify temp restoration
  local items_count=$(docker run --rm -v "$temp_volume:/target" alpine sh -c "find /target -type f | wc -l")
  log "INFO" "Test restoration successful: $items_count files extracted to temporary volume"

  # Now restore to actual volume
  log "INFO" "Restoring data to actual volume in progress... (this may take time)"
  echo "Restoring data in progress... (this may take time)"

  # First clear the target volume to ensure clean state
  if ! docker run --rm -v "$volume:/target" alpine sh -c "rm -rf /target/*"; then
    log "WARNING" "Unable to clean target volume before restoration. Continuing anyway."
  fi

  # Copy from temp volume to actual volume
  local cp_error
  if ! cp_error=$(docker run --rm \
    -v "$temp_volume:/source" \
    -v "$volume:/target" \
    alpine sh -c "cp -av /source/. /target/ 2>&1" 2>&1); then

    # Detailed error logging
    log "ERROR" "Error during data restoration: $cp_error"
    echo "Error during data restoration:"
    echo "$cp_error"

    # Verification despite error
    ITEMS_COUNT=$(docker run --rm -v "$volume:/target" alpine sh -c "find /target -type f | wc -l")
    log "WARNING" "Only $ITEMS_COUNT files may have been restored to $volume"
    echo "Only $ITEMS_COUNT files may have been restored. Data may be incomplete."

    # Don't remove temp volume on failure for debugging
    log "WARNING" "Temporary volume $temp_volume retained for debugging purposes. Remove manually when done."
    echo "Temporary volume $temp_volume retained for debugging purposes. Remove manually when done."
    exit 1
  else
    # Verify with item count comparison
    local source_count=$(docker run --rm -v "$temp_volume:/source" alpine sh -c "find /source -type f | wc -l")
    local target_count=$(docker run --rm -v "$volume:/target" alpine sh -c "find /target -type f | wc -l")

    if [ "$source_count" -ne "$target_count" ]; then
      log "WARNING" "File count mismatch: $source_count in source, $target_count in target"
      echo "WARNING: File count mismatch after restoration. Some files may not have been copied correctly."

      if [ "$FORCE" != "true" ]; then
        read -p "Continue despite file count mismatch? (y/n): " confirm
        if [ "$confirm" != "y" ]; then
          log "INFO" "Restoration canceled by user due to file count mismatch"
          echo "Restoration canceled."
          # Keep temp volume for debugging
          log "WARNING" "Temporary volume $temp_volume retained for debugging purposes. Remove manually when done."
          exit 1
        fi
      fi
    fi

    # Calculate restoration time
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))

    log "INFO" "Restoration completed in $DURATION seconds"
    echo "Restoration completed in $DURATION seconds"

    log "INFO" "Items restored in volume $volume: $target_count files"
    echo "Items restored in volume $volume: $target_count files"

    # Remove temporary volume
    if docker volume rm "$temp_volume"; then
      temp_volume="" # Reset the global variable
      log "INFO" "Temporary volume removed"
    else
      log "WARNING" "Unable to remove temporary volume $temp_volume. Manual cleanup may be needed."
    fi
  fi

  log "INFO" "Restoration completed successfully!"
  log "INFO" "==========================================="
  echo "Restoration completed successfully!"
}

# Main menu
echo "====== Docker Volume Restore Tool ======"
log "INFO" "Starting Docker volume restoration tool"
echo ""

# Create the Alpine container for all restore operations
if ! create_alpine_container; then
  log "ERROR" "Failed to create Alpine container. Exiting."
  exit 1
fi

# Get available backup dates
if [ ! -z "$SPECIFIC_DATE" ]; then
  log "INFO" "Using specified backup date: $SPECIFIC_DATE"

  # Verify that the backup directory exists
  if [ ! -d "$BACKUP_DIR/$SPECIFIC_DATE" ]; then
    log "ERROR" "Backup for date $SPECIFIC_DATE not found"
    echo "Error: Backup for date $SPECIFIC_DATE not found in $BACKUP_DIR"
    echo "Available backup dates:"
    find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d | xargs -n1 basename | sort
    exit 1
  fi

  # Set directly without showing the menu
  BACKUP_DATE_DIR="$BACKUP_DIR/$SPECIFIC_DATE"
else
  # Show the list of available backup dates
  read -ra BACKUP_DIRS <<<$(show_available_dates)

  if [ ${#BACKUP_DIRS[@]} -eq 0 ]; then
    log "ERROR" "No backup directories found"
    exit 1
  fi

  # Ask user to choose a date
  read -p "Select a backup date (1-${#BACKUP_DIRS[@]}, 0 to exit): " DATE_CHOICE

  if [ "$DATE_CHOICE" -eq 0 ]; then
    log "INFO" "Operation canceled by user"
    echo "Operation canceled."
    exit 0
  fi

  if [ "$DATE_CHOICE" -lt 1 ] || [ "$DATE_CHOICE" -gt "${#BACKUP_DIRS[@]}" ]; then
    log "ERROR" "Invalid choice: $DATE_CHOICE"
    echo "Invalid choice."
    exit 1
  fi

  # Get the selected backup date directory
  BACKUP_DATE_DIR="${BACKUP_DIRS[$((DATE_CHOICE - 1))]}"
  log "INFO" "Selected date: $(basename "$BACKUP_DATE_DIR")"
fi

# Check if a volume was specified as an argument
if [ -z "$VOLUME_ARG" ]; then
  # No volume specified, show the list for the selected date
  read -ra AVAILABLE_VOLUMES <<<$(show_available_volumes "$BACKUP_DATE_DIR")

  if [ ${#AVAILABLE_VOLUMES[@]} -eq 0 ]; then
    log "ERROR" "No volumes found in selected backup"
    exit 1
  fi

  # Ask user to choose
  read -p "Select the volume to restore (1-${#AVAILABLE_VOLUMES[@]}, 0 to exit): " VOLUME_CHOICE

  if [ "$VOLUME_CHOICE" -eq 0 ]; then
    log "INFO" "Operation canceled by user"
    echo "Operation canceled."
    exit 0
  fi

  if [ "$VOLUME_CHOICE" -lt 1 ] || [ "$VOLUME_CHOICE" -gt "${#AVAILABLE_VOLUMES[@]}" ]; then
    log "ERROR" "Invalid choice: $VOLUME_CHOICE"
    echo "Invalid choice."
    exit 1
  fi

  # Get the name of the selected volume
  VOLUME="${AVAILABLE_VOLUMES[$((VOLUME_CHOICE - 1))]}"
else
  # Volume specified as an argument
  VOLUME=$VOLUME_ARG

  # Verify the specified volume has a backup
  if [ ! -f "$BACKUP_DATE_DIR/$VOLUME.tar.gz" ]; then
    log "ERROR" "No backup found for volume $VOLUME in $(basename "$BACKUP_DATE_DIR")"
    echo "Error: No backup found for volume $VOLUME in $(basename "$BACKUP_DATE_DIR")"

    # Show available volumes for this date to help the user
    echo "Available volumes for $(basename "$BACKUP_DATE_DIR"):"
    find "$BACKUP_DATE_DIR" -name "*.tar.gz" -type f | xargs -n1 basename | sed 's/.tar.gz$//' | sort
    exit 1
  fi
fi

log "INFO" "Selected volume: $VOLUME"

# The backup file is always in the standard location for the selected date and volume
BACKUP_FILE="$BACKUP_DATE_DIR/$VOLUME.tar.gz"
log "INFO" "Selected backup: $BACKUP_FILE"

# Ask for final confirmation
if [ "$FORCE" != "true" ]; then
  echo "Ready to restore volume '$VOLUME' from backup: $(basename "$BACKUP_DATE_DIR")"
  read -p "This will override existing data in the volume. Continue? (y/n): " FINAL_CONFIRM
  if [ "$FINAL_CONFIRM" != "y" ]; then
    log "INFO" "Restoration canceled by user at final confirmation"
    echo "Restoration canceled."
    exit 0
  fi
fi

# Perform the restoration
restore_volume "$VOLUME" "$BACKUP_FILE"

exit 0
