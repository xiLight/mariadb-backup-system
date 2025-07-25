#!/bin/bash
cd "$(dirname "$0")"

# Load logging functions
source "./lib/logging.sh"

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
  shift
  local error_msg="$*"
  log_error "$error_msg (exit code: $exit_code)"
  log_both "ERROR" "$error_msg (exit code: $exit_code)" "$LOG_FILE"
  exit $exit_code
}

# Source environment variables
source .env || handle_error 1 "Failed to source .env file"

# Override variables with values from .env if they exist
[[ -n "$BACKUP_DIR" ]] && BACKUP_DIR="$BACKUP_DIR"
[[ -n "$BINLOG_DIR" ]] && BINLOG_BACKUP_DIR="$BINLOG_DIR"
[[ -n "$MARIADB_CONTAINER" ]] && MARIADB_CONTAINER="$MARIADB_CONTAINER"

# Parse arguments for --key and --include-empty BEFORE database detection
ENCRYPT_KEY_FILE=".backup_encryption_key"
INCLUDE_EMPTY_DATABASES=false
BACKUP_MODE="full"
SPECIFIC_DATABASE=""
COMPRESS_BACKUPS=true
CREATE_CHECKSUMS=true

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --full)
      BACKUP_MODE="full"
      shift
      ;;
    --incremental)
      BACKUP_MODE="incremental"
      shift
      ;;
    --database)
      SPECIFIC_DATABASE="$2"
      shift 2
      ;;
    --include-empty)
      INCLUDE_EMPTY_DATABASES=true
      shift
      ;;
    --key)
      ENCRYPT_KEY_FILE="$2"
      shift 2
      ;;
    --no-compress)
      COMPRESS_BACKUPS=false
      shift
      ;;
    --no-checksums)
      CREATE_CHECKSUMS=false
      shift
      ;;
    --help)
      echo "MariaDB Backup Script v$BACKUP_VERSION"
      echo ""
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Backup modes:"
      echo "  --full                 Create full backup (default)"
      echo "  --incremental          Create incremental backup"
      echo ""
      echo "Options:"
      echo "  --database DB          Backup specific database only"
      echo "  --include-empty        Include databases with no tables"
      echo "  --key FILE             Specify encryption key file (default: .backup_encryption_key)"
      echo "  --no-compress          Don't compress backup files"
      echo "  --no-checksums         Don't create checksum files"
      echo "  --help                 Show this help message"
      echo ""
      echo "Environment variables (from .env):"
      echo "  MARIADB_CONTAINER      MariaDB container name"
      echo "  MARIADB_ROOT_PASSWORD  MariaDB root password"
      echo "  BACKUP_DIR             Backup directory"
      echo "  BINLOG_DIR             Binary log backup directory"
      echo ""
      exit 0
      ;;
    *)
      handle_error 2 "Unknown option: $1"
      ;;
  esac
done

# Start timing and logging
BACKUP_START_TIME=$(date +%s)
BACKUP_START_DATE=$(date '+%Y-%m-%d %H:%M:%S')

log_info "Starting backup process (version $BACKUP_VERSION) at $BACKUP_START_DATE"
log_both "INFO" "Starting backup process (version $BACKUP_VERSION) at $BACKUP_START_DATE" "$LOG_FILE"
log_info "Backup mode: $BACKUP_MODE"
log_both "INFO" "Backup mode: $BACKUP_MODE" "$LOG_FILE"

# Create necessary directories
for dir in "$BACKUP_DIR" "$BINLOG_BACKUP_DIR" "$BINLOG_INFO_DIR" "$CHECKSUM_DIR" "$INCR_INFO_DIR"; do
  mkdir -p "$dir" || handle_error 3 "Failed to create directory: $dir"
done

# Generate timestamp for this backup session
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Check if encryption key exists, create if not
if [[ ! -f "$ENCRYPT_KEY_FILE" ]]; then
  log_warning "Encryption key not found, generating new one: $ENCRYPT_KEY_FILE"
  log_both "WARNING" "Generating new encryption key: $ENCRYPT_KEY_FILE" "$LOG_FILE"
  openssl rand -base64 32 > "$ENCRYPT_KEY_FILE" || handle_error 4 "Failed to generate encryption key"
  chmod 600 "$ENCRYPT_KEY_FILE"
  log_warning "New encryption key created. KEEP THIS SAFE!"
  log_both "WARNING" "New encryption key created at $ENCRYPT_KEY_FILE" "$LOG_FILE"
fi

# Test database connection
log_info "Testing database connection..."
log_info "Container: $MARIADB_CONTAINER"
log_info "Password length: ${#MARIADB_ROOT_PASSWORD} characters"

# Try multiple connection methods
CONNECTION_SUCCESS=false

# Method 1: Try without host/port (socket connection)
if docker exec "$MARIADB_CONTAINER" mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -e "SELECT 1;" &>/dev/null; then
  log_success "Database connection successful (socket)"
  CONNECTION_SUCCESS=true
  CONNECTION_METHOD="socket"
elif docker exec "$MARIADB_CONTAINER" mariadb -u root -e "SELECT 1;" &>/dev/null; then
  log_success "Database connection successful (socket, no password)"
  CONNECTION_SUCCESS=true
  CONNECTION_METHOD="socket_nopass"
elif docker exec "$MARIADB_CONTAINER" mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -h 127.0.0.1 -P 3306 -e "SELECT 1;" &>/dev/null; then
  log_success "Database connection successful (TCP)"
  CONNECTION_SUCCESS=true
  CONNECTION_METHOD="tcp"
fi

if [[ "$CONNECTION_SUCCESS" != "true" ]]; then
  log_error "All connection methods failed"
  handle_error 5 "Cannot connect to MariaDB container: $MARIADB_CONTAINER"
fi

# Function to execute MariaDB commands with the working connection method
execute_mariadb_command() {
  local command="$1"
  case "$CONNECTION_METHOD" in
    "socket")
      docker exec "$MARIADB_CONTAINER" mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -e "$command"
      ;;
    "socket_nopass")
      docker exec "$MARIADB_CONTAINER" mariadb -u root -e "$command"
      ;;
    "tcp")
      docker exec "$MARIADB_CONTAINER" mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -h 127.0.0.1 -P 3306 -e "$command"
      ;;
    *)
      return 1
      ;;
  esac
}

# Function to execute MariaDB dump with the working connection method
execute_mariadb_dump() {
  local database="$1"
  local output_file="$2"
  
  # First try with binary log features
  log_info "Attempting backup with binary log features..."
  case "$CONNECTION_METHOD" in
    "socket")
      if docker exec "$MARIADB_CONTAINER" mariadb-dump \
        -u root -p"$MARIADB_ROOT_PASSWORD" \
        --lock-tables \
        --routines \
        --triggers \
        --master-data=2 \
        --flush-logs \
        --databases "$database" > "$output_file" 2>/dev/null; then
        log_success "Backup created with binary log features"
        return 0
      fi
      ;;
    "socket_nopass")
      if docker exec "$MARIADB_CONTAINER" mariadb-dump \
        -u root \
        --lock-tables \
        --routines \
        --triggers \
        --master-data=2 \
        --flush-logs \
        --databases "$database" > "$output_file" 2>/dev/null; then
        log_success "Backup created with binary log features"
        return 0
      fi
      ;;
    "tcp")
      if docker exec "$MARIADB_CONTAINER" mariadb-dump \
        -u root -p"$MARIADB_ROOT_PASSWORD" \
        -h 127.0.0.1 \
        -P 3306 \
        --lock-tables \
        --routines \
        --triggers \
        --master-data=2 \
        --flush-logs \
        --databases "$database" > "$output_file" 2>/dev/null; then
        log_success "Backup created with binary log features"
        return 0
      fi
      ;;
  esac
  
  # If that fails, try without binary log features
  log_warning "Binary log features failed, trying fallback method..."
  case "$CONNECTION_METHOD" in
    "socket")
      docker exec "$MARIADB_CONTAINER" mariadb-dump \
        -u root -p"$MARIADB_ROOT_PASSWORD" \
        --lock-tables \
        --routines \
        --triggers \
        --databases "$database" > "$output_file"
      ;;
    "socket_nopass")
      docker exec "$MARIADB_CONTAINER" mariadb-dump \
        -u root \
        --lock-tables \
        --routines \
        --triggers \
        --databases "$database" > "$output_file"
      ;;
    "tcp")
      docker exec "$MARIADB_CONTAINER" mariadb-dump \
        -u root -p"$MARIADB_ROOT_PASSWORD" \
        -h 127.0.0.1 \
        -P 3306 \
        --lock-tables \
        --routines \
        --triggers \
        --databases "$database" > "$output_file"
      ;;
    *)
      return 1
      ;;
  esac
}

# Get list of databases
if [[ -n "$SPECIFIC_DATABASE" ]]; then
  # Verify specific database exists
  if ! execute_mariadb_command "USE \`$SPECIFIC_DATABASE\`;" &>/dev/null; then
    handle_error 6 "Database '$SPECIFIC_DATABASE' does not exist"
  fi
  DATABASES=("$SPECIFIC_DATABASE")
  log_info "Backing up specific database: $SPECIFIC_DATABASE"
else
  # Get all non-system databases
  mapfile -t DATABASES < <(execute_mariadb_command "SHOW DATABASES;" 2>/dev/null | tail -n +2 | grep -v -E "^(information_schema|performance_schema|mysql|sys)$")
  log_info "Found ${#DATABASES[@]} databases to backup: ${DATABASES[*]}"
fi

log_both "INFO" "Found ${#DATABASES[@]} databases: ${DATABASES[*]}" "$LOG_FILE"

# Initialize statistics
TOTAL_DATABASES=0
SUCCESSFUL_BACKUPS=0
FAILED_BACKUPS=0
SKIPPED_DATABASES=0
TOTAL_BACKUP_SIZE=0

# Kopiere Binlog-Dateien aus dem Container ins lokale Backup-Verzeichnis (immer zu Beginn)
BINLOG_CONTAINER_PATH="/var/lib/mysql"
log_info "Synchronisiere Binlog-Dateien aus dem Container..."
docker cp "$MARIADB_CONTAINER:$BINLOG_CONTAINER_PATH/mysql-bin.index" "$BINLOG_BACKUP_DIR/" 2>/dev/null || log_warning "mysql-bin.index nicht gefunden"
for binlog in $(docker exec "$MARIADB_CONTAINER" bash -c "ls $BINLOG_CONTAINER_PATH/mysql-bin.* 2>/dev/null"); do
  BINLOG_FILE=$(basename "$binlog")
  docker cp "$MARIADB_CONTAINER:$BINLOG_CONTAINER_PATH/$BINLOG_FILE" "$BINLOG_BACKUP_DIR/" 2>/dev/null || log_warning "$BINLOG_FILE nicht gefunden"
done

# Correct the binary log backup function - this is important for incremental backups
if [[ "$BACKUP_MODE" == "full" ]]; then
  log_info "Backing up binary logs..."
  
  # We know that the binary logs are mounted at /var/lib/mysql/binlogs in the container
  # (according to docker-compose.yml volume mapping)
  BINLOG_PATH="/var/lib/mysql/binlogs"
  
  # Check if the path exists
  if docker exec "$MARIADB_CONTAINER" test -d "$BINLOG_PATH"; then
    log_info "Using binary log path: $BINLOG_PATH"
    
    # Create temp directory for copying
    docker exec "$MARIADB_CONTAINER" mkdir -p /tmp/binlogs
    
    # Copy binary logs to temp directory
    docker exec "$MARIADB_CONTAINER" bash -c "cp $BINLOG_PATH/mysql-bin.* /tmp/binlogs/ 2>/dev/null"
    
    # Copy from container to host
    if docker cp "$MARIADB_CONTAINER:/tmp/binlogs/." "$BINLOG_BACKUP_DIR/"; then
      log_success "Binary logs backed up successfully"
      log_both "INFO" "Binary logs backed up to $BINLOG_BACKUP_DIR" "$LOG_FILE"
    else
      log_warning "Failed to copy binary logs from container or no binary logs found"
    fi
  else
    log_warning "Binary log directory not found in container: $BINLOG_PATH"
    log_both "WARNING" "Binary log directory not found in container: $BINLOG_PATH" "$LOG_FILE"
  fi
fi

# Improve binary log position detection for full backups
if [[ "$BACKUP_MODE" == "full" ]]; then
  log_info "Attempting to get binary log position..."
  
  # Try different commands for different MariaDB versions
  BINLOG_INFO=$(execute_mariadb_command "SHOW MASTER STATUS\G" 2>/dev/null)
  
  if [[ -z "$BINLOG_INFO" || "$BINLOG_INFO" == *"Empty set"* ]]; then
    # Try alternative syntax
    BINLOG_INFO=$(execute_mariadb_command "SHOW BINARY LOGS;" 2>/dev/null | tail -1)
  fi
  
  if [[ -n "$BINLOG_INFO" ]]; then
    # Extract files and positions (supports different output formats)
    if [[ "$BINLOG_INFO" == *"File:"* ]]; then
      # Format from SHOW MASTER STATUS\G
      BINLOG_FILE=$(echo "$BINLOG_INFO" | grep "File:" | awk '{print $2}')
      BINLOG_POS=$(echo "$BINLOG_INFO" | grep "Position:" | awk '{print $2}')
    else
      # Format from SHOW BINARY LOGS or SHOW MASTER STATUS
      BINLOG_FILE=$(echo "$BINLOG_INFO" | awk '{print $1}')
      BINLOG_POS=$(echo "$BINLOG_INFO" | awk '{print $2}')
    fi
    
    # Save the binary log position
    if [[ -n "$BINLOG_FILE" && -n "$BINLOG_POS" ]]; then
      BINLOG_INFO_FILE="$BINLOG_INFO_DIR/last_binlog_info_${DB}_${TIMESTAMP}.txt"
      echo "$BINLOG_FILE $BINLOG_POS" > "$BINLOG_INFO_FILE"
      log_success "Binary log position saved: $BINLOG_FILE:$BINLOG_POS"
    fi
  else
    log_warning "Binary log information not available. Check if binary logging is enabled."
    log_both "WARNING" "Binary logging may not be enabled on the server" "$LOG_FILE"
  fi
fi

# Improve incremental backup binary log processing
if [[ "$BACKUP_MODE" == "incremental" ]]; then
  # Since we know the path, we set it directly
  BINLOG_PATH_IN_CONTAINER="/var/lib/mysql/binlogs"
  
  # For each binary log, extract
  for bl_file in "${BINLOG_FILES[@]}"; do
    bl_name=$(basename "$bl_file")
    log_info "Processing binary log: $bl_name"
    
    # Copy the binlog file to the container for processing, if necessary
    docker cp "$bl_file" "$MARIADB_CONTAINER:$BINLOG_PATH_IN_CONTAINER/$bl_name" 2>/dev/null
    
    # Extract SQL from binary log with correct path
    if docker exec "$MARIADB_CONTAINER" mysqlbinlog \
      $START_POS $STOP_POS \
      --database="$DB" \
      "$BINLOG_PATH_IN_CONTAINER/$bl_name" >> "$BACKUP_FILE" 2>/dev/null; then
      log_info "Processed binary log: $bl_name"
    else
      log_warning "Failed to process binary log: $bl_name"
    fi
  done
fi

# Backup each database
for DB in "${DATABASES[@]}"; do
  TOTAL_DATABASES=$((TOTAL_DATABASES + 1))
  
  log_info "Processing database: $DB"
  log_both "INFO" "Processing database: $DB" "$LOG_FILE"
  
  # Check if database has tables (unless --include-empty is specified)
  if [[ "$INCLUDE_EMPTY_DATABASES" == "false" ]]; then
    TABLE_COUNT=$(execute_mariadb_command "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$DB';" 2>/dev/null | tail -n +2 || echo "0")
    
    if [[ "$TABLE_COUNT" == "0" ]]; then
      log_warning "Database $DB has no tables, skipping (use --include-empty to backup anyway)"
      log_both "WARNING" "Database $DB skipped (no tables)" "$LOG_FILE"
      SKIPPED_DATABASES=$((SKIPPED_DATABASES + 1))
      continue
    fi
  fi
  
  # Create backup filename
  if [[ "$BACKUP_MODE" == "full" ]]; then
    BACKUP_FILE="$BACKUP_DIR/${DB}_full_${TIMESTAMP}.sql"
  else
    BACKUP_FILE="$BACKUP_DIR/${DB}_incremental_${TIMESTAMP}.sql"
  fi
  
  # Create the backup
  log_info "Creating backup: $(basename "$BACKUP_FILE")"
  
  if [[ "$BACKUP_MODE" == "full" ]]; then
    # Full backup with binary log position
    if execute_mariadb_dump "$DB" "$BACKUP_FILE"; then
      log_success "Full backup created: $(basename "$BACKUP_FILE")"
    else
      log_error "Failed to create backup for database: $DB"
      log_both "ERROR" "Failed to create backup for database: $DB" "$LOG_FILE"
      FAILED_BACKUPS=$((FAILED_BACKUPS + 1))
      continue
    fi
  else
    # Incremental backup (binary logs)
    log_info "Creating incremental backup using binary logs..."
    
    # Find the last full backup binlog info
    LAST_BINLOG_INFO_FILE=$(find "$BINLOG_INFO_DIR" -name "last_binlog_info_${DB}_*.txt" -type f | sort | tail -1)
    
    if [[ -z "$LAST_BINLOG_INFO_FILE" || ! -f "$LAST_BINLOG_INFO_FILE" ]]; then
      log_error "No previous full backup found for database $DB. Run full backup first."
      log_both "ERROR" "No previous full backup found for database $DB" "$LOG_FILE"
      FAILED_BACKUPS=$((FAILED_BACKUPS + 1))
      continue
    fi
    
    # Read last binlog position
    read LAST_BINLOG_FILE LAST_BINLOG_POS < "$LAST_BINLOG_INFO_FILE"
    log_info "Last backup position: $LAST_BINLOG_FILE:$LAST_BINLOG_POS"
    
    # Get current binary log position
    CURRENT_BINLOG_INFO=$(execute_mariadb_command "SHOW MASTER STATUS;" 2>/dev/null | tail -n +2)
    if [[ -z "$CURRENT_BINLOG_INFO" ]]; then
      # Try filesystem method
      LATEST_BINLOG=$(docker exec "$MARIADB_CONTAINER" find /var/lib/mysql -name "mysql-bin.*" -not -name "*.idx" | sort -V | tail -1)
      if [[ -n "$LATEST_BINLOG" ]]; then
        CURRENT_BINLOG_FILE=$(basename "$LATEST_BINLOG")
        CURRENT_BINLOG_POS=$(docker exec "$MARIADB_CONTAINER" stat -c%s "$LATEST_BINLOG" 2>/dev/null || echo "4")
      else
        # Versuche als Fallback, die aktuelle Position aus unserem Backup-Verzeichnis zu bestimmen
        log_info "Trying to determine current binary log position from backup directory..."
        
        # Finde die neueste Binlog-Datei im Backup-Verzeichnis (OHNE .idx oder .index)
        LATEST_BINLOG=$(find "$BINLOG_BACKUP_DIR" -type f -name "mysql-bin.*" ! -name "*.idx" ! -name "*.index" | sort -V | tail -1)
        
        if [[ -n "$LATEST_BINLOG" ]]; then
          CURRENT_BINLOG_FILE=$(basename "$LATEST_BINLOG")
          # Ermittle die tatsächliche Dateigröße als Position
          CURRENT_BINLOG_POS=$(stat -c%s "$LATEST_BINLOG" 2>/dev/null || stat -f%z "$LATEST_BINLOG" 2>/dev/null || echo "4")
          log_info "Found current binary log position from backup directory: $CURRENT_BINLOG_FILE:$CURRENT_BINLOG_POS"
        else
          log_error "Cannot determine current binary log position"
          log_both "ERROR" "Cannot determine current binary log position for $DB" "$LOG_FILE"
          FAILED_BACKUPS=$((FAILED_BACKUPS + 1))
          continue
        fi
      fi
    else
      CURRENT_BINLOG_FILE=$(echo "$CURRENT_BINLOG_INFO" | awk '{print $1}')
      CURRENT_BINLOG_POS=$(echo "$CURRENT_BINLOG_INFO" | awk '{print $2}')
    fi
    
    log_info "Current position: $CURRENT_BINLOG_FILE:$CURRENT_BINLOG_POS"
    
    # Überprüfe die Gültigkeit der Binary Log-Daten vor der Verwendung
    if [[ "$LAST_BINLOG_FILE" == *".idx"* ]]; then
      # Korrigiere fehlerhafte .idx-Dateinamen in der letzten Position
      LAST_BINLOG_FILE="${LAST_BINLOG_FILE%.idx}"
      log_warning "Corrected last binary log filename (removed .idx suffix): $LAST_BINLOG_FILE"
    fi
    
    if [[ "$CURRENT_BINLOG_FILE" == *".idx"* ]]; then
      # Korrigiere fehlerhafte .idx-Dateinamen in der aktuellen Position
      CURRENT_BINLOG_FILE="${CURRENT_BINLOG_FILE%.idx}"
      log_warning "Corrected current binary log filename (removed .idx suffix): $CURRENT_BINLOG_FILE"
    fi
    
    # Check if there are changes
    if [[ "$LAST_BINLOG_FILE" == "$CURRENT_BINLOG_FILE" ]] && [[ "$LAST_BINLOG_POS" == "$CURRENT_BINLOG_POS" ]]; then
      log_info "No changes since last backup, skipping incremental backup"
      log_both "INFO" "No changes for $DB since last backup" "$LOG_FILE"
      SKIPPED_DATABASES=$((SKIPPED_DATABASES + 1))
      continue
    fi
    
    # Create incremental backup from binary logs
    INCR_BACKUP_SUCCESS=false
    
    # Find all binary log files between last and current position
    BINLOG_FILES=()
    if [[ ! -d "$BINLOG_BACKUP_DIR" ]]; then
      log_error "Binary log backup directory not found: $BINLOG_BACKUP_DIR"
      log_both "ERROR" "Binary log backup directory not found" "$LOG_FILE"
      FAILED_BACKUPS=$((FAILED_BACKUPS + 1))
      continue
    fi
    
    # Nur Dateien ohne .idx Erweiterung berücksichtigen (echte Binary Log Dateien)
    for bl_file in $(find "$BINLOG_BACKUP_DIR" -maxdepth 1 -type f -name "mysql-bin.*" ! -name "*.idx" ! -name "*.index" | sort -V); do
      if [[ -f "$bl_file" ]]; then
        BINLOG_FILES+=("$bl_file")
      fi
    done
    
    if [[ ${#BINLOG_FILES[@]} -eq 0 ]]; then
      log_error "No valid binary log files found for incremental backup"
      log_both "ERROR" "No valid binary log files found in $BINLOG_BACKUP_DIR" "$LOG_FILE"
      FAILED_BACKUPS=$((FAILED_BACKUPS + 1))
      continue
    fi
    
    # Sort binlog files
    IFS=$'\n' BINLOG_FILES=($(sort <<<"${BINLOG_FILES[*]}"))
    unset IFS
    
    log_info "Processing ${#BINLOG_FILES[@]} binary log files for incremental backup"
    
    # Create incremental backup file
    > "$BACKUP_FILE"  # Create empty file
    
    for bl_file in "${BINLOG_FILES[@]}"; do
      bl_name=$(basename "$bl_file")
      log_info "Processing binary log: $bl_name"
      
      # Überspringe mysql-bin.index und ähnliche Dateien
      if [[ "$bl_name" == *".index"* ]]; then
        log_info "Skipping index file: $bl_name"
        continue
      fi
      
      # Determine start and stop positions
      START_POS=""
      STOP_POS=""
      
      if [[ "$bl_name" == "$LAST_BINLOG_FILE" ]]; then
        START_POS="--start-position=$LAST_BINLOG_POS"
      fi
      
      if [[ "$bl_name" == "$CURRENT_BINLOG_FILE" ]]; then
        STOP_POS="--stop-position=$CURRENT_BINLOG_POS"
      fi
      
      # Extract SQL from binary log
      if docker exec "$MARIADB_CONTAINER" mysqlbinlog \
        $START_POS $STOP_POS \
        --database="$DB" \
        "$BINLOG_PATH_IN_CONTAINER/$bl_name" >> "$BACKUP_FILE" 2>/dev/null; then
        log_info "Processed binary log: $bl_name"
      else
        log_warning "Failed to process binary log: $bl_name"
      fi
    done
    
    # Check if backup file has content
    if [[ -s "$BACKUP_FILE" ]]; then
      log_success "Incremental backup created: $(basename "$BACKUP_FILE")"
      INCR_BACKUP_SUCCESS=true
    else
      log_warning "Incremental backup is empty, no relevant changes found"
      log_both "WARNING" "Incremental backup for $DB is empty" "$LOG_FILE"
      SKIPPED_DATABASES=$((SKIPPED_DATABASES + 1))
      rm -f "$BACKUP_FILE"
      continue
    fi
    
    if [[ "$INCR_BACKUP_SUCCESS" != "true" ]]; then
      log_error "Failed to create incremental backup for database: $DB"
      log_both "ERROR" "Failed to create incremental backup for database: $DB" "$LOG_FILE"
      FAILED_BACKUPS=$((FAILED_BACKUPS + 1))
      continue
    fi
  fi
  
  # Get backup file size
  BACKUP_SIZE=$(stat -c%s "$BACKUP_FILE" 2>/dev/null || stat -f%z "$BACKUP_FILE" 2>/dev/null || echo "0")
  TOTAL_BACKUP_SIZE=$((TOTAL_BACKUP_SIZE + BACKUP_SIZE))
  
  # Compress backup if enabled
  if [[ "$COMPRESS_BACKUPS" == "true" ]]; then
    log_info "Compressing backup..."
    if gzip "$BACKUP_FILE"; then
      BACKUP_FILE="${BACKUP_FILE}.gz"
      log_success "Backup compressed: $(basename "$BACKUP_FILE")"
    else
      log_error "Failed to compress backup"
      log_both "ERROR" "Failed to compress backup for $DB" "$LOG_FILE"
    fi
  fi
  
  # Encrypt backup
  log_info "Encrypting backup..."
  if ./encrypt_backup.sh --encrypt "$BACKUP_FILE" --key "$ENCRYPT_KEY_FILE"; then
    # Remove unencrypted file
    rm -f "$BACKUP_FILE"
    BACKUP_FILE="${BACKUP_FILE}.enc"
    log_success "Backup encrypted: $(basename "$BACKUP_FILE")"
  else
    log_error "Failed to encrypt backup"
    log_both "ERROR" "Failed to encrypt backup for $DB" "$LOG_FILE"
    FAILED_BACKUPS=$((FAILED_BACKUPS + 1))
    continue
  fi
  
  # Create checksum if enabled
  if [[ "$CREATE_CHECKSUMS" == "true" ]]; then
    CHECKSUM_FILE="$CHECKSUM_DIR/$(basename "$BACKUP_FILE").sha256"
    if command -v sha256sum &> /dev/null; then
      sha256sum "$BACKUP_FILE" > "$CHECKSUM_FILE"
    else
      openssl dgst -sha256 "$BACKUP_FILE" | sed 's/^.* //' > "$CHECKSUM_FILE"
    fi
    log_info "Checksum created: $(basename "$CHECKSUM_FILE")"
  fi
  
  # Save binary log position for full backups
  if [[ "$BACKUP_MODE" == "full" ]]; then
    # Get current binary log position - try different methods
    log_info "Attempting to get binary log position..."
    
    # Method 1: Try SHOW MASTER STATUS
    BINLOG_INFO=$(execute_mariadb_command "SHOW MASTER STATUS;" 2>/dev/null | tail -n +2)
    
    if [[ -n "$BINLOG_INFO" ]] && [[ "$BINLOG_INFO" != "" ]] && [[ "$BINLOG_INFO" != "NULL" ]]; then
      BINLOG_FILE=$(echo "$BINLOG_INFO" | awk '{print $1}')
      BINLOG_POS=$(echo "$BINLOG_INFO" | awk '{print $2}')
      
      # Check if we got valid data
      if [[ -n "$BINLOG_FILE" ]] && [[ "$BINLOG_FILE" != "NULL" ]] && [[ "$BINLOG_FILE" != "" ]] && [[ -n "$BINLOG_POS" ]] && [[ "$BINLOG_POS" != "NULL" ]]; then
        # Save binlog info
        BINLOG_INFO_FILE="$BINLOG_INFO_DIR/last_binlog_info_${DB}_${TIMESTAMP}.txt"
        echo "$BINLOG_FILE $BINLOG_POS" > "$BINLOG_INFO_FILE"
        
        log_success "Binary log position saved: $BINLOG_FILE:$BINLOG_POS"
        log_both "INFO" "Binary log position for $DB: $BINLOG_FILE:$BINLOG_POS" "$LOG_FILE"
      else
        log_warning "Got invalid binary log data: '$BINLOG_INFO'"
        # Try alternative method - get latest binlog file from filesystem
        LATEST_BINLOG=$(docker exec "$MARIADB_CONTAINER" find /var/lib/mysql -name "mysql-bin.*" -not -name "*.index" | sort -V | tail -1)
        if [[ -n "$LATEST_BINLOG" ]]; then
          BINLOG_FILE=$(basename "$LATEST_BINLOG")
          BINLOG_POS="4"  # Start position for binlog files
          
          BINLOG_INFO_FILE="$BINLOG_INFO_DIR/last_binlog_info_${DB}_${TIMESTAMP}.txt"
          echo "$BINLOG_FILE $BINLOG_POS" > "$BINLOG_INFO_FILE"
          log_info "Binary log position estimated from filesystem: $BINLOG_FILE:$BINLOG_POS"
          log_both "INFO" "Binary log position (estimated) for $DB: $BINLOG_FILE:$BINLOG_POS" "$LOG_FILE"
        else
          log_warning "Could not determine binary log position"
        fi
      fi
    else
      log_warning "SHOW MASTER STATUS returned no data"
      # Try alternative method - get latest binlog file from filesystem
      LATEST_BINLOG=$(docker exec "$MARIADB_CONTAINER" find /var/lib/mysql -name "mysql-bin.*" -not -name "*.index" | sort -V | tail -1)
      if [[ -n "$LATEST_BINLOG" ]]; then
        BINLOG_FILE=$(basename "$LATEST_BINLOG")
        BINLOG_POS="4"  # Start position for binlog files
        
        BINLOG_INFO_FILE="$BINLOG_INFO_DIR/last_binlog_info_${DB}_${TIMESTAMP}.txt"
        echo "$BINLOG_FILE $BINLOG_POS" > "$BINLOG_INFO_FILE"
        log_info "Binary log position estimated from filesystem: $BINLOG_FILE:$BINLOG_POS"
        log_both "INFO" "Binary log position (estimated) for $DB: $BINLOG_FILE:$BINLOG_POS" "$LOG_FILE"
      else
        # Fallback: Check copied binlogs in our backup directory
        LATEST_BINLOG=$(find "$BINLOG_BACKUP_DIR" -type f -name "mysql-bin.*" ! -name "*.idx" ! -name "*.index" | sort -V | tail -1 2>/dev/null)
        if [[ -n "$LATEST_BINLOG" ]]; then
          BINLOG_FILE=$(basename "$LATEST_BINLOG")
          BINLOG_POS="4"  # Start position for binlog files
          
          BINLOG_INFO_FILE="$BINLOG_INFO_DIR/last_binlog_info_${DB}_${TIMESTAMP}.txt"
          echo "$BINLOG_FILE $BINLOG_POS" > "$BINLOG_INFO_FILE"
          log_info "Binary log position estimated from backup directory: $BINLOG_FILE:$BINLOG_POS"
          log_both "INFO" "Binary log position (estimated from backups) for $DB: $BINLOG_FILE:$BINLOG_POS" "$LOG_FILE"
        else
          log_warning "No binary logs found anywhere. Incremental backups will not work until binary logging is enabled."
        fi
      fi
    fi
  elif [[ "$BACKUP_MODE" == "incremental" ]]; then
    # Save current binary log position for incremental backups too
    if [[ -n "$CURRENT_BINLOG_FILE" ]] && [[ -n "$CURRENT_BINLOG_POS" ]]; then
      BINLOG_INFO_FILE="$BINLOG_INFO_DIR/last_binlog_info_${DB}_${TIMESTAMP}.txt"
      echo "$CURRENT_BINLOG_FILE $CURRENT_BINLOG_POS" > "$BINLOG_INFO_FILE"
      log_info "Updated binary log position: $CURRENT_BINLOG_FILE:$CURRENT_BINLOG_POS"
      log_both "INFO" "Updated binary log position for $DB: $CURRENT_BINLOG_FILE:$CURRENT_BINLOG_POS" "$LOG_FILE"
    fi
  fi
  
  SUCCESSFUL_BACKUPS=$((SUCCESSFUL_BACKUPS + 1))
  log_success "Backup completed for database: $DB"
done

# Calculate backup duration
BACKUP_END_TIME=$(date +%s)
BACKUP_DURATION=$((BACKUP_END_TIME - BACKUP_START_TIME))

# Convert total size to human-readable format
if [[ $TOTAL_BACKUP_SIZE -gt 1048576 ]]; then
  SIZE_HR=$(echo "scale=2; $TOTAL_BACKUP_SIZE/1048576" | bc -l 2>/dev/null || echo "$((TOTAL_BACKUP_SIZE/1048576))")
  SIZE_UNIT="MB"
elif [[ $TOTAL_BACKUP_SIZE -gt 1024 ]]; then
  SIZE_HR=$(echo "scale=2; $TOTAL_BACKUP_SIZE/1024" | bc -l 2>/dev/null || echo "$((TOTAL_BACKUP_SIZE/1024))")
  SIZE_UNIT="KB"
else
  SIZE_HR=$TOTAL_BACKUP_SIZE
  SIZE_UNIT="bytes"
fi

# Show backup summary
log_success "Backup process completed!"
log_both "SUCCESS" "Backup process completed!" "$LOG_FILE"

echo
log_info "=== BACKUP SUMMARY ==="
log_info "Backup mode: $BACKUP_MODE"
log_info "Timestamp: $TIMESTAMP"
log_info "Duration: ${BACKUP_DURATION}s"
log_info "Total databases processed: $TOTAL_DATABASES"
log_info "Successful backups: $SUCCESSFUL_BACKUPS"
log_info "Failed backups: $FAILED_BACKUPS"
log_info "Skipped databases: $SKIPPED_DATABASES"
log_info "Total backup size: $SIZE_HR $SIZE_UNIT"
log_info "Compression: $([ "$COMPRESS_BACKUPS" == "true" ] && echo "enabled" || echo "disabled")"
log_info "Encryption: enabled"
log_info "Checksums: $([ "$CREATE_CHECKSUMS" == "true" ] && echo "enabled" || echo "disabled")"

# Log summary to file
log_both "INFO" "=== BACKUP SUMMARY ===" "$LOG_FILE"
log_both "INFO" "Mode: $BACKUP_MODE, Duration: ${BACKUP_DURATION}s" "$LOG_FILE"
log_both "INFO" "Processed: $TOTAL_DATABASES, Success: $SUCCESSFUL_BACKUPS, Failed: $FAILED_BACKUPS, Skipped: $SKIPPED_DATABASES" "$LOG_FILE"
log_both "INFO" "Total size: $SIZE_HR $SIZE_UNIT" "$LOG_FILE"

if [[ $FAILED_BACKUPS -gt 0 ]]; then
  log_error "$FAILED_BACKUPS backup(s) failed. Check the logs for details."
  log_both "ERROR" "$FAILED_BACKUPS backup(s) failed" "$LOG_FILE"
  exit 1
fi

log_info "All backups completed successfully!"
log_info "Backup files are encrypted and stored in: $BACKUP_DIR"
log_both "INFO" "Backup process finished at $(date '+%Y-%m-%d %H:%M:%S')" "$LOG_FILE"