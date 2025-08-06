#!/bin/bash
cd "$(dirname "$0")"

set -e

# Load logging functions
source "./lib/logging.sh"

# Version
CLEANUP_VERSION="1.0.0"

# Source environment variables
source .env

# Default settings
BACKUP_DIR=${BACKUP_DIR:-"./backups"}
BINLOG_DIR=${BINLOG_DIR:-"$BACKUP_DIR/binlogs"}
BINLOG_INFO_DIR=${BINLOG_INFO_DIR:-"$BACKUP_DIR/binlog_info"}
INCR_INFO_DIR=${INCR_INFO_DIR:-"$BACKUP_DIR/incr"}
KEEP_GENERATIONS=7
MARIADB_CONTAINER=${MARIADB_CONTAINER:-"mariadb"}
LOG_FILE="./logs/cleanup_backups.log"

# Create logs directory if it doesn't exist
mkdir -p "./logs"

# Function to get all databases from MariaDB server
get_all_databases() {
  # Query all databases excluding system databases
  DATABASES=$(docker exec -i "$MARIADB_CONTAINER" mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -N -e "SHOW DATABASES;" | grep -v -E "^(information_schema|performance_schema|mysql|sys)$" 2>/dev/null)
  echo "$DATABASES"
}

# Ensure directories exist
mkdir -p "$BACKUP_DIR" 2>/dev/null
mkdir -p "$BINLOG_DIR" 2>/dev/null
mkdir -p "$BINLOG_INFO_DIR" 2>/dev/null
mkdir -p "$INCR_INFO_DIR" 2>/dev/null

# Get databases using combined approach - server first, then fallback to existing backups
DBS=()

# Try to get databases from server first
DB_LIST=$(get_all_databases)
if [[ -n "$DB_LIST" ]]; then
  # Read the databases into the array
  while IFS= read -r line; do
    # Check if there are backups for this database
    if ls -1 $BACKUP_DIR/${line}_full_*.sql.gz.enc >/dev/null 2>&1; then
      DBS+=("$line")
    fi
  done <<< "$DB_LIST"
  log_info "Automatically detected databases with backups: ${DBS[*]}"
  log_both "INFO" "Automatically detected databases with backups: ${DBS[*]}" "$LOG_FILE"
else
  # Fallback to existing backup files
  log_warning "Could not detect databases from server, using existing backup files"
  log_both "WARNING" "Could not detect databases from server, using existing backup files" "$LOG_FILE"
  # Find all databases from encrypted backups
DBS=($(ls $BACKUP_DIR/*_full_*.sql.gz.enc 2>/dev/null | sed -r 's/.*\/(.*)_full_.*/\1/' | sort | uniq))
fi

for DB in "${DBS[@]}"; do
  log_info "Cleaning up old backups for $DB (keeping last $KEEP_GENERATIONS generations)..."
  log_both "INFO" "Cleaning up old backups for $DB (keeping last $KEEP_GENERATIONS generations)..." "$LOG_FILE"
  # Find all full backups, sorted by time (oldest first)
  FULLS=( $(ls -1 $BACKUP_DIR/${DB}_full_*.sql.gz.enc 2>/dev/null | sort) )
  N_FULLS=${#FULLS[@]}
  if (( N_FULLS > KEEP_GENERATIONS )); then
    for ((i=0; i<N_FULLS-KEEP_GENERATIONS; i++)); do
      OLD_FULL="${FULLS[$i]}"
      # Timestamp extraction:
      TS=$(basename "$OLD_FULL" | sed "s/${DB}_full_\(.*\)\.sql\.gz\.enc/\1/")
      log_info "  - Deleting $OLD_FULL"
      log_both "INFO" "  - Deleting $OLD_FULL" "$LOG_FILE"
      rm -f "$OLD_FULL"
      # Also remove binlog info and checksum
      INFO_TXT="$BINLOG_INFO_DIR/last_binlog_info_${DB}_${TS}.txt"
      if [[ -f "$INFO_TXT" ]]; then
        log_info "Deleting binlog info: $INFO_TXT"
        log_both "INFO" "Deleting binlog info: $INFO_TXT" "$LOG_FILE"
        rm -f "$INFO_TXT"
      fi

      # Remove incremental backups with same timestamp
      for INCR_TXT in $INCR_INFO_DIR/last_binlog_info_${DB}_${TS}_incr.txt; do
        if [[ -f "$INCR_TXT" ]]; then
          log_info "  - Deleting $INCR_TXT"
          log_both "INFO" "  - Deleting $INCR_TXT" "$LOG_FILE"
          rm -f "$INCR_TXT"
        fi
      done
      # Incremental
      for INCR_SQL in $BACKUP_DIR/incremental_${DB}_${TS}_*.sql; do
        if [[ -f "$INCR_SQL" ]]; then
          log_info "  - Deleting $INCR_SQL"
          log_both "INFO" "  - Deleting $INCR_SQL" "$LOG_FILE"
          rm -f "$INCR_SQL"
        fi
      done
    done
  fi
  log_success "Cleanup for $DB completed."
  log_both "SUCCESS" "Cleanup for $DB completed." "$LOG_FILE"
done

log_success "Cleanup completed."
log_both "SUCCESS" "Cleanup completed." "$LOG_FILE"