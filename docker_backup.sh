#!/bin/bash
# Docker Volume Backup - A utility to backup Docker volumes
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
DEFAULT_COMPRESSION_LEVEL="1"
DEFAULT_RETENTION_DAYS="30"
MINIMUM_FREE_SPACE_MB=500  # Minimum required free space in MB

# Parse command line arguments
usage() {
  echo "Usage: $0 [OPTIONS]"
  echo "Backup Docker volumes to compressed archives"
  echo ""
  echo "Options:"
  echo "  -d, --directory DIR    Backup directory (default: $DEFAULT_BACKUP_DIR)"
  echo "  -c, --compression LVL  Compression level (1-9, default: $DEFAULT_COMPRESSION_LEVEL)"
  echo "  -r, --retention DAYS   Number of days to keep backups (default: $DEFAULT_RETENTION_DAYS)"
  echo "  -v, --volumes VOL1,... Only backup specific volumes (comma-separated list)"
  echo "  -s, --skip-used        Skip volumes used by running containers"
  echo "  -f, --force            Don't ask for confirmation before stopping containers"
  echo "  -p, --prioritize-last NAME1,...  Container names to backup last (comma-separated list)"
  echo "  -h, --help             Display this help message"
  echo ""
  echo "Environment variables:"
  echo "  DOCKER_BACKUP_DIR      Same as --directory"
  echo "  DOCKER_COMPRESSION     Same as --compression"
  echo "  DOCKER_RETENTION_DAYS  Same as --retention"
  echo "  DOCKER_LAST_PRIORITY   Same as --prioritize-last"
  exit 1
}

# Get settings from environment variables or use defaults
BACKUP_DIR=${DOCKER_BACKUP_DIR:-$DEFAULT_BACKUP_DIR}
COMPRESSION=${DOCKER_COMPRESSION:-$DEFAULT_COMPRESSION_LEVEL}
RETENTION_DAYS=${DOCKER_RETENTION_DAYS:-$DEFAULT_RETENTION_DAYS}
SELECTED_VOLUMES=""
LAST_PRIORITY=${DOCKER_LAST_PRIORITY:-""}
SKIP_USED=false
FORCE=false

# Parse command line options
while [[ $# -gt 0 ]]; do
  case $1 in
    -d|--directory)
      BACKUP_DIR="$2"
      shift 2
      ;;
    -c|--compression)
      COMPRESSION="$2"
      if ! [[ "$COMPRESSION" =~ ^[1-9]$ ]]; then
        echo "ERROR: Compression level must be between 1 and 9"
        exit 1
      fi
      shift 2
      ;;
    -r|--retention)
      RETENTION_DAYS="$2"
      if ! [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
        echo "ERROR: Retention days must be a positive integer or 0"
        exit 1
      fi
      shift 2
      ;;
    -v|--volumes)
      SELECTED_VOLUMES="$2"
      shift 2
      ;;
    -p|--prioritize-last)
      LAST_PRIORITY="$2"
      shift 2
      ;;
    -s|--skip-used)
      SKIP_USED=true
      shift
      ;;
    -f|--force)
      FORCE=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown option: $1"
      usage
      ;;
  esac
done

# Set up date variables
DATE=$(date +%Y-%m-%d)
BACKUP_DATE_DIR="$BACKUP_DIR/$DATE"
LOG_FILE="$BACKUP_DIR/docker_backup.log"

# Map for storing containers by volume
declare -A CONTAINERS_BY_VOLUME
# Map for storing stopped containers that need to be restarted
declare -A STOPPED_CONTAINERS
# Map for storing volumes that should be backed up last
declare -A LAST_PRIORITY_VOLUMES

# Logging function
log() {
  local level="$1"
  local message="$2"
  local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Verify that the script is executed with necessary permissions
verify_permissions() {
  # Check if the user can execute docker commands
  if ! docker ps > /dev/null 2>&1; then
    log "ERROR" "Current user cannot execute Docker commands."
    log "ERROR" "Make sure you are in the 'docker' group or are root."
    echo "ERROR: Current user cannot execute Docker commands."
    echo "Make sure you are in the 'docker' group or are root:"
    echo "sudo usermod -aG docker $USER"
    echo "After adding to the group, restart your session (logout/login)."
    exit 1
  fi
  
  # Create backup directory if it doesn't exist
  if [ ! -d "$BACKUP_DIR" ]; then
    log "INFO" "Directory $BACKUP_DIR does not exist. Attempting to create it..."
    if ! mkdir -p $BACKUP_DIR; then
      log "ERROR" "Unable to create directory $BACKUP_DIR"
      echo "ERROR: Unable to create directory $BACKUP_DIR"
      echo "Run the following commands to create the directory with correct permissions:"
      echo "sudo mkdir -p $BACKUP_DIR"
      echo "sudo chown $USER:$USER $BACKUP_DIR"
      exit 1
    fi
    log "INFO" "Directory $BACKUP_DIR created successfully."
  fi
  
  # Verify write permissions on the backup directory
  if [ ! -w "$BACKUP_DIR" ]; then
    log "ERROR" "Current user does not have write permissions on $BACKUP_DIR"
    echo "ERROR: Current user does not have write permissions on $BACKUP_DIR"
    echo "Run the following command to configure permissions:"
    echo "sudo chown $USER:$USER $BACKUP_DIR"
    exit 1
  fi
  
  # Create directory for current date backups
  if [ ! -d "$BACKUP_DATE_DIR" ]; then
    log "INFO" "Creating directory for backups on $DATE..."
    if ! mkdir -p "$BACKUP_DATE_DIR"; then
      log "ERROR" "Unable to create directory $BACKUP_DATE_DIR"
      echo "ERROR: Unable to create directory $BACKUP_DATE_DIR"
      exit 1
    fi
    log "INFO" "Directory $BACKUP_DATE_DIR created successfully."
  fi
  
  log "INFO" "Necessary permissions verified."
}

# Check available disk space
check_disk_space() {
  log "INFO" "Checking available disk space in $BACKUP_DIR"
  
  # Get available disk space in MB
  local available_space
  available_space=$(df -m "$BACKUP_DIR" | awk 'NR==2 {print $4}')
  
  log "INFO" "Available disk space: $available_space MB"
  
  if [ "$available_space" -lt "$MINIMUM_FREE_SPACE_MB" ]; then
    log "ERROR" "Insufficient disk space. Available: $available_space MB, Required: $MINIMUM_FREE_SPACE_MB MB"
    echo "ERROR: Insufficient disk space. Available: $available_space MB, Required: $MINIMUM_FREE_SPACE_MB MB"
    exit 1
  fi
  
  # Estimate required space based on volume sizes
  log "INFO" "Estimating space required for selected volumes..."
  local estimated_size=0
  local docker_root=$(docker info --format '{{.DockerRootDir}}')
  
  for volume in "${VOLUMES_TO_BACKUP[@]}"; do
    # Try to get volume size - this is an approximation
    local volume_size
    volume_size=$(du -sm "${docker_root}/volumes/${volume}/_data" 2>/dev/null | awk '{print $1}' || echo 0)
    estimated_size=$((estimated_size + volume_size))
  done
  
  # Add 10% overhead
  estimated_size=$((estimated_size + (estimated_size / 10)))
  
  log "INFO" "Estimated space needed for backups: $estimated_size MB"
  
  if [ "$available_space" -lt "$estimated_size" ]; then
    log "WARNING" "Available space ($available_space MB) might be insufficient for estimated backup size ($estimated_size MB)"
    
    if [ "$FORCE" != "true" ]; then
      read -p "Available space may be insufficient. Continue anyway? (y/n): " confirm
      if [ "$confirm" != "y" ]; then
        log "INFO" "Backup canceled by user due to space concerns"
        exit 0
      fi
    else
      log "WARNING" "Continuing despite potential space issues due to force flag"
    fi
  fi
}

# Function to verify backup integrity
verify_backup() {
  local backup_file="$1"
  local volume_name="$2"
  
  log "INFO" "Verifying backup integrity: $backup_file"
  
  # Verify tar archive integrity
  if tar -tzf "$backup_file" > /dev/null 2>&1; then
    # Get file count in the archive
    local file_count=$(tar -tzf "$backup_file" | wc -l)
    log "INFO" "Backup contains $file_count files/directories"
    
    # Check minimum expected file count (at least one file or directory)
    if [ "$file_count" -lt 1 ]; then
      log "ERROR" "Backup for $volume_name appears to be empty"
      return 1
    fi
    
    log "INFO" "Integrity verification completed successfully for $volume_name"
    return 0
  else
    log "ERROR" "Integrity verification failed for $volume_name. The backup might be corrupted."
    return 1
  fi
}

# Function to stop containers using a volume
stop_containers() {
  local volume="$1"
  local containers="${CONTAINERS_BY_VOLUME[$volume]}"
  
  if [ -z "$containers" ]; then
    return 0
  fi
  
  log "INFO" "Stopping containers using volume $volume: $containers"
  
  # Ask for confirmation unless force mode is enabled
  if [ "$FORCE" != "true" ]; then
    read -p "Containers need to be stopped. Continue with backup? (y/n): " confirm
    if [ "$confirm" != "y" ]; then
      log "INFO" "Backup canceled by user for volume $volume"
      return 1
    fi
  fi
  
  # Stop the containers
  log "INFO" "Stopping containers for volume $volume..."
  local failed=false
  
  for container in $containers; do
    # Check if container is already running
    if docker inspect --format='{{.State.Running}}' "$container" 2>/dev/null | grep -q "true"; then
      if docker stop "$container"; then
        log "INFO" "Container $container stopped"
        # Mark container for restart
        STOPPED_CONTAINERS["$container"]="$volume"
      else
        log "ERROR" "Unable to stop container $container"
        failed=true
      fi
    else
      log "INFO" "Container $container is already stopped"
    fi
  done
  
  if [ "$failed" = true ]; then
    return 1
  fi
  
  return 0
}

# Function to restart containers that were stopped during backup
restart_containers() {
  if [ ${#STOPPED_CONTAINERS[@]} -eq 0 ]; then
    return 0
  fi
  
  log "INFO" "Restarting stopped containers..."
  
  for container in "${!STOPPED_CONTAINERS[@]}"; do
    if docker start "$container"; then
      log "INFO" "Container $container restarted"
    else
      log "ERROR" "Unable to restart container $container"
      log "WARNING" "Manual intervention required to restart container: $container"
    fi
    # Remove from the tracking array after handling
    unset STOPPED_CONTAINERS["$container"]
  done
}

# Function to ensure containers are restarted on script exit or error
cleanup_on_exit() {
  log "INFO" "Running cleanup on exit..."
  restart_containers
  log "INFO" "Cleanup completed"
}

# Register trap for cleanup
trap cleanup_on_exit EXIT INT TERM

# Create log file if it doesn't exist
if [ ! -f "$LOG_FILE" ]; then
  touch "$LOG_FILE"
  log "INFO" "Log file created at $LOG_FILE"
fi

# Verify necessary permissions
verify_permissions

log "INFO" "===========================================" 
log "INFO" "Starting Docker volume backup on $DATE in directory $BACKUP_DATE_DIR"
log "INFO" "===========================================" 

# Get list of all volumes
VOLUMES=$(docker volume ls -q)

if [ -z "$VOLUMES" ]; then
  log "WARNING" "No Docker volumes found in the system"
  echo "WARNING: No Docker volumes found in the system"
  exit 0
fi

# Filter volumes if a specific list was provided
VOLUMES_TO_BACKUP=()
if [ ! -z "$SELECTED_VOLUMES" ]; then
  log "INFO" "Filtering volumes: $SELECTED_VOLUMES"
  # Convert comma-separated list to array
  IFS=',' read -ra VOLUME_LIST <<< "$SELECTED_VOLUMES"
  
  # Filter volumes using exact matching
  for volume in $VOLUMES; do
    for selected in "${VOLUME_LIST[@]}"; do
      if [ "$volume" = "$selected" ]; then
        VOLUMES_TO_BACKUP+=("$volume")
        break
      fi
    done
  done
  
  # Check if any requested volumes were not found
  for requested in "${VOLUME_LIST[@]}"; do
    local found=false
    for volume in "${VOLUMES_TO_BACKUP[@]}"; do
      if [ "$volume" = "$requested" ]; then
        found=true
        break
      fi
    done
    
    if [ "$found" = false ]; then
      log "WARNING" "Requested volume not found: $requested"
      echo "WARNING: Requested volume not found: $requested"
    fi
  done
  
  # If no volumes match the filter, exit
  if [ ${#VOLUMES_TO_BACKUP[@]} -eq 0 ]; then
    log "ERROR" "None of the specified volumes were found"
    echo "ERROR: None of the specified volumes were found"
    exit 1
  fi
else
  # No filter, use all volumes
  for volume in $VOLUMES; do
    VOLUMES_TO_BACKUP+=("$volume")
  done
fi

# Map containers to volumes
log "INFO" "Mapping containers to volumes..."
for volume in "${VOLUMES_TO_BACKUP[@]}"; do
  # Find containers using this volume
  containers=$(docker ps -a --filter volume=$volume --format "{{.Names}}")
  
  if [ ! -z "$containers" ]; then
    # Store in associative array
    CONTAINERS_BY_VOLUME["$volume"]="$containers"
    
    # Check if we should skip used volumes
    if [ "$SKIP_USED" = true ]; then
      # Check for running containers using the volume
      running_containers=$(docker ps --filter volume=$volume --format "{{.Names}}")
      if [ ! -z "$running_containers" ]; then
        log "INFO" "Skipping volume $volume used by running containers (--skip-used enabled)"
        # Remove from the list of volumes to backup
        for i in "${!VOLUMES_TO_BACKUP[@]}"; do
          if [ "${VOLUMES_TO_BACKUP[$i]}" = "$volume" ]; then
            unset 'VOLUMES_TO_BACKUP[$i]'
            break
          fi
        done
      fi
    fi
    
    # Check if this volume is used by a container in the last priority list
    if [ ! -z "$LAST_PRIORITY" ]; then
      IFS=',' read -ra LAST_PRIORITY_ARRAY <<< "$LAST_PRIORITY"
      for container in $containers; do
        for last_priority_container in "${LAST_PRIORITY_ARRAY[@]}"; do
          if [ "$container" = "$last_priority_container" ]; then
            log "INFO" "Marking volume $volume for last priority backup (used by $container)"
            LAST_PRIORITY_VOLUMES["$volume"]=1
            break 2  # Break out of both loops
          fi
        done
      done
    fi
  fi
done

# Reindex array to remove potential gaps
VOLUMES_TO_BACKUP=("${VOLUMES_TO_BACKUP[@]}")

# Check if there are any volumes left to backup
if [ ${#VOLUMES_TO_BACKUP[@]} -eq 0 ]; then
  log "WARNING" "No volumes left to backup after applying filters"
  echo "WARNING: No volumes left to backup after applying filters"
  exit 0
fi

# Check disk space after determining which volumes to backup
check_disk_space

# Counters for statistics
TOTAL_VOLUMES=${#VOLUMES_TO_BACKUP[@]}
SUCCESSFUL_BACKUPS=0
FAILED_BACKUPS=0
SKIPPED_VOLUMES=0

# Reorganize volumes: regular volumes first, last priority volumes at the end
REGULAR_VOLUMES=()
LAST_VOLUMES=()

for volume in "${VOLUMES_TO_BACKUP[@]}"; do
  if [ -n "${LAST_PRIORITY_VOLUMES[$volume]}" ]; then
    LAST_VOLUMES+=("$volume")
  else
    REGULAR_VOLUMES+=("$volume")
  fi
done

log "INFO" "Regular volumes to backup: ${#REGULAR_VOLUMES[@]}"
log "INFO" "Last priority volumes to backup: ${#LAST_VOLUMES[@]}"

# Process regular volumes first
for volume in "${REGULAR_VOLUMES[@]}"; do
  BACKUP_FILE="$BACKUP_DATE_DIR/$volume.tar.gz"
  
  log "INFO" "Processing regular priority volume: $volume"
  
  # If there are containers using this volume
  if [ ! -z "${CONTAINERS_BY_VOLUME[$volume]}" ]; then
    log "INFO" "Containers using volume $volume: ${CONTAINERS_BY_VOLUME[$volume]}"
    
    # Stop containers
    if ! stop_containers "$volume"; then
      log "WARNING" "Skipping backup of volume $volume due to container stop issues"
      SKIPPED_VOLUMES=$((SKIPPED_VOLUMES+1))
      continue
    fi
  else
    log "INFO" "No containers are using volume $volume"
  fi
  
  # Perform backup using pigz (parallel gzip) for speed or fallback to regular tar
  log "INFO" "Backing up volume: $volume"
  
  backup_start_time=$(date +%s)
  
  # Check if volume exists
  if ! docker volume inspect "$volume" >/dev/null 2>&1; then
    log "ERROR" "Volume $volume no longer exists"
    FAILED_BACKUPS=$((FAILED_BACKUPS+1))
    continue
  fi
  
  # Run the backup command
  if docker run --rm \
    -v "$volume:/source:ro" \
    -v "$BACKUP_DIR:/backup" \
    alpine sh -c "apk add --no-cache pigz && tar -cf - -C /source . | pigz -$COMPRESSION > /backup/$DATE/$volume.tar.gz || tar -czf /backup/$DATE/$volume.tar.gz -C /source ."; then
    
    backup_end_time=$(date +%s)
    backup_duration=$((backup_end_time - backup_start_time))
    
    log "INFO" "Backup of volume $volume completed in $backup_duration seconds: $BACKUP_FILE"
    
    # Verify integrity
    if verify_backup "$BACKUP_FILE" "$volume"; then
      SUCCESSFUL_BACKUPS=$((SUCCESSFUL_BACKUPS+1))
    else
      log "ERROR" "Backup verification failed for $volume"
      FAILED_BACKUPS=$((FAILED_BACKUPS+1))
    fi
  else
    log "ERROR" "Backup of volume $volume failed"
    FAILED_BACKUPS=$((FAILED_BACKUPS+1))
  fi
  
  # Calculate and display backup size
  if [ -f "$BACKUP_FILE" ]; then
    BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
    log "INFO" "Backup size for $volume: $BACKUP_SIZE"
  fi
  
  # Restart containers for this volume before moving to next
  for container in "${!STOPPED_CONTAINERS[@]}"; do
    if [ "${STOPPED_CONTAINERS[$container]}" = "$volume" ]; then
      if docker start "$container"; then
        log "INFO" "Container $container restarted after backing up $volume"
        unset STOPPED_CONTAINERS["$container"]
      else
        log "ERROR" "Unable to restart container $container after backing up $volume"
      fi
    fi
  done
}

# Now process last priority volumes
for volume in "${LAST_VOLUMES[@]}"; do
  BACKUP_FILE="$BACKUP_DATE_DIR/$volume.tar.gz"
  
  log "INFO" "Processing last priority volume: $volume"
  
  # If there are containers using this volume
  if [ ! -z "${CONTAINERS_BY_VOLUME[$volume]}" ]; then
    log "INFO" "Containers using volume $volume: ${CONTAINERS_BY_VOLUME[$volume]}"
    
    # Stop containers
    if ! stop_containers "$volume"; then
      log "WARNING" "Skipping backup of volume $volume due to container stop issues"
      SKIPPED_VOLUMES=$((SKIPPED_VOLUMES+1))
      continue
    fi
  else
    log "INFO" "No containers are using volume $volume"
  fi
  
  # Perform backup using pigz (parallel gzip) for speed or fallback to regular tar
  log "INFO" "Backing up volume: $volume"
  
  backup_start_time=$(date +%s)
  
  # Check if volume exists
  if ! docker volume inspect "$volume" >/dev/null 2>&1; then
    log "ERROR" "Volume $volume no longer exists"
    FAILED_BACKUPS=$((FAILED_BACKUPS+1))
    continue
  fi
  
  # Run the backup command
  if docker run --rm \
    -v "$volume:/source:ro" \
    -v "$BACKUP_DIR:/backup" \
    alpine sh -c "apk add --no-cache pigz && tar -cf - -C /source . | pigz -$COMPRESSION > /backup/$DATE/$volume.tar.gz || tar -czf /backup/$DATE/$volume.tar.gz -C /source ."; then
    
    backup_end_time=$(date +%s)
    backup_duration=$((backup_end_time - backup_start_time))
    
    log "INFO" "Backup of volume $volume completed in $backup_duration seconds: $BACKUP_FILE"
    
    # Verify integrity
    if verify_backup "$BACKUP_FILE" "$volume"; then
      SUCCESSFUL_BACKUPS=$((SUCCESSFUL_BACKUPS+1))
    else
      log "ERROR" "Backup verification failed for $volume"
      FAILED_BACKUPS=$((FAILED_BACKUPS+1))
    fi
  else
    log "ERROR" "Backup of volume $volume failed"
    FAILED_BACKUPS=$((FAILED_BACKUPS+1))
  fi
  
  # Calculate and display backup size
  if [ -f "$BACKUP_FILE" ]; then
    BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
    log "INFO" "Backup size for $volume: $BACKUP_SIZE"
  fi
  
  # Restart containers for this volume immediately
  for container in "${!STOPPED_CONTAINERS[@]}"; do
    if [ "${STOPPED_CONTAINERS[$container]}" = "$volume" ]; then
      if docker start "$container"; then
        log "INFO" "Container $container restarted after backing up $volume"
        unset STOPPED_CONTAINERS["$container"]
      else
        log "ERROR" "Unable to restart container $container after backing up $volume"
      fi
    fi
  done
}

# Clean up old backups based on retention policy
cleanup_old_backups() {
  if [ "$RETENTION_DAYS" -gt 0 ]; then
    log "INFO" "Cleaning up backups older than $RETENTION_DAYS days..."
    
    # Find directories older than retention period and delete them
    OLD_BACKUPS=$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +$RETENTION_DAYS)
    
    if [ -z "$OLD_BACKUPS" ]; then
      log "INFO" "No backups older than $RETENTION_DAYS days to clean up"
    else
      for OLD_DIR in $OLD_BACKUPS; do
        log "INFO" "Removing old backup: $(basename "$OLD_DIR")"
        rm -rf "$OLD_DIR"
      done
    fi
  else
    log "INFO" "Retention policy disabled. Not cleaning up old backups."
  fi
}

# Clean up old backups
cleanup_old_backups

log "INFO" "===========================================" 
log "INFO" "Backup summary for $DATE:"
log "INFO" "Total volumes processed: $TOTAL_VOLUMES"
log "INFO" "Backups completed successfully: $SUCCESSFUL_BACKUPS"
log "INFO" "Failed backups: $FAILED_BACKUPS"
log "INFO" "Skipped volumes: $SKIPPED_VOLUMES"
log "INFO" "Total space used: $(du -sh $BACKUP_DIR | cut -f1)"
log "INFO" "Backup completed!"
log "INFO" "============================================"

# Check if any backups failed and set exit code appropriately
if [ $FAILED_BACKUPS -gt 0 ]; then
  exit 1
fi

exit 0