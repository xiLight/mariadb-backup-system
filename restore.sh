#!/bin/bash
cd "$(dirname "$0")"

set -o pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Verbose mode - set to true for detailed info messages
VERBOSE=false

# Logging functions with timestamps
log_info() {
  local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  if [ "$VERBOSE" = true ]; then
    echo -e "${BLUE}[$timestamp] [INFO] $1${NC}" | tee -a "$LOG_FILE"
  else
    echo "[$timestamp] [INFO] $1" >> "$LOG_FILE"
  fi
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

# Debug log function - only outputs if verbose mode is enabled
debug_log() {
  if [[ "$VERBOSE" == "true" ]]; then
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "${BLUE}[$timestamp] [DEBUG] $1${NC}" | tee -a "$LOG_FILE"
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

# Function to create preview for fzf
create_backup_preview() {
  local file="$1"
  local db="$2"
  echo "Backup file: $file"
  echo "Size: $(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo "unknown") bytes"
  echo "Modified: $(stat -c%y "$file" 2>/dev/null || stat -f%Sm "$file" 2>/dev/null || echo "unknown")"
  echo "Timestamp: $(basename "$file" | sed "s/${db}_full_\(.*\)\.sql\.gz\.enc/\1/")"
}

# Function to select database interactively
select_database_interactive() {
  local DBS=("$@")
  if [[ ${#DBS[@]} -eq 0 ]]; then
    log_error "No databases found" >&2
    return 1
  fi
  echo "" >&2
  echo "Available databases for restore:" >&2
  echo "================================" >&2
  # Check if fzf is available for better selection
  if command -v fzf &> /dev/null; then
    if [[ "$DEBUG_MODE" == "true" ]]; then
      debug_log "Using fzf for database selection..." >&2
      debug_log "fzf input: ALL_DATABASES ${DBS[*]}" >&2
    fi
    local selected_db
    # Add "All databases" option at the beginning
    selected_db=$(printf '%s\n' "ALL_DATABASES" "${DBS[@]}" | fzf --height=10 --reverse --header="Select database to restore (ALL_DATABASES = restore all):")
    debug_log "fzf output: '$selected_db'" >&2
    if [[ -n "$selected_db" ]]; then
      echo "$selected_db"
      return 0
    else
      debug_log "No database selected" >&2
      return 1
    fi
  else
    # Fallback to simple numbered selection
    debug_log "Using simple selection (install fzf for better experience)..." >&2
    echo "  [1] ALL_DATABASES (restore all databases)" >&2
    for i in "${!DBS[@]}"; do
      local db_name="${DBS[$i]}"
      echo "  [$((i+2))] $db_name" >&2
    done
    echo "" >&2
    read -p "Select database number (1-$((1+${#DBS[@]}))): " selection
    if [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 1 ]] && [[ "$selection" -le $((1+${#DBS[@]})) ]]; then
      if [[ "$selection" -eq 1 ]]; then
        echo "ALL_DATABASES"
      else
        local selected_index=$((selection - 2))
        echo "${DBS[$selected_index]}"
      fi
      return 0
    else
      if [[ "$DEBUG_MODE" == "true" ]]; then
        debug_log "Invalid selection: $selection" >&2
      fi
      return 1
    fi
  fi
}

# Function to select backup interactively
select_backup_interactive() {
  local DB=$1
  shift
  local FULLS=("$@")
  # Filter out empty or invalid entries
  local VALID_FULLS=()
  for f in "${FULLS[@]}"; do
    if [[ -n "$f" && -f "$f" ]]; then
      VALID_FULLS+=("$f")
    fi
  done
  if [[ ${#VALID_FULLS[@]} -eq 0 ]]; then
    if [[ "$DEBUG_MODE" == "true" ]]; then
      debug_log "No valid backups found for database $DB" >&2
    fi
    return 1
  fi
  echo "" >&2
  echo "Available backups for database '$DB':" >&2
  echo "======================================" >&2
  # Check if fzf is available for better selection
  if command -v fzf &> /dev/null; then
    if [[ "$DEBUG_MODE" == "true" ]]; then
      debug_log "Using fzf for interactive selection..." >&2
    fi
    local selected_backup
    export -f create_backup_preview
    export DB
    selected_backup=$(printf '%s\n' "${VALID_FULLS[@]}" | fzf --height=20 --reverse --header="Select backup for $DB:" --preview="create_backup_preview {} $DB")
    if [[ -n "$selected_backup" ]]; then
      echo "$selected_backup"
      return 0
    else
      if [[ "$DEBUG_MODE" == "true" ]]; then
        debug_log "No backup selected" >&2
      fi
      return 1
    fi
  else
    # Fallback to simple numbered selection
    if [[ "$DEBUG_MODE" == "true" ]]; then
      debug_log "Using simple selection (install fzf for better experience)..." >&2
    fi
    for i in "${!VALID_FULLS[@]}"; do
      local backup_file="${VALID_FULLS[$i]}"
      local backup_size=$(stat -c%s "$backup_file" 2>/dev/null || stat -f%z "$backup_file" 2>/dev/null || echo "unknown")
      local backup_date=$(stat -c%y "$backup_file" 2>/dev/null || stat -f%Sm "$backup_file" 2>/dev/null || echo "unknown")
      local backup_timestamp=$(basename "$backup_file" | sed -E "s/^${DB}_full_(.*)\.sql\.gz\.enc$/\1/")
      local formatted_timestamp=$(echo "$backup_timestamp" | sed 's/_/ /g' | sed 's/-/:/g')
      echo "  [$((i+1))] $formatted_timestamp (${backup_size} bytes, $backup_date)" >&2
    done
    echo "" >&2
    read -p "Select backup number (1-${#VALID_FULLS[@]}): " selection
    if [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 1 ]] && [[ "$selection" -le ${#VALID_FULLS[@]} ]]; then
      local selected_index=$((selection - 1))
      echo "${VALID_FULLS[$selected_index]}"
      return 0
    else
      if [[ "$DEBUG_MODE" == "true" ]]; then
        debug_log "Invalid selection: $selection" >&2
      fi
      return 1
    fi
  fi
}

# Robust argument parsing for all relevanten Flags
INTERACTIVE_SELECT=true
DEBUG_MODE=false
USE_LAST_BACKUP=false
RESTORE_TIMESTAMP=""
ENCRYPT_KEY_FILE=".backup_encryption_key"

NEW_ARGS=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --debug)
      DEBUG_MODE=true
      VERBOSE=true  # Enable verbose mode when debug is on
      shift
      ;;
    --verbose|-v)
      VERBOSE=true
      shift
      ;;
    --last)
      USE_LAST_BACKUP=true
      shift
      ;;
    --timestamp)
      RESTORE_TIMESTAMP="$2"
      shift 2
      ;;
    --key)
      ENCRYPT_KEY_FILE="$2"
      shift 2
      ;;
    --no-select)
      INTERACTIVE_SELECT=false
      shift
      ;;
    *)
      NEW_ARGS+=("$1")
      shift
      ;;
  esac
done
set -- "${NEW_ARGS[@]}"

# Enable debug output only if debug mode is enabled
if [[ "$DEBUG_MODE" == "true" ]]; then
  set -x  # Enable debug output for each line (very helpful)
fi

# Error handling function
function handle_error {
  local exit_code=$1
  local error_msg=$2
  log_error "$error_msg (exit code: $exit_code)" >&2
  exit $exit_code
}

MARIADB_CONTAINER="mariadb"
BACKUP_DIR="./backups"
BINLOG_DIR="./backups/binlogs"
BINLOG_INFO_DIR="./backups/binlog_info"
INCR_INFO_DIR="./backups/incr"
LOG_FILE="./logs/restore.log"

# Create logs directory if it doesn't exist
mkdir -p "./logs"

# Source environment variables
source .env || handle_error 2 "Failed to source .env file"


log_info "DEBUG: ENCRYPT_KEY_FILE=$ENCRYPT_KEY_FILE DEBUG_MODE=$DEBUG_MODE USE_LAST_BACKUP=$USE_LAST_BACKUP INTERACTIVE_SELECT=$INTERACTIVE_SELECT RESTORE_TIMESTAMP=$RESTORE_TIMESTAMP"

# Override variables with values from .env if they exist
[[ -n "$MARIADB_CONTAINER" ]] && MARIADB_CONTAINER="$MARIADB_CONTAINER"
[[ -n "$BACKUP_DIR" ]] && BACKUP_DIR="$BACKUP_DIR"
[[ -n "$BINLOG_DIR" ]] && BINLOG_DIR="$BINLOG_DIR"
[[ -n "$BINLOG_INFO_DIR" ]] && BINLOG_INFO_DIR="$BINLOG_INFO_DIR"
[[ -n "$INCR_INFO_DIR" ]] && INCR_INFO_DIR="$INCR_INFO_DIR"

# Function to get all databases from MariaDB server
get_all_databases() {
  # Query all databases excluding system databases
  DATABASES=$(docker exec -i "$MARIADB_CONTAINER" mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -N -e "SHOW DATABASES;" | grep -v -E "^(information_schema|performance_schema|mysql|sys)$" 2>/dev/null)
  echo "$DATABASES"
}

# Build list of databases that actually have at least one valid backup file
DBS=()

# Try to get databases from server first
DB_LIST=$(get_all_databases)
if [[ -n "$DB_LIST" ]]; then
  while IFS= read -r DB_NAME; do
    # Only add databases that have backup files
    PATTERN="${BACKUP_DIR}/${DB_NAME}_full_*.sql.gz.enc"
    if compgen -G "$PATTERN" > /dev/null; then
      DBS+=("$DB_NAME")
    else
      if [[ "$DEBUG_MODE" == "true" ]]; then
        debug_log "Database $DB_NAME detected from server but has no backup files"
      fi
    fi
  done <<< "$DB_LIST"
  if [[ "$DEBUG_MODE" == "true" ]]; then
    debug_log "Automatically detected databases with backups: ${DBS[*]}"
  fi
else
  # Fallback to .env file if server query fails
  if [[ "$DEBUG_MODE" == "true" ]]; then
    debug_log "Could not detect databases from server, falling back to .env file"
  fi
  for i in {1..5}; do
    VAR="MARIADB_DATABASE${i}"
    DB_NAME="${!VAR}"
    if [[ -n "$DB_NAME" ]]; then
      # Check if at least one backup file exists for this DB
      PATTERN="${BACKUP_DIR}/${DB_NAME}_full_*.sql.gz.enc"
      if compgen -G "$PATTERN" > /dev/null; then
        DBS+=("$DB_NAME")
      fi
    fi
  done
fi

if [[ ${#DBS[@]} -eq 0 ]]; then
  handle_error 3 "No databases with valid backups found!"
fi

debug_log "Found ${#DBS[@]} databases with backups to restore: ${DBS[*]}"

# Set total databases count for statistics
TOTAL_DATABASES=${#DBS[@]}

# Ensure databases exist
for DB in "${DBS[@]}"; do
  docker exec -i "$MARIADB_CONTAINER" mariadb -e "CREATE DATABASE IF NOT EXISTS $DB;" || log "Warning: Failed to create database $DB - it may already exist"
done

if [[ "$INTERACTIVE_SELECT" == "true" ]]; then
  if [[ "$DEBUG_MODE" == "true" ]]; then
    debug_log "Interactive restore mode - selecting database and backup"
  fi
  SELECTED_DB=""
  if SELECTED_DB=$(select_database_interactive "${DBS[@]}"); then
    debug_log "SELECTED_DB after selection: '$SELECTED_DB'"
  if [[ -z "$SELECTED_DB" ]]; then
      handle_error 4 "No database selected"
    fi
  else
    handle_error 4 "No database selected"
  fi
  if [[ "$SELECTED_DB" == "ALL_DATABASES" ]]; then
    log_info "Selected: ALL_DATABASES - will restore all databases"
    ALL_DATABASES_MODE=true
  else
    log_info "Selected database: $SELECTED_DB"
    DBS=("$SELECTED_DB")
    TOTAL_DATABASES=1
    ALL_DATABASES_MODE=false
  fi
fi

for DB in "${DBS[@]}"; do
  log_info "Processing database: $DB"
  # Ensure database exists before restore
  docker exec -i "$MARIADB_CONTAINER" mariadb -e "CREATE DATABASE IF NOT EXISTS $DB;" || log_warning "Warning: Failed to create database $DB - it may already exist"
  # Find all Full-Backups for this DB, sorted by time
  FULLS=( $(ls -1t ${BACKUP_DIR}/${DB}_full_*.sql.gz.enc 2>/dev/null) )
  if [[ ${#FULLS[@]} -eq 0 ]]; then
    log_warning "No Full Backup found for $DB! Attempting to create a backup first."
    ./backup.sh --full
    if [[ ${#FULLS[@]} -eq 0 ]]; then
      handle_error 3 "Still no Full Backup found for $DB after attempting backup!"
    fi
  fi

  debug_log "Found ${#FULLS[@]} full backups for $DB"

  # Select Full-Backup by timestamp or get the latest
  SELECTED_FULL=""
  SELECTED_BINLOG_INFO=""
  SELECTED_TS=""
  NEXT_FULL_TS=""
  
  if [[ "$INTERACTIVE_SELECT" == "true" && "$ALL_DATABASES_MODE" != "true" ]]; then
    log_info "Selecting backup for database: $DB"
    SELECTED_FULL=""
    if SELECTED_FULL=$(select_backup_interactive "$DB" "${FULLS[@]}"); then
    if [[ -z "$SELECTED_FULL" ]]; then
        handle_error 4 "No backup selected for $DB"
      fi
    else
      handle_error 4 "No backup selected for $DB"
    fi
    
    # Extract timestamp from selected backup
    SELECTED_TS=$(basename "$SELECTED_FULL" | sed -E "s/^${DB}_full_(.*)\.sql\.gz\.enc$/\1/")
    SELECTED_BINLOG_INFO="$BINLOG_INFO_DIR/last_binlog_info_${DB}_${SELECTED_TS}.txt"
    
    if [[ ! -f "$SELECTED_BINLOG_INFO" ]]; then
      log_warning "Warning: No binlog info file found for selected backup, attempting to continue..."
    fi
    
    log_info "Selected backup for $DB: $SELECTED_TS"
  else
    # Automatically take the latest backup
    SELECTED_FULL="${FULLS[0]}"
    SELECTED_TS=$(basename "$SELECTED_FULL" | sed -E "s/^${DB}_full_(.*)\.sql\.gz\.enc$/\1/")
    SELECTED_BINLOG_INFO="$BINLOG_INFO_DIR/last_binlog_info_${DB}_${SELECTED_TS}.txt"
    log_info "Automatically selected latest backup for $DB: $SELECTED_TS"
  fi
  
  if [[ -z "$SELECTED_FULL" || -z "$SELECTED_BINLOG_INFO" ]]; then
    handle_error 4 "No matching Full-Backup/Binlog-Info for $DB found!"
  fi

  # Find the End-Binlog-Info (last incremental backup)
  # Search for Binlog-Info file with the latest timestamp after the Full-Backup
  END_BINLOG_INFO=""
  END_BINLOG=""
  END_POS=""
  # Look in both the main backup directory and the incr directory
  BINLOG_INFOS=( $(ls -1t ${BINLOG_INFO_DIR}/last_binlog_info_${DB}_*.txt ${INCR_INFO_DIR}/last_binlog_info_${DB}_*.txt 2>/dev/null) )
  for INFO in "${BINLOG_INFOS[@]}"; do
    INFO_TS=$(basename "$INFO" | sed "s/last_binlog_info_${DB}_\(.*\)\.txt/\1/")
    if [[ "$INFO_TS" > "$SELECTED_TS" ]]; then
      END_BINLOG_INFO="$INFO"
      break
    fi
  done
  if [[ -n "$END_BINLOG_INFO" ]]; then
    read END_BINLOG END_POS < "$END_BINLOG_INFO"
    log_info "Binlogs will only be applied up to $END_BINLOG position $END_POS (last incremental backup)."
  fi

  debug_log "Using Full Backup: $SELECTED_FULL"
  debug_log "Using Binlog-Info: $SELECTED_BINLOG_INFO"
  if [[ -n "$NEXT_FULL_TS" ]]; then
    debug_log "Binlogs will only be applied up to the next Full-Backup ($NEXT_FULL_TS)."
  fi

  # Read Binlog information from file
  read START_BINLOG START_POS < "$SELECTED_BINLOG_INFO"
  log_info "Binlog-Info read: $START_BINLOG position $START_POS for $DB"

  # Track backup size
  BACKUP_SIZE=$(stat -c%s "$SELECTED_FULL" 2>/dev/null || stat -f%z "$SELECTED_FULL" 2>/dev/null || echo "0")
  TOTAL_BACKUP_SIZE=$((TOTAL_BACKUP_SIZE + BACKUP_SIZE))

  # Prepare Restore
  log_info "Restoring database $DB from Full-Backup..."
  
  # Start transaction for atomic restore
  docker exec -i "$MARIADB_CONTAINER" mariadb -e "START TRANSACTION;" "$DB" || handle_error 5 "Failed to start transaction"
  
  # Decrypt file once - target is simple .sql.gz
  DECRYPTED_FILE="${SELECTED_FULL%.enc}"
  log_info "Decrypting backup file for $DB ..."
  ./encrypt_backup.sh --decrypt "$SELECTED_FULL" --key "$ENCRYPT_KEY_FILE" || handle_error 10 "Error decrypting $SELECTED_FULL"
  
  # Restore the decrypted file
  zcat "$DECRYPTED_FILE" | docker exec -i "$MARIADB_CONTAINER" mariadb -p"$MARIADB_ROOT_PASSWORD" "$DB" || { 
    docker exec -i "$MARIADB_CONTAINER" mariadb -e "ROLLBACK;" "$DB" 2>/dev/null
    rm -f "$DECRYPTED_FILE"
    handle_error 6 "Full Backup Restore for $DB failed!"
  }
  
  # Clean up decrypted file
  rm -f "$DECRYPTED_FILE"
  log_info "Full Backup for $DB applied."

  # Function to validate binlog file before processing
  validate_binlog_file() {
    local basename="$1"
    local container_path="/tmp/binlogs/$basename"
    
    # Check if file exists in container
    if ! docker exec "$MARIADB_CONTAINER" test -f "$container_path"; then
      log_error "Binlog file $basename not found in container"
      return 1
    fi
    
    # Check if file is a valid binlog file using mysqlbinlog
    if ! docker exec "$MARIADB_CONTAINER" sh -c "$MYSQLBINLOG_CMD --short-form --start-position=4 $container_path | head -1" &>/dev/null; then
      log_warning "File $basename may not be a valid binary log file, will attempt processing anyway"
    fi
    
    return 0
  }
  
  # Function to apply binlog with fallback options for GTID issues
  apply_binlog_with_fallback() {
    local db="$1"
    local basename="$2"
    local cmd="$3"
    local options="$4"
    
    # Try with GTID handling first
    if docker exec -i "$MARIADB_CONTAINER" sh -c "$cmd --database=$db --force-if-open --skip-gtids $options /tmp/binlogs/$basename | mariadb -p\"$MARIADB_ROOT_PASSWORD\" $db" 2>/dev/null; then
      return 0
    fi
    
    # Fallback 1: Try without GTID flags
    log_warning "GTID application failed for $basename, trying without GTID flags..."
    if docker exec -i "$MARIADB_CONTAINER" sh -c "$cmd --database=$db --force-if-open $options /tmp/binlogs/$basename | mariadb -p\"$MARIADB_ROOT_PASSWORD\" $db" 2>/dev/null; then
      return 0
    fi
    
    # Fallback 2: Try without force-if-open
    log_warning "Force-if-open failed for $basename, trying basic application..."
    if docker exec -i "$MARIADB_CONTAINER" sh -c "$cmd --database=$db $options /tmp/binlogs/$basename | mariadb -p\"$MARIADB_ROOT_PASSWORD\" $db" 2>/dev/null; then
      return 0
    fi
    
    # Fallback 3: Try without database filter (last resort)
    log_warning "Database-specific application failed for $basename, trying without database filter..."
    if docker exec -i "$MARIADB_CONTAINER" sh -c "$cmd --force-if-open --skip-gtids $options /tmp/binlogs/$basename | mariadb -p\"$MARIADB_ROOT_PASSWORD\" $db" 2>/dev/null; then
      return 0
    fi
    
    # All fallbacks failed
    return 1
  }

  log_info "Applying Binlogs from $START_BINLOG starting at position $START_POS..."
  # Only select actual binlog files (exclude .index files)
  BINLOG_FILES=$(ls -1 ${BINLOG_DIR}/mysql-bin.[0-9]* 2>/dev/null | grep -v '\.index$' | sort || true)
  if [[ -z "$BINLOG_FILES" ]]; then
    log_warning "No Binlog files found, skipping incremental restore."
    docker exec -i "$MARIADB_CONTAINER" mariadb -e "COMMIT;" "$DB" || handle_error 7 "Failed to commit transaction after full backup"
  else
    # Check if mysqlbinlog is in the path, if not, try to find it
    if ! docker exec "$MARIADB_CONTAINER" which mysqlbinlog &>/dev/null; then
      MYSQLBINLOG_PATH=$(docker exec "$MARIADB_CONTAINER" find / -name mysqlbinlog 2>/dev/null | head -n1)
      if [[ -z "$MYSQLBINLOG_PATH" ]]; then
        MYSQLBINLOG_PATH=$(docker exec "$MARIADB_CONTAINER" find / -name mariadb-binlog 2>/dev/null | head -n1)
      fi
      if [[ -z "$MYSQLBINLOG_PATH" ]]; then
        docker exec -i "$MARIADB_CONTAINER" mariadb -e "ROLLBACK;" "$DB" 2>/dev/null
        handle_error 9 "Neither mysqlbinlog nor mariadb-binlog found in container"
      fi
      MYSQLBINLOG_CMD="$MYSQLBINLOG_PATH"
    else
      MYSQLBINLOG_CMD="mysqlbinlog"
    fi
    
    END_REACHED=0
    DB_BINLOGS_PROCESSED=0
    DB_BINLOGS_SKIPPED=0
    DB_BINLOGS_ERRORS=0
    DB_BINLOG_SIZE=0
    
    for BINLOG in $BINLOG_FILES; do
      BASENAME=$(basename "$BINLOG")
      if [[ "$BASENAME" < "$START_BINLOG" ]]; then
        debug_log "Skipping $BASENAME (before start point)"
        DB_BINLOGS_SKIPPED=$((DB_BINLOGS_SKIPPED + 1))
        TOTAL_BINLOGS_SKIPPED=$((TOTAL_BINLOGS_SKIPPED + 1))
        continue
      fi
      
      # Track binlog size
      BINLOG_SIZE=$(stat -c%s "$BINLOG" 2>/dev/null || stat -f%z "$BINLOG" 2>/dev/null || echo "0")
      DB_BINLOG_SIZE=$((DB_BINLOG_SIZE + BINLOG_SIZE))
      TOTAL_BINLOG_SIZE=$((TOTAL_BINLOG_SIZE + BINLOG_SIZE))
      
      # Copy Binlog to container temp
      docker cp "$BINLOG" "$MARIADB_CONTAINER:/tmp/binlogs/$BASENAME" || handle_error 8 "Failed to copy binlog to container"
      
      # Decide how to apply the binlog
      if [[ -n "$END_BINLOG" && "$BASENAME" > "$END_BINLOG" ]]; then
        log_info "Binlog $BASENAME is after End-Binlog ($END_BINLOG), stopping."
        break
      fi
      
      # Validate binlog file before processing
      if ! validate_binlog_file "$BASENAME"; then
        log_warning "Skipping invalid binlog file: $BASENAME"
        DB_BINLOGS_SKIPPED=$((DB_BINLOGS_SKIPPED + 1))
        TOTAL_BINLOGS_SKIPPED=$((TOTAL_BINLOGS_SKIPPED + 1))
        continue
      fi
      
      if [[ "$BASENAME" == "$START_BINLOG" && "$BASENAME" == "$END_BINLOG" && -n "$END_BINLOG" ]]; then
        log_info "Applying $BASENAME (start=$START_POS, stop=$END_POS) for $DB"
        if ! apply_binlog_with_fallback "$DB" "$BASENAME" "$MYSQLBINLOG_CMD" "--start-position=$START_POS --stop-position=$END_POS"; then
          docker exec -i "$MARIADB_CONTAINER" mariadb -e "ROLLBACK;" "$DB" 2>/dev/null
          DB_BINLOGS_ERRORS=$((DB_BINLOGS_ERRORS + 1))
          TOTAL_BINLOGS_ERRORS=$((TOTAL_BINLOGS_ERRORS + 1))
          handle_error 10 "Failed to apply binlog $BASENAME with all fallback methods"
        fi
        DB_BINLOGS_PROCESSED=$((DB_BINLOGS_PROCESSED + 1))
        TOTAL_BINLOGS_PROCESSED=$((TOTAL_BINLOGS_PROCESSED + 1))
        END_REACHED=1
        break
      elif [[ "$BASENAME" == "$START_BINLOG" ]]; then
        log_info "Applying $BASENAME (start=$START_POS) for $DB"
        if ! apply_binlog_with_fallback "$DB" "$BASENAME" "$MYSQLBINLOG_CMD" "--start-position=$START_POS"; then
          docker exec -i "$MARIADB_CONTAINER" mariadb -e "ROLLBACK;" "$DB" 2>/dev/null
          DB_BINLOGS_ERRORS=$((DB_BINLOGS_ERRORS + 1))
          TOTAL_BINLOGS_ERRORS=$((TOTAL_BINLOGS_ERRORS + 1))
          handle_error 11 "Failed to apply binlog $BASENAME with all fallback methods"
        fi
        DB_BINLOGS_PROCESSED=$((DB_BINLOGS_PROCESSED + 1))
        TOTAL_BINLOGS_PROCESSED=$((TOTAL_BINLOGS_PROCESSED + 1))
      elif [[ -n "$END_BINLOG" && "$BASENAME" == "$END_BINLOG" ]]; then
        log_info "Applying $BASENAME (stop=$END_POS) for $DB"
        if ! apply_binlog_with_fallback "$DB" "$BASENAME" "$MYSQLBINLOG_CMD" "--stop-position=$END_POS"; then
          docker exec -i "$MARIADB_CONTAINER" mariadb -e "ROLLBACK;" "$DB" 2>/dev/null
          DB_BINLOGS_ERRORS=$((DB_BINLOGS_ERRORS + 1))
          TOTAL_BINLOGS_ERRORS=$((TOTAL_BINLOGS_ERRORS + 1))
          handle_error 12 "Failed to apply binlog $BASENAME with all fallback methods"
        fi
        DB_BINLOGS_PROCESSED=$((DB_BINLOGS_PROCESSED + 1))
        TOTAL_BINLOGS_PROCESSED=$((TOTAL_BINLOGS_PROCESSED + 1))
        END_REACHED=1
        break
      else
        log_info "Applying $BASENAME completely for $DB"
        if ! apply_binlog_with_fallback "$DB" "$BASENAME" "$MYSQLBINLOG_CMD" ""; then
          docker exec -i "$MARIADB_CONTAINER" mariadb -e "ROLLBACK;" "$DB" 2>/dev/null
          DB_BINLOGS_ERRORS=$((DB_BINLOGS_ERRORS + 1))
          TOTAL_BINLOGS_ERRORS=$((TOTAL_BINLOGS_ERRORS + 1))
          handle_error 13 "Failed to apply binlog $BASENAME with all fallback methods"
        fi
        DB_BINLOGS_PROCESSED=$((DB_BINLOGS_PROCESSED + 1))
        TOTAL_BINLOGS_PROCESSED=$((TOTAL_BINLOGS_PROCESSED + 1))
      fi
      
      # Delete temporary binlogs in container after each run
      docker exec "$MARIADB_CONTAINER" rm -f /tmp/binlogs/$BASENAME
    done
    
    # Commit transaction after all binlogs are applied
    docker exec -i "$MARIADB_CONTAINER" mariadb -e "COMMIT;" "$DB" || handle_error 14 "Failed to commit transaction after binlog restore"
    
    if [[ $END_REACHED -eq 0 && -n "$END_BINLOG" ]]; then
      log_warning "Warning: Last incremental backup was not found as Binlog-End."
    fi
    
    # Log database-specific statistics
    debug_log "Database $DB: $DB_BINLOGS_PROCESSED binlogs processed, $DB_BINLOGS_SKIPPED skipped, $DB_BINLOGS_ERRORS errors"
  fi
  
  PROCESSED_DATABASES=$((PROCESSED_DATABASES + 1))
done

log_info "Checking database content after restore..."
for DB in "${DBS[@]}"; do
  docker exec -i "$MARIADB_CONTAINER" mariadb -e "USE $DB; SHOW TABLES;"
  TABLE=$(docker exec -i "$MARIADB_CONTAINER" mariadb -N -e "SHOW TABLES FROM $DB;" | head -n1 | tr -d '\r')
  if [[ -n "$TABLE" ]]; then
    docker exec -i "$MARIADB_CONTAINER" mariadb -e "USE $DB; SELECT COUNT(*) FROM $TABLE;"
  fi
done

log_success "Restore completed successfully."

# End timing and calculate statistics
RESTORE_END_TIME=$(date +%s)
RESTORE_DURATION=$((RESTORE_END_TIME - RESTORE_START_TIME))

# Convert sizes to human readable format
format_size() {
  local size=$1
  if [[ $size -gt 1073741824 ]]; then
    echo "$(echo "scale=2; $size/1073741824" | bc -l 2>/dev/null || echo "$((size/1073741824))") GB"
  elif [[ $size -gt 1048576 ]]; then
    echo "$(echo "scale=2; $size/1048576" | bc -l 2>/dev/null || echo "$((size/1048576))") MB"
  elif [[ $size -gt 1024 ]]; then
    echo "$(echo "scale=2; $size/1024" | bc -l 2>/dev/null || echo "$((size/1024))") KB"
  else
    echo "$size bytes"
  fi
}

BACKUP_SIZE_HR=$(format_size $TOTAL_BACKUP_SIZE)
BINLOG_SIZE_HR=$(format_size $TOTAL_BINLOG_SIZE)
TOTAL_SIZE_HR=$(format_size $((TOTAL_BACKUP_SIZE + TOTAL_BINLOG_SIZE)))

# Calculate performance metrics
if [[ $RESTORE_DURATION -gt 0 ]]; then
  BACKUP_THROUGHPUT=$(echo "scale=2; $TOTAL_BACKUP_SIZE / $RESTORE_DURATION" | bc -l 2>/dev/null || echo "0")
  BACKUP_THROUGHPUT_HR=$(format_size $BACKUP_THROUGHPUT)
  BINLOG_THROUGHPUT=$(echo "scale=2; $TOTAL_BINLOG_SIZE / $RESTORE_DURATION" | bc -l 2>/dev/null || echo "0")
  BINLOG_THROUGHPUT_HR=$(format_size $BINLOG_THROUGHPUT)
else
  BACKUP_THROUGHPUT_HR="0 bytes/s"
  BINLOG_THROUGHPUT_HR="0 bytes/s"
fi

# Format duration
if [[ $RESTORE_DURATION -gt 3600 ]]; then
  DURATION_HR="$((RESTORE_DURATION / 3600))h $(( (RESTORE_DURATION % 3600) / 60 ))m $((RESTORE_DURATION % 60))s"
elif [[ $RESTORE_DURATION -gt 60 ]]; then
  DURATION_HR="$((RESTORE_DURATION / 60))m $((RESTORE_DURATION % 60))s"
else
  DURATION_HR="${RESTORE_DURATION}s"
fi

log_info ""
log_info "╔══════════════════════════════════════════════════════════════════════════════╗"
log_info "║                           RESTORE STATISTICS                                ║"
log_info "╠══════════════════════════════════════════════════════════════════════════════╣"
log_info "║  TIMING:                                                                     ║"
log_info "║    Start Time:  $RESTORE_START_DATE"
log_info "║    End Time:    $(date '+%Y-%m-%d %H:%M:%S')"
log_info "║    Duration:    $DURATION_HR ($RESTORE_DURATION seconds)"
log_info "║                                                                              ║"
log_info "║  DATABASES:                                                                  ║"
log_info "║    Total Found:     $TOTAL_DATABASES"
log_info "║    Processed:       $PROCESSED_DATABASES"
if [[ $TOTAL_DATABASES -gt 0 ]]; then
  log_info "║    Success Rate:    $(( (PROCESSED_DATABASES * 100) / TOTAL_DATABASES ))%"
else
  log_info "║    Success Rate:    N/A (no databases found)"
fi
log_info "║                                                                              ║"
log_info "║  BINLOG PROCESSING:                                                          ║"
log_info "║    Processed:       $TOTAL_BINLOGS_PROCESSED"
log_info "║    Skipped:         $TOTAL_BINLOGS_SKIPPED"
log_info "║    Errors:          $TOTAL_BINLOGS_ERRORS"
if [[ $((TOTAL_BINLOGS_PROCESSED + TOTAL_BINLOGS_ERRORS)) -gt 0 ]]; then
  log_info "║    Success Rate:    $(( (TOTAL_BINLOGS_PROCESSED * 100) / (TOTAL_BINLOGS_PROCESSED + TOTAL_BINLOGS_ERRORS) ))%"
else
  log_info "║    Success Rate:    N/A (no binlogs processed)"
fi
log_info "║                                                                              ║"
log_info "║  DATA VOLUMES:                                                               ║"
log_info "║    Backup Size:     $BACKUP_SIZE_HR"
log_info "║    Binlog Size:     $BINLOG_SIZE_HR"
log_info "║    Total Size:      $TOTAL_SIZE_HR"
log_info "║                                                                              ║"
log_info "║  PERFORMANCE:                                                               ║"
log_info "║    Backup Throughput: $BACKUP_THROUGHPUT_HR/s"
log_info "║    Binlog Throughput: $BINLOG_THROUGHPUT_HR/s"
if [[ $PROCESSED_DATABASES -gt 0 ]]; then
  log_info "║    Avg DB Time:     $((RESTORE_DURATION / PROCESSED_DATABASES))s per database"
else
  log_info "║    Avg DB Time:     N/A (no databases processed)"
fi
log_info "║                                                                              ║"
log_info "║  SYSTEM INFO:                                                               ║"
log_info "║    Container:       $MARIADB_CONTAINER"
log_info "║    Backup Dir:      $BACKUP_DIR"
log_info "║    Binlog Dir:      $BINLOG_DIR"
log_info "║    Log File:        $LOG_FILE"
log_info "╚══════════════════════════════════════════════════════════════════════════════╝"
log_info ""
