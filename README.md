# Docker Volume Tools

A set of bash utilities for backing up, restoring, and cleaning Docker volumes reliably and efficiently.

## Features

- **Easy Backup**: Automatically backup all Docker volumes or specify just the ones you need
- **Intelligent Container Handling**: Automatically stops and restarts containers when necessary
- **Efficient Compression**: Uses parallel compression (pigz) for better performance
- **Backup Integrity Verification**: Verifies backup integrity to ensure successful restoration
- **Retention Policy**: Automatically removes backups older than a specified number of days
- **Full CLI Support**: Comprehensive command-line options and environment variable integration
- **Interactive Restoration**: User-friendly interactive mode for selecting backups to restore
- **Disk Space Verification**: Automatically checks if there's enough free space for backups/restores
- **Two-Stage Restoration**: Performs a test restoration to a temporary volume for safety
- **Cleanup on Exit**: Ensures containers are restarted even if the scripts exit unexpectedly
- **Resource Cleanup**: Comprehensive tool for cleaning unused Docker resources

## Installation

```bash
# Clone the repository
git clone https://github.com/domresc/docker-volume-tools.git
cd docker-volume-tools

# Make scripts executable
chmod +x docker_backup.sh docker_restore.sh docker_cleanup.sh
```

## Backup Usage

```bash
./docker_backup.sh [OPTIONS]
```

### Backup Options

| Option                   | Environment Variable    | Description                                           |
| ------------------------ | ----------------------- | ----------------------------------------------------- |
| `-d, --directory DIR`    | `DOCKER_BACKUP_DIR`     | Backup directory (default: `/backup/docker`)          |
| `-c, --compression LVL`  | `DOCKER_COMPRESSION`    | Compression level 1-9 (default: 1)                    |
| `-r, --retention DAYS`   | `DOCKER_RETENTION_DAYS` | Days to keep backups (default: 30, 0 to disable)      |
| `-v, --volumes VOL1,...` | -                       | Only backup specific volumes (comma-separated)        |
| `-s, --skip-used`        | -                       | Skip volumes used by running containers               |
| `-f, --force`            | -                       | Don't ask for confirmation before stopping containers |
| `-h, --help`             | -                       | Display help message                                  |

### Backup Examples

```bash
# Basic backup with default settings
./docker_backup.sh

# Specify backup directory and higher compression
./docker_backup.sh -d /mnt/backups/docker -c 5

# Backup specific volumes only
./docker_backup.sh -v postgres_data,mongodb_data

# Skip volumes that are currently in use by containers
./docker_backup.sh -s

# Keep backups for 60 days and use environment variable for directory
export DOCKER_BACKUP_DIR=/mnt/storage/backups
./docker_backup.sh -r 60

# Backup with forced container stopping (no confirmation prompts)
./docker_backup.sh -f
```

## Restore Usage

```bash
./docker_restore.sh [OPTIONS] [VOLUME_NAME]
```

### Restore Options

| Option                | Environment Variable | Description                                           |
| --------------------- | -------------------- | ----------------------------------------------------- |
| `-d, --directory DIR` | `DOCKER_BACKUP_DIR`  | Backup directory (default: `/backup/docker`)          |
| `-b, --backup DATE`   | -                    | Specific backup date to restore (format: YYYY-MM-DD)  |
| `-f, --force`         | -                    | Don't ask for confirmation before stopping containers |
| `-h, --help`          | -                    | Display help message                                  |

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

## Cleanup Usage

```bash
./docker_cleanup.sh [OPTIONS]
```

### Cleanup Options

| Option              | Description                                                                    |
| ------------------- | ------------------------------------------------------------------------------ |
| `-v, --volumes`     | Clean unused volumes                                                           |
| `-i, --images`      | Clean dangling images                                                          |
| `-c, --containers`  | Remove stopped containers                                                      |
| `-n, --networks`    | Remove unused networks                                                         |
| `-b, --builder`     | Clean up builder cache                                                         |
| `-t, --temp`        | Clean temporary restore volumes                                                |
| `-a, --all`         | Clean all of the above                                                         |
| `-x, --prune-all`   | Run Docker system prune with all options (CAUTION: removes ALL unused objects) |
| `-d, --dry-run`     | Show what would be removed without actually removing                           |
| `-f, --force`       | Don't ask for confirmation                                                     |
| `-l, --log-dir DIR` | Custom log directory (default: `/var/log/docker-tools`)                        |
| `-h, --help`        | Display help message                                                           |

### Cleanup Examples

```bash
# Clean only unused volumes
./docker_cleanup.sh -v

# Clean dangling images and stopped containers
./docker_cleanup.sh -i -c

# Clean everything except with dry-run (no actual deletions)
./docker_cleanup.sh -a -d

# Clean temporary volumes created during restore operations
./docker_cleanup.sh -t

# Force cleanup of all resources without confirmation
./docker_cleanup.sh -a -f

# Run a complete system prune (caution: removes ALL unused objects)
./docker_cleanup.sh -x
```

## Prerequisites

- Docker installed and running
- User with access to Docker (in the docker group or running as root)
- Sufficient disk space for backups (at least 500MB free plus estimated backup size)
- Basic bash utilities (find, sed, etc.)
- The script will automatically verify these prerequisites before running

## How It Works

### Backup Process

1. Verifies prerequisites (Docker access, permissions, disk space)
2. Identifies volumes to back up (all or specified with the `-v` option)
3. Estimates disk space requirements and verifies sufficient free space
4. Maps containers to volumes for efficient stopping/starting
5. For each volume:
   - Identifies containers using the volume
   - Skips the volume if the `-s/--skip-used` option is enabled and the volume is in use
   - Asks for confirmation before stopping containers (unless `-f/--force` is used)
   - Stops containers if necessary
   - Creates compressed archive of volume data with specified compression level
   - Verifies backup integrity and content
   - Records backup statistics (size, duration, etc.)
6. Restarts any stopped containers (even if errors occurred)
7. Provides a summary of successful and failed backups
8. Cleans up old backups according to retention policy

### Restore Process

1. Verifies prerequisites (Docker access, permissions, disk space)
2. Shows list of available backup dates (or uses specified date with `-b` option)
3. Shows list of volumes available in the selected backup
4. Verifies backup integrity and content before restoration
5. Creates a temporary volume to test the backup restoration first
6. Identifies and stops only running containers that use the volume
7. Clears the target volume to ensure clean state
8. Performs data restoration with detailed progress indication
9. Verifies restored data with file count checks
10. Restarts containers that were previously running
11. Removes the temporary test volume if successful

### Cleanup Process

1. Verifies Docker access permissions
2. Based on specified options, performs targeted cleanup:
   - For unused volumes: Identifies and removes volumes not attached to any containers
   - For temporary volumes: Removes restore-temporary volumes (starting with "temp*restore*")
   - For dangling images: Removes images without tags that are not being used
   - For stopped containers: Removes containers in "exited" state
   - For unused networks: Removes custom networks not used by any containers
   - For builder cache: Cleans up Docker's build cache
3. Provides detailed outputs and logs of all operations
4. Can perform a "dry run" to show what would be removed without making changes
5. Can run a complete system prune for thorough cleanup

## Best Practices

- Set up regular cron jobs for automated backups
- Store backups on a separate disk/server for safety
- Regularly test the restore process on non-production volumes
- Set an appropriate retention policy to manage disk space
- Use the `-s/--skip-used` flag for backup during high traffic times
- Consider using higher compression levels for long-term archival
- Ensure sufficient free disk space (at least twice the size of your volumes)
- Monitor backup logs for warnings or errors
- Test restoration occasionally to verify backup integrity
- Run cleanup regularly with dry-run first to understand what will be removed
- Use specific cleanup options instead of `--prune-all` in production environments

## Security Considerations

- The scripts need to be run by a user with Docker permissions
- Backup files contain all volume data and should be stored securely
- Consider encrypting backups for sensitive data
- The scripts automatically restart containers after backups/restores, which might trigger automated processes

## Troubleshooting

**Error: Current user cannot execute Docker commands**

- Ensure your user is in the docker group: `sudo usermod -aG docker $USER`
- Log out and back in for the group change to take effect

**Error: Insufficient disk space for backup/restore**

- Free up disk space on your backup destination
- Use a different backup location with more free space
- For backups, consider using higher compression levels
- Run the cleanup script to free up Docker resources: `./docker_cleanup.sh -a`

**Error: Unable to create directory**

- Check permissions on the parent directory
- Run manually with `sudo mkdir -p /backup/docker && sudo chown $USER:$USER /backup/docker`

**Error: Integrity verification failed**

- The backup file may be corrupted
- Try an earlier backup if available
- Check disk space and permissions

**Error: Unable to restart container**

- The container might need manual intervention
- Try restarting it with `docker start <container_name>`
- Check logs with `docker logs <container_name>`

**Error: Temporary volume creation failed**

- Check Docker volume driver status
- Ensure Docker has sufficient resources

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the license text at the top of each script file for details.
