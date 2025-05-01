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
DEFAULT_PARALLEL_JOBS="2"  # Number of parallel backup jobs
MINIMUM_FREE_SPACE_MB=500  # Minimum required free space in MB
MINIMUM_FREE_MEMORY_MB=100 # Minimum required free memory in MB

# Early declaration of associative arrays to avoid issues
declare -A CONTAINERS_BY_VOLUME
declare -A STOPPED_CONTAINERS
declare -A LAST_PRIORITY_VOLUMES
declare -A VOLUME_BACKUP_STATUS
declare -A CONTAINERS_TO_RESTART
declare -A VOLUMES_BY_CONTAINER

# Flag to track if pigz is available on the host system
PIGZ_AVAILABLE=false

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
  echo "  -j, --jobs NUM         Number of parallel backup jobs (default: $DEFAULT_PARALLEL_JOBS)"
  echo "  -h, --help             Display this help message"
  echo ""
  echo "Environment variables:"
  echo "  DOCKER_BACKUP_DIR      Same as --directory"
  echo "  DOCKER_COMPRESSION     Same as --compression"
  echo "  DOCKER_RETENTION_DAYS  Same as --retention"
  echo "  DOCKER_LAST_PRIORITY   Same as --prioritize-last"
  echo "  DOCKER_PARALLEL_JOBS   Same as --jobs"
  exit 1
}

# Get settings from environment variables or use defaults
BACKUP_DIR=${DOCKER_BACKUP_DIR:-$DEFAULT_BACKUP_DIR}
COMPRESSION=${DOCKER_COMPRESSION:-$DEFAULT_COMPRESSION_LEVEL}
RETENTION_DAYS=${DOCKER_RETENTION_DAYS:-$DEFAULT_RETENTION_DAYS}
PARALLEL_JOBS=${DOCKER_PARALLEL_JOBS:-$DEFAULT_PARALLEL_JOBS}
SELECTED_VOLUMES=""
LAST_PRIORITY=${DOCKER_LAST_PRIORITY:-""}
SKIP_USED=false
FORCE=false

# Parse command line options
while [[ $# -gt 0 ]]; do
  case $1 in
  -d | --directory)
    BACKUP_DIR="$2"
    shift 2
    ;;
  -c | --compression)
    COMPRESSION="$2"
    if ! [[ "$COMPRESSION" =~ ^[1-9]$ ]]; then
      echo "ERROR: Compression level must be between 1 and 9"
      exit 1
    fi
    shift 2
    ;;
  -r | --retention)
    RETENTION_DAYS="$2"
    if ! [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
      echo "ERROR: Retention days must be a positive integer or 0"
      exit 1
    fi
    shift 2
    ;;
  -v | --volumes)
    SELECTED_VOLUMES="$2"
    shift 2
    ;;
  -p | --prioritize-last)
    LAST_PRIORITY="$2"
    shift 2
    ;;
  -j | --jobs)
    PARALLEL_JOBS="$2"
    if ! [[ "$PARALLEL_JOBS" =~ ^[1-9][0-9]*$ ]]; then
      echo "ERROR: Number of parallel jobs must be a positive integer"
      exit 1
    fi
    shift 2
    ;;
  -s | --skip-used)
    SKIP_USED=true
    shift
    ;;
  -f | --force)
    FORCE=true
    shift
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

# Set up date variables
DATE=$(date +%Y-%m-%d)
BACKUP_DATE_DIR="$BACKUP_DIR/$DATE"
LOG_FILE="$BACKUP_DIR/docker_backup.log"

# Logging function
log() {
  local level="$1"
  local message="$2"
  local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Function to check if pigz is installed on the host system
check_pigz_installation() {
  if ! command -v pigz &>/dev/null; then
    log "WARNING" "pigz is not installed on the host system"
    echo "WARNING: pigz is not installed on the host system."
    echo "pigz is required for efficient parallel compression of backups."
    echo ""
    echo "To install pigz:"
    echo "  - On Debian/Ubuntu: sudo apt-get install pigz"
    echo "  - On CentOS/RHEL: sudo yum install pigz"
    echo "  - On Alpine Linux: apk add pigz"
    echo "  - On macOS: brew install pigz"
    echo ""
    read -p "Would you like to continue without pigz (will use gzip instead)? (y/n): " continue_without_pigz
    if [ "$continue_without_pigz" != "y" ]; then
      log "INFO" "Backup canceled by user due to missing pigz"
      exit 1
    fi
    log "INFO" "Continuing with gzip instead of pigz"
    return 1
  fi
  log "INFO" "pigz is installed on the host system"
  return 0
}

# Verify that the script is executed with necessary permissions
verify_permissions() {
  # Check if the user can execute docker commands
  if ! docker ps >/dev/null 2>&1; then
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

# Check available system resources
check_resources() {
  log "INFO" "Checking available system resources..."

  # Get available disk space in MB
  local available_space
  available_space=$(df -m "$BACKUP_DIR" | awk 'NR==2 {print $4}')

  log "INFO" "Available disk space: $available_space MB"

  if [ "$available_space" -lt "$MINIMUM_FREE_SPACE_MB" ]; then
    log "ERROR" "Insufficient disk space. Available: $available_space MB, Required: $MINIMUM_FREE_SPACE_MB MB"
    echo "ERROR: Insufficient disk space. Available: $available_space MB, Required: $MINIMUM_FREE_SPACE_MB MB"
    exit 1
  fi

  # Check available memory
  local available_memory
  available_memory=$(free -m | awk 'NR==2 {print $7}')

  log "INFO" "Available memory: $available_memory MB"

  if [ "$available_memory" -lt "$MINIMUM_FREE_MEMORY_MB" ]; then
    log "WARNING" "Low memory conditions: $available_memory MB available"

    if [ "$PARALLEL_JOBS" -gt 1 ]; then
      local new_jobs=$((PARALLEL_JOBS / 2))
      [ "$new_jobs" -lt 1 ] && new_jobs=1

      log "WARNING" "Reducing parallel jobs from $PARALLEL_JOBS to $new_jobs due to low memory"
      PARALLEL_JOBS=$new_jobs
    fi
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

  # Check if the backup file exists and is not empty
  if [ ! -f "$BACKUP_DATE_DIR/$backup_file" ] || [ ! -s "$BACKUP_DATE_DIR/$backup_file" ]; then
    log "ERROR" "Backup file is missing or empty: $backup_file"
    return 1
  fi

  # Use the appropriate tool based on availability
  if [ "$PIGZ_AVAILABLE" = true ]; then
    # Check integrity with pigz
    if ! pigz -t "$BACKUP_DATE_DIR/$backup_file" 2>/dev/null; then
      log "ERROR" "Integrity verification failed for $volume_name. Invalid compressed format."
      return 1
    fi
  else
    # Check integrity with gzip
    if ! gzip -t "$BACKUP_DATE_DIR/$backup_file" 2>/dev/null; then
      log "ERROR" "Integrity verification failed for $volume_name. Invalid compressed format."
      return 1
    fi
  fi

  # Quick check of the tar content (just list a few files)
  local file_check
  if [ "$PIGZ_AVAILABLE" = true ]; then
    file_check=$(pigz -dc "$BACKUP_DATE_DIR/$backup_file" 2>/dev/null | tar -tf - 2>/dev/null | head -5 | wc -l)
  else
    file_check=$(gzip -dc "$BACKUP_DATE_DIR/$backup_file" 2>/dev/null | tar -tf - 2>/dev/null | head -5 | wc -l)
  fi

  if [ "$file_check" -gt 0 ]; then
    log "INFO" "Integrity verification passed for $volume_name"
    return 0
  else
    log "ERROR" "Backup appears to be empty or invalid for $volume_name"
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

  log "INFO" "Containers using volume $volume: $containers"

  # Ask for confirmation unless force mode is enabled
  if [ "$FORCE" != "true" ]; then
    read -p "Containers need to be stopped. Continue with backup? (y/n): " confirm
    if [ "$confirm" != "y" ]; then
      log "INFO" "Backup canceled by user for volume $volume"
      return 1
    fi
  fi

  # Create a temp lock file
  local lock_file="/tmp/docker_backup_container_lock"
  (
    flock -x 200

    # Create a temporary array to track containers we stop
    local stopped_containers_for_volume=()

    # Stop the containers
    log "INFO" "Stopping containers for volume $volume..."
    local failed=false

    for container in $containers; do
      # Check if container is already running
      if docker inspect --format='{{.State.Running}}' "$container" 2>/dev/null | grep -q "true"; then
        if docker stop "$container"; then
          log "INFO" "Container $container stopped"
          # Add to temporary array
          stopped_containers_for_volume+=("$container")

          # Add to global tracking arrays - mark for restart later
          CONTAINERS_TO_RESTART["$container"]=1

          # Store all volumes used by this container
          local all_container_volumes=$(docker inspect --format='{{range .Mounts}}{{.Name}} {{end}}' "$container")
          VOLUMES_BY_CONTAINER["$container"]="$all_container_volumes"
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

    # Now safely add to the global tracking array for immediate restarts
    for container in "${stopped_containers_for_volume[@]}"; do
      STOPPED_CONTAINERS["$container"]="$volume"
    done
  ) 200>$lock_file

  return 0
}

# Function to restart containers that were stopped during backup
# This is now intentionally empty to prevent immediate restarts
restart_containers() {
  local volume="$1"
  # This function is now intentionally empty to prevent immediate restarts
  # We'll only restart containers after all volumes are backed up
  log "INFO" "Delaying restart of containers for volume $volume until all volumes are processed"
  return 0
}

# Function to restart all containers after all volumes are processed
restart_all_containers_safely() {
  if [ ${#CONTAINERS_TO_RESTART[@]} -eq 0 ]; then
    log "INFO" "No containers to restart"
    return 0
  fi

  log "INFO" "Restarting all containers after backup completion..."

  # Create a temp lock file
  local lock_file="/tmp/docker_backup_container_lock"
  (
    flock -x 200

    for container in "${!CONTAINERS_TO_RESTART[@]}"; do
      local volumes="${VOLUMES_BY_CONTAINER[$container]}"

      # Check if all the volumes are saved correctly
      local all_volumes_ready=true
      for volume in $volumes; do
        if [ "${VOLUME_BACKUP_STATUS[$volume]}" != "SUCCESS" ]; then
          all_volumes_ready=false
          log "WARNING" "Volume $volume not successfully backed up, delaying container $container restart"
          break
        fi
      done

      if [ "$all_volumes_ready" = true ]; then
        log "INFO" "All volumes for container $container are backed up. Restarting..."
        if docker start "$container"; then
          log "INFO" "Container $container restarted"
          # Remove from tracking arrays
          unset CONTAINERS_TO_RESTART["$container"]
          unset VOLUMES_BY_CONTAINER["$container"]

          # Also remove from the immediate restart array if present
          unset STOPPED_CONTAINERS["$container"]
        else
          log "ERROR" "Unable to restart container $container"
          log "WARNING" "Manual intervention required to restart container: $container"
        fi
      else
        log "WARNING" "Not restarting container $container because not all of its volumes were successfully backed up"
      fi
    done
  ) 200>$lock_file
}

# Function to restart all remaining stopped containers
restart_all_containers() {
  if [ ${#STOPPED_CONTAINERS[@]} -eq 0 ]; then
    return 0
  fi

  log "INFO" "Restarting all remaining stopped containers..."

  local container_list=("${!STOPPED_CONTAINERS[@]}")
  for container in "${container_list[@]}"; do
    if docker start "$container"; then
      log "INFO" "Container $container restarted"
      unset STOPPED_CONTAINERS["$container"]
    else
      log "ERROR" "Unable to restart container $container"
      log "WARNING" "Manual intervention required to restart container: $container"
    fi
  done
}

# Function to ensure containers are restarted on script exit or error
cleanup_on_exit() {
  log "INFO" "Running cleanup on exit..."

  # First try to restart using the new tracking system
  if [ ${#CONTAINERS_TO_RESTART[@]} -gt 0 ]; then
    log "INFO" "Restarting containers from new tracking system..."
    for container in "${!CONTAINERS_TO_RESTART[@]}"; do
      if docker inspect --format='{{.State.Running}}' "$container" 2>/dev/null | grep -q "false"; then
        if docker start "$container"; then
          log "INFO" "Container $container restarted during cleanup"
        else
          log "ERROR" "Unable to restart container $container during cleanup"
        fi
      fi
    done
  fi

  # Then try the old system as fallback
  restart_all_containers

  log "INFO" "Cleanup completed"
}

# Function to perform backup of a single volume
backup_volume() {
  local volume="$1"
  local backup_file="$volume.tar.gz"

  log "INFO" "Starting backup of volume: $volume"

  # Check if containers need to be stopped
  if [ ! -z "${CONTAINERS_BY_VOLUME[$volume]}" ]; then
    log "INFO" "Containers using volume $volume: ${CONTAINERS_BY_VOLUME[$volume]}"

    # Stop containers
    if ! stop_containers "$volume"; then
      log "WARNING" "Skipping backup of volume $volume due to container stop issues"
      VOLUME_BACKUP_STATUS["$volume"]="SKIPPED"
      return 1
    fi
  else
    log "INFO" "No containers are using volume $volume"
  fi

  # Record backup start time
  local backup_start_time=$(date +%s)

  # Check if volume exists
  if ! docker volume inspect "$volume" >/dev/null 2>&1; then
    log "ERROR" "Volume $volume no longer exists"
    VOLUME_BACKUP_STATUS["$volume"]="FAILED"
    restart_containers "$volume"
    return 1
  fi

  # Full path to backup file
  local backup_file_path="$BACKUP_DATE_DIR/$backup_file"

  # Run the backup using direct pipeline to avoid permission issues with temporary files
  if [ "$PIGZ_AVAILABLE" = true ]; then
    # Use pigz for compression with direct pipe
    log "INFO" "Using pigz for compression with direct pipe"

    if docker run --rm \
      -v "$volume:/source:ro" \
      alpine sh -c "tar -cf - -C /source ." |
      pigz -$COMPRESSION >"$backup_file_path"; then

      backup_end_time=$(date +%s)
      backup_duration=$((backup_end_time - backup_start_time))
      log "INFO" "Backup of volume $volume completed in $backup_duration seconds: $backup_file"

      # Verify backup integrity
      if verify_backup "$backup_file" "$volume"; then
        VOLUME_BACKUP_STATUS["$volume"]="SUCCESS"
      else
        log "ERROR" "Backup verification failed for $volume"
        VOLUME_BACKUP_STATUS["$volume"]="FAILED-VERIFICATION"
      fi
    else
      log "ERROR" "Backup of volume $volume failed"
      VOLUME_BACKUP_STATUS["$volume"]="FAILED"
    fi
  else
    # Use gzip for compression with direct pipe
    log "INFO" "Using gzip for compression with direct pipe"

    if docker run --rm \
      -v "$volume:/source:ro" \
      alpine sh -c "tar -cf - -C /source ." |
      gzip -$COMPRESSION >"$backup_file_path"; then

      backup_end_time=$(date +%s)
      backup_duration=$((backup_end_time - backup_start_time))
      log "INFO" "Backup of volume $volume completed in $backup_duration seconds: $backup_file (using gzip)"

      # Verify backup integrity
      if verify_backup "$backup_file" "$volume"; then
        VOLUME_BACKUP_STATUS["$volume"]="SUCCESS"
      else
        log "ERROR" "Backup verification failed for $volume"
        VOLUME_BACKUP_STATUS["$volume"]="FAILED-VERIFICATION"
      fi
    else
      log "ERROR" "Backup of volume $volume failed"
      VOLUME_BACKUP_STATUS["$volume"]="FAILED"
    fi
  fi

  # Calculate and display backup size
  local backup_full_path="$BACKUP_DATE_DIR/$backup_file"
  if [ -f "$backup_full_path" ]; then
    BACKUP_SIZE=$(du -h "$backup_full_path" | cut -f1)
    log "INFO" "Backup size for $volume: $BACKUP_SIZE"
  else
    log "INFO" "Backup size for $volume: 0"
  fi

  restart_containers "$volume"

  return 0
}

# Function to process volumes in parallel
process_volumes_parallel() {
  local volumes=("$@")
  local volume_count=${#volumes[@]}
  local i=0

  log "INFO" "Processing $volume_count volumes with parallelism of $PARALLEL_JOBS"

  # Process volumes in batches based on PARALLEL_JOBS
  while [ $i -lt $volume_count ]; do
    local active_jobs=0
    local job_pids=()

    # Start a batch of parallel jobs
    while [ $active_jobs -lt $PARALLEL_JOBS ] && [ $i -lt $volume_count ]; do
      local volume="${volumes[$i]}"
      backup_volume "$volume" &
      job_pids+=($!)
      ((active_jobs++))
      ((i++))
    done

    # Wait for all jobs in this batch to complete
    for pid in "${job_pids[@]}"; do
      wait $pid
    done
  done
}

# Register trap for cleanup
trap cleanup_on_exit EXIT INT TERM

# Create log file if it doesn't exist
if [ ! -f "$LOG_FILE" ]; then
  mkdir -p $(dirname "$LOG_FILE")
  touch "$LOG_FILE"
  log "INFO" "Log file created at $LOG_FILE"
fi

# Verify necessary permissions
verify_permissions

log "INFO" "==========================================="
log "INFO" "Starting Docker volume backup on $DATE in directory $BACKUP_DATE_DIR"
log "INFO" "Parallel jobs: $PARALLEL_JOBS"
log "INFO" "==========================================="

# Check if pigz is installed
if check_pigz_installation; then
  PIGZ_AVAILABLE=true
fi

# Cache Docker volumes information - improves performance for large systems
log "INFO" "Retrieving volumes information..."
VOLUMES=$(docker volume ls -q)

if [ -z "$VOLUMES" ]; then
  log "WARNING" "No Docker volumes found in the system"
  echo "WARNING: No Docker volumes found in the system"
  exit 0
fi

# Cache container-to-volume mapping information
log "INFO" "Mapping containers to volumes (caching metadata)..."
CONTAINER_VOLUME_MAPPING=$(docker ps -a --format '{{.Names}}|||{{.Mounts}}')

# Filter volumes if a specific list was provided
VOLUMES_TO_BACKUP=()
if [ ! -z "$SELECTED_VOLUMES" ]; then
  log "INFO" "Filtering volumes: $SELECTED_VOLUMES"
  # Convert comma-separated list to array
  IFS=',' read -ra VOLUME_LIST <<<"$SELECTED_VOLUMES"

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

# Parse the previously cached container-to-volume mapping
log "INFO" "Processing container-to-volume relationships..."
while IFS= read -r line; do
  container_name=$(echo "$line" | cut -d'|' -f1)
  mounts=$(echo "$line" | cut -d'|' -f3-)

  # Extract volume names from mounts string
  for volume in "${VOLUMES_TO_BACKUP[@]}"; do
    if echo "$mounts" | grep -q "$volume"; then
      # Append container to the volume's container list
      if [ -z "${CONTAINERS_BY_VOLUME[$volume]}" ]; then
        CONTAINERS_BY_VOLUME[$volume]="$container_name"
      else
        CONTAINERS_BY_VOLUME[$volume]="${CONTAINERS_BY_VOLUME[$volume]} $container_name"
      fi

      # Check if this volume is used by a container in the last priority list
      if [ ! -z "$LAST_PRIORITY" ]; then
        IFS=',' read -ra LAST_PRIORITY_ARRAY <<<"$LAST_PRIORITY"
        for last_priority_container in "${LAST_PRIORITY_ARRAY[@]}"; do
          if [ "$container_name" = "$last_priority_container" ]; then
            log "INFO" "Marking volume $volume for last priority backup (used by $container_name)"
            LAST_PRIORITY_VOLUMES["$volume"]=1
            break
          fi
        done
      fi
    fi
  done
done < <(echo "$CONTAINER_VOLUME_MAPPING")

# Check if there are volumes that should be skipped due to --skip-used flag
if [ "$SKIP_USED" = true ]; then
  # Get running containers
  RUNNING_CONTAINERS=$(docker ps --format "{{.Names}}")

  # Find volumes used by running containers
  for volume in "${!CONTAINERS_BY_VOLUME[@]}"; do
    for container in ${CONTAINERS_BY_VOLUME[$volume]}; do
      if echo "$RUNNING_CONTAINERS" | grep -q "$container"; then
        log "INFO" "Skipping volume $volume used by running container $container (--skip-used enabled)"
        # Remove from the list of volumes to backup by setting a flag
        for i in "${!VOLUMES_TO_BACKUP[@]}"; do
          if [ "${VOLUMES_TO_BACKUP[$i]}" = "$volume" ]; then
            unset 'VOLUMES_TO_BACKUP[$i]'
            break
          fi
        done
        break
      fi
    done
  done

  # Recreate array without gaps
  VOLUMES_TO_BACKUP=("${VOLUMES_TO_BACKUP[@]}")
fi

# Check if there are any volumes left to backup
if [ ${#VOLUMES_TO_BACKUP[@]} -eq 0 ]; then
  log "WARNING" "No volumes left to backup after applying filters"
  echo "WARNING: No volumes left to backup after applying filters"
  exit 0
fi

# Check system resources after determining which volumes to backup
check_resources

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

# Process regular volumes first with parallelization
if [ ${#REGULAR_VOLUMES[@]} -gt 0 ]; then
  log "INFO" "Processing regular priority volumes..."
  process_volumes_parallel "${REGULAR_VOLUMES[@]}"
fi

# Process last priority volumes (if any) with parallelization
if [ ${#LAST_VOLUMES[@]} -gt 0 ]; then
  log "INFO" "Processing last priority volumes..."
  process_volumes_parallel "${LAST_VOLUMES[@]}"
fi

# Now that all volumes are processed, restart containers safely
log "INFO" "All backup operations completed. Now restarting containers..."
restart_all_containers_safely

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

# Prepare backup summary statistics
TOTAL_VOLUMES=${#VOLUMES_TO_BACKUP[@]}
SUCCESSFUL_BACKUPS=0
FAILED_BACKUPS=0
SKIPPED_VOLUMES=0

# Count results based on backup status
for volume in "${VOLUMES_TO_BACKUP[@]}"; do
  case "${VOLUME_BACKUP_STATUS[$volume]}" in
  "SUCCESS")
    ((SUCCESSFUL_BACKUPS++))
    ;;
  "FAILED"*) # Match both FAILED and FAILED-VERIFICATION
    ((FAILED_BACKUPS++))
    ;;
  "SKIPPED")
    ((SKIPPED_VOLUMES++))
    ;;
  esac
done

log "INFO" "==========================================="
log "INFO" "Backup summary for $DATE:"
log "INFO" "Total volumes processed: $TOTAL_VOLUMES"
log "INFO" "Backups completed successfully: $SUCCESSFUL_BACKUPS"
log "INFO" "Failed backups: $FAILED_BACKUPS"
log "INFO" "Skipped volumes: $SKIPPED_VOLUMES"
log "INFO" "Total space used: $(du -sh $BACKUP_DATE_DIR | cut -f1)"
log "INFO" "Backup completed!"
log "INFO" "============================================"

# Check if any backups failed and set exit code appropriately
if [ $FAILED_BACKUPS -gt 0 ]; then
  exit 1
fi

exit 0
