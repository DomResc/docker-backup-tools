#!/bin/bash

# Function to print usage
print_usage() {
    echo "ERROR: Configuration file not specified."
    echo ""
    echo "USAGE:"
    echo "  $0 -c /path/to/configuration.conf [options]"
    echo ""
    echo "OPTIONS:"
    echo "  -c, --config FILE      Specify the configuration file (REQUIRED)"
    echo "  --create-config FILE   Create a sample configuration file"
    echo "  --show-config          Show active configuration and exit"
    echo "  --backup               Perform a backup (default action when no other action specified)"
    echo "  --restore ARCHIVE      Restore a specific backup archive"
    echo "  --list                 List available backup archives"
    echo "  --cleanup              Remove temporary files and enforce retention policy"
    echo "  --download             Download backup repository from Filen remote storage"
    echo "  -h, --help             Show this help message"
    echo ""
    echo "To get started, create a configuration file with:"
    echo "  $0 --create-config /path/to/save/configuration.conf"
    echo ""
}

# Function to create a sample configuration file
create_sample_config() {
    # Verify that the destination directory exists
    CONFIG_DIR=$(dirname "$1")
    if [ ! -d "$CONFIG_DIR" ]; then
        mkdir -p "$CONFIG_DIR" || {
            echo "Unable to create directory $CONFIG_DIR"
            exit 1
        }
    fi

    cat >"$1" <<EOF
# Docker Backup Configuration
# Generated: $(date)
# --------------------------------------------------------------
# WARNING: This file contains critical settings!
# Modify with care and test after making changes.
# --------------------------------------------------------------

# Main directories
DOCKER_DIR="/var/lib/docker"
BACKUP_DIR="/backup/docker"
REMOTE_DEST="/backup/docker"
LOG_FILE="/var/log/docker-backup.log"
COMPRESSION="lz4"

# Retention policy
KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=12
KEEP_YEARLY=0

# Email configuration
EMAIL_ENABLED=false
EMAIL_TO="admin@example.com"
EMAIL_FROM="docker-backup@$(hostname -f)"
EMAIL_SUBJECT="Docker Backup Report: $(hostname -s)"
EMAIL_NOTIFY_SUCCESS=false
EMAIL_NOTIFY_ERROR=true
EMAIL_SMTP_SERVER="smtp.gmail.com"
EMAIL_SMTP_PORT="587"
EMAIL_SMTP_USER=""
EMAIL_SMTP_PASSWORD=""
EMAIL_SMTP_TLS=true

# Mode configuration
INTERACTIVE=true
SHOW_PROGRESS=true
SYNC_ENABLED=true

# Docker cleanup configuration
DOCKER_CLEANUP_ENABLED=false
DOCKER_PRUNE_ALL_IMAGES=false
DOCKER_SYSTEM_PRUNE=false
DOCKER_PRUNE_VOLUMES=false

# Restore configuration
RESTORE_TEMP_DIR="/tmp/docker-restore"
EOF
    echo "Sample configuration generated at: $1"
    echo "Edit this file according to your needs and then run:"
    echo "  $0 -c $1"

    # Set secure permissions
    chmod 600 "$1"
}

# Function to verify the configuration file
verify_config() {
    if [ ! -f "$1" ]; then
        echo "ERROR: Configuration file '$1' does not exist."
        echo "Create a configuration file with:"
        echo "  $0 --create-config $1"
        exit 1
    fi

    if [ ! -r "$1" ]; then
        echo "ERROR: Configuration file '$1' is not readable."
        echo "Check file permissions."
        exit 1
    fi
}

# Function to print active configuration
print_config() {
    echo "=== Active Configuration ==="
    echo "DOCKER_DIR: $DOCKER_DIR"
    echo "BACKUP_DIR: $BACKUP_DIR"
    echo "REMOTE_DEST: $REMOTE_DEST"
    echo "LOG_FILE: $LOG_FILE"
    echo "COMPRESSION: $COMPRESSION"
    echo
    echo "Retention:"
    echo "  KEEP_DAILY: $KEEP_DAILY"
    echo "  KEEP_WEEKLY: $KEEP_WEEKLY"
    echo "  KEEP_MONTHLY: $KEEP_MONTHLY"
    echo "  KEEP_YEARLY: $KEEP_YEARLY"
    echo
    echo "Email: $EMAIL_ENABLED (to: $EMAIL_TO)"
    echo "Sync: $SYNC_ENABLED"
    echo "Mode: Interactive=$INTERACTIVE, Progress=$SHOW_PROGRESS"
    echo
    echo "Docker Cleanup: $DOCKER_CLEANUP_ENABLED"
    if [ "$DOCKER_CLEANUP_ENABLED" = true ]; then
        echo "  Prune All Images: $DOCKER_PRUNE_ALL_IMAGES"
        echo "  System Prune: $DOCKER_SYSTEM_PRUNE"
        echo "  Prune Volumes: $DOCKER_PRUNE_VOLUMES"
    fi
    echo
    echo "Restore temporary directory: $RESTORE_TEMP_DIR"
}

# Create lock directory function - more atomic than file-based locks
create_lock() {
    LOCK_DIR="/tmp/docker-backup.lock"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        # Check if the lock is stale
        if [ -f "$LOCK_DIR/pid" ]; then
            pid=$(cat "$LOCK_DIR/pid")
            if ! ps -p "$pid" >/dev/null 2>&1; then
                log "Removing stale lock from PID $pid" "WARN"
                rm -rf "$LOCK_DIR"
                mkdir "$LOCK_DIR" || return 1
            else
                return 1 # Lock exists and process is still running
            fi
        else
            return 1 # Lock exists but no PID file (shouldn't happen)
        fi
    fi

    # Store PID in the lock directory
    echo $$ >"$LOCK_DIR/pid"
    return 0
}

# Remove lock directory function
remove_lock() {
    LOCK_DIR="/tmp/docker-backup.lock"
    if [ -d "$LOCK_DIR" ]; then
        rm -rf "$LOCK_DIR"
    fi
}

# Log function
log() {
    local level="INFO"
    if [ "$2" ]; then
        level="$2"
    fi

    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $1"

    # Log to file
    echo "$msg" >>"$LOG_FILE"

    # Log to email temp file if it exists
    if [ -f "$EMAIL_TEMP_FILE" ]; then
        echo "$msg" >>"$EMAIL_TEMP_FILE"
    fi

    # Log to screen if in interactive mode
    if [ "$INTERACTIVE" = true ] || [ "$level" = "ERROR" ]; then
        if [ "$level" = "ERROR" ]; then
            echo -e "\033[0;31m$msg\033[0m"
        else
            echo "$msg"
        fi
    fi
}

# Email sending function
send_email() {
    if [ "$EMAIL_ENABLED" = true ]; then
        local status="SUCCESS"
        if [ "$BACKUP_SUCCESS" = false ]; then
            status="ERROR"
        fi

        # Calculate execution time
        local end_time=$(date +%s)
        local duration=$((end_time - BACKUP_START_TIME))
        local hours=$((duration / 3600))
        local minutes=$(((duration % 3600) / 60))
        local seconds=$((duration % 60))

        # Prepare temporary message
        local email_body_file=$(mktemp)
        {
            echo "Subject: $EMAIL_SUBJECT - $status"
            echo "From: $EMAIL_FROM"
            echo "To: $EMAIL_TO"
            echo "MIME-Version: 1.0"
            echo "Content-Type: text/plain; charset=utf-8"
            echo
            echo "=== Docker Backup Report ==="
            echo "Status: $status"
            echo "Host: $(hostname -f)"
            echo "Date: $(date)"
            echo "Duration: ${hours}h ${minutes}m ${seconds}s"
            echo "Source: $DOCKER_DIR"
            echo "Backup: $BACKUP_DIR"
            echo
            echo "=== Log Details ==="
            cat "$EMAIL_TEMP_FILE"
        } >"$email_body_file"

        # Create temporary msmtp config
        local msmtp_config=$(mktemp)
        {
            echo "account default"
            echo "host $EMAIL_SMTP_SERVER"
            echo "port $EMAIL_SMTP_PORT"
            echo "from $EMAIL_FROM"
            echo "user $EMAIL_SMTP_USER"
            echo "password $EMAIL_SMTP_PASSWORD"
            echo "auth on"
            if [ "$EMAIL_SMTP_TLS" = true ]; then
                echo "tls on"
                echo "tls_starttls on"
            else
                echo "tls off"
            fi
        } >"$msmtp_config"

        chmod 600 "$msmtp_config" # Ensure config file has secure permissions

        # Send email using config file
        if cat "$email_body_file" | msmtp --file="$msmtp_config" "$EMAIL_TO"; then
            log "Notification email sent to $EMAIL_TO"
        else
            log "Email sending failed" "ERROR"
        fi

        # Remove temporary files
        rm -f "$msmtp_config" "$email_body_file"
    fi
}

# Progress bar function
show_progress() {
    if [ "$SHOW_PROGRESS" = true ] && [ "$INTERACTIVE" = true ]; then
        local percent="$1"
        local width=50
        local num_chars=$((percent * width / 100))

        # Build the bar
        local progress_bar="["
        for ((i = 0; i < num_chars; i++)); do
            progress_bar+="#"
        done
        for ((i = num_chars; i < width; i++)); do
            progress_bar+=" "
        done
        progress_bar+="] $percent%"

        # Clear the line and show the bar
        echo -ne "\r\033[K$progress_bar"
    fi
}

# Script termination function
finish() {
    local exit_code="$1"

    # Send notification email if needed
    if [ "$BACKUP_SUCCESS" = false ] && [ "$EMAIL_NOTIFY_ERROR" = true ]; then
        send_email
    elif [ "$BACKUP_SUCCESS" = true ] && [ "$EMAIL_NOTIFY_SUCCESS" = true ]; then
        send_email
    fi

    # Remove temporary file if exists
    if [ -f "$EMAIL_TEMP_FILE" ]; then
        rm -f "$EMAIL_TEMP_FILE"
    fi

    # Remove lock
    remove_lock

    # Exit with appropriate code
    exit "$exit_code"
}

# Error handling
handle_error() {
    log "$1" "ERROR"
    BACKUP_SUCCESS=false
    finish 1
}

# Function to stop Docker services
stop_docker() {
    log "Stopping Docker services"
    if ! systemctl stop docker.socket; then
        handle_error "Unable to stop docker.socket"
    fi

    if ! systemctl stop docker.service; then
        log "Unable to stop docker.service" "ERROR"
        systemctl start docker.socket
        handle_error "Unable to stop docker.service"
    fi
}

# Function to start Docker services
start_docker() {
    log "Starting Docker services"
    if ! systemctl start docker.service; then
        handle_error "Unable to start docker.service"
    fi

    if ! systemctl start docker.socket; then
        handle_error "Unable to start docker.socket"
    fi
}

# Function to perform backup
perform_backup() {
    log "Starting Docker backup process"

    # Create lock to prevent multiple executions
    if ! create_lock; then
        pid=$(cat "/tmp/docker-backup.lock/pid" 2>/dev/null || echo "unknown")
        handle_error "Another instance of this script is already running (PID: $pid)"
    fi

    # Temporary file for email report
    EMAIL_TEMP_FILE=$(mktemp)
    BACKUP_SUCCESS=true
    BACKUP_START_TIME=$(date +%s)

    log "Configuration loaded from: $CONFIG_FILE"
    log "Configuration: DOCKER_DIR=$DOCKER_DIR, BACKUP_DIR=$BACKUP_DIR"
    log "Retention: daily=$KEEP_DAILY, weekly=$KEEP_WEEKLY, monthly=$KEEP_MONTHLY, yearly=$KEEP_YEARLY"

    # Check if Docker directory exists
    if [ ! -d "$DOCKER_DIR" ]; then
        handle_error "Docker directory $DOCKER_DIR does not exist"
    fi

    # Check available space
    AVAILABLE_SPACE=$(df -Pk "$BACKUP_DIR" | tail -1 | awk '{print $4}')
    DOCKER_SIZE=$(du -sk "$DOCKER_DIR" | awk '{print $1}')
    if [ "$AVAILABLE_SPACE" -lt "$DOCKER_SIZE" ]; then
        handle_error "Insufficient space for backup. Available: ${AVAILABLE_SPACE}KB, Required: ${DOCKER_SIZE}KB"
    fi

    # Set borg options based on mode
    BORG_OPTS=""
    if [ "$SHOW_PROGRESS" = true ]; then
        BORG_OPTS="--progress"
    fi
    if [ "$INTERACTIVE" = false ]; then
        export BORG_RELOCATED_REPO_ACCESS_IS_OK=yes
        export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes
    fi

    # Initialize Borg repo if it doesn't exist
    if [ ! -d "$BACKUP_DIR/data" ]; then
        log "Initializing Borg repository"
        if ! borg init --encryption=none "$BACKUP_DIR"; then
            handle_error "Unable to initialize Borg repository"
        fi
    fi

    # Stop Docker services
    stop_docker
    show_progress 10

    # Backup name with timestamp
    BACKUP_NAME="docker-$(date +%Y-%m-%d_%H:%M:%S)"

    # Create backup
    log "Creating backup: $BACKUP_NAME"
    if ! borg create --stats $BORG_OPTS --compression "$COMPRESSION" "$BACKUP_DIR"::"$BACKUP_NAME" "$DOCKER_DIR"; then
        log "Backup creation failed" "ERROR"
        start_docker
        handle_error "Backup creation failed"
    fi
    show_progress 40

    # Restart Docker services
    start_docker
    show_progress 50

    # Verify backup integrity
    log "Verifying backup integrity"
    if ! borg check $BORG_OPTS "$BACKUP_DIR"::"$BACKUP_NAME"; then
        handle_error "Backup integrity verification failed"
    fi
    show_progress 60

    # Clean old backups with advanced strategy
    log "Cleaning old backups"
    if ! borg prune --stats $BORG_OPTS \
        --keep-daily="$KEEP_DAILY" \
        --keep-weekly="$KEEP_WEEKLY" \
        --keep-monthly="$KEEP_MONTHLY" \
        --keep-yearly="$KEEP_YEARLY" \
        "$BACKUP_DIR"; then
        handle_error "Backup cleanup failed"
    fi
    show_progress 75

    # Compact repository
    log "Compacting repository"
    if ! borg compact $BORG_OPTS "$BACKUP_DIR"; then
        handle_error "Repository compaction failed"
    fi
    show_progress 85

    # Sync backup
    if [ "$SYNC_ENABLED" = true ]; then
        log "Syncing backup to remote storage: $REMOTE_DEST"
        if ! filen sync "$BACKUP_DIR":ltc:"$REMOTE_DEST"; then
            handle_error "Remote storage sync failed"
        fi
    else
        log "Remote sync disabled"
    fi
    show_progress 100

    # Line break after progress bar
    if [ "$SHOW_PROGRESS" = true ] && [ "$INTERACTIVE" = true ]; then
        echo
    fi

    log "Backup completed successfully"
    finish 0
}

# Function to list available backups
list_backups() {
    log "Listing available backups"

    # Check if backup directory exists
    if [ ! -d "$BACKUP_DIR" ]; then
        handle_error "Backup directory $BACKUP_DIR does not exist"
    fi

    echo "=== Local Backups ==="
    borg list "$BACKUP_DIR"

    # Check if Filen is enabled and available
    if [ "$SYNC_ENABLED" = true ] && command -v filen &>/dev/null; then
        echo ""
        echo "=== Remote Backups (Filen) ==="
        filen ls "$REMOTE_DEST"
    fi
}

# Function to restore backup
restore_backup() {
    local archive="$1"

    if [ -z "$archive" ]; then
        handle_error "No archive specified for restore"
    fi

    log "Starting Docker backup restore for archive: $archive"

    # Create lock to prevent multiple executions
    if ! create_lock; then
        pid=$(cat "/tmp/docker-backup.lock/pid" 2>/dev/null || echo "unknown")
        handle_error "Another instance of this script is already running (PID: $pid)"
    fi

    # Temporary file for email report
    EMAIL_TEMP_FILE=$(mktemp)
    BACKUP_SUCCESS=true
    BACKUP_START_TIME=$(date +%s)

    # Verify the archive exists
    if ! borg list "$BACKUP_DIR"::"$archive" &>/dev/null; then
        handle_error "Archive $archive not found in repository"
    fi

    # Create temporary restore directory if it doesn't exist
    if [ ! -d "$RESTORE_TEMP_DIR" ]; then
        log "Creating temporary restore directory: $RESTORE_TEMP_DIR"
        if ! mkdir -p "$RESTORE_TEMP_DIR"; then
            handle_error "Unable to create temporary restore directory"
        fi
    else
        # Clean any previous restore data
        log "Cleaning temporary restore directory"
        if ! rm -rf "$RESTORE_TEMP_DIR"/*; then
            handle_error "Unable to clean temporary restore directory"
        fi
    fi

    show_progress 10

    # Extract backup to temporary location
    log "Extracting backup to temporary location"
    if ! borg extract --progress "$BACKUP_DIR"::"$archive" --destination "$RESTORE_TEMP_DIR"; then
        handle_error "Failed to extract backup"
    fi

    show_progress 50

    # Stop Docker services
    stop_docker

    show_progress 60

    # Move current Docker directory to backup (just in case)
    local date_suffix=$(date +%Y%m%d%H%M%S)
    local docker_backup="$DOCKER_DIR.backup.$date_suffix"
    log "Moving current Docker directory to $docker_backup"
    if ! mv "$DOCKER_DIR" "$docker_backup"; then
        start_docker
        handle_error "Failed to backup current Docker directory"
    fi

    show_progress 70

    # Create new Docker directory
    if ! mkdir -p "$DOCKER_DIR"; then
        log "Failed to create new Docker directory, restoring from backup" "ERROR"
        mv "$docker_backup" "$DOCKER_DIR"
        start_docker
        handle_error "Failed to create new Docker directory"
    fi

    # Copy restored data to Docker directory
    log "Copying restored data to Docker directory"
    if ! cp -a "$RESTORE_TEMP_DIR"/* "$DOCKER_DIR"/; then
        log "Failed to copy restored data, restoring from backup" "ERROR"
        rm -rf "$DOCKER_DIR"
        mv "$docker_backup" "$DOCKER_DIR"
        start_docker
        handle_error "Failed to copy restored data"
    fi

    show_progress 90

    # Set proper permissions
    log "Setting proper permissions"
    chown -R root:root "$DOCKER_DIR"

    # Start Docker services
    start_docker

    show_progress 100

    # Line break after progress bar
    if [ "$SHOW_PROGRESS" = true ] && [ "$INTERACTIVE" = true ]; then
        echo
    fi

    log "Restore completed successfully"
    log "Previous Docker directory backed up at: $docker_backup"
    log "You may want to remove it after verifying everything works correctly"

    finish 0
}

# Function to cleanup temporary files and enforce retention
cleanup() {
    log "Starting cleanup process"

    # Check if backup directory exists
    if [ ! -d "$BACKUP_DIR" ]; then
        handle_error "Backup directory $BACKUP_DIR does not exist"
    fi

    # Set default values for new configuration parameters if not set
    DOCKER_CLEANUP_ENABLED=${DOCKER_CLEANUP_ENABLED:-false}
    DOCKER_PRUNE_ALL_IMAGES=${DOCKER_PRUNE_ALL_IMAGES:-false}
    DOCKER_SYSTEM_PRUNE=${DOCKER_SYSTEM_PRUNE:-false}
    DOCKER_PRUNE_VOLUMES=${DOCKER_PRUNE_VOLUMES:-false}

    # Remove temporary directories if they exist
    if [ -d "$RESTORE_TEMP_DIR" ]; then
        log "Cleaning temporary restore directory"
        if ! rm -rf "$RESTORE_TEMP_DIR"/*; then
            handle_error "Unable to clean temporary restore directory"
        fi
    fi

    # Perform Docker cleanup if enabled
    if [ "$DOCKER_CLEANUP_ENABLED" = true ]; then
        log "Docker cleanup is enabled"

        # Check if Docker is running
        if ! systemctl is-active --quiet docker; then
            log "Starting Docker services for cleanup"
            if ! systemctl start docker; then
                handle_error "Unable to start Docker for cleanup"
            fi
        fi

        # Perform Docker cleanup
        log "Starting Docker cleanup operations"

        # Remove stopped containers
        log "Removing stopped containers"
        if ! docker container prune -f; then
            log "Warning: Failed to remove stopped containers" "WARN"
        fi

        # Remove unused images (with option for all unused vs just dangling)
        if [ "$DOCKER_PRUNE_ALL_IMAGES" = true ]; then
            log "Removing ALL unused Docker images (including tagged images)"
            if ! docker image prune -af; then
                log "Warning: Failed to remove unused images" "WARN"
            fi
        else
            log "Removing dangling Docker images only"
            if ! docker image prune -f; then
                log "Warning: Failed to remove dangling images" "WARN"
            fi
        fi

        # Remove unused volumes if configured
        if [ "$DOCKER_PRUNE_VOLUMES" = true ]; then
            log "Removing unused Docker volumes"
            if ! docker volume prune -f; then
                log "Warning: Failed to remove unused volumes" "WARN"
            fi
        fi

        # Remove unused networks
        log "Removing unused Docker networks"
        if ! docker network prune -f; then
            log "Warning: Failed to remove unused networks" "WARN"
        fi

        # System prune (more aggressive cleanup, optional)
        if [ "$DOCKER_SYSTEM_PRUNE" = true ]; then
            if [ "$DOCKER_PRUNE_ALL_IMAGES" = true ] && [ "$DOCKER_PRUNE_VOLUMES" = true ]; then
                log "Performing system-wide Docker cleanup (including ALL images and volumes)"
                if ! docker system prune -af --volumes; then
                    log "Warning: Failed to perform system prune with all images and volumes" "WARN"
                fi
            elif [ "$DOCKER_PRUNE_ALL_IMAGES" = true ]; then
                log "Performing system-wide Docker cleanup (including ALL images)"
                if ! docker system prune -af; then
                    log "Warning: Failed to perform system prune with all images" "WARN"
                fi
            elif [ "$DOCKER_PRUNE_VOLUMES" = true ]; then
                log "Performing system-wide Docker cleanup (with volumes)"
                if ! docker system prune -f --volumes; then
                    log "Warning: Failed to perform system prune with volumes" "WARN"
                fi
            else
                log "Performing basic system-wide Docker cleanup (dangling only)"
                if ! docker system prune -f; then
                    log "Warning: Failed to perform basic system prune" "WARN"
                fi
            fi
        fi

        log "Docker cleanup completed"
    else
        log "Docker cleanup is disabled in configuration"
    fi

    # Enforce retention policy
    log "Enforcing retention policy"
    if ! borg prune --stats \
        --keep-daily="$KEEP_DAILY" \
        --keep-weekly="$KEEP_WEEKLY" \
        --keep-monthly="$KEEP_MONTHLY" \
        --keep-yearly="$KEEP_YEARLY" \
        "$BACKUP_DIR"; then
        handle_error "Retention policy enforcement failed"
    fi

    # Compact repository
    log "Compacting repository to reclaim space"
    if ! borg compact "$BACKUP_DIR"; then
        handle_error "Repository compaction failed"
    fi

    log "Cleanup completed successfully"
}

# Function to download backup from Filen
download_backup() {
    log "Starting download of backup repository from Filen"

    # Create lock to prevent multiple executions
    if ! create_lock; then
        pid=$(cat "/tmp/docker-backup.lock/pid" 2>/dev/null || echo "unknown")
        handle_error "Another instance of this script is already running (PID: $pid)"
    fi

    # Check if Filen is available
    if ! command -v filen &>/dev/null; then
        handle_error "Filen client not installed. Please install it to download backups."
    fi

    # Create a temporary directory for the download
    local temp_download_dir
    temp_download_dir=$(mktemp -d)
    if [ ! -d "$temp_download_dir" ]; then
        handle_error "Unable to create temporary download directory"
    fi

    # Temporary file for email report
    EMAIL_TEMP_FILE=$(mktemp)
    BACKUP_SUCCESS=true
    BACKUP_START_TIME=$(date +%s)

    # Verify remote location exists
    log "Verifying remote backup location exists"
    if ! filen ls "$REMOTE_DEST" &>/dev/null; then
        handle_error "Remote backup location not found in Filen storage"
    fi

    # Check if local backup directory exists
    if [ -d "$BACKUP_DIR" ]; then
        log "Backup directory already exists locally, creating backup of it"
        local date_suffix
        date_suffix=$(date +%Y%m%d%H%M%S)
        local backup_dir_backup="$BACKUP_DIR.bak.$date_suffix"

        if ! mv "$BACKUP_DIR" "$backup_dir_backup"; then
            handle_error "Unable to backup existing backup directory"
        fi
        log "Existing backup directory moved to $backup_dir_backup"
    fi

    # Create new backup directory
    if ! mkdir -p "$BACKUP_DIR"; then
        handle_error "Unable to create local backup directory"
    fi

    # Download the backup repository
    log "Downloading backup repository from remote storage"
    if ! filen download "$REMOTE_DEST" "$temp_download_dir"; then
        # Attempt to restore previous backup directory if download fails
        if [ -d "$backup_dir_backup" ]; then
            log "Restoring previous backup directory" "WARN"
            rm -rf "$BACKUP_DIR"
            mv "$backup_dir_backup" "$BACKUP_DIR"
        fi
        handle_error "Failed to download repository from remote storage"
    fi

    # Move downloaded files to backup directory
    log "Moving downloaded files to backup directory"
    if ! cp -a "$temp_download_dir"/* "$BACKUP_DIR"/; then
        handle_error "Failed to move downloaded files to backup directory"
    fi

    # Clean up temporary directory
    rm -rf "$temp_download_dir"

    # Verify the Borg repository
    log "Verifying downloaded Borg repository"
    if ! borg check "$BACKUP_DIR"; then
        log "Warning: Downloaded repository verification failed" "WARN"
        log "The repository may be incomplete or corrupted" "WARN"
    else
        log "Repository verification successful"
    fi

    log "Download completed successfully"
    log "Backup repository is now available in $BACKUP_DIR"

    # List available backups in the downloaded repository
    log "Available backups in the downloaded repository:"
    borg list "$BACKUP_DIR"

    finish 0
}

# Trap signals for clean exit - setting this early
trap 'handle_error "Script interrupted by signal"' INT TERM

# Parameter analysis
CONFIG_FILE=""
SHOW_CONFIG=false
OPERATION="backup"
ARCHIVE=""

# If no parameters, show help and exit
if [ $# -eq 0 ]; then
    print_usage
    exit 1
fi

# Parameter parsing
while [[ $# -gt 0 ]]; do
    case $1 in
    -c | --config)
        CONFIG_FILE="$2"
        shift 2
        ;;
    --show-config)
        SHOW_CONFIG=true
        shift
        ;;
    --create-config)
        if [ -z "$2" ]; then
            echo "ERROR: Destination path not specified for --create-config"
            exit 1
        fi
        create_sample_config "$2"
        exit 0
        shift 2
        ;;
    --backup)
        OPERATION="backup"
        shift
        ;;
    --restore)
        OPERATION="restore"
        ARCHIVE="$2"
        shift 2
        ;;
    --list)
        OPERATION="list"
        shift
        ;;
    --cleanup)
        OPERATION="cleanup"
        shift
        ;;
    --download)
        OPERATION="download"
        shift
        ;;
    -h | --help)
        print_usage
        exit 0
        ;;
    *)
        echo "Unknown parameter: $1"
        print_usage
        exit 1
        ;;
    esac
done

# Verify that the configuration file was specified
if [ -z "$CONFIG_FILE" ]; then
    echo "ERROR: Configuration file not specified."
    print_usage
    exit 1
fi

# Verify the configuration file
verify_config "$CONFIG_FILE"

# Load configuration file
source "$CONFIG_FILE"

# Show configuration if requested
if [ "$SHOW_CONFIG" = true ]; then
    print_config
    exit 0
fi

# Verify that essential variables are set in the config
if [ -z "$DOCKER_DIR" ] || [ -z "$BACKUP_DIR" ]; then
    echo "ERROR: Incomplete configuration, missing essential parameters."
    echo "Verify that DOCKER_DIR and BACKUP_DIR are set in the file $CONFIG_FILE"
    exit 1
fi

# Check if script is run as root
if [ "$(id -u)" -ne 0 ]; then
    handle_error "This script must be run as root"
fi

# Check required tools
for cmd in borg; do
    if ! command -v "$cmd" &>/dev/null; then
        handle_error "$cmd not found. Please install it."
    fi
done

# Check filen only if sync is enabled
if [ "$SYNC_ENABLED" = true ] && ! command -v filen &>/dev/null; then
    handle_error "filen not found but required for sync. Please install it or disable sync."
fi

# Check msmtp if email is enabled
if [ "$EMAIL_ENABLED" = true ] && ! command -v msmtp &>/dev/null; then
    handle_error "msmtp not found but required for email notifications. Please install it."
fi

# Check if backup directory exists
if [ ! -d "$BACKUP_DIR" ]; then
    log "Backup directory not found. Creating $BACKUP_DIR"
    if ! mkdir -p "$BACKUP_DIR"; then
        handle_error "Unable to create backup directory"
    fi
fi

# Execute the requested operation
case "$OPERATION" in
backup)
    perform_backup
    ;;
restore)
    restore_backup "$ARCHIVE"
    ;;
list)
    list_backups
    ;;
cleanup)
    cleanup
    ;;
download)
    download_backup
    ;;
*)
    handle_error "Unknown operation: $OPERATION"
    ;;
esac

# End
finish 0
