#!/bin/bash
cd "$(dirname "$0")"

set -o pipefail

# Load logging functions
source "./lib/logging.sh"

# Verbose mode - set to true for detailed info messages
VERBOSE=false

# Debug log function - only outputs if verbose mode is enabled
debug_log() {
  if [[ "$VERBOSE" == "true" ]]; then
    log_info "[DEBUG] $1"
  fi
}

# Start timing
RESTORE_START_TIME=$(date +%s)
RESTORE_START_DATE=$(date '+%Y-%m-%d %H:%M:%S')

# Initialize statistics variables
TOTAL_BACKUP_SIZE=0
TOTAL_BINLOG_SIZE=0
TOTAL_BINLOGS_PROCESSED=0
TOTAL_BINLOGS_SKIPPED=0
TOTAL_BINLOGS_ERRORS=0
PROCESSED_DATABASES=0

# Function to get all databases with at least one backup
get_databases_with_backups() {
  local dbs=()
  log_info "Searching for backup files to identify databases..." >&2
  for backup_file in $(find "./backups" -type f -name "*_full_*.sql.gz.enc" 2>/dev/null); do
    db_name=$(basename "$backup_file" | sed 's/_full_.*//')
    if [[ ! " ${dbs[*]} " =~ " ${db_name} " ]] && [[ "$db_name" != "binlogs" ]]; then
      dbs+=("$db_name")
    fi
  done
  echo "${dbs[@]}"
}

# Function to select database interactively
select_database_interactive() {
  local DBS=("$@")
  if [[ ${#DBS[@]} -eq 0 ]]; then
    log_error "No databases with backup files found." >&2
    exit 1
  fi
  
  echo "" >&2
  echo "Available databases for restore:" >&2
  echo "================================" >&2
  
  echo "  [1] ALL_DATABASES (restore all databases)" >&2
  for i in "${!DBS[@]}"; do
    local db_name="${DBS[$i]}"
    echo "  [$((i+2))] $db_name" >&2
  done
  
  echo "" >&2
  read -p "Select an option (1-$((1+${#DBS[@]}))): " selection
  
  if [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 1 ]] && [[ "$selection" -le $((1+${#DBS[@]})) ]]; then
    if [[ "$selection" -eq 1 ]]; then
      echo "ALL_DATABASES"
    else
      local selected_index=$((selection - 2))
      echo "${DBS[$selected_index]}"
    fi
  else
    log_error "Invalid selection: $selection" >&2
    exit 1
  fi
}

# Function to select backup interactively
select_backup_interactive() {
  local DB=$1
  shift
  local FULLS=("$@")
  
  if [[ ${#FULLS[@]} -eq 0 ]]; then
    log_error "No valid backups found for database $DB" >&2
    exit 1
  fi
  
  echo "" >&2
  echo "Available backups for database '$DB':" >&2
  echo "======================================" >&2
  
  for i in "${!FULLS[@]}"; do
    local backup_file="${FULLS[$i]}"
    local backup_size=$(stat -c%s "$backup_file" 2>/dev/null || stat -f%z "$backup_file" 2>/dev/null || echo "unknown")
    local backup_date=$(stat -c%y "$backup_file" 2>/dev/null || stat -f%Sm "$backup_file" 2>/dev/null || echo "unknown")
    local backup_timestamp=$(basename "$backup_file" | sed -E "s/^${DB}_full_(.*)\.sql\.gz\.enc$/\1/")
    local formatted_timestamp=$(echo "$backup_timestamp" | sed 's/_/ /g' | sed 's/-/:/g')
    echo "  [$((i+1))] $formatted_timestamp (${backup_size} bytes, $backup_date)" >&2
  done
  
  echo "" >&2
  read -p "Select backup number (1-${#FULLS[@]}): " selection
  
  if [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 1 ]] && [[ "$selection" -le ${#FULLS[@]} ]]; then
    local selected_index=$((selection - 1))
    echo "${FULLS[$selected_index]}"
  else
    log_error "Invalid selection: $selection" >&2
    exit 1
  fi
}

# Robust argument parsing for all relevanten Flags
INTERACTIVE_SELECT=true
DEBUG_MODE=false
USE_LAST_BACKUP=false
RESTORE_TIMESTAMP=""
DATABASE=""
BACKUP_FILE=""
RESTORE_TO_TIMESTAMP=""
LOG_FILE="./logs/restore.log"

# Create logs directory
mkdir -p "./logs"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --database)
      DATABASE="$2"
      INTERACTIVE_SELECT=false
      shift 2
      ;;
    --backup-file)
      BACKUP_FILE="$2"
      INTERACTIVE_SELECT=false
      shift 2
      ;;
    --last)
      USE_LAST_BACKUP=true
      INTERACTIVE_SELECT=false
      shift
      ;;
    --to-timestamp)
      RESTORE_TO_TIMESTAMP="$2"
      shift 2
      ;;
    --verbose)
      VERBOSE=true
      shift
      ;;
    --debug)
      DEBUG_MODE=true
      VERBOSE=true
      shift
      ;;
    --help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "OPTIONS:"
      echo "  --database DB          Specify database name"
      echo "  --backup-file FILE     Specify backup file path"
      echo "  --last                 Use the most recent backup"
      echo "  --to-timestamp TS      Restore up to specific timestamp (YYYY-MM-DD HH:MM:SS)"
      echo "  --verbose              Enable verbose output"
      echo "  --debug                Enable debug mode"
      echo "  --help                 Show this help message"
      echo ""
      echo "If no options are provided, interactive mode is used."
      exit 0
      ;;
    *)
      log_error "Unknown option: $1"
      exit 1
      ;;
  esac
done

log_info "Starting restore process at $RESTORE_START_DATE"
log_both "INFO" "Starting restore process at $RESTORE_START_DATE" "$LOG_FILE"

# Load environment variables
if [[ -f ".env" ]]; then
  source .env
  debug_log "Loaded environment variables from .env"
else
  log_error ".env file not found"
  exit 1
fi

# Interactive selection if no parameters provided
if [[ "$INTERACTIVE_SELECT" == "true" ]]; then
  log_info "Interactive mode - select database and backup"
  
  DBS_WITH_BACKUPS=( $(get_databases_with_backups) )
  SELECTED_DB=$(select_database_interactive "${DBS_WITH_BACKUPS[@]}")
  
  if [[ "$SELECTED_DB" == "ALL_DATABASES" ]]; then
    log_info "Selected: ALL_DATABASES. Restoring all databases from their latest backup."
    DATABASE="ALL" # Special value to indicate all databases
    BACKUP_FILE="LATEST" # Special value
  else
    DATABASE="$SELECTED_DB"
    BACKUP_FILES=( $(ls -1t ./backups/${DATABASE}_full_*.sql.gz.enc 2>/dev/null) )
    BACKUP_FILE=$(select_backup_interactive "$DATABASE" "${BACKUP_FILES[@]}")
  fi
fi

# Auto-select last backup if requested
if [[ "$USE_LAST_BACKUP" == "true" ]]; then
  if [[ -z "$DATABASE" ]]; then
    log_error "--last requires --database parameter"
    exit 1
  fi
  
  BACKUP_FILE=$(ls -1t "./backups/${DATABASE}_full_"*.sql.gz.enc 2>/dev/null | head -1)
  if [[ -z "$BACKUP_FILE" ]]; then
    log_error "No backups found for database: $DATABASE"
    exit 1
  fi
fi

# Handle restore for all databases
if [[ "$DATABASE" == "ALL" ]]; then
  DBS_TO_RESTORE=( $(get_databases_with_backups) )
  log_info "Starting restore for all databases: ${DBS_TO_RESTORE[*]}"
else
  DBS_TO_RESTORE=("$DATABASE")
fi

for DB_TO_RESTORE in "${DBS_TO_RESTORE[@]}"; do
  # If restoring all, get the latest backup for each DB
  if [[ "$DATABASE" == "ALL" ]]; then
    CURRENT_BACKUP_FILE=$(ls -1t "./backups/${DB_TO_RESTORE}_full_"*.sql.gz.enc 2>/dev/null | head -1)
    if [[ -z "$CURRENT_BACKUP_FILE" ]]; then
      log_warning "No backup found for $DB_TO_RESTORE. Skipping."
      continue
    fi
  else
    CURRENT_BACKUP_FILE="$BACKUP_FILE"
  fi
  
  # Validate parameters for the current database
  if [[ -z "$DB_TO_RESTORE" ]]; then
    log_error "Database not specified"
    continue
  fi

  if [[ -z "$CURRENT_BACKUP_FILE" ]]; then
    log_error "Backup file not specified for $DB_TO_RESTORE"
    continue
  fi

  if [[ ! -f "$CURRENT_BACKUP_FILE" ]]; then
    log_error "Backup file not found: $CURRENT_BACKUP_FILE"
    continue
  fi

  log_info "--- Processing database: $DB_TO_RESTORE ---"
  log_info "Selected backup: $CURRENT_BACKUP_FILE"
  log_both "INFO" "Selected database: $DB_TO_RESTORE, backup: $CURRENT_BACKUP_FILE" "$LOG_FILE"

  # Extract timestamp from backup filename
  BACKUP_TIMESTAMP=$(basename "$CURRENT_BACKUP_FILE" | sed "s/${DB_TO_RESTORE}_full_\(.*\)\.sql\.gz\.enc/\1/")
  log_info "Backup timestamp: $BACKUP_TIMESTAMP"

  # Get backup file size for statistics
  BACKUP_SIZE=$(stat -c%s "$CURRENT_BACKUP_FILE" 2>/dev/null || stat -f%z "$CURRENT_BACKUP_FILE" 2>/dev/null || echo "0")
  TOTAL_BACKUP_SIZE=$((TOTAL_BACKUP_SIZE + BACKUP_SIZE))

  log_info "Starting restore process..."
  log_both "INFO" "Starting restore process for $DB_TO_RESTORE from $BACKUP_TIMESTAMP" "$LOG_FILE"

  # Step 1: Decrypt and restore the full backup
  log_info "Step 1: Decrypting and restoring full backup..."

  # Check if encryption key exists
  if [[ ! -f ".backup_encryption_key" ]]; then
    log_error "Encryption key not found: .backup_encryption_key"
    exit 1
  fi

  # Decrypt and restore the backup
  if ! ./encrypt_backup.sh --decrypt "$CURRENT_BACKUP_FILE" --key .backup_encryption_key; then
    log_error "Failed to decrypt backup file"
    continue
  fi

  # Get decrypted filename
  DECRYPTED_FILE="${CURRENT_BACKUP_FILE%.enc}"

  # Import the backup
  log_info "Importing backup into database: $DB_TO_RESTORE"

  # Determine the best connection method for MariaDB
  if docker exec mariadb mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -e "SELECT 1;" &>/dev/null; then
    MYSQL_CONNECTION_ARGS=(-u root -p"$MARIADB_ROOT_PASSWORD")
  elif docker exec mariadb mariadb -u root -e "SELECT 1;" &>/dev/null; then
    MYSQL_CONNECTION_ARGS=(-u root)
  else
    log_error "Cannot connect to MariaDB container"
    exit 1
  fi

  # Create database if it doesn't exist
  docker exec mariadb mariadb "${MYSQL_CONNECTION_ARGS[@]}" -e "CREATE DATABASE IF NOT EXISTS \`$DB_TO_RESTORE\`;"

  # Import the backup using the working connection method
  if ! docker exec -i mariadb mariadb "${MYSQL_CONNECTION_ARGS[@]}" "$DB_TO_RESTORE" < <(gunzip -c "$DECRYPTED_FILE"); then
    log_error "Failed to import backup for $DB_TO_RESTORE"
    rm -f "$DECRYPTED_FILE"
    continue
  fi

  log_success "Full backup for $DB_TO_RESTORE restored successfully"
  PROCESSED_DATABASES=$((PROCESSED_DATABASES + 1))

  # Clean up decrypted file
  rm -f "$DECRYPTED_FILE"

  # Step 2: Apply binary logs
  log_info "Step 2: Applying binary logs..."
  
  # Find binlog info file associated with the full backup
  BINLOG_INFO_FILE="./backups/binlog_info/last_binlog_info_${DB_TO_RESTORE}_${BACKUP_TIMESTAMP}.txt"
  if [[ ! -f "$BINLOG_INFO_FILE" ]]; then
    # Fallback for older backup scripts that might store it in 'incr'
    BINLOG_INFO_FILE="./backups/incr/last_binlog_info_${DB_TO_RESTORE}_${BACKUP_TIMESTAMP}.txt"
  fi
  
  if [[ -f "$BINLOG_INFO_FILE" ]]; then
    read BINLOG_FILE BINLOG_POS < "$BINLOG_INFO_FILE"
    log_info "Starting from binlog: $BINLOG_FILE at position $BINLOG_POS"
    log_both "INFO" "Applying binlogs from $BINLOG_FILE:$BINLOG_POS" "$LOG_FILE"
    
    # Find all binlog files from the backup point onwards
    BINLOG_FILES=()
    # Ensure we only process actual binlog files, not the index
    for bl_file in $(find ./backups/binlogs -name "mysql-bin.*" -not -name "*.index" -not -name "*.idx" | sort); do
      if [[ -f "$bl_file" ]]; then
        bl_name=$(basename "$bl_file")
        if [[ "$bl_name" > "$BINLOG_FILE" || ( "$bl_name" == "$BINLOG_FILE" ) ]]; then
          BINLOG_FILES+=("$bl_file")
        fi
      fi
    done
    
    log_info "Found ${#BINLOG_FILES[@]} binlog files to process."
    
    # Process each binlog file
    for bl_file in "${BINLOG_FILES[@]}"; do
      bl_name=$(basename "$bl_file")
      log_info "Processing binlog: $bl_name"
      
      # Get binlog size for statistics
      if [[ -f "$bl_file" ]]; then
        BL_SIZE=$(stat -c%s "$bl_file" 2>/dev/null || stat -f%z "$bl_file" 2>/dev/null || echo "0")
        TOTAL_BINLOG_SIZE=$((TOTAL_BINLOG_SIZE + BL_SIZE))
      fi
      
      # Set start and stop options for mysqlbinlog
      MYSQLBINLOG_OPTIONS=""
      if [[ "$bl_name" == "$BINLOG_FILE" ]]; then
        MYSQLBINLOG_OPTIONS+=" --start-position=$BINLOG_POS"
      fi
      if [[ -n "$RESTORE_TO_TIMESTAMP" ]]; then
        MYSQLBINLOG_OPTIONS+=" --stop-datetime=\"$RESTORE_TO_TIMESTAMP\""
      fi
      
      # Copy binlog file to container for processing
      docker exec mariadb mkdir -p /tmp/binlogs 2>/dev/null
      docker cp "$bl_file" "mariadb:/tmp/binlogs/$bl_name"
      
      # Apply binlog using the correct mariadb-binlog path
      if [[ -n "$RESTORE_TO_TIMESTAMP" ]]; then
        eval "docker exec mariadb /usr/bin/mariadb-binlog \
          $MYSQLBINLOG_OPTIONS \
          --database=\"$DB_TO_RESTORE\" \
          \"/tmp/binlogs/$bl_name\"" | \
          docker exec -i mariadb mariadb "${MYSQL_CONNECTION_ARGS[@]}" "$DB_TO_RESTORE"
      else
        docker exec mariadb /usr/bin/mariadb-binlog \
          $MYSQLBINLOG_OPTIONS \
          --database="$DB_TO_RESTORE" \
          "/tmp/binlogs/$bl_name" | \
          docker exec -i mariadb mariadb "${MYSQL_CONNECTION_ARGS[@]}" "$DB_TO_RESTORE"
      fi
      
      # Clean up temporary binlog file
      docker exec mariadb rm -f "/tmp/binlogs/$bl_name"
        
      if [[ $? -eq 0 ]]; then
        log_success "Applied binlog: $bl_name"
        TOTAL_BINLOGS_PROCESSED=$((TOTAL_BINLOGS_PROCESSED + 1))
      else
        log_warning "Failed to apply binlog: $bl_name (this might be normal if no relevant data or if changes were already applied)"
        TOTAL_BINLOGS_ERRORS=$((TOTAL_BINLOGS_ERRORS + 1))
      fi
    done
  else
    log_warning "Binlog info file not found: $BINLOG_INFO_FILE"
    log_warning "Cannot apply incremental changes for $DB_TO_RESTORE. Only the full backup was restored."
  fi
done

# Calculate restore duration
RESTORE_END_TIME=$(date +%s)
RESTORE_DURATION=$((RESTORE_END_TIME - RESTORE_START_TIME))

# Convert sizes to human readable format
if [[ $TOTAL_BACKUP_SIZE -gt 1048576 ]]; then
  BACKUP_SIZE_HR=$(echo "scale=2; $TOTAL_BACKUP_SIZE/1048576" | bc -l 2>/dev/null || echo "$((TOTAL_BACKUP_SIZE/1048576))")
  BACKUP_SIZE_UNIT="MB"
elif [[ $TOTAL_BACKUP_SIZE -gt 1024 ]]; then
  BACKUP_SIZE_HR=$(echo "scale=2; $TOTAL_BACKUP_SIZE/1024" | bc -l 2>/dev/null || echo "$((TOTAL_BACKUP_SIZE/1024))")
  BACKUP_SIZE_UNIT="KB"
else
  BACKUP_SIZE_HR=$TOTAL_BACKUP_SIZE
  BACKUP_SIZE_UNIT="bytes"
fi

if [[ $TOTAL_BINLOG_SIZE -gt 1048576 ]]; then
  BINLOG_SIZE_HR=$(echo "scale=2; $TOTAL_BINLOG_SIZE/1048576" | bc -l 2>/dev/null || echo "$((TOTAL_BINLOG_SIZE/1048576))")
  BINLOG_SIZE_UNIT="MB"
elif [[ $TOTAL_BINLOG_SIZE -gt 1024 ]]; then
  BINLOG_SIZE_HR=$(echo "scale=2; $TOTAL_BINLOG_SIZE/1024" | bc -l 2>/dev/null || echo "$((TOTAL_BINLOG_SIZE/1024))")
  BINLOG_SIZE_UNIT="KB"
else
  BINLOG_SIZE_HR=$TOTAL_BINLOG_SIZE
  BINLOG_SIZE_UNIT="bytes"
fi

# Show restore summary
log_success "Restore completed successfully!"
log_both "SUCCESS" "Restore completed successfully!" "$LOG_FILE"

echo
log_info "=== RESTORE SUMMARY ==="
if [[ "$DATABASE" == "ALL" ]]; then
  log_info "Databases: All (${#DBS_TO_RESTORE[@]} databases)"
else
  log_info "Database: $DATABASE"
fi
if [[ -n "$RESTORE_TO_TIMESTAMP" ]]; then
  log_info "Restored to timestamp: $RESTORE_TO_TIMESTAMP"
fi
log_info "Duration: ${RESTORE_DURATION}s"
log_info "Backup size processed: $BACKUP_SIZE_HR $BACKUP_SIZE_UNIT"
if [[ $TOTAL_BINLOG_SIZE -gt 0 ]]; then
  log_info "Binlog size processed: $BINLOG_SIZE_HR $BINLOG_SIZE_UNIT"
  log_info "Binlogs processed: $TOTAL_BINLOGS_PROCESSED"
  if [[ $TOTAL_BINLOGS_ERRORS -gt 0 ]]; then
    log_warning "Binlogs with errors: $TOTAL_BINLOGS_ERRORS"
  fi
fi

# Log summary to file
log_both "INFO" "=== RESTORE SUMMARY ===" "$LOG_FILE"
log_both "INFO" "Database: $DATABASE, Duration: ${RESTORE_DURATION}s" "$LOG_FILE"
log_both "INFO" "Backup size: $BACKUP_SIZE_HR $BACKUP_SIZE_UNIT, Binlog size: $BINLOG_SIZE_HR $BINLOG_SIZE_UNIT" "$LOG_FILE"
log_both "INFO" "Binlogs processed: $TOTAL_BINLOGS_PROCESSED, Errors: $TOTAL_BINLOGS_ERRORS" "$LOG_FILE"

log_info "Restore process completed at $(date '+%Y-%m-%d %H:%M:%S')"

BINLOG_BACKUP_DIR="./backups/binlogs"
BINLOG_INFO_DIR="./backups/binlog_info"

