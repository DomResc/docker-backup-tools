# Docker Backup Script

A robust Bash script for backing up Docker data directories using Borg backup with advanced retention management, optional remote synchronization, and email notifications.

## Features

- **Complete Docker Backup**: Safely stops Docker services, creates a full backup, and restarts services
- **Borg Backup Integration**: Uses Borg's powerful deduplication and compression
- **Smart Retention Policy**: Configurable retention for daily, weekly, monthly, and yearly backups
- **Remote Synchronization**: Optional synchronization to remote storage using Filen
- **Email Notifications**: Configurable email alerts for success and/or failure
- **Progress Monitoring**: Interactive progress bar when running manually
- **Error Handling**: Comprehensive error handling with automatic service recovery
- **Resource Verification**: Checks for sufficient disk space before starting
- **Lock Mechanism**: Prevents concurrent execution of multiple backup instances

## Requirements

- Linux system with Bash
- Root privileges
- Docker installed and running
- Borg backup utility (`apt install borgbackup` on Debian/Ubuntu)
- Filen client (for remote synchronization, optional)
- msmtp (for email notifications, optional)

## Configuration

Edit the script and modify the following variables at the beginning:

### Basic Configuration

```bash
DOCKER_DIR="/var/lib/docker"        # Docker data directory to backup
BACKUP_DIR="/backup/docker"         # Where to store the Borg repository
REMOTE_DEST="/backup/docker"        # Remote destination for sync
LOG_FILE="/var/log/docker-backup.log"   # Log file location
COMPRESSION="lz4"                   # Compression algorithm (lz4, zlib, zstd, etc.)
```

### Retention Configuration

```bash
KEEP_DAILY=7      # Number of daily backups to keep
KEEP_WEEKLY=4     # Number of weekly backups to keep
KEEP_MONTHLY=12   # Number of monthly backups to keep
KEEP_YEARLY=0     # Number of yearly backups to keep
```

### Email Configuration

```bash
EMAIL_ENABLED=false                        # Set to true to enable email notifications
EMAIL_TO="admin@example.com"               # Email recipient
EMAIL_FROM="docker-backup@$(hostname -f)"  # Email sender
EMAIL_SUBJECT="Docker Backup Report: $(hostname -s)"  # Email subject
EMAIL_NOTIFY_SUCCESS=false                 # Send email on success
EMAIL_NOTIFY_ERROR=true                    # Send email on error
EMAIL_SMTP_SERVER="smtp.gmail.com"         # SMTP server
EMAIL_SMTP_PORT="587"                      # SMTP port
EMAIL_SMTP_USER=""                         # SMTP username
EMAIL_SMTP_PASSWORD=""                     # SMTP password
EMAIL_SMTP_TLS=true                        # Use TLS for SMTP
```

### Mode Configuration

```bash
INTERACTIVE=true      # Interactive mode with detailed output
SHOW_PROGRESS=true    # Show progress bar
SYNC_ENABLED=true     # Enable remote synchronization
```

## Usage

Run the script as root:

```bash
sudo ./docker-backup.sh
```

## Scheduling with Cron

For automated execution, add an entry to the root crontab:

```bash
sudo crontab -e
```

Then add a line like:

```
# Run Docker backup every day at 2 AM
0 2 * * * /path/to/docker-backup.sh
```

When running via cron, you might want to set `INTERACTIVE=false` and `SHOW_PROGRESS=false` in the script configuration.

## Troubleshooting

Check the log file (default: `/var/log/docker-backup.log`) for detailed information about the backup process and any errors.

Common issues:

- **Insufficient disk space**: Ensure the backup destination has enough free space
- **Tool not found**: Install missing tools (borg, filen, msmtp)
- **Docker not stopping**: Check Docker service status and dependencies
- **Email notifications not working**: Verify SMTP settings and connectivity

## Security Notes

- The script requires root privileges to stop and start Docker services
- SMTP passwords in the script could be a security risk; consider using environment variables or secure credential storage
- Ensure your backup directory has appropriate permissions
