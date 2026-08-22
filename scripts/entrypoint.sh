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

log_info "Starte MariaDB-Initialisierung..."

# Check if required environment variables are set
if [ -z "$MARIADB_ROOT_PASSWORD" ]; then
  handle_error "MARIADB_ROOT_PASSWORD Umgebungsvariable ist nicht gesetzt!"
fi

# --- Galera cluster support ----------------------------------------------
GALERA_ENABLED="${GALERA_ENABLED:-no}"
WSREP_NEW_CLUSTER=""

if [ "$GALERA_ENABLED" = "yes" ]; then
  log_info "Galera-Modus ist aktiv (Node: ${GALERA_NODE_NAME:-unknown})"

  # Render the per-node Galera config from the template
  if [ -f "/etc/mysql/galera.cnf.template" ]; then
    GALERA_SST_METHOD="${GALERA_SST_METHOD:-mariabackup}"
    GALERA_GCACHE_SIZE="${GALERA_GCACHE_SIZE:-512M}"
    export GALERA_CLUSTER_NAME GALERA_CLUSTER_ADDRESS GALERA_NODE_NAME GALERA_NODE_ADDRESS GALERA_NODE_ID GALERA_SST_METHOD GALERA_GCACHE_SIZE MARIADB_ROOT_PASSWORD
    envsubst < /etc/mysql/galera.cnf.template > /etc/mysql/conf.d/zz-galera.cnf ||
      handle_error "Fehler beim Erstellen der Galera-Konfiguration."
    log_info "Galera-Konfiguration wurde unter /etc/mysql/conf.d/zz-galera.cnf gespeichert."
  else
    handle_error "Galera-Template nicht gefunden: /etc/mysql/galera.cnf.template"
  fi

  # A 'force_bootstrap' marker file in the datadir tells this node to start
  # a new cluster (first init or full-cluster recovery). One-shot: the
  # marker is consumed here so a normal restart joins the existing cluster.
  if [ -f "/var/lib/mysql/force_bootstrap" ]; then
    rm -f "/var/lib/mysql/force_bootstrap"
    WSREP_NEW_CLUSTER="--wsrep-new-cluster"
    log_warning "Bootstrap-Marker gefunden - diese Node startet einen NEUEN Cluster!"

    if [ -f "/var/lib/mysql/grastate.dat" ]; then
      sed -i 's/^safe_to_bootstrap: 0/safe_to_bootstrap: 1/' "/var/lib/mysql/grastate.dat"
    fi
  fi
fi

# --- Server-side TLS (optional) -------------------------------------------
# MySQL-protocol TLS is negotiated in-protocol (STARTTLS-style), so it must
# terminate at mariadbd itself - a TLS-terminating proxy cannot work.
# Certs are mounted root-owned; copy them readable for the mysql user.
if [ -f "/etc/mysql/tls/server-cert.pem" ] && [ -f "/etc/mysql/tls/server-key.pem" ]; then
  log_info "TLS-Zertifikate gefunden - serverseitiges TLS wird aktiviert."
  mkdir -p /etc/mysql/tls-runtime
  cp /etc/mysql/tls/server-cert.pem /etc/mysql/tls/server-key.pem /etc/mysql/tls-runtime/
  [ -f /etc/mysql/tls/ca.pem ] && cp /etc/mysql/tls/ca.pem /etc/mysql/tls-runtime/
  chown -R mysql:mysql /etc/mysql/tls-runtime
  chmod 500 /etc/mysql/tls-runtime
  chmod 400 /etc/mysql/tls-runtime/*
  {
    echo "[mysqld]"
    echo "ssl_cert = /etc/mysql/tls-runtime/server-cert.pem"
    echo "ssl_key = /etc/mysql/tls-runtime/server-key.pem"
    if [ -f /etc/mysql/tls-runtime/ca.pem ]; then
      echo "ssl_ca = /etc/mysql/tls-runtime/ca.pem"
    fi
  } > /etc/mysql/conf.d/zz-tls.cnf
fi

# --- Performance tuning (optional, via .env) -------------------------------
# Overrides the moderate defaults in my_custom.cnf without touching tracked
# files. Loaded last (zz-tuning), so these values win.
if [ -n "$DB_BUFFER_POOL_SIZE" ] || [ -n "$DB_LOG_FILE_SIZE" ] || [ -n "$DB_IO_CAPACITY" ] || [ -n "$DB_MAX_CONNECTIONS" ] || [ -n "$DB_TMP_TABLE_SIZE" ]; then
  log_info "Wende Performance-Tuning-Overrides aus der Umgebung an..."
  {
    echo "[mysqld]"
    if [ -n "$DB_BUFFER_POOL_SIZE" ]; then
      echo "innodb_buffer_pool_size = $DB_BUFFER_POOL_SIZE"
    fi
    if [ -n "$DB_LOG_FILE_SIZE" ]; then
      echo "innodb_log_file_size = $DB_LOG_FILE_SIZE"
    fi
    if [ -n "$DB_IO_CAPACITY" ]; then
      echo "innodb_io_capacity = $DB_IO_CAPACITY"
    fi
    if [ -n "$DB_MAX_CONNECTIONS" ]; then
      echo "max_connections = $DB_MAX_CONNECTIONS"
    fi
    if [ -n "$DB_TMP_TABLE_SIZE" ]; then
      echo "tmp_table_size = $DB_TMP_TABLE_SIZE"
      echo "max_heap_table_size = $DB_TMP_TABLE_SIZE"
    fi
  } > /etc/mysql/conf.d/zz-tuning.cnf
fi

# Create necessary directories
log_info "Erstelle Verzeichnisse..."
mkdir -p "$DATADIR" || handle_error "Fehler beim Erstellen des Datenverzeichnisses."
mkdir -p "$BINLOG_DIR" || handle_error "Fehler beim Erstellen des Binlog-Verzeichnisses." 
mkdir -p "$TMP_DIR" || handle_error "Fehler beim Erstellen des temporären Binlog-Verzeichnisses."
mkdir -p "/run/mysqld" || handle_error "Fehler beim Erstellen des mysqld Socket-Verzeichnisses."

# Set proper permissions
chown -R mysql:mysql "$DATADIR" "$BINLOG_DIR" "$TMP_DIR" "/run/mysqld" || handle_error "Fehler beim Setzen der Verzeichnis-Berechtigungen."
chmod 700 "$DATADIR" "$BINLOG_DIR"
chmod 755 "/run/mysqld"

# Initialize database if it doesn't exist
if [ ! -d "$DATADIR/mysql" ]; then
  log_info "Initialisiere MariaDB-Datenbank im Datenverzeichnis: $DATADIR"

  # Initialize database with proper settings
  log_info "Führe mariadb-install-db aus..."
  mariadb-install-db --user=mysql --datadir="$DATADIR" --basedir=/usr --skip-test-db --verbose || {
    log_info "mariadb-install-db fehlgeschlagen, versuche alternative Methode..."
    # Try alternative initialization method
    mariadbd --initialize-insecure --user=mysql --datadir="$DATADIR" --basedir=/usr || handle_error "Fehler beim Initialisieren der Datenbank mit beiden Methoden!"
  }

  # Joiner nodes get all data via state transfer (SST) from the cluster,
  # so the SQL initialization below only runs on standalone or bootstrap nodes.
  # SKIP_PROVISION=yes skips it too (used by restore_test.sh for throwaway
  # instances that only need a bare server with socket root access).
  if [ "$SKIP_PROVISION" = "yes" ]; then
    log_info "SKIP_PROVISION=yes: SQL-Initialisierung übersprungen (Bare-Instanz)."
  elif [ "$GALERA_ENABLED" = "yes" ] && [ -z "$WSREP_NEW_CLUSTER" ]; then
    log_info "Galera Joiner Node: SQL-Initialisierung übersprungen (Daten kommen via SST)."
  else

  log_info "Starte MariaDB temporär über Unix-Socket für die Initialisierung..."
  mariadbd --user=mysql --datadir="$DATADIR" --socket=/run/mysqld/mysqld.sock --skip-networking --wsrep-on=OFF --pid-file=/run/mysqld/mysqld.pid &
  pid=$!

  # Wait for MariaDB to become available
  log_info "Warte auf den MariaDB Socket..."
  for i in {1..60}; do
    if [ -S /run/mysqld/mysqld.sock ]; then
      log_info "Socket gefunden: /run/mysqld/mysqld.sock"
      break
    fi
    sleep 1
    if [ "$i" = 60 ]; then
      log_info "Socket nicht gefunden, suche an alternativen Speicherorten..."
      find /var /run /tmp -name "*.sock" 2>/dev/null | head -10
      handle_error "Timeout: MariaDB Socket wurde nicht rechtzeitig erstellt!"
    fi
  done

  # Wait for MariaDB to respond to ping
  for i in {1..60}; do
    if mariadb-admin --protocol=socket --socket=/run/mysqld/mysqld.sock ping --silent > /dev/null 2>&1; then
      break
    fi
    sleep 1
    if [ "$i" = 60 ]; then
      handle_error "Timeout: MariaDB antwortet nicht."
    fi
  done
  log_success "MariaDB erfolgreich gestartet!"

  # Create databases and users for external access
  log_info "Erstelle Datenbanken und Benutzer für den externen Zugriff..."

  # Remote root is convenient but a large attack surface -
  # disable with MARIADB_ROOT_REMOTE=no (admin then via 'docker exec' only)
  ROOT_REMOTE_SQL=""
  if [ "${MARIADB_ROOT_REMOTE:-yes}" = "yes" ]; then
    ROOT_REMOTE_SQL="CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '$MARIADB_ROOT_PASSWORD';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
GRANT RELOAD, REPLICATION CLIENT, BINLOG MONITOR, BINLOG REPLAY ON *.* TO 'root'@'%';"
  else
    log_info "MARIADB_ROOT_REMOTE=no - Der root-Benutzer ist nur noch innerhalb des Containers erreichbar."
  fi

  mariadb --protocol=socket --socket=/run/mysqld/mysqld.sock -u root <<EOF
-- Create databases first
CREATE DATABASE IF NOT EXISTS \`$MARIADB_DATABASE1\`;
CREATE DATABASE IF NOT EXISTS \`$MARIADB_DATABASE2\`;
CREATE DATABASE IF NOT EXISTS \`$MARIADB_DATABASE3\`;
CREATE DATABASE IF NOT EXISTS \`$MARIADB_DATABASE4\`;
CREATE DATABASE IF NOT EXISTS \`$MARIADB_DATABASE5\`;

-- Keep root@localhost without password for backup scripts
-- Remote root access (optional, see MARIADB_ROOT_REMOTE)
$ROOT_REMOTE_SQL

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

-- Passwordless check user for HAProxy health checks (no privileges granted)
CREATE USER IF NOT EXISTS 'haproxy_check'@'%';

-- SST user for Galera state transfers (mariabackup on the donor connects
-- with password auth; root@localhost uses unix_socket which the SST
-- script - running as the mysql user - cannot pass)
CREATE USER IF NOT EXISTS 'sst_user'@'localhost' IDENTIFIED BY '$MARIADB_ROOT_PASSWORD';
GRANT RELOAD, PROCESS, LOCK TABLES, BINLOG MONITOR ON *.* TO 'sst_user'@'localhost';

FLUSH PRIVILEGES;
EOF

  if [ $? -eq 0 ]; then
    log_success "Datenbanken und Benutzer erfolgreich angelegt!"
  else
    handle_error "Fehler beim Erstellen der Datenbanken und Benutzer!"
  fi

  # Verify databases were created (password via env, not process list)
  log_info "Überprüfe erstellte Datenbanken:"
  MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb --protocol=socket --socket=/run/mysqld/mysqld.sock -u root -e "SHOW DATABASES;" | grep -E "^($MARIADB_DATABASE1|$MARIADB_DATABASE2|$MARIADB_DATABASE3|$MARIADB_DATABASE4|$MARIADB_DATABASE5)$"

  log_info "Überprüfe erstellte Benutzer:"
  MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb --protocol=socket --socket=/run/mysqld/mysqld.sock -u root -e "SELECT User, Host FROM mysql.user WHERE User NOT IN ('', 'mysql.sys', 'mysql.session', 'mysql.infoschema') ORDER BY User, Host;"

  # Stop the temporary MariaDB instance
  log_info "Stoppe die temporäre MariaDB-Instanz..."
  kill "$pid"
  wait "$pid" 2>/dev/null || true

  fi

else
  log_info "MariaDB-Datenverzeichnis existiert bereits, Initialisierung wird übersprungen."
fi

log_info "Starte MariaDB-Server (Netzwerk aktiviert)..."

# Verify configuration file exists
if [ -f "/etc/mysql/conf.d/my_custom.cnf" ]; then
  log_info "Konfigurationsdatei gefunden: /etc/mysql/conf.d/my_custom.cnf"
  log_info "Vorschau der Konfigurationsdatei:"
  head -10 "/etc/mysql/conf.d/my_custom.cnf" | while read line; do
    log_info "  $line"
  done
else
  log_warning "Konfigurationsdatei wurde nicht gefunden unter /etc/mysql/conf.d/my_custom.cnf"
  log_info "Vorhandene Dateien in /etc/mysql/conf.d/:"
  ls -la /etc/mysql/conf.d/ || log_info "Verzeichnis existiert nicht"
fi

# Ensure binary log directory exists with proper permissions
mkdir -p /var/lib/mysql/binlogs
chown -R mysql:mysql /var/lib/mysql/binlogs
chmod -R 750 /var/lib/mysql/binlogs

# Start MariaDB with explicit bind-address to override any defaults
if [ -n "$WSREP_NEW_CLUSTER" ]; then
  log_warning "Starte MariaDB als Bootstrap-Node für einen neuen Galera-Cluster!"
fi
exec mariadbd --user=mysql --datadir="$DATADIR" --bind-address=0.0.0.0 $WSREP_NEW_CLUSTER