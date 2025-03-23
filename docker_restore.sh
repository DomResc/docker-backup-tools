#!/bin/bash
# Docker Volume Restore - A utility to restore Docker volumes
# https://github.com/yourusername/docker-volume-tools
# 
# MIT License
# 
# Copyright (c) 2025 Your Name
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

# Parse command line options
while [[ $# -gt 0 ]]; do
  case $1 in
    -d|--directory)
      BACKUP_DIR="$2"
      shift 2
      ;;
    -b|--backup)
      SPECIFIC_DATE="$2"
      shift 2
      ;;
    -f|--force)
      FORCE=true
      shift
      ;;
    -h|--help)
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

LOG_FILE="$BACKUP_DIR/docker_backup.log"

# Logging function
log() {
  local level="$1"
  local message="$2"
  local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Create directory if it doesn't exist
mkdir -p $BACKUP_DIR

# Create log file if it doesn't exist
if [ ! -f "$LOG_FILE" ]; then
  touch "$LOG_FILE"
  log "INFO" "Log file created at $LOG_FILE"
fi

# Function to verify backup integrity
verify_backup() {
  local backup_file="$1"
  
  log "INFO" "Verifying backup integrity: $backup_file"
  
  # Verify integrity of tar archive with pigz if available
  if docker run --rm \
    -v $BACKUP_DIR:/backup \
    alpine sh -c "apk add --no-cache pigz && pigz -t /backup/$(basename $backup_file) || tar -tzf /backup/$(basename $backup_file)" > /dev/null 2>&1; then
    log "INFO" "Integrity verification completed successfully"
    return 0
  else
    log "ERROR" "Integrity verification failed. The backup might be corrupted."
    return 1
  fi
}

# Function to show available backup dates
show_available_dates() {
  log "INFO" "Searching for available backup dates"
  echo "Available backup dates:"
  echo "-------------------------"
  
  # Find all backup directories sorted by date (most recent first)
  BACKUP_DATES=$(find $BACKUP_DIR -mindepth 1 -maxdepth 1 -type d | sort -r)
  
  if [ -z "$BACKUP_DATES" ]; then
    log "WARNING" "No backup directories found in $BACKUP_DIR"
    echo "No backups found in $BACKUP_DIR"
    exit 1
  fi
  
  # Show dates with numbers
  COUNT=1
  for DATE_DIR in $BACKUP_DATES; do
    DATE_NAME=$(basename "$DATE_DIR")
    echo "$COUNT) Backup from $DATE_NAME"
    COUNT=$((COUNT+1))
  done
  
  return $COUNT
}

# Function to show list of available volumes for restoration on a specific date
show_available_volumes() {
  BACKUP_DATE=$1
  BACKUP_DATE_DIR="$BACKUP_DIR/$BACKUP_DATE"
  
  log "INFO" "Searching for available volumes for restoration on date $BACKUP_DATE"
  echo "Volumes available for restoration from $BACKUP_DATE:"
  echo "------------------------------------"
  
  # Extract unique volume names from backup files
  AVAILABLE_VOLUMES=$(find "$BACKUP_DATE_DIR" -name "*.tar.gz" -type f | xargs -n1 basename | sed 's/.tar.gz$//')
  
  if [ -z "$AVAILABLE_VOLUMES" ]; then
    log "WARNING" "No backups found in $BACKUP_DATE_DIR"
    echo "No backups found in $BACKUP_DATE_DIR"
    exit 1
  fi
  
  # Show volumes with numbers
  COUNT=1
  for VOL in $AVAILABLE_VOLUMES; do
    echo "$COUNT) $VOL"
    COUNT=$((COUNT+1))
  done
  
  return $COUNT
}

# Function to show available backups for a volume on a specific date
show_available_backups() {
  BACKUP_DATE=$1
  VOLUME=$2
  BACKUP_DATE_DIR="$BACKUP_DIR/$BACKUP_DATE"
  
  log "INFO" "Searching for available backups for volume $VOLUME on date $BACKUP_DATE"
  echo "Available backups for volume $VOLUME from $BACKUP_DATE:"
  echo "----------------------------------------"
  
  # Find the backup for this volume on the specified date
  BACKUP="$BACKUP_DATE_DIR/$VOLUME.tar.gz"
  
  if [ ! -f "$BACKUP" ]; then
    log "WARNING" "No backup found for volume $VOLUME on date $BACKUP_DATE"
    echo "No backup found for volume $VOLUME on date $BACKUP_DATE"
    exit 1
  fi
  
  # Get backup size
  SIZE=$(du -h "$BACKUP" | cut -f1)
  
  echo "Available backup - Size: $SIZE"
  
  # Return 2 because we have only one option (1) plus exit (0)
  return 2
}

# Function to restore a volume
restore_volume() {
  VOLUME=$1
  BACKUP_FILE=$2
  
  log "INFO" "===========================================" 
  log "INFO" "Starting restoration procedure"
  log "INFO" "Volume: $VOLUME"
  log "INFO" "Backup file: $BACKUP_FILE"
  
  # Verify backup integrity before restoration
  if ! verify_backup "$BACKUP_FILE"; then
    log "ERROR" "Integrity verification failed. Restoration canceled."
    echo "Integrity verification failed. Restoration canceled."
    exit 1
  fi
  
  log "INFO" "Restoring volume $VOLUME from backup: $BACKUP_FILE"
  echo "Restoring volume $VOLUME from backup: $BACKUP_FILE"
  
  # Find containers using this volume
  CONTAINERS=$(docker ps -a --filter volume=$VOLUME --format "{{.Names}}")
  
  # If there are containers using this volume, stop them
  if [ ! -z "$CONTAINERS" ]; then
    log "INFO" "Containers using volume $VOLUME: $CONTAINERS"
    echo "Containers using volume $VOLUME: $CONTAINERS"
    
    # Ask for confirmation unless force mode is enabled
    if [ "$FORCE" != "true" ]; then
      read -p "These containers will be stopped during restoration. Continue? (y/n): " CONFIRM
      if [ "$CONFIRM" != "y" ]; then
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
    for CONTAINER in $CONTAINERS; do
      if docker stop $CONTAINER; then
        log "INFO" "Container $CONTAINER stopped"
        echo "Container $CONTAINER stopped"
      else
        log "ERROR" "Unable to stop container $CONTAINER"
        echo "Error: unable to stop container $CONTAINER"
      fi
    done
  fi
  
  # Create volume if it doesn't exist
  if ! docker volume inspect $VOLUME >/dev/null 2>&1; then
    log "INFO" "Volume $VOLUME does not exist. Creating..."
    echo "Volume $VOLUME does not exist. Creating..."
    if docker volume create $VOLUME; then
      log "INFO" "Volume $VOLUME created successfully"
      echo "Volume $VOLUME created successfully"
    else
      log "ERROR" "Unable to create volume $VOLUME"
      echo "Error: unable to create volume $VOLUME"
      exit 1
    fi
  fi
  
  # Timestamp for start of restoration
  START_TIME=$(date +%s)
  
  # Restore backup with pigz for faster speed
  log "INFO" "Restoring data in progress... (this may take time)"
  echo "Restoring data in progress... (this may take time)"
  if docker run --rm \
    -v $VOLUME:/target \
    -v $BACKUP_DIR:/backup \
    alpine sh -c "apk add --no-cache pigz && pigz -dc /backup/$(basename $BACKUP_FILE) | tar -xf - -C /target || tar -xzf /backup/$(basename $BACKUP_FILE) -C /target"; then
    
    # Calculate restoration time
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    
    log "INFO" "Restoration completed in $DURATION seconds"
    echo "Restoration completed in $DURATION seconds"
    
    # Verify contents after restoration
    ITEMS_COUNT=$(docker run --rm -v $VOLUME:/target alpine sh -c "find /target -type f | wc -l")
    log "INFO" "Items restored in volume $VOLUME: $ITEMS_COUNT files"
    echo "Items restored in volume $VOLUME: $ITEMS_COUNT files"
  else
    log "ERROR" "Error during data restoration"
    echo "Error during data restoration"
    
    # Restart containers even in case of error if they were running
    if [ ! -z "$CONTAINERS" ]; then
      log "INFO" "Restarting containers after error..."
      echo "Restarting containers after error..."
      for CONTAINER in $CONTAINERS; do
        docker start $CONTAINER
        log "INFO" "Container $CONTAINER restarted"
        echo "Container $CONTAINER restarted"
      done
    fi
    
    exit 1
  fi
  
  # Restart containers if they were running
  if [ ! -z "$CONTAINERS" ]; then
    log "INFO" "Restarting containers..."
    echo "Restarting containers..."
    for CONTAINER in $CONTAINERS; do
      if docker start $CONTAINER; then
        log "INFO" "Container $CONTAINER restarted"
        echo "Container $CONTAINER restarted"
      else
        log "ERROR" "Unable to restart container $CONTAINER"
        echo "Error: unable to restart container $CONTAINER"
      fi
    done
  fi
  
  log "INFO" "Restoration completed successfully!"
  log "INFO" "===========================================" 
  echo "Restoration completed successfully!"
}

# Main menu
echo "====== Docker Volume Restore Tool ======"
log "INFO" "Starting Docker volume restoration tool"
echo ""

# If a specific date was provided via command line
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
  BACKUP_DATE="$SPECIFIC_DATE"
else
  # Show the list of available backup dates
  show_available_dates
  MAX_DATES=$?

  # Ask user to choose a date
  read -p "Select a backup date (1-$((MAX_DATES-1)), 0 to exit): " DATE_CHOICE

  if [ "$DATE_CHOICE" -eq 0 ]; then
    log "INFO" "Operation canceled by user"
    echo "Operation canceled."
    exit 0
  fi

  if [ "$DATE_CHOICE" -lt 1 ] || [ "$DATE_CHOICE" -ge "$MAX_DATES" ]; then
    log "ERROR" "Invalid choice: $DATE_CHOICE"
    echo "Invalid choice."
    exit 1
  fi

  # Get the selected backup date
  BACKUP_DATE=$(find $BACKUP_DIR -mindepth 1 -maxdepth 1 -type d | sort -r | sed -n "${DATE_CHOICE}p" | xargs basename)
  log "INFO" "Selected date: $BACKUP_DATE"
fi

# Check if a volume was specified as an argument
if [ -z "$VOLUME_ARG" ]; then
  # No volume specified, show the list for the selected date
  show_available_volumes "$BACKUP_DATE"
  MAX_VOLUMES=$?
  
  # Ask user to choose
  read -p "Select the volume to restore (1-$((MAX_VOLUMES-1)), 0 to exit): " VOLUME_CHOICE
  
  if [ "$VOLUME_CHOICE" -eq 0 ]; then
    log "INFO" "Operation canceled by user"
    echo "Operation canceled."
    exit 0
  fi
  
  if [ "$VOLUME_CHOICE" -lt 1 ] || [ "$VOLUME_CHOICE" -ge "$MAX_VOLUMES" ]; then
    log "ERROR" "Invalid choice: $VOLUME_CHOICE"
    echo "Invalid choice."
    exit 1
  fi
  
  # Get the name of the selected volume
  VOLUME=$(find "$BACKUP_DIR/$BACKUP_DATE" -name "*.tar.gz" -type f | xargs -n1 basename | sed 's/.tar.gz$//' | sed -n "${VOLUME_CHOICE}p")
else
  # Volume specified as an argument
  VOLUME=$VOLUME_ARG
  
  # Verify the specified volume has a backup
  if [ ! -f "$BACKUP_DIR/$BACKUP_DATE/$VOLUME.tar.gz" ]; then
    log "ERROR" "No backup found for volume $VOLUME on date $BACKUP_DATE"
    echo "Error: No backup found for volume $VOLUME on date $BACKUP_DATE"
    
    # Show available volumes for this date to help the user
    echo "Available volumes for $BACKUP_DATE:"
    find "$BACKUP_DIR/$BACKUP_DATE" -name "*.tar.gz" -type f | xargs -n1 basename | sed 's/.tar.gz$//' | sort
    exit 1
  fi
fi

log "INFO" "Selected volume: $VOLUME"

# For consistency with the rest of the script, even if there's only one backup, we show the function
show_available_backups "$BACKUP_DATE" "$VOLUME"

# The backup file is always in the standard location for the selected date and volume
BACKUP_FILE="$BACKUP_DIR/$BACKUP_DATE/$VOLUME.tar.gz"
log "INFO" "Selected backup: $BACKUP_FILE"

# Perform the restoration
restore_volume $VOLUME $BACKUP_FILE