#!/bin/bash
cd "$(dirname "$0")"

set -o pipefail

# Load logging functions
source "./lib/logging.sh"

# Version
CLEANUP_VERSION="1.0.0"

# Source environment variables
source .env

# Set default values
BACKUP_DIR="./backups"
BINLOG_DIR="$BACKUP_DIR/binlogs"
BINLOG_INFO_DIR="$BACKUP_DIR/binlog_info"
INCR_INFO_DIR="$BACKUP_DIR/incr"
LOG_FILE="./logs/cleanup_binlogs.log"
KEEP_GENERATIONS=2

# Create logs directory if it doesn't exist
mkdir -p "./logs"

# Error handling function
function handle_error {
  local exit_code=$1
  local error_msg=$2
  log_error "$error_msg (exit code: $exit_code)"
  log_both "ERROR" "$error_msg (exit code: $exit_code)" "$LOG_FILE"
  exit $exit_code
}

# Override variables with values from .env if they exist
[[ -n "$BACKUP_DIR" ]] && BACKUP_DIR="$BACKUP_DIR"
[[ -n "$BINLOG_DIR" ]] && BINLOG_DIR="$BINLOG_DIR"
[[ -n "$BINLOG_INFO_DIR" ]] && BINLOG_INFO_DIR="$BINLOG_INFO_DIR"
[[ -n "$INCR_INFO_DIR" ]] && INCR_INFO_DIR="$INCR_INFO_DIR"
[[ -n "$MARIADB_CONTAINER" ]] && MARIADB_CONTAINER="$MARIADB_CONTAINER"

# Function to get all databases from MariaDB server
get_all_databases() {
  # Query all databases excluding system databases
  DATABASES=$(docker exec -i "$MARIADB_CONTAINER" mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -N -e "SHOW DATABASES;" | grep -v -E "^(information_schema|performance_schema|mysql|sys)$" 2>/dev/null)
  echo "$DATABASES"
}

# Create log directory if it doesn't exist
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
mkdir -p "$BACKUP_DIR" 2>/dev/null
mkdir -p "$BINLOG_DIR" 2>/dev/null
mkdir -p "$BINLOG_INFO_DIR" 2>/dev/null
mkdir -p "$INCR_INFO_DIR" 2>/dev/null

log_info "Starting binlog cleanup process (version $CLEANUP_VERSION)"
log_both "INFO" "Starting binlog cleanup process (version $CLEANUP_VERSION)" "$LOG_FILE"

# Get all database names from the server or fallback to .env
DBS=()

# Try to get databases from server first
DB_LIST=$(get_all_databases)
if [[ -n "$DB_LIST" ]]; then
  # Read the databases into the array
  while IFS= read -r line; do
    # Check if there are backups for this database
    if ls -1 ${BACKUP_DIR}/${line}_full_*.sql.gz.enc >/dev/null 2>&1; then
      DBS+=("$line")
    fi
  done <<< "$DB_LIST"
  log_info "Automatically detected databases with backups: ${DBS[*]}"
  log_both "INFO" "Automatically detected databases with backups: ${DBS[*]}" "$LOG_FILE"
else
  # Fallback to .env file if server query fails
  log_warning "Could not detect databases from server, falling back to .env file"
  log_both "WARNING" "Could not detect databases from server, falling back to .env file" "$LOG_FILE"
for i in {1..5}; do
  VAR="MARIADB_DATABASE${i}"
  DB_NAME="${!VAR}"
  if [[ -n "$DB_NAME" ]]; then
      # Only add if backups exist
      if ls -1 ${BACKUP_DIR}/${DB_NAME}_full_*.sql.gz.enc >/dev/null 2>&1; then
    DBS+=("$DB_NAME")
      fi
  fi
done
fi

log_info "Found ${#DBS[@]} databases to check: ${DBS[*]}"
log_both "INFO" "Found ${#DBS[@]} databases to check: ${DBS[*]}" "$LOG_FILE"

# Find the oldest still needed binlog position (across all DBs)
OLDEST_BINLOG=""
OLDEST_POSITION=""

for DB in "${DBS[@]}"; do
  log_info "Checking binlog requirements for database: $DB"
  log_both "INFO" "Checking binlog requirements for database: $DB" "$LOG_FILE"
  
  # Find all Full-Backups for this DB, sorted by time (oldest first)
  FULLS=( $(ls -1t ${BACKUP_DIR}/${DB}_full_*.sql.gz.enc 2>/dev/null | sort) )
  N_FULLS=${#FULLS[@]}
  
  if [[ $N_FULLS -eq 0 ]]; then
    log_warning "No full backups found for database $DB, skipping"
    log_both "WARNING" "No full backups found for database $DB, skipping" "$LOG_FILE"
    continue
  fi
  
  log_info "Found $N_FULLS full backups for $DB"
  log_both "INFO" "Found $N_FULLS full backups for $DB" "$LOG_FILE"
  
  if (( N_FULLS >= KEEP_GENERATIONS )); then
    # The oldest generation to keep
    OLDEST_TO_KEEP="${FULLS[N_FULLS-KEEP_GENERATIONS]}"
    
    # Zeitstempel-Extraktion:
    TS=$(basename "$OLDEST_TO_KEEP" | sed "s/${DB}_full_\(.*\)\.sql\.gz\.enc/\1/")
    
    # Look for binlog info in backup files (full backups)
    INFO_TXT="$BINLOG_INFO_DIR/last_binlog_info_${DB}_${TS}.txt"
    if [[ ! -f "$INFO_TXT" ]]; then
      INFO_TXT="$INCR_INFO_DIR/last_binlog_info_${DB}_${TS}.txt"
    fi
    
    if [[ -f "$INFO_TXT" ]]; then
      read BINLOG_FILE BINLOG_POS < "$INFO_TXT"
      log_info "Oldest backup for $DB requires binlog: $BINLOG_FILE at position $BINLOG_POS"
      log_both "INFO" "Oldest backup for $DB requires binlog: $BINLOG_FILE at position $BINLOG_POS" "$LOG_FILE"
      
      if [[ -z "$OLDEST_BINLOG" || "$BINLOG_FILE" < "$OLDEST_BINLOG" ]]; then
        OLDEST_BINLOG="$BINLOG_FILE"
        OLDEST_POSITION="$BINLOG_POS"
        log_info "Updated oldest required binlog to: $OLDEST_BINLOG"
        log_both "INFO" "Updated oldest required binlog to: $OLDEST_BINLOG" "$LOG_FILE"
      fi
    else
      log_warning "No binlog info file found for $DB backup at $TS"
      log_both "WARNING" "No binlog info file found for $DB backup at $TS" "$LOG_FILE"
    fi
  else
    log_warning "Only $N_FULLS backups for $DB (less than $KEEP_GENERATIONS), keeping all binlogs"
    log_both "WARNING" "Only $N_FULLS backups for $DB (less than $KEEP_GENERATIONS), keeping all binlogs" "$LOG_FILE"
  fi
done

if [[ -z "$OLDEST_BINLOG" ]]; then
  log_info "No binlog cleanup needed (insufficient backups or no binlog info found)"
  log_both "INFO" "No binlog cleanup needed (insufficient backups or no binlog info found)" "$LOG_FILE"
  exit 0
fi

log_info "Oldest required binlog: $OLDEST_BINLOG at position $OLDEST_POSITION"
log_both "INFO" "Oldest required binlog: $OLDEST_BINLOG at position $OLDEST_POSITION" "$LOG_FILE"

# Delete all binlogs that are older than OLDEST_BINLOG
if [[ ! -d "$BINLOG_DIR" ]]; then
  log_warning "Binlog directory not found: $BINLOG_DIR"
  log_both "WARNING" "Binlog directory not found: $BINLOG_DIR" "$LOG_FILE"
  exit 0
fi

log_info "Starting cleanup of binlogs older than $OLDEST_BINLOG..."
log_both "INFO" "Starting cleanup of binlogs older than $OLDEST_BINLOG..." "$LOG_FILE"

DELETED_COUNT=0
TOTAL_SIZE=0

# Get all binlog files and sort them
BINLOG_FILES=( $(ls -1 $BINLOG_DIR/mysql-bin.* 2>/dev/null | sort) )

if [[ ${#BINLOG_FILES[@]} -eq 0 ]]; then
  log_info "No binlog files found in $BINLOG_DIR"
  log_both "INFO" "No binlog files found in $BINLOG_DIR" "$LOG_FILE"
  exit 0
fi

for BL in "${BINLOG_FILES[@]}"; do
  BLBASE=$(basename "$BL")
  
  if [[ "$BLBASE" < "$OLDEST_BINLOG" ]]; then
    # Get file size before deletion for reporting
    if [[ -f "$BL" ]]; then
      FILE_SIZE=$(stat -c%s "$BL" 2>/dev/null || stat -f%z "$BL" 2>/dev/null || echo "0")
      TOTAL_SIZE=$((TOTAL_SIZE + FILE_SIZE))
      
      log_info "Deleting old binlog: $BLBASE (size: $FILE_SIZE bytes)"
      log_both "INFO" "Deleting old binlog: $BLBASE (size: $FILE_SIZE bytes)" "$LOG_FILE"
      rm -f "$BL"
      
      if [[ $? -eq 0 ]]; then
        DELETED_COUNT=$((DELETED_COUNT + 1))
        log_success "Successfully deleted: $BLBASE"
        log_both "SUCCESS" "Successfully deleted: $BLBASE" "$LOG_FILE"
      else
        log_error "Failed to delete: $BLBASE"
        log_both "ERROR" "Failed to delete: $BLBASE" "$LOG_FILE"
      fi
    fi
  else
    log_info "Keeping binlog: $BLBASE (not older than $OLDEST_BINLOG)"
    log_both "INFO" "Keeping binlog: $BLBASE (not older than $OLDEST_BINLOG)" "$LOG_FILE"
  fi
done

# Convert total size to human readable format
if [[ $TOTAL_SIZE -gt 0 ]]; then
  if [[ $TOTAL_SIZE -gt 1048576 ]]; then
    SIZE_HR=$(echo "scale=2; $TOTAL_SIZE/1048576" | bc -l 2>/dev/null || echo "$((TOTAL_SIZE/1048576))")
    SIZE_UNIT="MB"
  elif [[ $TOTAL_SIZE -gt 1024 ]]; then
    SIZE_HR=$(echo "scale=2; $TOTAL_SIZE/1024" | bc -l 2>/dev/null || echo "$((TOTAL_SIZE/1024))")
    SIZE_UNIT="KB"
  else
    SIZE_HR=$TOTAL_SIZE
    SIZE_UNIT="bytes"
  fi
else
  SIZE_HR="0"
  SIZE_UNIT="bytes"
fi

log_success "Binlog cleanup completed successfully"
log_both "SUCCESS" "Binlog cleanup completed successfully" "$LOG_FILE"
log_info "Deleted $DELETED_COUNT binlog files"
log_both "INFO" "Deleted $DELETED_COUNT binlog files" "$LOG_FILE"
log_info "Freed up approximately $SIZE_HR $SIZE_UNIT of disk space"
log_both "INFO" "Freed up approximately $SIZE_HR $SIZE_UNIT of disk space" "$LOG_FILE"
log_info "Oldest kept binlog: $OLDEST_BINLOG"
log_both "INFO" "Oldest kept binlog: $OLDEST_BINLOG" "$LOG_FILE"