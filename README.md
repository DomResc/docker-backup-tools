# Docker Volume Tools

A set of bash utilities for backing up and restoring Docker volumes reliably and efficiently.

## Features

- **Easy Backup**: Automatically backup all Docker volumes or specify just the ones you need
- **Intelligent Container Handling**: Automatically stops and restarts containers when necessary
- **Efficient Compression**: Uses parallel compression (pigz) for better performance
- **Backup Integrity Verification**: Verifies backup integrity to ensure successful restoration
- **Retention Policy**: Automatically removes backups older than a specified number of days
- **Full CLI Support**: Comprehensive command-line options and environment variable integration
- **Interactive Restoration**: User-friendly interactive mode for selecting backups to restore

## Installation

```bash
# Clone the repository
git clone https://github.com/yourusername/docker-volume-tools.git
cd docker-volume-tools

# Make scripts executable
chmod +x docker_backup.sh docker_restore.sh
```

## Backup Usage

```bash
./docker_backup.sh [OPTIONS]
```

### Backup Options

| Option | Environment Variable | Description |
|--------|----------------------|-------------|
| `-d, --directory DIR` | `DOCKER_BACKUP_DIR` | Backup directory (default: `/backup/docker`) |
| `-c, --compression LVL` | `DOCKER_COMPRESSION` | Compression level 1-9 (default: 1) |
| `-r, --retention DAYS` | `DOCKER_RETENTION_DAYS` | Days to keep backups (default: 30, 0 to disable) |
| `-v, --volumes VOL1,...` | - | Only backup specific volumes (comma-separated) |
| `-s, --skip-used` | - | Skip volumes used by running containers |
| `-f, --force` | - | Don't ask for confirmation before stopping containers |
| `-h, --help` | - | Display help message |

### Backup Examples

```bash
# Basic backup with default settings
./docker_backup.sh

# Specify backup directory and higher compression
./docker_backup.sh -d /mnt/backups/docker -c 5

# Backup specific volumes only
./docker_backup.sh -v postgres_data,mongodb_data

# Keep backups for 60 days and use environment variable for directory
export DOCKER_BACKUP_DIR=/mnt/storage/backups
./docker_backup.sh -r 60
```

## Restore Usage

```bash
./docker_restore.sh [OPTIONS] [VOLUME_NAME]
```

### Restore Options

| Option | Environment Variable | Description |
|--------|----------------------|-------------|
| `-d, --directory DIR` | `DOCKER_BACKUP_DIR` | Backup directory (default: `/backup/docker`) |
| `-b, --backup DATE` | - | Specific backup date to restore (format: YYYY-MM-DD) |
| `-f, --force` | - | Don't ask for confirmation before stopping containers |
| `-h, --help` | - | Display help message |

### Restore Examples

```bash
# Interactive restore (will show menus to select date and volume)
./docker_restore.sh

# Restore specific volume with interactive date selection
./docker_restore.sh postgres_data

# Restore specific volume from a specific backup date
./docker_restore.sh -b 2025-02-15 mongodb_data

# Force restore without confirmation prompts
./docker_restore.sh -f -b 2025-02-15 postgres_data
```

## Prerequisites

- Docker installed and running
- User with access to Docker (in the docker group or running as root)
- Sufficient disk space for backups
- Basic bash utilities (find, sed, etc.)

## How It Works

### Backup Process

1. Identifies volumes to back up (all or specified)
2. For each volume:
   - Identifies containers using the volume
   - Stops containers if necessary
   - Creates compressed archive of volume data
   - Verifies backup integrity
   - Restarts any stopped containers
3. Provides a summary of successful and failed backups
4. Cleans up old backups according to retention policy

### Restore Process

1. Shows list of available backup dates (or uses specified date)
2. Shows list of volumes available in the selected backup
3. Verifies backup integrity before restoration
4. Handles stopping and restarting affected containers
5. Performs data restoration with detailed progress indication
6. Verifies restored data

## Best Practices

- Set up regular cron jobs for automated backups
- Store backups on a separate disk/server for safety
- Regularly test the restore process on non-production volumes
- Set an appropriate retention policy to manage disk space

## Troubleshooting

**Error: Current user cannot execute Docker commands**
- Ensure your user is in the docker group: `sudo usermod -aG docker $USER`
- Log out and back in for the group change to take effect

**Error: Unable to create directory**
- Check permissions on the parent directory
- Run manually with `sudo mkdir -p /backup/docker && sudo chown $USER:$USER /backup/docker`

**Error: Integrity verification failed**
- The backup file may be corrupted
- Try an earlier backup if available
- Check disk space and permissions

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the license text at the top of each script file for details.