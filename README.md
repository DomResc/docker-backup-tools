# Docker Volume Tools

A set of bash utilities for backing up, restoring, and cleaning Docker volumes reliably and efficiently.

## Features

- **Easy Backup**: Automatically backup all Docker volumes or specify just the ones you need
- **Intelligent Container Handling**: Automatically stops and restarts containers when necessary
- **Parallel Processing**: Backup multiple volumes simultaneously for improved performance
- **Priority Backup Ordering**: Specify containers to backup last (useful for critical infrastructure services like DNS)
- **Efficient Compression**: Uses parallel compression (pigz) for better performance
- **Single Container Optimization**: Uses a single Alpine container for all operations, reducing overhead
- **Fast Backup Verification**: Optimized quick verification of backup integrity with minimal overhead
- **Retention Policy**: Automatically removes backups older than a specified number of days
- **Full CLI Support**: Comprehensive command-line options and environment variable integration
- **Interactive Restoration**: User-friendly interactive mode for selecting backups to restore
- **Disk Space Verification**: Automatically checks if there's enough free space for backups/restores
- **Memory Optimization**: Auto-adjusts parallel jobs based on available system memory
- **Two-Stage Restoration**: Performs a test restoration to a temporary volume for safety
- **Cleanup on Exit**: Ensures containers are restarted even if the scripts exit unexpectedly
- **Resource Cleanup**: Comprehensive tool for cleaning unused Docker resources
- **System Information**: Shows Docker resource usage before cleanup operations

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

| Option                            | Environment Variable    | Description                                           |
| --------------------------------- | ----------------------- | ----------------------------------------------------- |
| `-d, --directory DIR`             | `DOCKER_BACKUP_DIR`     | Backup directory (default: `/backup/docker`)          |
| `-c, --compression LVL`           | `DOCKER_COMPRESSION`    | Compression level 1-9 (default: 1)                    |
| `-r, --retention DAYS`            | `DOCKER_RETENTION_DAYS` | Days to keep backups (default: 30, 0 to disable)      |
| `-v, --volumes VOL1,...`          | -                       | Only backup specific volumes (comma-separated)        |
| `-s, --skip-used`                 | -                       | Skip volumes used by running containers               |
| `-f, --force`                     | -                       | Don't ask for confirmation before stopping containers |
| `-p, --prioritize-last NAME1,...` | `DOCKER_LAST_PRIORITY`  | Container names to backup last (comma-separated)      |
| `-j, --jobs NUM`                  | `DOCKER_PARALLEL_JOBS`  | Number of parallel backup jobs (default: 2)           |
| `-h, --help`                      | -                       | Display help message                                  |

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

# Process critical infrastructure containers (like DNS servers) last
./docker_backup.sh --prioritize-last pihole

# Use 4 parallel jobs for faster backup
./docker_backup.sh --jobs 4

# Process multiple critical containers last with parallel processing
./docker_backup.sh --prioritize-last "pihole,dns-server,network-gateway" --jobs 3

# Set parallel jobs via environment variable
export DOCKER_PARALLEL_JOBS="4"
./docker_backup.sh
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
| `-l, --log-dir DIR` | Custom log directory (default: `/backup/docker`)                               |
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
- Sufficient memory for parallel operations (auto-adjusts based on available memory)
- Basic bash utilities (find, sed, etc.)
- The script will automatically verify these prerequisites before running

## How It Works

### Backup Process

1. Verifies prerequisites (Docker access, permissions, disk space, memory)
2. Identifies volumes to back up (all or specified with the `-v` option)
3. Estimates disk space requirements and verifies sufficient free space
4. Maps containers to volumes for efficient stopping/starting
5. Identifies containers that should be processed last (via `--prioritize-last` option)
6. Creates a single Alpine container with pigz installed for all compression operations
7. Processes regular volumes first (in parallel batches):
   - Identifies containers using the volume
   - Skips the volume if the `-s/--skip-used` option is enabled and the volume is in use
   - Asks for confirmation before stopping containers (unless `-f/--force` is used)
   - Stops containers if necessary
   - Creates compressed archive of volume data with specified compression level
   - Performs fast verification of backup integrity (optimized to minimize verification time)
   - Records backup statistics (size, duration, etc.)
8. Then processes priority volumes (those used by critical containers)
9. Restarts all affected containers after all volume backups are complete
10. Provides a summary of successful and failed backups
11. Cleans up old backups according to retention policy

### Restore Process

1. Verifies prerequisites (Docker access, permissions, disk space)
2. Shows list of available backup dates (or uses specified date with `-b` option)
3. Shows list of volumes available in the selected backup
4. Creates a single Alpine container with pigz installed for all decompression operations
5. Verifies backup integrity and content before restoration
6. Creates a temporary volume to test the backup restoration first
7. Identifies and stops only running containers that use the volume
8. Clears the target volume to ensure clean state
9. Performs data restoration with detailed progress indication
10. Verifies restored data with file count checks
11. Restarts containers that were previously running
12. Removes the temporary test volume if successful

### Cleanup Process

1. Verifies Docker access permissions
2. Displays current Docker system usage statistics
3. Based on specified options, performs targeted cleanup:
   - For unused volumes: Identifies and removes volumes not attached to any containers
   - For temporary volumes: Removes restore-temporary volumes (starting with "temp*restore*")
   - For dangling images: Removes images without tags that are not being used
   - For stopped containers: Removes containers in "exited" state
   - For unused networks: Removes custom networks not used by any containers
   - For builder cache: Cleans up Docker's build cache
4. Provides detailed outputs and logs of all operations
5. Can perform a "dry run" to show what would be removed without making changes
6. Can run a complete system prune for thorough cleanup

## Performance Optimizations

- **Single Container Reuse**: Uses a single Alpine container for all backup/restore operations
- **Parallel Volume Processing**: Process multiple volumes simultaneously with the `--jobs` option
- **Memory-Aware Execution**: Automatically adjusts parallelism based on available system memory
- **Fast Integrity Verification**: Uses efficient sampling techniques to verify backup integrity with minimal overhead
- **Metadata Caching**: Reduces Docker API calls by caching container and volume information
- **Efficient Container Management**: Safely stops and restarts only the containers that need it
- **Optimized Compression**: Uses pigz (parallel gzip) for multi-threaded compression
- **Delayed Container Restart**: Restarts containers only after all volumes are processed

## Best Practices

- Set up regular cron jobs for automated backups
- Store backups on a separate disk/server for safety
- Regularly test the restore process on non-production volumes
- Set an appropriate retention policy to manage disk space
- Use the `-s/--skip-used` flag for backup during high traffic times
- Use higher parallel jobs (`-j`) for systems with plenty of CPU cores and memory
- Consider using higher compression levels for long-term archival
- Ensure sufficient free disk space (at least twice the size of your volumes)
- Monitor backup logs for warnings or errors
- Test restoration occasionally to verify backup integrity
- Run cleanup regularly with dry-run first to understand what will be removed
- Use specific cleanup options instead of `--prune-all` in production environments
- Use the `--prioritize-last` option for critical infrastructure containers like DNS servers to minimize service disruption

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

**Error: Low memory conditions detected**

- The script will automatically reduce the number of parallel jobs
- You can manually specify fewer parallel jobs with `-j 1`
- Close other memory-intensive applications
- Add more RAM or increase swap space

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

**Problem: Critical containers like DNS servers affect all other containers when stopped**

- Use the `--prioritize-last` option to ensure these containers are backed up last
- This minimizes downtime for critical infrastructure services

**Problem: Backup is running slowly**

- Increase the number of parallel jobs with `--jobs` option
- Use a lower compression level (1-3) for faster backups
- Store backups on SSD rather than HDD
- Consider backing up fewer volumes at once

**Problem: Verification is taking too long**

- The backup verification has been optimized for speed in the latest version
- If you're still experiencing slow verification, try updating to the latest version
- Verification now uses efficient sampling to validate backup integrity with minimal overhead

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the license text at the top of each script file for details.
