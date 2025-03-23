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
  echo "  -h, --help             Display this help message"
  echo ""
  echo "Environment variables:"
  echo "  DOCKER_BACKUP_DIR      Same as --directory"
  echo "  DOCKER_COMPRESSION     Same as --compression"
  echo "  DOCKER_RETENTION_DAYS  Same as --retention"
  exit 1
}

# Get settings from environment variables or use defaults
BACKUP_DIR=${DOCKER_BACKUP_DIR:-$DEFAULT_BACKUP_DIR}
COMPRESSION=${DOCKER_COMPRESSION:-$DEFAULT_COMPRESSION_LEVEL}
RETENTION_DAYS=${DOCKER_RETENTION_DAYS:-$DEFAULT_RETENTION_DAYS}
SELECTED_VOLUMES=""
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
      shift 2
      ;;
    -r|--retention)
      RETENTION_DAYS="$2"
      shift 2
      ;;
    -v|--volumes)
      SELECTED_VOLUMES="$2"
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

# Verify that the script is executed with necessary permissions
verify_permissions() {
  # Check if the user can execute docker commands
  if ! docker ps > /dev/null 2>&1; then
    echo "ERROR: Current user cannot execute Docker commands."
    echo "Make sure you are in the 'docker' group or are root:"
    echo "sudo usermod -aG docker $USER"
    echo "After adding to the group, restart your session (logout/login)."
    exit 1
  fi
  
  # Create backup directory if it doesn't exist
  if [ ! -d "$BACKUP_DIR" ]; then
    echo "Directory $BACKUP_DIR does not exist. Attempting to create it..."
    if ! mkdir -p $BACKUP_DIR; then
      echo "ERROR: Unable to create directory $BACKUP_DIR"
      echo "Run the following commands to create the directory with correct permissions:"
      echo "sudo mkdir -p $BACKUP_DIR"
      echo "sudo chown $USER:$USER $BACKUP_DIR"
      exit 1
    fi
    echo "Directory $BACKUP_DIR created successfully."
  fi
  
  # Verify write permissions on the backup directory
  if [ ! -w "$BACKUP_DIR" ]; then
    echo "ERROR: Current user does not have write permissions on $BACKUP_DIR"
    echo "Run the following command to configure permissions:"
    echo "sudo chown $USER:$USER $BACKUP_DIR"
    exit 1
  fi
  
  # Create directory for current date backups
  if [ ! -d "$BACKUP_DATE_DIR" ]; then
    echo "Creating directory for backups on $DATE..."
    if ! mkdir -p "$BACKUP_DATE_DIR"; then
      echo "ERROR: Unable to create directory $BACKUP_DATE_DIR"
      exit 1
    fi
    echo "Directory $BACKUP_DATE_DIR created successfully."
  fi
  
  echo "Necessary permissions verified. Continuing script execution..."
}

# Logging function
log() {
  local level="$1"
  local message="$2"
  local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Function to verify backup integrity
verify_backup() {
  local backup_file="$1"
  local volume_name="$2"
  
  log "INFO" "Verifying backup integrity: $backup_file"
  
  # Verify tar archive integrity
  if tar -tzf "$backup_file" > /dev/null 2>&1; then
    log "INFO" "Integrity verification completed successfully for $volume_name"
    return 0
  else
    log "ERROR" "Integrity verification failed for $volume_name. The backup might be corrupted."
    return 1
  fi
}

# Verify necessary permissions
verify_permissions

# Create log file if it doesn't exist
if [ ! -f "$LOG_FILE" ]; then
  touch "$LOG_FILE"
  log "INFO" "Log file created at $LOG_FILE"
fi

log "INFO" "===========================================" 
log "INFO" "Starting Docker volume backup on $DATE in directory $BACKUP_DATE_DIR"
log "INFO" "===========================================" 

# Get list of all volumes
VOLUMES=$(docker volume ls -q)

if [ -z "$VOLUMES" ]; then
  log "WARNING" "No Docker volumes found in the system"
fi

# Filter volumes if a specific list was provided
VOLUMES_TO_BACKUP=()
if [ ! -z "$SELECTED_VOLUMES" ]; then
  log "INFO" "Filtering volumes: $SELECTED_VOLUMES"
  # Convert comma-separated list to array
  IFS=',' read -ra VOLUME_LIST <<< "$SELECTED_VOLUMES"
  
  # Filter volumes
  for VOLUME in $VOLUMES; do
    if echo "${VOLUME_LIST[@]}" | grep -q "$VOLUME"; then
      VOLUMES_TO_BACKUP+=("$VOLUME")
    fi
  done
  
  # Check if any requested volumes were not found
  for REQUESTED in "${VOLUME_LIST[@]}"; do
    if ! echo "$VOLUMES" | grep -q "$REQUESTED"; then
      log "WARNING" "Requested volume not found: $REQUESTED"
    fi
  done
  
  # If no volumes match the filter, exit
  if [ ${#VOLUMES_TO_BACKUP[@]} -eq 0 ]; then
    log "ERROR" "None of the specified volumes were found"
    exit 1
  fi
else
  # No filter, use all volumes
  for VOLUME in $VOLUMES; do
    VOLUMES_TO_BACKUP+=("$VOLUME")
  done
fi

# Counters for statistics
TOTAL_VOLUMES=0
SUCCESSFUL_BACKUPS=0
FAILED_BACKUPS=0

# For each volume, find containers using it, stop them, backup, and restart
for VOLUME in "${VOLUMES_TO_BACKUP[@]}"
do
  TOTAL_VOLUMES=$((TOTAL_VOLUMES+1))
  BACKUP_FILE="$BACKUP_DATE_DIR/$VOLUME.tar.gz"
  
  log "INFO" "Processing volume: $VOLUME"
  
  # Find containers using this volume
  CONTAINERS=$(docker ps -a --filter volume=$VOLUME --format "{{.Names}}")
  
  # If there are containers using this volume
  if [ ! -z "$CONTAINERS" ]; then
    # Skip if the skip-used option is enabled
    if [ "$SKIP_USED" = true ]; then
      log "INFO" "Skipping volume $VOLUME used by running containers (--skip-used enabled)"
      continue
    fi
    
    log "INFO" "Containers using volume $VOLUME: $CONTAINERS"
    
    # Ask for confirmation unless force mode is enabled
    if [ "$FORCE" != "true" ]; then
      read -p "Containers need to be stopped. Continue with backup? (y/n): " CONFIRM
      if [ "$CONFIRM" != "y" ]; then
        log "INFO" "Backup canceled by user for volume $VOLUME"
        continue
      fi
    fi
    
    # Stop the containers
    log "INFO" "Stopping containers..."
    for CONTAINER in $CONTAINERS
    do
      if docker stop $CONTAINER; then
        log "INFO" "Container $CONTAINER stopped"
      else
        log "ERROR" "Unable to stop container $CONTAINER"
        # If we can't stop a container, we shouldn't continue with this volume
        continue 2
      fi
    done
    
    # Perform backup using pigz (parallel gzip) for speed
    log "INFO" "Backing up volume: $VOLUME"
    if docker run --rm \
      -v $VOLUME:/source:ro \
      -v $BACKUP_DIR:/backup \
      alpine sh -c "apk add --no-cache pigz && tar -cf - -C /source . | pigz -$COMPRESSION > /backup/$DATE/$VOLUME.tar.gz || tar -czf /backup/$DATE/$VOLUME.tar.gz -C /source ."; then
      log "INFO" "Backup of volume $VOLUME completed: $BACKUP_FILE"
    else
      log "ERROR" "Backup of volume $VOLUME failed"
      FAILED_BACKUPS=$((FAILED_BACKUPS+1))
      
      # Restart containers even in case of error
      log "INFO" "Restarting containers after error..."
      for CONTAINER in $CONTAINERS
      do
        if docker start $CONTAINER; then
          log "INFO" "Container $CONTAINER restarted"
        else
          log "ERROR" "Unable to restart container $CONTAINER"
        fi
      done
      
      continue
    fi
    
    # Verify integrity
    if verify_backup "$BACKUP_FILE" "$VOLUME"; then
      SUCCESSFUL_BACKUPS=$((SUCCESSFUL_BACKUPS+1))
    else
      FAILED_BACKUPS=$((FAILED_BACKUPS+1))
    fi
    
    # Restart containers
    log "INFO" "Restarting containers..."
    for CONTAINER in $CONTAINERS
    do
      if docker start $CONTAINER; then
        log "INFO" "Container $CONTAINER restarted"
      else
        log "ERROR" "Unable to restart container $CONTAINER"
        log "WARNING" "Manual intervention required to restart container: $CONTAINER"
      fi
    done
  else
    # No containers are using this volume, just do the backup
    log "INFO" "No containers are using volume $VOLUME"
    log "INFO" "Backing up volume: $VOLUME"
    if docker run --rm \
      -v $VOLUME:/source:ro \
      -v $BACKUP_DIR:/backup \
      alpine sh -c "apk add --no-cache pigz && tar -cf - -C /source . | pigz -$COMPRESSION > /backup/$DATE/$VOLUME.tar.gz || tar -czf /backup/$DATE/$VOLUME.tar.gz -C /source ."; then
      log "INFO" "Backup of volume $VOLUME completed: $BACKUP_FILE"
      
      # Verify integrity
      if verify_backup "$BACKUP_FILE" "$VOLUME"; then
        SUCCESSFUL_BACKUPS=$((SUCCESSFUL_BACKUPS+1))
      else
        FAILED_BACKUPS=$((FAILED_BACKUPS+1))
      fi
    else
      log "ERROR" "Backup of volume $VOLUME failed"
      FAILED_BACKUPS=$((FAILED_BACKUPS+1))
    fi
  fi
  
  # Calculate and display backup size
  if [ -f "$BACKUP_FILE" ]; then
    BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
    log "INFO" "Backup size for $VOLUME: $BACKUP_SIZE"
  fi
done

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
log "INFO" "Total space used: $(du -sh $BACKUP_DIR | cut -f1)"
log "INFO" "Backup completed!"
log "INFO" "============================================"

# Check if any backups failed and set exit code appropriately
if [ $FAILED_BACKUPS -gt 0 ]; then
  exit 1
fi