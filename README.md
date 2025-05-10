# Docker Volume Tools - Borg Backup Edition

A set of bash utilities for backing up, restoring, and verifying Docker data using Borg Backup.

## Features

- **Full Backup**: Backs up the entire Docker directory, not just volumes
- **Incremental Backup**: Uses Borg Backup for efficient deduplicated storage
- **Simple Restoration**: Restore the entire Docker environment with a single command
- **Intelligent Service Handling**: Automatically stops and restarts Docker when necessary
- **Wide Compatibility**: Supports various init systems (systemd, sysvinit, upstart) and Linux distributions
- **Configurable Compression**: Choose from different compression algorithms
- **Retention Policy**: Automatically removes backups older than a specified number of days
- **Integrity Verification**: Verify backups to ensure data integrity
- **Installation Script**: Easy setup with included installation script
- **Detailed Logging**: Colored output and comprehensive logs of all operations
- **Space Verification**: Checks available space before backup or restore operations
- **Permission Management**: Proper permission settings after restoration
- **Resource Cleanup**: Tools for cleaning unused Docker resources and obsolete backups

## Differences from Previous Version

This edition uses a different approach compared to the original scripts:

1. **Full backup vs volume backup**: This version backs up the entire `/var/lib/docker/` directory rather than individual volumes
2. **Technology**: Uses Borg Backup for efficient deduplication, compression, and incremental backups
3. **Downtime**: Requires complete Docker shutdown during backup/restore
4. **Speed**: First backup is slower, but subsequent backups are incremental and much faster
5. **Space efficiency**: Thanks to deduplication, requires less disk space for multiple backups

## Installation

```bash
# Clone the repository
git clone https://github.com/domresc/docker-volume-tools.git
cd docker-volume-tools

# Run the installation script (requires root privileges)
sudo bash docker_install.sh
```

The installation script will:

1. Check if Docker is installed on your system
2. Detect the init system in use (systemd, sysvinit, upstart)
3. Check for and install Borg Backup if necessary
4. Create directories for backups and logs
5. Install the scripts on your system
6. Set up an optional cron job for automated backups
7. Offer the option to initialize a Borg repository immediately

## Backup Usage

```bash
docker_backup_full [OPTIONS]
```

### Backup Options

| Option                   | Environment Variable    | Description                                            |
| ------------------------ | ----------------------- | ------------------------------------------------------ |
| `-d, --directory DIR`    | `DOCKER_BACKUP_DIR`     | Backup directory (default: `/backup/docker`)           |
| `-c, --compression TYPE` | `DOCKER_COMPRESSION`    | Compression type: lz4, zstd, zlib, none (default: lz4) |
| `-r, --retention DAYS`   | `DOCKER_RETENTION_DAYS` | Days to keep backups (default: 30, 0 to disable)       |
| `-f, --force`            | -                       | Don't ask for confirmation before stopping Docker      |
| `-s, --skip-check`       | -                       | Skip integrity check after backup                      |
| `-h, --help`             | -                       | Display help message                                   |

### Backup Examples

```bash
# Basic backup with default settings
docker_backup_full

# Specify backup directory and higher compression
docker_backup_full -d /mnt/backups/docker -c zstd

# Backup with forced Docker stopping (no confirmation prompts)
docker_backup_full -f

# Keep backups for 60 days
docker_backup_full -r 60

# Using environment variables
export DOCKER_BACKUP_DIR=/mnt/storage/backups
export DOCKER_COMPRESSION=zlib
docker_backup_full
```

## Restore Usage

```bash
docker_restore_full [OPTIONS] [ARCHIVE]
```

### Restore Options

| Option                | Environment Variable | Description                                       |
| --------------------- | -------------------- | ------------------------------------------------- |
| `-d, --directory DIR` | `DOCKER_BACKUP_DIR`  | Backup directory (default: `/backup/docker`)      |
| `-f, --force`         | -                    | Don't ask for confirmation before stopping Docker |
| `-h, --help`          | -                    | Display help message                              |

### Restore Examples

```bash
# Interactive restore (will show menu to select archive)
docker_restore_full

# Restore specific archive
docker_restore_full docker-2025-05-10_14:30:45

# Force restore without confirmation prompts
docker_restore_full -f docker-2025-05-10_14:30:45
```

## Verify Usage

```bash
docker_verify [OPTIONS] [ARCHIVE]
```

### Verify Options

| Option                | Description                                  |
| --------------------- | -------------------------------------------- |
| `-d, --directory DIR` | Backup directory (default: `/backup/docker`) |
| `-a, --all`           | Verify all archives individually             |
| `-l, --list`          | List available archives                      |
| `-q, --quiet`         | Only output errors                           |
| `-h, --help`          | Display help message                         |

### Verify Examples

```bash
# Verify repository integrity
docker_verify

# List available archives
docker_verify -l

# Verify specific archive
docker_verify docker-2025-05-10_14:30:45

# Verify all archives
docker_verify -a

# Quiet verification (output only on errors)
docker_verify -q -a
```

## Cleanup Usage

```bash
docker_cleanup [OPTIONS]
```

### Cleanup Options

| Option                   | Description                                          |
| ------------------------ | ---------------------------------------------------- |
| `-v, --volumes`          | Clean unused volumes                                 |
| `-i, --images`           | Clean dangling images                                |
| `-c, --containers`       | Remove stopped containers                            |
| `-n, --networks`         | Remove unused networks                               |
| `-b, --builder`          | Clean up builder cache                               |
| `-B, --borg`             | Clean and compact Borg repository                    |
| `-o, --old-backups DAYS` | Remove backups older than DAYS days                  |
| `-a, --all`              | Clean all Docker resources (not Borg)                |
| `-A, --all-borg`         | Clean all Borg backups (DANGER: removes ALL backups) |
| `-x, --prune-all`        | Run Docker system prune with all options             |
| `-d, --dry-run`          | Show what would be removed without actually removing |
| `-f, --force`            | Don't ask for confirmation                           |
| `-l, --backup-dir DIR`   | Custom backup directory (default: `/backup/docker`)  |
| `-h, --help`             | Display help message                                 |

### Cleanup Examples

```bash
# Clean unused volumes and images
docker_cleanup -v -i

# Dry-run mode to see what would be removed
docker_cleanup -a -d

# Remove backups older than 90 days
docker_cleanup -o 90

# Clean all Docker resources
docker_cleanup -a

# Compact the Borg repository
docker_cleanup -B
```

## Prerequisites

- Linux system with Docker installed
- Administrator privileges (to stop/start Docker)
- Borg Backup installed (installation script can install it automatically)
- Sufficient disk space for backups

## How It Works

### Backup Process

1. Verifies prerequisites (Docker access, permissions, disk space)
2. Checks for Borg Backup installation
3. Initializes Borg repository if it doesn't exist
4. Stops the Docker service (with user confirmation)
5. Creates an incremental backup of the `/var/lib/docker/` directory
6. Restarts the Docker service
7. Verifies backup integrity (optional)
8. Cleans up old backups according to retention policy

### Restore Process

1. Shows menu to select archive to restore (if not specified)
2. Checks available space for restoration
3. Stops the Docker service
4. Creates backup of current Docker directory by renaming it
5. Restores the selected archive
6. Sets proper permissions
7. Restarts the Docker service
8. Verifies Docker is working properly after restoration

### Verify Process

1. For repository verification: checks Borg repository integrity
2. For archive verification: checks integrity of a specific archive
3. For full verification: checks all archives and provides a summary

## Benefits of Using Borg Backup

- **Data Deduplication**: More efficient archives that take up less space
- **Incremental Backups**: Subsequent backups are much faster
- **Efficient Compression**: Various compression algorithms available
- **Verifiable Integrity**: Built-in integrity checks
- **Security**: Encryption capability (not enabled in this configuration)

## Security Considerations

- Scripts require elevated privileges to stop/start Docker
- Backup files contain all Docker data and should be stored securely
- The user running backups must have access to the `/var/lib/docker/` directory

## Compatibility

- Supports various init systems: systemd, sysvinit, upstart
- Works on different Linux distributions: Debian, Ubuntu, CentOS, RHEL, Fedora, Alpine
- Requires Bash 4.0 or higher

## Troubleshooting

**Error: Unable to stop Docker service**

- Verify you have the necessary privileges
- Check Docker service status with `systemctl status docker` or `service docker status`
- Try stopping Docker manually before running the scripts

**Error: Insufficient disk space**

- Free up disk space
- Use a different backup location
- Consider using higher compression options

**Error: Integrity verification failed**

- The backup file may be corrupted
- Try an earlier backup if available
- Check disk health with `smart-ctl` or similar tools

**Error: Borg not installed**

- Run the installation script: `sudo docker_install`
- Manually install Borg: `sudo apt-get install borgbackup`

**Problem: Restore failed**

- Check logs for specific details
- Verify backup path is correct
- Ensure you have proper privileges
- Check available space

**Problem: Docker doesn't start after restore**

- Check Docker logs: `journalctl -u docker` or `cat /var/log/docker.log`
- Verify permissions are set correctly
- Try restoring from a different backup

## License

This project is licensed under the MIT License - see the license text at the top of each script file for details.
