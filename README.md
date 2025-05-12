# Docker Backup Script

A robust Bash script for backing up Docker data directories using Borg backup with advanced retention management, optional remote synchronization, and email notifications.

## Features

- **Complete Docker Backup**: Safely stops Docker services, creates a full backup, and restarts services
- **Borg Backup Integration**: Uses Borg's powerful deduplication and compression
- **Smart Retention Policy**: Configurable retention for daily, weekly, monthly, and yearly backups
- **Remote Synchronization**: Optional synchronization to remote storage using Filen
- **Download Capability**: Download repository directly from Filen remote storage
- **Docker Cleanup**: Configurable pruning of Docker resources (containers, images, networks, volumes)
- **Email Notifications**: Configurable email alerts for success and/or failure
- **Progress Monitoring**: Interactive progress bar when running manually
- **Error Handling**: Comprehensive error handling with automatic service recovery
- **Resource Verification**: Checks for sufficient disk space before starting
- **Directory-Based Lock Mechanism**: Prevents concurrent execution of multiple backup instances with improved atomicity
- **Required Configuration File**: Ensures explicit configuration for safer operation

## Requirements

- Linux system with Bash
- Root privileges
- Docker installed and running
- Borg backup utility (`apt install borgbackup` on Debian/Ubuntu)
- Filen client (for remote synchronization, optional)
- msmtp (for email notifications, optional)

## Configuration

The script requires a configuration file to run. You can create a sample configuration file with:

```bash
sudo ./docker-backup.sh --create-config /etc/docker-backup/config.conf
```

Then edit this file to customize the settings:

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

### Docker Cleanup Configuration

```bash
DOCKER_CLEANUP_ENABLED=false     # Enable Docker cleanup during cleanup operation
DOCKER_PRUNE_ALL_IMAGES=false    # When true, removes all unused images (not just dangling)
DOCKER_SYSTEM_PRUNE=false        # Enable more aggressive system-wide cleanup
DOCKER_PRUNE_VOLUMES=false       # Enable removal of unused volumes (use with caution)
```

### Mode Configuration

```bash
INTERACTIVE=true      # Interactive mode with detailed output
SHOW_PROGRESS=true    # Show progress bar
SYNC_ENABLED=true     # Enable remote synchronization
```

### Restore Configuration

```bash
RESTORE_TEMP_DIR="/tmp/docker-restore"  # Temporary directory for restore operations
```

## Usage

The script must be run with a configuration file:

```bash
sudo ./docker-backup.sh -c /path/to/config.conf
```

### Available Options

```
OPTIONS:
  -c, --config FILE      Specify the configuration file (REQUIRED)
  --create-config FILE   Create a sample configuration file
  --show-config          Show active configuration and exit
  --backup               Perform a backup (default action when no other action specified)
  --restore ARCHIVE      Restore a specific backup archive
  --list                 List available backup archives
  --cleanup              Remove temporary files and enforce retention policy
  --download             Download backup repository from Filen remote storage
  -h, --help             Show this help message
```

### Examples

Create a configuration file:

```bash
sudo ./docker-backup.sh --create-config /etc/docker-backup/config.conf
```

View current configuration:

```bash
sudo ./docker-backup.sh -c /etc/docker-backup/config.conf --show-config
```

Run a backup:

```bash
sudo ./docker-backup.sh -c /etc/docker-backup/config.conf
```

List available backups:

```bash
sudo ./docker-backup.sh -c /etc/docker-backup/config.conf --list
```

Restore a specific backup:

```bash
sudo ./docker-backup.sh -c /etc/docker-backup/config.conf --restore docker-2023-05-15_02:00:00
```

Run Docker cleanup with backup maintenance:

```bash
sudo ./docker-backup.sh -c /etc/docker-backup/config.conf --cleanup
```

Download backup repository from remote storage:

```bash
sudo ./docker-backup.sh -c /etc/docker-backup/config.conf --download
```

## Docker Cleanup

The Docker cleanup functionality allows you to clean unused resources during the cleanup operation:

1. Set `DOCKER_CLEANUP_ENABLED=true` to activate Docker cleanup
2. Configure the level of cleanup:
   - Basic cleanup (default): Removes stopped containers and dangling images/networks
   - Full image cleanup (`DOCKER_PRUNE_ALL_IMAGES=true`): Removes all unused images, including tagged ones
   - Volume cleanup (`DOCKER_PRUNE_VOLUMES=true`): Removes unused volumes (use with caution!)
   - System cleanup (`DOCKER_SYSTEM_PRUNE=true`): Performs a system-wide cleanup

These settings can be combined for customized cleanup behavior.

## Scheduling with Cron

For automated execution, add an entry to the root crontab:

```bash
sudo crontab -e
```

Then add a line like:

```
# Run Docker backup every day at 2 AM
0 2 * * * /path/to/docker-backup.sh -c /etc/docker-backup/config.conf
```

When running via cron, you might want to set `INTERACTIVE=false` and `SHOW_PROGRESS=false` in the configuration file.

## Troubleshooting

Check the log file (default: `/var/log/docker-backup.log`) for detailed information about the backup process and any errors.

Common issues:

- **Configuration file not found**: Make sure the path to the configuration file is correct
- **Insufficient disk space**: Ensure the backup destination has enough free space
- **Tool not found**: Install missing tools (borg, filen, msmtp)
- **Docker not stopping**: Check Docker service status and dependencies
- **Lock file exists**: If the script was interrupted abnormally, you might need to manually remove the lock directory at `/tmp/docker-backup.lock`
- **Email notifications not working**: Verify SMTP settings and connectivity
- **Docker cleanup failures**: Ensure Docker is running during cleanup operations; check for active containers using volumes if volume cleanup fails

## Security Notes

- The script requires root privileges to stop and start Docker services
- The configuration file permissions are set to 600 (readable only by owner) by default
- SMTP passwords in the configuration file could be a security risk; consider using environment variables or secure credential storage
- Temporary files containing sensitive information (like SMTP passwords) are created with strict permissions (600)
- Ensure your backup directory has appropriate permissions
- The lock mechanism uses a directory-based approach for improved atomicity
- Docker cleanup operations may affect running services; use the volume cleanup option (`DOCKER_PRUNE_VOLUMES=true`) with extreme caution in production environments
