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
if ! docker exec "$MARIADB_CONTAINER" mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -e "SELECT 1;" &>/dev/null; then
  handle_error 5 "Cannot connect to MariaDB container: $MARIADB_CONTAINER"
fi
log_success "Database connection successful"

# Get list of databases
if [[ -n "$SPECIFIC_DATABASE" ]]; then
  # Verify specific database exists
  if ! docker exec "$MARIADB_CONTAINER" mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -e "USE \`$SPECIFIC_DATABASE\`;" &>/dev/null; then
    handle_error 6 "Database '$SPECIFIC_DATABASE' does not exist"
  fi
  DATABASES=("$SPECIFIC_DATABASE")
  log_info "Backing up specific database: $SPECIFIC_DATABASE"
else
  # Get all non-system databases
  mapfile -t DATABASES < <(docker exec "$MARIADB_CONTAINER" mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -N -e "SHOW DATABASES;" | grep -v -E "^(information_schema|performance_schema|mysql|sys)$")
  log_info "Found ${#DATABASES[@]} databases to backup: ${DATABASES[*]}"
fi

log_both "INFO" "Found ${#DATABASES[@]} databases: ${DATABASES[*]}" "$LOG_FILE"

# Initialize statistics
TOTAL_DATABASES=0
SUCCESSFUL_BACKUPS=0
FAILED_BACKUPS=0
SKIPPED_DATABASES=0
TOTAL_BACKUP_SIZE=0

# Backup each database
for DB in "${DATABASES[@]}"; do
  TOTAL_DATABASES=$((TOTAL_DATABASES + 1))
  
  log_info "Processing database: $DB"
  log_both "INFO" "Processing database: $DB" "$LOG_FILE"
  
  # Check if database has tables (unless --include-empty is specified)
  if [[ "$INCLUDE_EMPTY_DATABASES" == "false" ]]; then
    TABLE_COUNT=$(docker exec "$MARIADB_CONTAINER" mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$DB';" 2>/dev/null || echo "0")
    
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
    if docker exec "$MARIADB_CONTAINER" mariadb-dump \
      -u root -p"$MARIADB_ROOT_PASSWORD" \
      --single-transaction \
      --routines \
      --triggers \
      --flush-logs \
      --master-data=2 \
      --databases "$DB" > "$BACKUP_FILE"; then
      
      log_success "Full backup created: $(basename "$BACKUP_FILE")"
    else
      log_error "Failed to create backup for database: $DB"
      log_both "ERROR" "Failed to create backup for database: $DB" "$LOG_FILE"
      FAILED_BACKUPS=$((FAILED_BACKUPS + 1))
      continue
    fi
  else
    # Incremental backup (binary logs)
    log_info "Creating incremental backup (binary logs not yet implemented in this version)"
    log_both "WARNING" "Incremental backup mode not fully implemented yet" "$LOG_FILE"
    SKIPPED_DATABASES=$((SKIPPED_DATABASES + 1))
    continue
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
    # Get current binary log position
    BINLOG_INFO=$(docker exec "$MARIADB_CONTAINER" mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -N -e "SHOW MASTER STATUS;" 2>/dev/null)
    if [[ -n "$BINLOG_INFO" ]]; then
      BINLOG_FILE=$(echo "$BINLOG_INFO" | awk '{print $1}')
      BINLOG_POS=$(echo "$BINLOG_INFO" | awk '{print $2}')
      
      # Save binlog info
      BINLOG_INFO_FILE="$BINLOG_INFO_DIR/last_binlog_info_${DB}_${TIMESTAMP}.txt"
      echo "$BINLOG_FILE $BINLOG_POS" > "$BINLOG_INFO_FILE"
      
      log_info "Binary log position saved: $BINLOG_FILE:$BINLOG_POS"
      log_both "INFO" "Binary log position for $DB: $BINLOG_FILE:$BINLOG_POS" "$LOG_FILE"
    else
      log_warning "Could not get binary log position"
    fi
  fi
  
  SUCCESSFUL_BACKUPS=$((SUCCESSFUL_BACKUPS + 1))
  log_success "Backup completed for database: $DB"
done

# Backup binary logs
if [[ "$BACKUP_MODE" == "full" ]]; then
  log_info "Backing up binary logs..."
  if docker exec "$MARIADB_CONTAINER" find /var/lib/mysql -name "mysql-bin.*" -exec cp {} /tmp/binlogs/ \; 2>/dev/null; then
    # Copy binary logs from container
    if docker cp "$MARIADB_CONTAINER:/tmp/binlogs/." "$BINLOG_BACKUP_DIR/"; then
      log_success "Binary logs backed up successfully"
      log_both "INFO" "Binary logs backed up to $BINLOG_BACKUP_DIR" "$LOG_FILE"
    else
      log_warning "Failed to copy binary logs from container"
    fi
  else
    log_warning "No binary logs found or failed to copy them"
  fi
fi

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