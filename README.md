# MariaDB Backup System with Docker

A comprehensive Docker-based MariaDB backup solution with encryption, binary log support, and automated cleanup.

## Features

- 🔒 **Encrypted Backups** - All backups are automatically encrypted using AES-256
- 📊 **Binary Log Support** - Point-in-time recovery with MariaDB binary logs
- 🔄 **Automated Cleanup** - Configurable retention policies for backups and logs
- 🐳 **Docker Ready** - Complete Docker Compose setup included
- 📈 **Monitoring** - Comprehensive logging with centralized system
- 🚀 **Easy Setup** - One-command installation and configuration
- 🔧 **Interactive Tools** - User-friendly interactive restore and backup selection
- 📋 **Health Checks** - Built-in system monitoring and validation

## Quick Start

### Prerequisites
- Docker and Docker Compose installed
- Linux/Unix environment (or WSL on Windows)

### 1. Clone and Setup

```bash
git clone https://github.com/xiLight/mariadb-backup-system.git
cd mariadb-backup-system
chmod +x *.sh
```

### 1.1. Installer (Recommended)
```bash
# Quick installation with automatic setup
make install
# or interactively choose single node vs. HA cluster:
./install.sh
# or non-interactive:
./install.sh --single                  # one MariaDB container
./install.sh --cluster                 # 3-node Galera cluster + HAProxy + self-healing cron
./install.sh --cluster --stack shop    # unique stack name -> shop-node1, shop-haproxy, ...

# Verify installation
make health
# or
./health_check.sh
```

The installer does everything - after it finishes, the system is ready to use:

1. **Installs [Portolan](https://git.simbrey.com/docker-public/portolan)** (port/subnet registry)
   and uses it to pick **collision-free ports and subnets** for `.env`:
   port 3306 taken? Portolan suggests the next free one. The chosen ports are
   reserved in Portolan's registry so other stacks won't collide with this one.
2. Generates secure passwords and the backup encryption key
3. Creates directories, networks, and starts the containers
4. Cluster mode: initializes the Galera cluster **and installs the self-healing
   cron job** (`./heal.sh` every minute) - no manual steps needed
5. Runs an initial backup test

### 2. Configure Environment

```bash
# Copy and edit the environment file
cp .env.example .env
# Edit .env with your settings (see Configuration section)
```

### 3. Start MariaDB

```bash
docker compose up -d
```

### 4. Run Your First Backup

```bash
# Full backup with empty databases included
./backup.sh --full --include-empty

# Incremental backup with empty databases included
./backup.sh --incremental --include-empty
```

```bash
./backup.sh --full
```

This creates:
- A compressed SQL dump of the entire database
- A binlog info file with the current position
- Backup of all existing binlog files
- SHA-256 checksums for all backup files

### 3. Creating an Incremental Backup

```bash
./backup.sh --incremental
```

This only backs up new binlog files since the last backup.

### 4. Restoring from Backup

Interactive restore (select database and backup):
```bash
./restore.sh
```

Restore all databases automatically:
```bash
./restore.sh --database ALL --backup-file LATEST
```

### 5. Point-in-Time Recovery

```bash
./restore.sh --to-timestamp "YYYY-MM-DD HH:MM:SS"
```

Restores the database to the state at the specified timestamp using binary log replay.

### 6. Encrypting Backups

```bash
./encrypt_backup.sh --encrypt backups/db_full_2023-01-01_12-00-00.sql.gz
```

Encrypts the backup file using AES-256 encryption.

### 7. Decrypting Backups

```bash
./encrypt_backup.sh --decrypt backups/db_full_2023-01-01_12-00-00.sql.gz.enc
```

Decrypts a previously encrypted backup file.

### 8. Cleanup

```bash
./cleanup_backups.sh
```

Deletes backups older than the specified retention period.

## Configuration

### Environment Variables (.env)

| Variable | Description | Example | Required |
|----------|-------------|---------|----------|
| `MARIADB_ROOT_PASSWORD` | Root password for MariaDB | `your_secure_password` | Yes |
| `MARIADB_DATABASE1-5` | Database names to create | `myapp_db` | No |
| `MARIADB_USER` | Application user | `app_user` | Yes |
| `MARIADB_PASSWORD` | Application user password | `app_password` | Yes |
| `DATABASE1-5_PASSWORD` | Individual DB passwords | `db_password` | No |
| `MARIADB_CONTAINER` | Container name | `mariadb` | No |
| `BACKUP_DIR` | Backup storage directory | `./backups` | No |
| `BINLOG_DIR` | Binary log backup directory | `./backups/binlogs` | No |
| `BACKUP_KEEP_GENERATIONS` | Full backup generations to keep per DB | `7` | No |
| `LOG_MAX_SIZE_KB` | Rotate logs when they exceed this size | `5120` | No |
| `LOG_KEEP` | Number of rotated log files to keep | `5` | No |
| `LOG_RETENTION_DAYS` | Delete rotated logs older than this | `14` | No |
| `TZ` | Timezone | `Europe/Berlin` | No |

### MariaDB Configuration (my_custom.cnf)

The system includes an optimized MariaDB configuration:

```ini
[mysqld]
# Network settings
bind-address = 0.0.0.0
max_connections = 900

# Binary logging for point-in-time recovery
log_bin = mysql-bin
binlog_format = ROW
expire_logs_days = 30

# Performance optimizations
innodb_buffer_pool_size = 1024M
query_cache_size = 64M
```

## High Availability: Galera Cluster (3 Nodes)

Optional synchronous multi-master replication with automatic failover and
self-healing. The single-node setup (`docker-compose.yml`) keeps working
unchanged - the cluster lives in its own compose file.

```
                        ┌──────────────┐
   Clients ──► :3306 ──►│   HAProxy    │  automatic failover
                        └──┬────┬────┬─┘  (stats: :8404)
                           │    │    │
                        ┌──▼─┐┌─▼──┐┌─▼──┐
                        │node1││node2││node3│   Galera: synchronous
                        └────┘└────┘└────┘     multi-master replication
```

- **Synchronous replication**: every commit is replicated to all 3 nodes before it returns
- **Automatic failover**: HAProxy routes traffic to node1; if it fails, node2/node3 take over within seconds and node1 resumes once healthy
- **Single-writer routing**: writes go to one node at a time (Galera best practice, avoids certification conflicts)

### Cluster Setup

```bash
# One-time initialization (bootstraps node1, joins node2+3, starts HAProxy)
./cluster.sh init          # or: make cluster-init

# Daily operations
./cluster.sh status        # cluster health overview
./cluster.sh stop          # graceful shutdown
./cluster.sh start         # start again (safe cold-start via heal.sh)
```

Connect your applications to `localhost:3306` (HAProxy) - failover is transparent.

### Rolling Updates (zero downtime)

```bash
./update.sh                # or: make update
```

`update.sh` pulls the latest version from git, rebuilds the image, then updates
**node1 first while node2/3 keep serving**. It waits until node1 is back and
fully `Synced`, then updates node2, then node3 - exactly one node is ever down.
The update aborts immediately if the cluster is not fully healthy.

```bash
./update.sh --skip-pull    # rebuild + roll without git pull
./update.sh --yes          # non-interactive (for automation)
```

### Self-Healing

```bash
./heal.sh                  # one-shot check (ideal for cron)
./heal.sh --daemon         # continuous monitoring (HEAL_INTERVAL, default 30s)
./heal.sh --recover        # force full-cluster recovery
```

What it heals automatically:
- **Stopped node** → restarted and rejoins the cluster (state transfer via mariabackup)
- **Stuck node** (not responding / split-brain non-Primary) → restarted after 3 consecutive failed checks
- **Whole cluster down** → bootstraps from the node with the newest data (`grastate.dat` seqno), then rejoins the others
- **HAProxy down** → restarted

`./install.sh --cluster` installs this cron job automatically. Manual setup:
```
* * * * * cd /path/to/mariadb-backup-system && ./heal.sh >/dev/null 2>&1
```

### Unique Names per Stack

`STACK_NAME` in `.env` prefixes the compose project, all container names, and
the image tag - so several installations can run on one host without collisions:

```
STACK_NAME=shop   ->  shop-node1, shop-node2, shop-node3, shop-haproxy
STACK_NAME=blog   ->  blog-node1, blog-node2, blog-node3, blog-haproxy
```

The cluster nodes only join the stack's private `galera` network (its subnet
comes from Portolan via `GALERA_SUBNET`). Only HAProxy joins the shared `web`
network - other containers reach it via its unique name, e.g. `shop-haproxy:3306`.

### Backups in Cluster Mode

Point the backup system at one node in `.env` (install.sh does this automatically):
```
MARIADB_CONTAINER=${STACK_NAME}-node1    # e.g. mariadb-node1
```
All backup/restore/verify scripts work unchanged. Restores replicate to the
other nodes automatically (SQL imports go through Galera replication).

## Key Improvements in Current Version

### 🔧 Enhanced Restore System
- **Interactive Selection**: Choose databases and backups through user-friendly menus
- **ALL_DATABASES Option**: Restore all databases with a single command
- **Better Error Handling**: Detailed error messages and debugging options
- **Verbose Mode**: Step-by-step progress information during restore

### 🔍 Fixed Binary Log Issues
- **MariaDB Compatibility**: Uses `/usr/bin/mariadb-binlog` instead of legacy `mysqlbinlog`
- **File Filtering**: Properly excludes `.index` and `.idx` files from processing
- **Temporary Processing**: Safer binlog handling with container-based processing
- **Point-in-Time Recovery**: Accurate timestamp-based restoration

### 📋 Centralized Logging
- **Unified System**: All scripts use `lib/logging.sh` for consistent logging
- **Color-Coded Output**: Easy-to-read INFO, SUCCESS, WARNING, ERROR messages
- **File + Console**: Simultaneous logging to files and console
- **Debugging Support**: Enhanced debug and trace logging capabilities

### 🛠️ Installation Improvements
- **Docker Installation**: Automated Docker setup with `install-docker.sh`
- **Password Generation**: Secure automatic password generation during setup
- **Health Checks**: Comprehensive system validation and testing
- **Cross-Platform**: Better Windows/Linux compatibility

## Usage

### Command Reference

#### Backup Commands

```bash
# Full backup
./backup.sh --full

# Full backup including empty databases
./backup.sh --full --include-empty

# Incremental backup (binary logs only)
./backup.sh --incremental

# Full backup with verification (decrypt + integrity test after creation)
./backup.sh --full --verify

# Custom encryption key
./backup.sh --full --key /path/to/custom.key
```

#### Verify Commands

```bash
# Verify all backups (checksum + decryption + gzip integrity)
./verify_backup.sh

# Verify only the latest backup per database
./verify_backup.sh --latest

# Verify backups of a specific database
./verify_backup.sh --database myapp_db
```

#### Restore Commands

```bash
# Interactive restore - select database and backup
./restore.sh

# Restore all databases using latest backups
./restore.sh --database ALL

# Restore specific database with latest backup
./restore.sh --database myapp_db --last

# Point-in-time recovery to specific timestamp
./restore.sh --to-timestamp "YYYY-MM-DD HH:MM:SS"

# Skip the confirmation prompt (for automation/cron)
./restore.sh --database myapp_db --last --yes

# Restore with verbose output
./restore.sh --verbose

# Use specific backup file
./restore.sh --database myapp_db --backup-file backup_file.sql.gz.enc
```

> **Note:** Restoring overwrites the target database. The script asks for
> confirmation unless `--yes` is passed.

#### Database Administration

```bash
# Create a database
./db_admin.sh create-database mydb          # or: make database NAME=mydb

# Create a user (password auto-generated if omitted, shown once)
./db_admin.sh create-user myuser            # or: make user NAME=myuser

# Provision: database + same-named user with ALL privileges on that DB only
./db_admin.sh provision myapp               # or: make provision NAME=myapp

# Superuser with full access to all databases (asks for confirmation)
./db_admin.sh create-superuser admin        # or: make superuser NAME=admin

# List databases and users
./db_admin.sh list                          # or: make list-db
```

Without arguments the commands ask interactively. In cluster mode all
changes replicate to every node automatically.

#### Maintenance Commands

```bash
# Clean old backups (keeps last BACKUP_KEEP_GENERATIONS full backups per DB, default 7)
./cleanup_backups.sh

# Clean binary logs no longer needed by any kept backup
./cleanup_binlogs.sh

# Rotate oversized logs and prune old rotated logs
./log_cleanup.sh

# Truncate all logs
./log_cleanup.sh --all

# System health check
./health_check.sh

# Health check with backup test
./health_check.sh --test-backup
```

#### Using Make (Recommended)

```bash
# Show all available commands
make help

# Quick setup
make install

# Container management
make start
make stop
make restart
make status

# Backup operations
make backup          # Incremental
make backup-full     # Full backup
make backup-empty    # Full with empty DBs
make verify          # Verify all backups
make verify-latest   # Verify latest backup per DB

# Maintenance
make cleanup         # Clean backups and logs
make health          # Health check
make logs            # View MariaDB logs
```

## Directory Structure

```
mariadb-backup-system/
├── 📁 .github/                 # GitHub workflows and templates
│   ├── workflows/ci.yml        # CI/CD pipeline
│   └── ISSUE_TEMPLATE/         # Issue templates
├── 📄 docker-compose.yml       # Docker Compose configuration
├── 📄 Dockerfile.mariadb      # Custom MariaDB image
├── 📄 my_custom.cnf           # MariaDB configuration
├── 📄 entrypoint.sh           # MariaDB startup script
├── 📄 .env.example            # Environment template
├── 📄 install.sh              # Installation script
├── 📄 install-docker.sh       # Docker installation script
├── 📄 Makefile                # Make commands
├── 📄 health_check.sh         # System health check
├── 🔧 backup.sh               # Main backup script
├── 🔧 restore.sh              # Restore script with interactive selection
├── 🔧 encrypt_backup.sh       # Encryption utilities
├── 🔧 verify_backup.sh        # Backup integrity verification
├── 🔧 cleanup_backups.sh      # Backup cleanup
├── 🔧 cleanup_binlogs.sh      # Binary log cleanup
├── 🔧 log_cleanup.sh          # Log rotation and cleanup
├── 📁 lib/                    # Shared libraries
│   └── logging.sh             # Centralized logging system
├── 📁 backups/                # Backup storage
│   ├── binlogs/               # Binary log backups
│   ├── checksums/             # Backup checksums
│   ├── incr/                  # Incremental backup info
│   └── binlog_info/           # Binary log positions
├── 📁 logs/                   # Application logs
└── 📁 mariadb_data/           # MariaDB data (created by Docker)
```

## Logs

All log files are organized in the `logs/` directory with centralized logging:

- **Backup Logs**: `logs/backup.log`
- **Restore Logs**: `logs/restore.log`
- **Encryption Logs**: `logs/encrypt.log`
- **Cleanup Logs**: `logs/cleanup_backups.log`, `logs/cleanup_binlogs.log`
- **MariaDB Logs**: View with `docker logs mariadb`

### Centralized Logging System

The project uses a centralized logging system located in `lib/logging.sh` that provides:
- Consistent timestamp formatting
- Color-coded log levels (INFO, SUCCESS, WARNING, ERROR, DEBUG)
- Automatic console and file output (set `LOG_FILE` + call `init_logging`)
- **Rolling logs**: automatic size-based rotation (`backup.log` → `backup.log.1` → ... ),
  configurable via `LOG_MAX_SIZE_KB` and `LOG_KEEP` in `.env`

### Log Management

```bash
# Rotate oversized logs, prune rotated logs older than LOG_RETENTION_DAYS
./log_cleanup.sh

# View recent backup operations
tail -f logs/backup.log

# Monitor restore operations in real-time
tail -f logs/restore.log

# Check encryption operations
cat logs/encrypt.log

# View all logs summary
ls -la logs/ && echo "Total log size: $(du -sh logs/ | cut -f1)"
```

## Troubleshooting

### Common Issues

#### Container Keeps Restarting
```bash
# Check MariaDB logs
docker logs mariadb

# Verify configuration
./health_check.sh

# Check disk space
df -h

# Verify file permissions
ls -la mariadb_data/
```

#### Backup Fails
```bash
# Check backup logs
tail -f logs/backup.log

# Verify database connection
docker exec mariadb mariadb -u root -p -e "SELECT 1;"

# Check disk space
df -h ./backups/

# Verify encryption key
ls -la .backup_encryption_key
```

#### Binary Logging Issues
```bash
# Check binary log status
docker exec mariadb mariadb -u root -p -e "SHOW VARIABLES LIKE 'log_bin%';"

# Verify binary log directory
docker exec mariadb ls -la /var/lib/mysql/binlogs/

# Check MariaDB binary log tools
docker exec mariadb which mariadb-binlog

# Test binary log processing
docker exec mariadb /usr/bin/mariadb-binlog --version

# Check binary log file permissions
docker exec mariadb ls -la /var/lib/mysql/binlogs/
```

#### Restore Problems
```bash
# Check restore logs
tail -f logs/restore.log

# Test backup file integrity
./encrypt_backup.sh --decrypt backup_file.sql.gz.enc

# Check available space
df -h mariadb_data/

# Verify binary log compatibility
docker exec mariadb ls -la /var/lib/mysql/binlogs/

# Test restore with verbose output
./restore.sh --verbose --debug
```

### Error Codes

| Code | Description | Solution |
|------|-------------|----------|
| 1 | Configuration error | Check .env file and environment variables |
| 2 | Directory creation failed | Check permissions and disk space |
| 3 | Database connection failed | Check MariaDB status and credentials |
| 4 | Backup operation failed | Check logs and disk space |
| 5 | Encryption failed | Check encryption key and OpenSSL |
| 6 | Binary log processing failed | Check mariadb-binlog tool availability |
| 10 | Restore operation failed | Check backup file integrity and format |
| 11 | Interactive selection failed | Check terminal capabilities |

### Getting Support

1. **Check logs** in `./logs/` directory
2. **Run health check**: `./health_check.sh --test-backup`
3. **Review configuration**: `make config` or check `.env` file
4. **Test restore functionality**: `./restore.sh --verbose --debug`
5. **Check GitHub issues** for similar problems
6. **Create new issue** with detailed information including:
   - Log files from `./logs/`
   - Output of `./health_check.sh`
   - Your `.env` configuration (without passwords)
   - Steps to reproduce the issue

## Security Features

### Encryption
- **Algorithm**: AES-256-CBC encryption for all backups
- **Key Management**: Secure key storage with proper permissions (600)
- **Key Rotation**: Support for custom encryption keys

### Access Control
- **Database Users**: Separate users for applications and backups
- **Network Security**: Configurable bind addresses
- **File Permissions**: Secure file and directory permissions

### Backup Integrity
- **Checksums**: SHA-256 verification for all backup files
- **Validation**: Automatic backup verification during restore
- **Atomic Operations**: Transaction-based restore operations

## Monitoring & Maintenance

### Log Files
- `logs/backup.log` - Backup operations and status
- `logs/restore.log` - Restore operations and results
- `logs/cleanup.log` - Cleanup operations
- `logs/encrypt.log` - Encryption/decryption operations

### Health Monitoring
```bash
# Run comprehensive health check
make health

# Check specific components
docker logs mariadb                    # MariaDB logs
docker exec mariadb mariadb -e "SHOW STATUS;"  # Database status
```

### Backup Verification
```bash
# Verify backup integrity using encryption tool
find backups -name "*.enc" -exec ./encrypt_backup.sh --decrypt {} \; -exec rm -f {}.decrypted \;

# Check backup statistics with improved format
make backup-stats

# List recent backups with detailed information
make list-backups

# Test restore process without actually restoring
./restore.sh --verbose --debug --database test_db 2>&1 | head -50
```

### Performance Tuning

Adjust MariaDB settings in `my_custom.cnf`:

```ini
# For high-memory systems
innodb_buffer_pool_size = 2048M
innodb_buffer_pool_instances = 8

# For high-traffic systems
max_connections = 2000
thread_cache_size = 256
```

### Backup Scheduling

Set up automated backups with Windows Task Scheduler or cron (WSL/Linux):

#### Windows Task Scheduler
```powershell
# Create a scheduled task for daily full backup
schtasks /create /tn "MariaDB Full Backup" /tr "powershell.exe -Command 'cd C:\path\to\mariadb-backup-system; .\backup.sh --full'" /sc daily /st 02:00

# Create incremental backup task
schtasks /create /tn "MariaDB Incremental Backup" /tr "powershell.exe -Command 'cd C:\path\to\mariadb-backup-system; .\backup.sh'" /sc daily /st 06:00,12:00,18:00
```

#### Linux/WSL Cron
```bash
# Edit crontab
crontab -e

# Add backup schedule
0 2 * * * cd /path/to/mariadb-backup-system && ./backup.sh --full
0 6,12,18 * * * cd /path/to/mariadb-backup-system && ./backup.sh --incremental
0 3 * * 0 cd /path/to/mariadb-backup-system && ./cleanup_backups.sh
```

## Contributing

We welcome contributions! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

### Quick Start for Contributors

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly with `make health-test`
5. Submit a pull request

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Acknowledgments

- **MariaDB Foundation** for the excellent database system and mariadb-binlog tools
- **Docker Community** for containerization technologies
- **OpenSSL Project** for encryption capabilities
- **GitHub Community** for CI/CD and collaboration tools
- **Contributors and Testers** who helped improve the system

---

**⚠️ Important Notes**: 
- Always test backup and restore procedures before relying on them in production!
- The restore system now uses `/usr/bin/mariadb-binlog` instead of the legacy `mysqlbinlog`
- Interactive restore mode provides better user experience for database selection
- Point-in-time recovery requires properly configured binary logging