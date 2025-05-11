#!/bin/bash

# Configuration (modify these values as needed)
DOCKER_DIR="/var/lib/docker"
BACKUP_DIR="/backup/docker"
REMOTE_DEST="/backup/docker"
LOG_FILE="/var/log/docker-backup.log"
COMPRESSION="lz4"

# Retention configuration
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

# Temporary file for email report
EMAIL_TEMP_FILE=$(mktemp)
BACKUP_SUCCESS=true
BACKUP_START_TIME=$(date +%s)

# Log function
log() {
    local level="INFO"
    if [ "$2" ]; then
        level="$2"
    fi

    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $1"

    # Log to file
    echo "$msg" >>"$LOG_FILE"

    # Log to email temp file
    echo "$msg" >>"$EMAIL_TEMP_FILE"

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

        # MSMTP configuration
        local msmtp_args=()
        if [ -n "$EMAIL_SMTP_USER" ]; then
            msmtp_args+=(--user="$EMAIL_SMTP_USER")
        fi
        if [ -n "$EMAIL_SMTP_PASSWORD" ]; then
            msmtp_args+=(--passwordeval="echo $EMAIL_SMTP_PASSWORD")
        fi
        if [ "$EMAIL_SMTP_TLS" = true ]; then
            msmtp_args+=(--tls=on --tls-starttls=on)
        else
            msmtp_args+=(--tls=off)
        fi

        # Send email with msmtp
        if cat "$email_body_file" | msmtp "${msmtp_args[@]}" --host="$EMAIL_SMTP_SERVER" --port="$EMAIL_SMTP_PORT" --from="$EMAIL_FROM" "$EMAIL_TO"; then
            log "Notification email sent to $EMAIL_TO"
        else
            log "Email sending failed" "ERROR"
        fi

        # Remove temporary file
        rm -f "$email_body_file"
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

    # Remove temporary file
    rm -f "$EMAIL_TEMP_FILE"

    # Exit with appropriate code
    exit "$exit_code"
}

# Error handling
handle_error() {
    log "$1" "ERROR"
    BACKUP_SUCCESS=false
    finish 1
}

# Create lock file to prevent multiple executions
LOCK_FILE="/tmp/docker-backup.lock"
if [ -e "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE")
    if ps -p "$pid" >/dev/null; then
        handle_error "Another instance of this script is already running (PID: $pid)"
    else
        log "Obsolete lock file detected, removing"
        rm -f "$LOCK_FILE"
    fi
fi
echo $$ >"$LOCK_FILE"

log "Starting Docker backup script"
log "Configuration: DOCKER_DIR=$DOCKER_DIR, BACKUP_DIR=$BACKUP_DIR"
log "Retention: daily=$KEEP_DAILY, weekly=$KEEP_WEEKLY, monthly=$KEEP_MONTHLY, yearly=$KEEP_YEARLY"

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

# Stop Docker services
log "Stopping Docker services"
if ! systemctl stop docker.socket; then
    handle_error "Unable to stop docker.socket"
fi

if ! systemctl stop docker.service; then
    log "Unable to stop docker.service" "ERROR"
    systemctl start docker.socket
    handle_error "Unable to stop docker.service"
fi

# Backup name with timestamp
BACKUP_NAME="docker-$(date +%Y-%m-%d_%H:%M:%S)"
show_progress 10

# Create backup
log "Creating backup: $BACKUP_NAME"
if ! borg create --stats $BORG_OPTS --compression "$COMPRESSION" "$BACKUP_DIR"::"$BACKUP_NAME" "$DOCKER_DIR"; then
    log "Backup creation failed" "ERROR"
    systemctl start docker.service
    systemctl start docker.socket
    handle_error "Backup creation failed"
fi
show_progress 40

# Restart Docker services
log "Restarting Docker services"
if ! systemctl start docker.service; then
    handle_error "Unable to restart docker.service"
fi

if ! systemctl start docker.socket; then
    handle_error "Unable to restart docker.socket"
fi
show_progress 50

# Verify backup integrity
log "Verifying backup integrity"
if ! borg check $BORG_OPTS "$BACKUP_DIR"; then
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

# Remove lock file
rm -f "$LOCK_FILE"

# End
finish 0
