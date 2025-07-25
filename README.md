# MariaDB Backup System with Docker

A comprehensive Docker-based MariaDB backup solution with encryption, binary log support, and automated cleanup.

## Features

- 🔒 **Encrypted Backups** - All backups are automatically encrypted using OpenSSL
- 📊 **Binary Log Support** - Full and incremental backups with binary log rotation
- 🔄 **Automated Cleanup** - Configurable retention policies for backups and logs
- 🐳 **Docker Ready** - Complete Docker Compose setup included
- 📈 **Monitoring** - Comprehensive logging and error handling
- 🚀 **Easy Setup** - One-command installation and configuration

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

### 1.1. Installer
```bash

#requirements (as root)
./install-docker.sh --allow-root
#edit .env.example
#apt-get install nano
nano .env.example
#apt-get install make
make install
# or
./install.sh
#enjoy
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

# Incremental backup
./backup.sh
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
./backup.sh
```

This only backs up new binlog files since the last backup.

### 4. Restoring from Backup

```bash
./restore.sh
```

### 5. Point-in-Time Recovery

```bash
./restore.sh --timestamp "YYYY-MM-DD_HH-MM-SS"
```

Restores the database to the state at the specified timestamp.

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
| `TZ` | Timezone | `Europe/Berlin` | No |

### MariaDB Configuration (my_custom.cnf)

The system includes an optimized MariaDB configuration:

```ini
[mysqld]
# Network settings
bind-address = 0.0.0.0
max_connections = 900

# Binary logging for incremental backups
log_bin = /var/lib/mysql/binlogs/mysql-bin
binlog_format = ROW
expire_logs_days = 30

# Performance optimizations
innodb_buffer_pool_size = 1028M
query_cache_size = 64M
```

## Usage

### Command Reference

#### Backup Commands

```bash
# Full backup
./backup.sh --full

# Full backup including empty databases
./backup.sh --full --include-empty

# Incremental backup (binary logs only)
./backup.sh

# Custom encryption key
./backup.sh --full --key /path/to/custom.key
```

#### Restore Commands

```bash
# Interactive restore (default - select database and backup)
./restore.sh

# Automatic restore using latest backup (no interaction)
./restore.sh --no-select

# Restore latest backup with debug information
./restore.sh --last --debug

# Restore to specific timestamp
./restore.sh --timestamp "YYYY-MM-DD_HH-MM-SS"

# Restore with custom encryption key
./restore.sh --key /path/to/custom.key

# Verbose output during restore
./restore.sh --verbose

# Restore specific backup file and database
./restore.sh backup_file.sql.gz.enc database_name
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
├── 📄 Makefile                # Make commands
├── 📄 health_check.sh         # System health check
├── 🔧 backup.sh               # Main backup script
├── 🔧 restore.sh              # Restore script
├── 🔧 encrypt_backup.sh       # Encryption utilities
├── 🔧 cleanup_backups.sh      # Backup cleanup
├── 🔧 cleanup_binlogs.sh      # Binary log cleanup
├── 🔧 log_cleanup.sh          # Log cleanup
├── 📁 backups/                # Backup storage
│   ├── binlogs/               # Binary log backups
│   ├── checksums/             # Backup checksums
│   ├── incr/                  # Incremental backup info
│   └── binlog_info/           # Binary log positions
├── 📁 logs/                   # Application logs
└── 📁 mariadb_data/           # MariaDB data (created by Docker)
```

## Logs

All log files are now organized in the `logs/` directory:

- **Backup Logs**: `logs/backup.log`
- **Restore Logs**: `logs/restore.log`
- **Encryption Logs**: `logs/encrypt.log`
- **Cleanup Logs**: `logs/cleanup_backups.log`, `logs/cleanup_binlogs.log`
- **MariaDB Logs**: View with `docker logs mariadb`

### Log Management

Clean all log files:
```bash
./log_cleanup.sh
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

# Check binary log permissions
docker exec mariadb ls -la /var/lib/mysql/binlogs/
```

#### Restore Problems
```bash
# Check restore logs
tail -f logs/restore.log

# Verify backup file integrity
./encrypt_backup.sh --verify backup_file.sql.gz.enc

# Check available space
df -h mariadb_data/
```

### Error Codes

| Code | Description | Solution |
|------|-------------|----------|
| 1 | Configuration error | Check .env file |
| 2 | Directory creation failed | Check permissions |
| 3 | Database connection failed | Check MariaDB status |
| 4 | Backup operation failed | Check logs and disk space |
| 5 | Encryption failed | Check encryption key |
| 10 | Restore operation failed | Check backup file integrity |

### Getting Support

1. **Check logs** in `./logs/` directory
2. **Run health check**: `./health_check.sh`
3. **Review configuration**: `make config`
4. **Check GitHub issues** for similar problems
5. **Create new issue** with detailed information

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
./backup.sh --verify                   # Verify backups
docker exec mariadb mariadb -e "SHOW STATUS;"  # Database status
```

### Backup Verification
```bash
# Verify backup integrity
find backups -name "*.enc" -exec ./encrypt_backup.sh --verify {} \;

# Check backup statistics
make backup-stats

# List recent backups
make list-backups
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

Set up automated backups with cron:

```bash
# Edit crontab
crontab -e

# Add backup schedule
0 2 * * * cd /path/to/mariadb-backup-system && ./backup.sh --full
0 6,12,18 * * * cd /path/to/mariadb-backup-system && ./backup.sh
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

### Version 1.0.0
- Initial release
- Full and incremental backup support
- Automatic encryption
- Binary log management
- Docker Compose setup
- Comprehensive logging
- Health monitoring

## Acknowledgments

- MariaDB Foundation for the excellent database system
- Docker community for containerization tools
- OpenSSL project for encryption capabilities
- Contributors and testers

---

**⚠️ Important**: Always test backup and restore procedures before relying on them in production!