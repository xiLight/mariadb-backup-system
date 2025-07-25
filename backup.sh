#!/bin/bash
cd "$(dirname "$0")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Version
BACKUP_VERSION="1.0.0"

# Set default values
BACKUP_DIR="./backups"
BINLOG_BACKUP_DIR="$BACKUP_DIR/binlogs"
BINLOG_INFO_DIR="$BACKUP_DIR/binlog_info"
LOG_FILE="./logs/backup.log"
CHECKSUM_DIR="$BACKUP_DIR/checksums"
INCR_INFO_DIR="$BACKUP_DIR/incr"

# Create logs directory if it doesn't exist
mkdir -p "./logs"

# Error handling function
function handle_error {
  local exit_code=$1
  local error_msg=$2
  log_error "$error_msg (exit code: $exit_code)"
  exit $exit_code
}

# Logging functions with timestamps
log_info() {
  local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  echo -e "${BLUE}[$timestamp] [INFO] $1${NC}" | tee -a "$LOG_FILE"
}

log_success() {
  local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  echo -e "${GREEN}[$timestamp] [SUCCESS] $1${NC}" | tee -a "$LOG_FILE"
}

log_warning() {
  local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  echo -e "${YELLOW}[$timestamp] [WARNING] $1${NC}" | tee -a "$LOG_FILE"
}

log_error() {
  local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  echo -e "${RED}[$timestamp] [ERROR] $1${NC}" | tee -a "$LOG_FILE"
}

# Source environment variables
source .env || handle_error 1 "Failed to source .env file"

# Override variables with values from .env if they exist
[[ -n "$BACKUP_DIR" ]] && BACKUP_DIR="$BACKUP_DIR"
[[ -n "$BINLOG_DIR" ]] && BINLOG_BACKUP_DIR="$BINLOG_DIR"
[[ -n "$MARIADB_CONTAINER" ]] && MARIADB_CONTAINER="$MARIADB_CONTAINER"

# Parse arguments for --key and --include-empty BEFORE database detection
ENCRYPT_KEY_FILE=".backup_encryption_key"
INCLUDE_EMPTY_DBS=false
NEW_ARGS=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --key)
      ENCRYPT_KEY_FILE="$2"
      shift 2
      ;;
    --include-empty)
      INCLUDE_EMPTY_DBS=true
      shift
      ;;
    *)
      NEW_ARGS+=("$1")
      shift
      ;;
  esac
done
set -- "${NEW_ARGS[@]}"

# Function to get all databases from MariaDB server
get_all_databases() {
  # Query all databases excluding system databases
  DATABASES=$(docker exec "$MARIADB_CONTAINER" mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -N -e "SHOW DATABASES;" | grep -v -E "^(information_schema|performance_schema|mysql|sys)$" 2>/dev/null)
  echo "$DATABASES"
}

# Ensure backup directories exist
mkdir -p "$BACKUP_DIR" || handle_error 2 "Failed to create backup directory"
mkdir -p "$BINLOG_BACKUP_DIR" || handle_error 2 "Failed to create binlog backup directory"
mkdir -p "$CHECKSUM_DIR" || handle_error 2 "Failed to create checksum directory"
mkdir -p "$INCR_INFO_DIR" || handle_error 2 "Failed to create incremental info directory"
mkdir -p "$BINLOG_INFO_DIR" || handle_error 2 "Failed to create binlog info directory"

TIMESTAMP=$(date +'%Y-%m-%d_%H-%M-%S')

# Function to create a checksum file for a backup
create_checksum() {
  local file="$1"
  local checksum_file="$CHECKSUM_DIR/$(basename "$file").sha256"
  
  if command -v sha256sum &> /dev/null; then
    sha256sum "$file" | awk '{print $1}' > "$checksum_file"
  else
    # Fallback for systems without sha256sum
    openssl dgst -sha256 "$file" | sed 's/^.* //' > "$checksum_file"
  fi
  
  log_info "Created checksum for $file"
}

# Function to verify a checksum
verify_checksum() {
  local file="$1"
  local checksum_file="$CHECKSUM_DIR/$(basename "$file").sha256"
  
  if [ ! -f "$checksum_file" ]; then
    log_error "Checksum file not found for $file"
    return 1
  fi
  
  local expected_checksum=$(cat "$checksum_file")
  local actual_checksum
  
  if command -v sha256sum &> /dev/null; then
    actual_checksum=$(sha256sum "$file" | awk '{print $1}')
  else
    # Fallback for systems without sha256sum
    actual_checksum=$(openssl dgst -sha256 "$file" | sed 's/^.* //')
  fi
  
  if [ "$actual_checksum" = "$expected_checksum" ]; then
    log_info "Checksum verified for $file"
    return 0
  else
    log_error "Checksum verification failed for $file"
    return 1
  fi
}

# Get all database names from MariaDB server or fallback to .env
DBS=()

# Try to get databases from server first
DB_LIST=$(get_all_databases)
if [[ -n "$DB_LIST" ]]; then
  log_info "Raw database list from server: $DB_LIST"
  # Convert to array for debugging
  readarray -t DB_ARRAY <<< "$DB_LIST"
  log_info "Total databases found: ${#DB_ARRAY[@]}"
  
  # Read the databases into the array, checking for tables unless --include-empty is specified
  db_count=0
  while IFS= read -r line; do
    db_count=$((db_count + 1))
    # Skip empty lines
    if [[ -z "$line" ]]; then
      log_info "DEBUG: Skipping empty line at position $db_count"
      continue
    fi
    
    log_info "Processing database $db_count: '$line'"
    
    # Skip the special 'binlogs' database as it cannot be backed up with mysqldump
    if [[ "$line" == "binlogs" ]]; then
      log_warning "Skipping 'binlogs' database - this is a special MariaDB system database that cannot be backed up"
      continue
    fi
    
    # Check if database has any tables
    log_info "DEBUG: Checking table count for database '$line'..."
    TABLE_COUNT=$(docker exec "$MARIADB_CONTAINER" mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$line';" 2>/dev/null || echo "0")
    log_info "DEBUG: Table count for '$line': $TABLE_COUNT"
    
    if [[ "$TABLE_COUNT" -gt 0 ]]; then
      DBS+=("$line")
      log_info "Database $line has $TABLE_COUNT tables - will be backed up"
    elif [[ "$INCLUDE_EMPTY_DBS" == true ]]; then
      DBS+=("$line")
      log_info "Database $line is empty (0 tables) - backing up anyway due to --include-empty flag"
    else
      log_warning "Database $line is empty (0 tables) - skipping backup"
    fi
    
    log_info "DEBUG: Finished processing database '$line', continuing to next..."
  done <<< "$DB_LIST"
  
  log_info "DEBUG: Finished processing all databases. Total processed: $db_count"
  log_info "Automatically detected databases from server: ${DBS[*]}"
else
  # Fallback to .env file if server query fails
  log_warning "Could not detect databases from server, falling back to .env file"
  for i in {1..5}; do
    VAR="MARIADB_DATABASE${i}"
    DB_NAME="${!VAR}"
    if [[ -n "$DB_NAME" ]]; then
      # Check if this database exists and has tables
      TABLE_COUNT=$(docker exec "$MARIADB_CONTAINER" mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB_NAME';" 2>/dev/null || echo "0")
      if [[ "$TABLE_COUNT" -gt 0 ]]; then
        DBS+=("$DB_NAME")
        log_info "Database $DB_NAME has $TABLE_COUNT tables - will be backed up"
      elif [[ "$INCLUDE_EMPTY_DBS" == true ]]; then
        DBS+=("$DB_NAME")
        log_info "Database $DB_NAME is empty (0 tables) - backing up anyway due to --include-empty flag"
      else
        log_warning "Database $DB_NAME is empty (0 tables) - skipping backup"
      fi
    fi
  done
fi

log_info "Starting backup process (version $BACKUP_VERSION)"
log_info "Found ${#DBS[@]} databases to backup: ${DBS[*]}"

# Ensure each database exists before backing up
for DB in "${DBS[@]}"; do
  docker exec -i "$MARIADB_CONTAINER" mariadb -e "CREATE DATABASE IF NOT EXISTS $DB;" || log_warning "Failed to create database $DB - may already exist"
done

# Process databases in parallel for full backups
backup_database() {
  local DB=$1
  local FULL_BACKUP=$2
  local FULL_BACKUP_FILE="$BACKUP_DIR/${DB}_full_${TIMESTAMP}.sql"
  local BINLOG_INFO_FILE="$BINLOG_INFO_DIR/last_binlog_info_${DB}_${TIMESTAMP}.txt"

  log_info "Creating Full Backup for DB: $DB => $FULL_BACKUP_FILE"

  # Check if mysqldump works inside the container
  MYSQLDUMP_CMD=""
  if docker exec "$MARIADB_CONTAINER" which mysqldump &>/dev/null; then
    MYSQLDUMP_CMD="mysqldump"
    log_info "Using mysqldump for backup"
  elif docker exec "$MARIADB_CONTAINER" which mariadb-dump &>/dev/null; then
    MYSQLDUMP_CMD="mariadb-dump"
    log_info "Using mariadb-dump for backup (mysqldump not found)"
  else
    # Try to find mysqldump in common locations
    MYSQLDUMP_PATH=$(docker exec "$MARIADB_CONTAINER" find / -name mysqldump 2>/dev/null | head -n1)
    if [[ -n "$MYSQLDUMP_PATH" ]]; then
      MYSQLDUMP_CMD="$MYSQLDUMP_PATH"
      log_info "Using mysqldump from: $MYSQLDUMP_PATH"
    else
      MYSQLDUMP_PATH=$(docker exec "$MARIADB_CONTAINER" find / -name mariadb-dump 2>/dev/null | head -n1)
      if [[ -n "$MYSQLDUMP_PATH" ]]; then
        MYSQLDUMP_CMD="$MYSQLDUMP_PATH"
        log_info "Using mariadb-dump from: $MYSQLDUMP_PATH"
      else
        log_error "Neither mysqldump nor mariadb-dump found in container!"
        return 1
      fi
    fi
  fi

  # Test the connection first
  log_info "Testing database connection for $DB..."
  if ! docker exec "$MARIADB_CONTAINER" mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -e "USE $DB; SELECT 1;" >/dev/null 2>&1; then
    log_error "Cannot connect to database $DB or database does not exist"
    return 1
  fi

  # Dump with Binlog-Info in header (try with --master-data first, fallback without)
  log_info "Attempting backup with binary log information..."
  DUMP_ERROR_FILE="/tmp/dump_error_${DB}_$$.log"
  if docker exec "$MARIADB_CONTAINER" $MYSQLDUMP_CMD --single-transaction --master-data=2 -u root -p"$MARIADB_ROOT_PASSWORD" "$DB" > "$FULL_BACKUP_FILE" 2>"$DUMP_ERROR_FILE"; then
    log_success "Full Backup for $DB successfully created with binary log information"
  elif docker exec "$MARIADB_CONTAINER" $MYSQLDUMP_CMD --single-transaction -u root -p"$MARIADB_ROOT_PASSWORD" "$DB" > "$FULL_BACKUP_FILE" 2>"$DUMP_ERROR_FILE"; then
    log_success "Full Backup for $DB successfully created (without binary log information)"
    log_warning "Binary log information not available - incremental backups may not work"
  else
    log_error "Error creating Full Backup for $DB!"
    if [[ -f "$DUMP_ERROR_FILE" ]]; then
      log_error "Dump error details: $(cat "$DUMP_ERROR_FILE" 2>/dev/null || echo 'Could not read error file')"
      rm -f "$DUMP_ERROR_FILE"
    fi
    return 1
  fi
  
  # Clean up error file if backup was successful
  rm -f "$DUMP_ERROR_FILE"

  # Extract Binlog-Info from dump (if available)
  MASTER_LINE=$(grep -m1 '^-- CHANGE MASTER TO' "$FULL_BACKUP_FILE" 2>/dev/null || echo "")
  if [[ -n "$MASTER_LINE" ]]; then
    BINLOG=$(echo "$MASTER_LINE" | sed -n "s/.*MASTER_LOG_FILE='\\([^']*\\)'.*/\\1/p")
    POS=$(echo "$MASTER_LINE" | sed -n "s/.*MASTER_LOG_POS=\\([0-9]*\\).*/\\1/p")
    if [[ -n "$BINLOG" && -n "$POS" ]]; then
      echo "$BINLOG $POS" > "$BINLOG_INFO_FILE"
      log_info "Binlog-Info saved: $BINLOG_INFO_FILE ($BINLOG at position $POS)"
    else
      log_warning "Could not extract valid binlog information from backup"
      echo "unknown 0" > "$BINLOG_INFO_FILE"
    fi
  else
    log_warning "No binlog information found in backup (binary logging may not be enabled)"
    echo "unknown 0" > "$BINLOG_INFO_FILE"
  fi

  # Compress backup with progress indicator
  log_info "Compressing backup file for $DB..."
  if command -v pv &> /dev/null; then
    # Use pv for progress indication if available
    pv "$FULL_BACKUP_FILE" | gzip > "$FULL_BACKUP_FILE.gz"
  else
    gzip -f "$FULL_BACKUP_FILE"
  fi
  
  # Encrypt if safety mode is enabled
  log_info "Encrypting backup file for $DB (Encryption always enabled)..."
  ./encrypt_backup.sh --encrypt "$FULL_BACKUP_FILE.gz" --key ".backup_encryption_key" || handle_error 10 "Error encrypting $FULL_BACKUP_FILE.gz"
  rm -f "$FULL_BACKUP_FILE.gz"
  log_success "Backup for $DB encrypted successfully."
  
  # Create checksum for compressed file
  create_checksum "$FULL_BACKUP_FILE.gz.enc"
  
  # Cleanup uncompressed file
  rm -f "$FULL_BACKUP_FILE"
  
  log_success "Full backup for $DB completed"
}

if [ "$1" == "--full" ]; then
  log_info "Checking and preparing binary log system..."
  
  # Check if binary logging is enabled
  BINLOG_ENABLED=$(docker exec "$MARIADB_CONTAINER" mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -N -e "SELECT @@log_bin;" 2>/dev/null || echo "0")
  
  if [[ "$BINLOG_ENABLED" == "1" ]]; then
    log_info "Binary logging is enabled, preparing directories..."
    
    # Get the actual binlog path from configuration
    BINLOG_BASE=$(docker exec "$MARIADB_CONTAINER" mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -N -e "SELECT @@log_bin_basename;" 2>/dev/null || echo "")
    
    if [[ -n "$BINLOG_BASE" ]]; then
      BINLOG_DIR_PATH=$(dirname "$BINLOG_BASE")
      log_info "Binary log directory: $BINLOG_DIR_PATH"
      
      # Create binlog directory if it doesn't exist
      docker exec "$MARIADB_CONTAINER" mkdir -p "$BINLOG_DIR_PATH" || log_warning "Could not create binlog directory"
      docker exec "$MARIADB_CONTAINER" chown mysql:mysql "$BINLOG_DIR_PATH" 2>/dev/null || log_warning "Could not set binlog directory permissions"
      
      # Try to flush binary logs
      log_info "Forcing binlog rotation (FLUSH BINARY LOGS)..."
      if docker exec "$MARIADB_CONTAINER" mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -e "FLUSH BINARY LOGS;" 2>/dev/null; then
        log_success "Binary logs flushed successfully"
      else
        log_warning "Failed to flush binary logs - continuing with backup anyway"
      fi
    else
      log_warning "Could not determine binary log path - skipping binlog flush"
    fi
  else
    log_warning "Binary logging is not enabled - backups will not include binary log information"
  fi

  # Start parallel backups if parallel command is available
  if command -v parallel &> /dev/null; then
    log_info "Using parallel processing for database backups"
    # Export functions and variables needed by the parallel processes
    export -f backup_database log_info log_success log_error log_warning create_checksum
    export BACKUP_DIR TIMESTAMP MARIADB_CONTAINER CHECKSUM_DIR MARIADB_ROOT_PASSWORD
    
    # Run backups in parallel with a max of 3 concurrent jobs
    printf "%s\n" "${DBS[@]}" | parallel -j 3 "backup_database {} true"
  else
    log_info "Parallel command not available, running backups sequentially"
    for DB in "${DBS[@]}"; do
      backup_database "$DB" true
    done
  fi
else
  log_info "Incremental backup: saving only new binlogs"
  
  # Check if binary logging is enabled before attempting incremental backup
  BINLOG_ENABLED=$(docker exec "$MARIADB_CONTAINER" mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -N -e "SELECT @@log_bin;" 2>/dev/null || echo "0")
  
  if [[ "$BINLOG_ENABLED" == "1" ]]; then
    if docker exec "$MARIADB_CONTAINER" mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -e "FLUSH BINARY LOGS;" 2>/dev/null; then
      log_success "Binary logs flushed for incremental backup"
    else
      log_warning "Failed to flush binary logs for incremental backup - continuing anyway"
    fi

    for DB in "${DBS[@]}"; do
      # Save binlog info after incremental backup
      BINLOG_STATUS=$(docker exec "$MARIADB_CONTAINER" mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -e "SHOW MASTER STATUS;" 2>/dev/null | tail -n1)
      if [[ -n "$BINLOG_STATUS" && "$BINLOG_STATUS" != "Variable_name" ]]; then
        CURRENT_BINLOG=$(echo "$BINLOG_STATUS" | awk '{print $1}')
        CURRENT_POS=$(echo "$BINLOG_STATUS" | awk '{print $2}')
        if [[ -n "$CURRENT_BINLOG" && -n "$CURRENT_POS" ]]; then
          INCR_INFO_FILE="$INCR_INFO_DIR/last_binlog_info_${DB}_${TIMESTAMP}_incr.txt"
          echo "$CURRENT_BINLOG $CURRENT_POS" > "$INCR_INFO_FILE"
          log_success "Binlog-Info after incremental backup saved: $INCR_INFO_FILE"
        else
          log_warning "Could not get valid binlog position for $DB"
        fi
      else
        log_warning "Could not get master status for $DB"
      fi
    done
  else
    log_warning "Binary logging is not enabled - incremental backup not possible"
  fi
fi

log_info "Backing up completed binlog files..."

# Create temp directory for binlog operations
docker exec "$MARIADB_CONTAINER" mkdir -p /tmp/binlogs 2>/dev/null || log_warning "Could not create temp binlog directory"

# Get binlog list (only if binary logging is enabled)
BINLOG_LIST=$(docker exec "$MARIADB_CONTAINER" mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -e "SHOW BINARY LOGS;" 2>/dev/null | awk 'NR>1 {print $1}' || echo "")

if [[ -z "$BINLOG_LIST" ]]; then
  log_warning "No binary logs found or binary logging is not enabled"
else
  LAST_BINLOG=$(echo "$BINLOG_LIST" | tail -n1)
  log_info "Found binary logs to backup: $(echo "$BINLOG_LIST" | wc -l) files"

  # Get binlog directory from container
  CONTAINER_BINLOG_DIR=$(docker exec "$MARIADB_CONTAINER" mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -N -e "SELECT @@log_bin_basename;" 2>/dev/null | sed 's/mysql-bin$//' || echo "/var/lib/mysql/")

  for BINLOG in $BINLOG_LIST; do
    if [[ "$BINLOG" == "$LAST_BINLOG" ]]; then
      log_warning "Skipping $BINLOG (currently open, not backing up)"
      continue
    fi
    BACKUP_BINLOG="$BINLOG_BACKUP_DIR/$BINLOG"
    if [[ -f "$BACKUP_BINLOG" ]]; then
      log_warning "Skipping $BINLOG (already backed up)"
      continue
    fi
    log_info "Copying $BINLOG from container..."
    
    # Try multiple potential paths for binlog files
    BACKUP_SUCCESS=false
    
    # Try the configured binlog path first
    if docker cp "$MARIADB_CONTAINER:$CONTAINER_BINLOG_DIR/$BINLOG" "$BACKUP_BINLOG" 2>/dev/null; then
      BACKUP_SUCCESS=true
    # Try common default paths
    elif docker cp "$MARIADB_CONTAINER:/var/lib/mysql/binlogs/$BINLOG" "$BACKUP_BINLOG" 2>/dev/null; then
      BACKUP_SUCCESS=true
    elif docker cp "$MARIADB_CONTAINER:/var/lib/mysql/$BINLOG" "$BACKUP_BINLOG" 2>/dev/null; then
      BACKUP_SUCCESS=true
    # Try to find the binlog file anywhere in the container
    else
      BINLOG_LOCATION=$(docker exec "$MARIADB_CONTAINER" find /var/lib/mysql -name "$BINLOG" 2>/dev/null | head -n1)
      if [[ -n "$BINLOG_LOCATION" ]] && docker cp "$MARIADB_CONTAINER:$BINLOG_LOCATION" "$BACKUP_BINLOG" 2>/dev/null; then
        BACKUP_SUCCESS=true
      fi
    fi
    
        if [[ "$BACKUP_SUCCESS" == "true" ]]; then
      log_success "$BINLOG successfully backed up"
      # Create checksum for binlog file
      create_checksum "$BACKUP_BINLOG"
    else
      log_warning "Could not backup $BINLOG - file not found in container"
      # Try to locate binlog files for debugging
      BINLOG_FILES=$(docker exec "$MARIADB_CONTAINER" find /var/lib/mysql -name "mysql-bin.*" -o -name "mariadb-bin.*" 2>/dev/null | head -5)
      if [[ -n "$BINLOG_FILES" ]]; then
        log_info "Available binlog files in container: $(echo "$BINLOG_FILES" | tr '\n' ' ')"
      else
        log_warning "No binlog files found in container"
      fi
    fi
  done
fi

log_success "Backup completed successfully."
