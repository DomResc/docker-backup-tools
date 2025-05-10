# Docker Volume Tools - Borg Backup Edition

A set of bash utilities for backing up, restoring, and verifying Docker data using Borg Backup.

## Features

- **Full Backup**: Backs up the entire Docker directory, not just volumes
- **Incremental Backup**: Uses Borg Backup for efficient deduplicated storage
- **Simple Restoration**: Restore the entire Docker environment with a single command
- **Intelligent Service Handling**: Automatically stops and restarts Docker when necessary
- **Configurable Compression**: Choose from different compression algorithms
- **Retention Policy**: Automatically removes backups older than a specified number of days
- **Integrity Verification**: Verify backups to ensure data integrity
- **Installation Script**: Easy setup with included installation script
- **Detailed Logging**: Colored output and comprehensive logs of all operations

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

1. Check for and install Borg Backup if necessary
2. Create directories for backups and logs
3. Install the scripts on your system
4. Set up an optional cron job for automated backups

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
2. Stops the Docker service
3. Creates backup of current Docker directory by renaming it
4. Restores the selected archive
5. Sets proper permissions
6. Restarts the Docker service

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

## Troubleshooting

**Error: Unable to stop Docker service**

- Verify you have the necessary privileges
- Check Docker service status with `systemctl status docker`

**Error: Insufficient disk space**

- Free up disk space
- Use a different backup location
- Consider using higher compression options

**Error: Integrity verification failed**

- The backup file may be corrupted
- Try an earlier backup if available

**Error: Borg not installed**

- Run the installation script: `sudo bash docker_install.sh`
- Manually install Borg: `sudo apt-get install borgbackup`

**Problem: Restore failed**

- Check logs for specific details
- Verify backup path is correct
- Ensure you have proper privileges

## License

This project is licensed under the MIT License - see the license text at the top of each script file for details.
