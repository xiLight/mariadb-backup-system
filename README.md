# MariaDB Backup System with Docker

A comprehensive Docker-based MariaDB backup solution with encryption, binary log support, and automated cleanup.

## Features

- 🔒 **Encrypted Backups** - AES-256-CBC with PBKDF2 (200k iterations), SHA-256 checksums
- 📊 **Binary Log Support** - Point-in-time recovery with MariaDB binary logs
- ✅ **Backup Verification** - decrypt + integrity test without touching the database
- ☁️ **Offsite Replication** - rsync/rclone to a second host, key never leaves the server
- 🌐 **HA Cluster (optional)** - 3-node Galera multi-master, HAProxy failover, self-healing
- 🔁 **Rolling Updates** - zero-downtime updates, one node at a time
- ⚓ **Portolan Integration** - collision-free ports/subnets picked automatically at install
- 🔄 **Automated Cleanup** - configurable retention for backups, binlogs, and rolling logs
- 📈 **Dashboard** - live terminal dashboard + HTML status page
- 🛠️ **DB Administration** - create databases/users/superusers with one command
- 🚀 **Easy Setup** - one command installs everything incl. cron jobs
- 📋 **Health Checks** - built-in system monitoring and validation

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

### 2. Manual Setup (without installer)

```bash
# Copy and edit the environment file
cp .env.example .env

# Start MariaDB
docker compose up -d
```

### 3. Run Your First Backup

```bash
./backup.sh --full                    # full backup
./backup.sh --full --include-empty    # include databases without tables
./backup.sh --incremental             # binlog-based incremental backup
```

A full backup creates:
- A compressed, encrypted SQL dump per database
- A binlog info file with the exact position (for incrementals/PITR)
- A synced copy of all binlog files
- SHA-256 checksums for all backup files

### 4. Restoring from Backup

```bash
./restore.sh                                        # interactive selection
./restore.sh --database ALL                         # all DBs from their latest backup
./restore.sh --database mydb --last                 # one DB, latest backup
./restore.sh --to-timestamp "YYYY-MM-DD HH:MM:SS"   # point-in-time recovery
```

## Configuration

### Environment Variables (.env)

| Variable | Description | Example | Required |
|----------|-------------|---------|----------|
| `MARIADB_ROOT_PASSWORD` | Root password for MariaDB | `your_secure_password` | Yes |
| `MARIADB_ROOT_REMOTE` | Allow root login from outside the container | `yes` / `no` | No |
| `MARIADB_DATABASE1-5` | Database names to create | `myapp_db` | No |
| `MARIADB_USER` | Application user | `app_user` | Yes |
| `MARIADB_PASSWORD` | Application user password | `app_password` | Yes |
| `DATABASE1-5_PASSWORD` | Individual DB passwords | `db_password` | No |
| `STACK_NAME` | Unique prefix for containers/image per installation | `shop` | No |
| `MARIADB_CONTAINER` | Container name (set by installer) | `mariadb` | No |
| `MARIADB_PORT` | Host port (single node; filled via Portolan) | `3306` | No |
| `MARIADB_BIND_IP` | Interface to publish the DB port on | `0.0.0.0` | No |
| `BACKUP_DIR` | Backup storage directory | `./backups` | No |
| `BINLOG_DIR` | Binary log backup directory | `./backups/binlogs` | No |
| `BACKUP_KEEP_GENERATIONS` | Full backup generations to keep per DB | `7` | No |
| `OFFSITE_METHOD` | Offsite sync tool | `rsync` / `rclone` | No |
| `OFFSITE_TARGET` | Offsite destination | `user@host:/backups` | No |
| `OFFSITE_AUTO` | Sync automatically after each backup | `no` | No |
| `OFFSITE_DELETE` | Mirror local retention to the remote | `no` | No |
| `OFFSITE_BWLIMIT` | Bandwidth limit (rsync: KB/s) | `5000` | No |
| `LOG_MAX_SIZE_KB` | Rotate logs when they exceed this size | `5120` | No |
| `LOG_KEEP` | Number of rotated log files to keep | `5` | No |
| `LOG_RETENTION_DAYS` | Delete rotated logs older than this | `14` | No |
| `GALERA_CLUSTER_NAME` | Galera cluster name (cluster mode) | `mariadb-galera` | No |
| `GALERA_SUBNET` | Cluster network subnet (filled via Portolan) | `172.20.0.0/24` | No |
| `HAPROXY_PORT` | HAProxy MariaDB port (cluster mode) | `3306` | No |
| `HAPROXY_STATS_PORT` | HAProxy stats dashboard port | `8404` | No |
| `HAPROXY_STATS_BIND_IP` | Stats page binding (localhost by default) | `127.0.0.1` | No |
| `CLUSTER_SYNC_TIMEOUT` | Max seconds for a node to resync | `600` | No |
| `HEAL_INTERVAL` | Check interval for `heal.sh --daemon` | `30` | No |
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
# Query cache is disabled (mutex contention, unsupported with Galera)
query_cache_size = 0
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

### 🌐 High Availability
- **3-node Galera cluster** with synchronous multi-master replication
- **HAProxy failover** with automatic failback and single-writer routing
- **Rolling updates** (`update.sh`): git pull + node-by-node restart, zero downtime
- **Self-healing** (`heal.sh`): restarts stuck/stopped nodes, recovers a fully
  dead cluster from the node with the newest data

### 🔒 Security Hardening
- PBKDF2 with 200,000 iterations (legacy backups stay restorable)
- Passwords via `MYSQL_PWD`, never visible in process lists
- HAProxy stats bound to localhost, configurable bind IPs, optional remote root
- Offsite replication that never syncs the encryption key

### ⚡ Performance & Reliability
- `--single-transaction` dumps (no table locks), multi-core compression via pigz
- Incremental binlog sync (only new/changed files are copied)
- Exact binlog positions parsed from the dump header (gap-free incrementals)
- Rolling logs with size-based rotation; backup verification without plaintext on disk

### 🛠️ Tooling
- **Portolan integration**: collision-free ports/subnets chosen at install time
- **Unique stack names**: several installations coexist on one host
- **Dashboard**: live terminal view + HTML status page
- **DB administration**: database/user/superuser provisioning with one command

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

# Backup a single database only
./backup.sh --full --database myapp_db

# Custom encryption key
./backup.sh --full --key /path/to/custom.key

# Skip compression / checksum creation
./backup.sh --full --no-compress
./backup.sh --full --no-checksums
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

#### Offsite Replication

```bash
# Configure the target in .env first:
#   OFFSITE_TARGET=user@backuphost:/backups/mariadb   (rsync over SSH)
#   OFFSITE_METHOD=rclone + OFFSITE_TARGET=remote:dir (any rclone backend)

./offsite_sync.sh --dry-run    # preview what would be transferred
./offsite_sync.sh --verify     # verify latest backups, then sync
make offsite                   # same as --verify

# Or fully automatic after every backup:
#   OFFSITE_AUTO=yes in .env
```

Why: with backups only on the same disk, a disk failure or compromise loses
the database **and** its backups. The offsite copy closes that gap. The
encryption key is **never synced** - store `.backup_encryption_key`
separately (password manager/vault); without it the offsite files are
useless to anyone who obtains them. `health_check.sh` warns when the last
offsite sync is older than 7 days.

#### Dashboard

```bash
./dashboard.sh                 # live terminal dashboard (q to quit)
./dashboard.sh --once          # print once and exit
./dashboard.sh --html          # write status.html (auto-refreshing page)
./dashboard.sh --interval 10   # refresh every 10s instead of 5s
```

Shows server status, cluster health, database sizes, backup freshness per
database, disk usage, and recent backup/heal activity. The HTML page is a
local file (not served) - access it remotely via SSH tunnel instead of
exposing DB internals: `ssh -L 8000:localhost:8000 server` + any local server.

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
make help            # Show all available commands

# Setup & container management
make install         # Full installation (portolan, .env, cron, start)
make env             # Create .env with generated passwords
make start / stop / restart / status / build

# Backup & verify
make backup          # Incremental backup
make backup-full     # Full backup
make backup-empty    # Full backup incl. empty DBs
make verify          # Verify all backups
make verify-latest   # Verify latest backup per DB
make restore         # Interactive restore
make offsite         # Verify + replicate backups offsite
make offsite-dry     # Preview offsite sync

# Galera cluster (HA)
make cluster-init    # First-time 3-node cluster setup
make cluster-start / cluster-stop / cluster-status
make update          # Rolling update (git pull + node by node)
make heal            # One self-healing check
make heal-daemon     # Continuous self-healing

# Database administration
make database NAME=mydb      # Create database
make user NAME=myuser        # Create user
make provision NAME=myapp    # DB + user + grants in one step
make superuser NAME=admin    # Superuser (all databases)
make list-db                 # List databases and users

# Monitoring & maintenance
make dashboard       # Live terminal dashboard
make dashboard-html  # Write status.html
make health          # Health check
make health-test     # Health check incl. backup test
make cleanup         # Clean old backups + rotate logs
make cleanup-logs-all # Truncate all logs
make logs / logs-backup / logs-follow
make list-backups / backup-stats / disk-usage
make mariadb         # Open a MariaDB shell
```

## Directory Structure

```
mariadb-backup-system/
├── 📁 .github/                 # GitHub workflows and templates
├── 📄 docker-compose.yml       # Single-node Docker Compose
├── 📄 docker-compose.cluster.yml # 3-node Galera cluster + HAProxy
├── 📄 Dockerfile.mariadb       # Custom MariaDB image (incl. Galera)
├── 📄 my_custom.cnf            # MariaDB configuration
├── 📄 galera.cnf.template      # Per-node Galera config (rendered by entrypoint)
├── 📄 haproxy.cfg              # HAProxy failover configuration
├── 📄 entrypoint.sh            # MariaDB startup script
├── 📄 .env.example             # Environment template
├── 📄 install.sh               # Installer (Portolan, mode, cron, start)
├── 📄 install-docker.sh        # Docker installation script
├── 📄 Makefile                 # Make commands
├── 🔧 backup.sh                # Main backup script
├── 🔧 restore.sh               # Restore with interactive selection
├── 🔧 encrypt_backup.sh        # Encryption utilities
├── 🔧 verify_backup.sh         # Backup integrity verification
├── 🔧 offsite_sync.sh          # Offsite replication (rsync/rclone)
├── 🔧 cluster.sh               # Cluster init/start/stop/status
├── 🔧 update.sh                # Rolling updates (zero downtime)
├── 🔧 heal.sh                  # Self-healing (cron/daemon)
├── 🔧 db_admin.sh              # Database/user administration
├── 🔧 dashboard.sh             # Terminal + HTML dashboard
├── 🔧 health_check.sh          # System health check
├── 🔧 cleanup_backups.sh       # Backup retention cleanup
├── 🔧 cleanup_binlogs.sh       # Binary log cleanup
├── 🔧 log_cleanup.sh           # Log rotation and cleanup
├── 📁 lib/
│   ├── logging.sh              # Central logging with rolling logs
│   └── cluster.sh              # Shared cluster helpers
├── 📁 backups/                 # Backup storage
│   ├── binlogs/                # Binary log backups
│   ├── checksums/              # SHA-256 checksums
│   ├── incr/                   # Incremental backup info
│   └── binlog_info/            # Binary log positions
├── 📁 logs/                    # Application logs (rotated)
├── 📁 mariadb_data/            # Single-node data (created by Docker)
└── 📁 cluster_data/            # Cluster node data (node1/2/3)
```

## Logs

All log files are organized in the `logs/` directory with centralized logging:

- **Backup / Restore**: `logs/backup.log`, `logs/restore.log`, `logs/verify.log`
- **Encryption**: `logs/encrypt.log`
- **Offsite Replication**: `logs/offsite.log`
- **Cluster**: `logs/cluster.log`, `logs/update.log`, `logs/heal.log`
- **Administration**: `logs/db_admin.log`, `logs/health_check.log`
- **Cleanup**: `logs/cleanup_backups.log`, `logs/cleanup_binlogs.log`
- **MariaDB itself**: `docker logs <container>` (e.g. `mariadb` or `<stack>-node1`)

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

# Verify database connection (interactive password prompt)
docker exec -it mariadb mariadb -u root -p -e "SELECT 1;"

# Check disk space
df -h ./backups/

# Verify encryption key
ls -la .backup_encryption_key
```

#### Binary Logging Issues
```bash
# Check binary log status
docker exec -it mariadb mariadb -u root -p -e "SHOW VARIABLES LIKE 'log_bin%';"

# List binary logs in the container (they live in the datadir)
docker exec mariadb sh -c "ls -la /var/lib/mysql/mysql-bin.*"

# Check MariaDB binary log tool
docker exec mariadb mariadb-binlog --version
```

#### Cluster Node Won't Join (stuck at "n/a" / "not responding")

The container runs but mariadbd inside keeps failing - almost always a
failed SST (state transfer from the donor). Diagnose first, always:

```bash
# THE most important command - the reason is in the joiner's log:
docker logs --tail 50 <stack>-node2

# Datadirs created before the log_error removal write errors to a file
# instead of docker logs - check that too:
tail -50 cluster_data/node2/error.log

# Also check the donor side (node1) for SST errors:
docker logs --tail 50 <stack>-node1 2>&1 | grep -i sst
tail -50 cluster_data/node1/error.log | grep -i sst
```

Common causes and fixes:

```bash
# 1. SST auth failure (log shows "Access denied" / mariabackup errors):
#    older installations lack the sst_user - create it on the donor:
docker exec <stack>-node1 mariadb -u root -e "
  CREATE USER IF NOT EXISTS 'sst_user'@'localhost' IDENTIFIED BY '<MARIADB_ROOT_PASSWORD>';
  GRANT RELOAD, PROCESS, LOCK TABLES, BINLOG MONITOR ON *.* TO 'sst_user'@'localhost';"
docker restart <stack>-node2

# 2. Switch to rsync SST (no credentials needed at all):
#    set GALERA_SST_METHOD=rsync in .env, then re-create the nodes:
docker compose -f docker-compose.cluster.yml up -d --force-recreate node2 node3

# 3. Fresh cluster with no data yet? Clean re-init is the fastest fix:
docker compose -f docker-compose.cluster.yml down
rm -rf cluster_data
./cluster.sh init
```

#### Restore Problems
```bash
# Check restore logs
tail -f logs/restore.log

# Test backup integrity WITHOUT writing plaintext to disk
./verify_backup.sh --database mydb

# Check available space
df -h mariadb_data/

# Run restore with verbose output
./restore.sh --verbose
```

### Error Codes (backup.sh)

| Code | Description | Solution |
|------|-------------|----------|
| 1 | `.env` missing or backups failed | Check `.env` and `logs/backup.log` |
| 2 | Unknown command line option | See `./backup.sh --help` |
| 3 | Directory creation failed | Check permissions and disk space |
| 4 | Encryption key generation failed | Check OpenSSL installation |
| 5 | Cannot connect to MariaDB container | Check container status and credentials |
| 6 | Requested database does not exist | Check the `--database` name |

`encrypt_backup.sh` uses its own codes (1-9, see `--help`); all other
scripts exit `1` on failure with details in their log file under `logs/`.

### Getting Support

1. **Check logs** in `./logs/` directory
2. **Run health check**: `./health_check.sh --test-backup`
3. **Review configuration**: `make config` or check `.env` file
4. **Verify backups**: `./verify_backup.sh --latest`
5. **Check GitHub issues** for similar problems
6. **Create new issue** with detailed information including:
   - Log files from `./logs/`
   - Output of `./health_check.sh`
   - Your `.env` configuration (without passwords)
   - Steps to reproduce the issue

## Security Features

### Encryption
- **Algorithm**: AES-256-CBC with PBKDF2 key derivation (200,000 iterations;
  older backups with legacy parameters remain restorable)
- **Key Management**: key stored with permissions `600`, never synced offsite -
  keep a copy in a password manager/vault
- **No plaintext on disk**: verification decrypts in a pipe (`verify_backup.sh`)

### Access Control
- **Database Users**: separate per-database users; remote root optional
  (`MARIADB_ROOT_REMOTE=no` disables it)
- **Network Security**: configurable bind IPs (`MARIADB_BIND_IP`); HAProxy
  stats bound to localhost by default; passwords passed via `MYSQL_PWD`,
  never on command lines
- **File Permissions**: secure file and directory permissions

### Backup Integrity
- **Checksums**: SHA-256 verification for all backup files
- **Validation**: checksum verified before every decrypt/restore;
  `--verify` tests decryptability right after backup creation
- **Offsite copies**: `offsite_sync.sh --verify` refuses to replicate
  backups that fail verification

## Monitoring & Maintenance

### Health Monitoring
```bash
# Live dashboard (terminal or HTML)
make dashboard
make dashboard-html

# Run comprehensive health check
make health

# Check specific components
docker logs mariadb                    # MariaDB logs
./cluster.sh status                    # Cluster health (cluster mode)
```

### Backup Verification
```bash
# Verify ALL backups safely (checksum + decrypt + gzip test, no plaintext on disk)
make verify

# Only the latest backup per database (fast, ideal for cron)
make verify-latest

# Statistics and listings
make backup-stats
make list-backups
```

### Performance Tuning

Adjust MariaDB settings in `my_custom.cnf`:

```ini
# For high-memory systems (rule of thumb: ~70% of available RAM)
innodb_buffer_pool_size = 2048M
innodb_log_file_size = 256M

# For high-traffic systems
max_connections = 2000
thread_cache_size = 256
```

For full durability (at the cost of write performance) set
`sync_binlog = 1` and `innodb_flush_log_at_trx_commit = 1` - the shipped
defaults favor performance because backups + cluster replication exist.

### Backup Scheduling

Set up automated backups with cron (the self-healing cron job is installed
automatically by `./install.sh --cluster`):

```bash
# Edit crontab
crontab -e

# Recommended schedule
0 2 * * *      cd /path/to/mariadb-backup-system && ./backup.sh --full
0 6,12,18 * * * cd /path/to/mariadb-backup-system && ./backup.sh --incremental
30 2 * * *     cd /path/to/mariadb-backup-system && ./verify_backup.sh --latest
0 3 * * *      cd /path/to/mariadb-backup-system && ./offsite_sync.sh --verify
0 4 * * 0      cd /path/to/mariadb-backup-system && ./cleanup_backups.sh && ./cleanup_binlogs.sh && ./log_cleanup.sh
```

Tip: set `OFFSITE_AUTO=yes` in `.env` instead of the offsite cron line to
replicate immediately after every backup.

On Windows, run the scripts via WSL (`wsl -e bash -c "cd /path && ./backup.sh --full"`)
in the Task Scheduler - the shell scripts require a POSIX environment.

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
- Always test backup **and restore** procedures before relying on them in production!
- Store `.backup_encryption_key` in a second safe place (password manager/vault) -
  without it, no backup can ever be restored
- Point-in-time recovery requires properly configured binary logging (enabled by default)
- Restoring overwrites the target database - the script asks for confirmation
  unless `--yes` is passed