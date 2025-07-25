#!/bin/bash
set -e

# Load logging functions
if [ -f "/usr/local/lib/logging.sh" ]; then
    source "/usr/local/lib/logging.sh"
else
    # Fallback logging functions
    log_info() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1"; }
    log_success() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [SUCCESS] $1"; }
    log_warning() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARNING] $1"; }
    log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1"; }
fi

# Use environment variables passed by docker-compose
# These are already available as environment variables

# Database directory
DATADIR="/var/lib/mysql"
BINLOG_DIR="/var/lib/mysql/binlogs"
TMP_DIR="/tmp/binlogs"

# Error handling function
handle_error() {
  local error_msg="$1"
  log_error "$error_msg"
  exit 1
}

log_info "Starting MariaDB initialization process"

# Check if required environment variables are set
if [ -z "$MARIADB_ROOT_PASSWORD" ]; then
  handle_error "MARIADB_ROOT_PASSWORD environment variable is not set"
fi

# Create necessary directories
log_info "Creating directories"
mkdir -p "$DATADIR" || handle_error "Failed to create data directory"
mkdir -p "$BINLOG_DIR" || handle_error "Failed to create binlog directory" 
mkdir -p "$TMP_DIR" || handle_error "Failed to create temp binlog directory"
mkdir -p "/run/mysqld" || handle_error "Failed to create mysqld socket directory"

# Set proper permissions
chown -R mysql:mysql "$DATADIR" "$BINLOG_DIR" "$TMP_DIR" "/run/mysqld" || handle_error "Failed to set directory permissions"
chmod 700 "$DATADIR" "$BINLOG_DIR"
chmod 755 "/run/mysqld"

# Initialize database if it doesn't exist
if [ ! -d "$DATADIR/mysql" ]; then
  log_info "Initializing MariaDB database in data directory: $DATADIR"

  # Initialize database with proper settings
  log_info "Running mariadb-install-db..."
  mariadb-install-db --user=mysql --datadir="$DATADIR" --basedir=/usr --skip-test-db --verbose || {
    log_info "mariadb-install-db failed, trying alternative method..."
    # Try alternative initialization method
    mariadbd --initialize-insecure --user=mysql --datadir="$DATADIR" --basedir=/usr || handle_error "Failed to initialize database with both methods"
  }

  log_info "Starting MariaDB temporarily for initialization via Unix socket..."
  mariadbd --user=mysql --datadir="$DATADIR" --socket=/run/mysqld/mysqld.sock --skip-networking --pid-file=/run/mysqld/mysqld.pid &
  pid=$!

  # Wait for MariaDB to become available
  log_info "Waiting for MariaDB socket..."
  for i in {1..60}; do
    if [ -S /run/mysqld/mysqld.sock ]; then
      log_info "Socket found at /run/mysqld/mysqld.sock"
      break
    fi
    sleep 1
    if [ "$i" = 60 ]; then
      log_info "Socket not found, checking alternative locations..."
      find /var /run /tmp -name "*.sock" 2>/dev/null | head -10
      handle_error "Timed out waiting for MariaDB socket"
    fi
  done

  # Wait for MariaDB to respond to ping
  for i in {1..60}; do
    if mariadb-admin --protocol=socket --socket=/run/mysqld/mysqld.sock ping --silent > /dev/null 2>&1; then
      break
    fi
    sleep 1
    if [ "$i" = 60 ]; then
      handle_error "Timed out waiting for MariaDB to respond"
    fi
  done
  log_success "MariaDB started successfully"

  # Create databases and users for external access
  log_info "Creating databases and users for external access..."
  
  mariadb --protocol=socket --socket=/run/mysqld/mysqld.sock -u root <<EOF
-- Create databases first
CREATE DATABASE IF NOT EXISTS \`$MARIADB_DATABASE1\`;
CREATE DATABASE IF NOT EXISTS \`$MARIADB_DATABASE2\`;
CREATE DATABASE IF NOT EXISTS \`$MARIADB_DATABASE3\`;
CREATE DATABASE IF NOT EXISTS \`$MARIADB_DATABASE4\`;
CREATE DATABASE IF NOT EXISTS \`$MARIADB_DATABASE5\`;

-- Keep root@localhost without password for backup scripts
-- Only set password for external root access

-- Enable root access from external hosts
CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '$MARIADB_ROOT_PASSWORD';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;

-- Create database-specific users for external access
CREATE USER IF NOT EXISTS '$MARIADB_DATABASE1'@'%' IDENTIFIED BY '$DATABASE1_PASSWORD';
GRANT ALL PRIVILEGES ON \`$MARIADB_DATABASE1\`.* TO '$MARIADB_DATABASE1'@'%';

CREATE USER IF NOT EXISTS '$MARIADB_DATABASE2'@'%' IDENTIFIED BY '$DATABASE2_PASSWORD';
GRANT ALL PRIVILEGES ON \`$MARIADB_DATABASE2\`.* TO '$MARIADB_DATABASE2'@'%';

CREATE USER IF NOT EXISTS '$MARIADB_DATABASE3'@'%' IDENTIFIED BY '$DATABASE3_PASSWORD';
GRANT ALL PRIVILEGES ON \`$MARIADB_DATABASE3\`.* TO '$MARIADB_DATABASE3'@'%';

CREATE USER IF NOT EXISTS '$MARIADB_DATABASE4'@'%' IDENTIFIED BY '$DATABASE4_PASSWORD';
GRANT ALL PRIVILEGES ON \`$MARIADB_DATABASE4\`.* TO '$MARIADB_DATABASE4'@'%';

CREATE USER IF NOT EXISTS '$MARIADB_DATABASE5'@'%' IDENTIFIED BY '$DATABASE5_PASSWORD';
GRANT ALL PRIVILEGES ON \`$MARIADB_DATABASE5\`.* TO '$MARIADB_DATABASE5'@'%';

-- Create general user for external access
CREATE USER IF NOT EXISTS '$MARIADB_USER'@'%' IDENTIFIED BY '$MARIADB_PASSWORD';
GRANT ALL PRIVILEGES ON \`$MARIADB_DATABASE1\`.* TO '$MARIADB_USER'@'%';
GRANT ALL PRIVILEGES ON \`$MARIADB_DATABASE2\`.* TO '$MARIADB_USER'@'%';
GRANT ALL PRIVILEGES ON \`$MARIADB_DATABASE3\`.* TO '$MARIADB_USER'@'%';
GRANT ALL PRIVILEGES ON \`$MARIADB_DATABASE4\`.* TO '$MARIADB_USER'@'%';
GRANT ALL PRIVILEGES ON \`$MARIADB_DATABASE5\`.* TO '$MARIADB_USER'@'%';

-- Grant binlog privileges
GRANT RELOAD, REPLICATION CLIENT, BINLOG MONITOR, BINLOG REPLAY ON *.* TO '$MARIADB_USER'@'%';
GRANT RELOAD, REPLICATION CLIENT, BINLOG MONITOR, BINLOG REPLAY ON *.* TO 'root'@'%';

FLUSH PRIVILEGES;
EOF

  if [ $? -eq 0 ]; then
    log_success "Databases and users created successfully"
  else
    handle_error "Failed to create databases and users"
  fi

  # Verify databases were created
  log_info "Verifying created databases:"
  mariadb --protocol=socket --socket=/run/mysqld/mysqld.sock -u root -p"$MARIADB_ROOT_PASSWORD" -e "SHOW DATABASES;" | grep -E "^($MARIADB_DATABASE1|$MARIADB_DATABASE2|$MARIADB_DATABASE3|$MARIADB_DATABASE4|$MARIADB_DATABASE5)$"

  log_info "Verifying created users:"
  mariadb --protocol=socket --socket=/run/mysqld/mysqld.sock -u root -p"$MARIADB_ROOT_PASSWORD" -e "SELECT User, Host FROM mysql.user WHERE User NOT IN ('', 'mysql.sys', 'mysql.session', 'mysql.infoschema') ORDER BY User, Host;"

  # Stop the temporary MariaDB instance
  log_info "Stopping temporary MariaDB instance..."
  kill "$pid"
  wait "$pid" 2>/dev/null || true

else
  log_info "MariaDB data directory already exists, skipping initialization"
fi

log_info "Starting MariaDB server with networking enabled..."

# Verify configuration file exists
if [ -f "/etc/mysql/conf.d/my_custom.cnf" ]; then
  log_info "Configuration file found: /etc/mysql/conf.d/my_custom.cnf"
  log_info "Configuration file contents preview:"
  head -10 "/etc/mysql/conf.d/my_custom.cnf" | while read line; do
    log_info "  $line"
  done
else
  log_warning "Configuration file not found at /etc/mysql/conf.d/my_custom.cnf"
  log_info "Available files in /etc/mysql/conf.d/:"
  ls -la /etc/mysql/conf.d/ || log_info "Directory does not exist"
fi

# Ensure binary log directory exists with proper permissions
mkdir -p /var/lib/mysql/binlogs
chown -R mysql:mysql /var/lib/mysql/binlogs
chmod -R 750 /var/lib/mysql/binlogs

# Start MariaDB with explicit bind-address to override any defaults
exec mariadbd --user=mysql --datadir="$DATADIR" --bind-address=0.0.0.0