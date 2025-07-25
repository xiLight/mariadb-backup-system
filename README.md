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
# Install Docker (as root if needed)
./install-docker.sh --allow-root

# Edit environment configuration
cp .env.example .env
nano .env  # Or use your preferred editor

# Quick installation with automatic setup
make install
# OR manually:
./install.sh

# Verify installation
./health_check.sh
```

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
| `TZ` | Timezone | `Europe/Berlin` | No |

### MariaDB Configuration (my_custom.cnf)

The system includes an optimized MariaDB configuration:

```ini
[mysqld]
# Network settings
bind-address = 0.0.0.0
max_connections = 900

# Binary logging for point-in-time recovery
log_bin = /var/lib/mysql/binlogs/mysql-bin
binlog_format = ROW
expire_logs_days = 30

# Performance optimizations
innodb_buffer_pool_size = 1028M
query_cache_size = 64M

# Security and replication settings
binlog_do_db = myapp_db,analytics_db
binlog_ignore_db = mysql,information_schema,performance_schema
```

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

# Custom encryption key
./backup.sh --full --key /path/to/custom.key
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

# Restore with verbose output and debug information
./restore.sh --verbose --debug

# Use specific backup file
./restore.sh --database myapp_db --backup-file backup_file.sql.gz.enc
```

#### Maintenance Commands

```bash
# Clean old backups (keeps last 7 days by default)
./cleanup_backups.sh

# Clean old binary logs (keeps last 3 days by default)
./cleanup_binlogs.sh

# Clean application logs
./log_cleanup.sh

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
├── 🔧 cleanup_backups.sh      # Backup cleanup
├── 🔧 cleanup_binlogs.sh      # Binary log cleanup
├── 🔧 log_cleanup.sh          # Log cleanup
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
- Combined console and file output
- Customizable log formatting

### Log Management

Clean all log files:
```bash
# Clean application logs
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

## Changelog

### Version 1.1.0 (Current)
- **Enhanced Restore System**: Interactive database and backup selection
- **Improved Binary Log Processing**: Fixed mariadb-binlog path issues
- **Point-in-Time Recovery**: Enhanced timestamp-based restoration
- **Centralized Logging**: All scripts now use lib/logging.sh
- **Better Error Handling**: Improved error codes and debugging
- **Docker Installation**: Added install-docker.sh script
- **Health Monitoring**: Enhanced health_check.sh with backup testing
- **File Filtering**: Improved binary log file filtering (.index, .idx exclusion)

### Version 1.0.0
- Initial release
- Full and incremental backup support
- Automatic encryption
- Binary log management
- Docker Compose setup
- Comprehensive logging
- Health monitoring

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