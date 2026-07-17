#!/bin/bash
cd "$(dirname "$0")"

set -o pipefail

source "./lib/logging.sh"

LOG_FILE="./logs/restore.log"
init_logging

VERBOSE=false

debug_log() {
  [[ "$VERBOSE" == "true" ]] && log_debug "$1"
}

RESTORE_START_TIME=$(date +%s)

BACKUP_DIR="./backups"
BINLOG_BACKUP_DIR="$BACKUP_DIR/binlogs"
BINLOG_INFO_DIR="$BACKUP_DIR/binlog_info"
INCR_INFO_DIR="$BACKUP_DIR/incr"
ENCRYPT_KEY_FILE=".backup_encryption_key"

TOTAL_BACKUP_SIZE=0
TOTAL_BINLOG_SIZE=0
TOTAL_BINLOGS_PROCESSED=0
TOTAL_BINLOGS_ERRORS=0
PROCESSED_DATABASES=0

human_size() {
  local bytes=$1
  if [[ $bytes -gt 1048576 ]]; then
    echo "$(echo "scale=2; $bytes/1048576" | bc -l 2>/dev/null || echo $((bytes / 1048576))) MB"
  elif [[ $bytes -gt 1024 ]]; then
    echo "$(echo "scale=2; $bytes/1024" | bc -l 2>/dev/null || echo $((bytes / 1024))) KB"
  else
    echo "$bytes bytes"
  fi
}

get_databases_with_backups() {
  local dbs=()
  for backup_file in "$BACKUP_DIR"/*_full_*.sql.gz.enc; do
    [[ -f "$backup_file" ]] || continue
    db_name=$(basename "$backup_file" | sed 's/_full_.*//')
    if [[ ! " ${dbs[*]} " =~ " ${db_name} " ]] && [[ "$db_name" != "binlogs" ]]; then
      dbs+=("$db_name")
    fi
  done
  echo "${dbs[@]}"
}

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
    echo "  [$((i + 2))] ${DBS[$i]}" >&2
  done

  echo "" >&2
  read -p "Select an option (1-$((1 + ${#DBS[@]}))): " selection

  if [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 1 ]] && [[ "$selection" -le $((1 + ${#DBS[@]})) ]]; then
    if [[ "$selection" -eq 1 ]]; then
      echo "ALL_DATABASES"
    else
      echo "${DBS[$((selection - 2))]}"
    fi
  else
    log_error "Invalid selection: $selection" >&2
    exit 1
  fi
}

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
    local backup_size backup_date size_hr age_text
    backup_size=$(stat -c%s "$backup_file" 2>/dev/null || stat -f%z "$backup_file" 2>/dev/null || echo "0")
    backup_date=$(stat -c%Y "$backup_file" 2>/dev/null || stat -f%m "$backup_file" 2>/dev/null || echo "")
    size_hr=$(human_size "$backup_size")

    if [[ -n "$backup_date" ]]; then
      local age_seconds=$(( $(date +%s) - backup_date ))
      if (( age_seconds >= 86400 )); then
        age_text="$((age_seconds / 86400)) day(s) ago"
      elif (( age_seconds >= 3600 )); then
        age_text="$((age_seconds / 3600)) hour(s) ago"
      elif (( age_seconds >= 60 )); then
        age_text="$((age_seconds / 60)) minute(s) ago"
      else
        age_text="${age_seconds} second(s) ago"
      fi
    else
      age_text="unknown date"
    fi

    local backup_timestamp
    backup_timestamp=$(basename "$backup_file" | sed -E "s/^${DB}_full_(.*)\.sql\.gz\.enc$/\1/")
    echo "[$((i + 1))] $backup_timestamp ($size_hr, $age_text)" >&2
  done

  echo "" >&2
  read -p "Select backup number (1-${#FULLS[@]}): " selection

  if [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 1 ]] && [[ "$selection" -le ${#FULLS[@]} ]]; then
    echo "${FULLS[$((selection - 1))]}"
  else
    log_error "Invalid selection: $selection" >&2
    exit 1
  fi
}

INTERACTIVE_SELECT=true
USE_LAST_BACKUP=false
DATABASE=""
BACKUP_FILE=""
RESTORE_TO_TIMESTAMP=""
SKIP_CONFIRM=false

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
    --yes)
      SKIP_CONFIRM=true
      shift
      ;;
    --verbose)
      VERBOSE=true
      shift
      ;;
    --debug)
      VERBOSE=true
      shift
      ;;
    --help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "OPTIONS:"
      echo "  --database DB          Specify database name"
      echo "  --backup-file FILE     Specify backup file path"
      echo "  --last                 Use the most recent backup (requires --database)"
      echo "  --to-timestamp TS      Restore up to specific timestamp (YYYY-MM-DD HH:MM:SS)"
      echo "  --yes                  Skip the confirmation prompt"
      echo "  --verbose              Enable verbose output"
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

log_info "Starting restore process"

if [[ -f ".env" ]]; then
  source .env
  debug_log "Loaded environment variables from .env"
else
  log_error ".env file not found"
  exit 1
fi

MARIADB_CONTAINER="${MARIADB_CONTAINER:-mariadb}"

if [[ ! -f "$ENCRYPT_KEY_FILE" ]]; then
  log_error "Encryption key not found: $ENCRYPT_KEY_FILE - cannot decrypt backups"
  exit 1
fi

if [[ "$INTERACTIVE_SELECT" == "true" ]]; then
  log_info "Interactive mode - select database and backup"

  DBS_WITH_BACKUPS=( $(get_databases_with_backups) )
  SELECTED_DB=$(select_database_interactive "${DBS_WITH_BACKUPS[@]}")

  if [[ "$SELECTED_DB" == "ALL_DATABASES" ]]; then
    log_info "Selected: ALL_DATABASES. Restoring all databases from their latest backup."
    DATABASE="ALL"
    BACKUP_FILE="LATEST"
  else
    DATABASE="$SELECTED_DB"
    BACKUP_FILES=( $(ls -1t "$BACKUP_DIR/${DATABASE}"_full_*.sql.gz.enc 2>/dev/null) )
    BACKUP_FILE=$(select_backup_interactive "$DATABASE" "${BACKUP_FILES[@]}")
  fi
fi

if [[ "$USE_LAST_BACKUP" == "true" ]]; then
  if [[ -z "$DATABASE" ]]; then
    log_error "--last requires --database parameter"
    exit 1
  fi

  BACKUP_FILE=$(ls -1t "$BACKUP_DIR/${DATABASE}_full_"*.sql.gz.enc 2>/dev/null | head -1)
  if [[ -z "$BACKUP_FILE" ]]; then
    log_error "No backups found for database: $DATABASE"
    exit 1
  fi
fi

if [[ "$DATABASE" == "ALL" ]]; then
  DBS_TO_RESTORE=( $(get_databases_with_backups) )
  log_info "Restoring all databases: ${DBS_TO_RESTORE[*]}"
else
  DBS_TO_RESTORE=("$DATABASE")
fi

# Restoring overwrites live data - make sure the user really wants this.
if [[ "$SKIP_CONFIRM" != "true" ]]; then
  echo "" >&2
  log_warning "This will OVERWRITE the following database(s) in container '$MARIADB_CONTAINER': ${DBS_TO_RESTORE[*]}"
  read -p "Continue? (type 'yes' to confirm): " confirm
  if [[ "$confirm" != "yes" ]]; then
    log_info "Restore cancelled by user"
    exit 0
  fi
fi

# Determine connection method (password via MYSQL_PWD, not on the command line)
DOCKER_ENV=(-e MYSQL_PWD="$MARIADB_ROOT_PASSWORD")
if docker exec "${DOCKER_ENV[@]}" "$MARIADB_CONTAINER" mariadb -u root -e "SELECT 1;" &>/dev/null; then
  :
elif docker exec "$MARIADB_CONTAINER" mariadb -u root -e "SELECT 1;" &>/dev/null; then
  DOCKER_ENV=()
else
  log_error "Cannot connect to MariaDB container: $MARIADB_CONTAINER"
  exit 1
fi

db_exec() {
  docker exec "${DOCKER_ENV[@]}" "$MARIADB_CONTAINER" mariadb -u root "$@"
}

db_exec_stdin() {
  docker exec -i "${DOCKER_ENV[@]}" "$MARIADB_CONTAINER" mariadb -u root "$@"
}

for DB_TO_RESTORE in "${DBS_TO_RESTORE[@]}"; do
  if [[ "$DATABASE" == "ALL" ]]; then
    CURRENT_BACKUP_FILE=$(ls -1t "$BACKUP_DIR/${DB_TO_RESTORE}_full_"*.sql.gz.enc 2>/dev/null | head -1)
    if [[ -z "$CURRENT_BACKUP_FILE" ]]; then
      log_warning "No backup found for $DB_TO_RESTORE. Skipping."
      continue
    fi
  else
    CURRENT_BACKUP_FILE="$BACKUP_FILE"
  fi

  if [[ -z "$DB_TO_RESTORE" || -z "$CURRENT_BACKUP_FILE" ]]; then
    log_error "Database or backup file not specified"
    continue
  fi

  if [[ ! -f "$CURRENT_BACKUP_FILE" ]]; then
    log_error "Backup file not found: $CURRENT_BACKUP_FILE"
    continue
  fi

  log_info "--- Processing database: $DB_TO_RESTORE ---"
  log_info "Selected backup: $CURRENT_BACKUP_FILE"

  BACKUP_TIMESTAMP=$(basename "$CURRENT_BACKUP_FILE" | sed "s/${DB_TO_RESTORE}_full_\(.*\)\.sql\.gz\.enc/\1/")
  debug_log "Backup timestamp: $BACKUP_TIMESTAMP"

  BACKUP_SIZE=$(stat -c%s "$CURRENT_BACKUP_FILE" 2>/dev/null || stat -f%z "$CURRENT_BACKUP_FILE" 2>/dev/null || echo "0")
  TOTAL_BACKUP_SIZE=$((TOTAL_BACKUP_SIZE + BACKUP_SIZE))

  # Step 1: Decrypt and import the full backup
  log_info "Step 1: Decrypting and restoring full backup..."

  if ! ./encrypt_backup.sh --decrypt "$CURRENT_BACKUP_FILE" --key "$ENCRYPT_KEY_FILE"; then
    log_error "Failed to decrypt backup file for $DB_TO_RESTORE"
    continue
  fi

  DECRYPTED_FILE="${CURRENT_BACKUP_FILE%.enc}"

  log_info "Importing backup into database: $DB_TO_RESTORE"
  db_exec -e "CREATE DATABASE IF NOT EXISTS \`$DB_TO_RESTORE\`;"

  if ! db_exec_stdin "$DB_TO_RESTORE" < <(gunzip -c "$DECRYPTED_FILE"); then
    log_error "Failed to import backup for $DB_TO_RESTORE"
    rm -f "$DECRYPTED_FILE"
    continue
  fi

  rm -f "$DECRYPTED_FILE"
  log_success "Full backup for $DB_TO_RESTORE restored successfully"
  PROCESSED_DATABASES=$((PROCESSED_DATABASES + 1))

  # Step 2: Roll forward using binary logs
  log_info "Step 2: Applying binary logs..."

  BINLOG_INFO_FILE="$BINLOG_INFO_DIR/last_binlog_info_${DB_TO_RESTORE}_${BACKUP_TIMESTAMP}.txt"
  if [[ ! -f "$BINLOG_INFO_FILE" ]]; then
    BINLOG_INFO_FILE="$INCR_INFO_DIR/last_binlog_info_${DB_TO_RESTORE}_${BACKUP_TIMESTAMP}.txt"
  fi

  if [[ ! -f "$BINLOG_INFO_FILE" ]]; then
    log_warning "Binlog info file not found for backup $BACKUP_TIMESTAMP"
    log_warning "Cannot apply incremental changes for $DB_TO_RESTORE. Only the full backup was restored."
    continue
  fi

  read -r START_BINLOG_FILE START_BINLOG_POS < "$BINLOG_INFO_FILE"
  log_info "Starting from binlog: $START_BINLOG_FILE at position $START_BINLOG_POS"

  BINLOG_FILES=()
  while IFS= read -r bl_file; do
    bl_name=$(basename "$bl_file")
    if [[ ! "$bl_name" < "$START_BINLOG_FILE" ]]; then
      BINLOG_FILES+=("$bl_file")
    fi
  done < <(find "$BINLOG_BACKUP_DIR" -name "mysql-bin.*" -not -name "*.index" -not -name "*.idx" 2>/dev/null | sort -V)

  log_info "Found ${#BINLOG_FILES[@]} binlog file(s) to process."
  docker exec "$MARIADB_CONTAINER" mkdir -p /tmp/binlogs 2>/dev/null

  for bl_file in "${BINLOG_FILES[@]}"; do
    bl_name=$(basename "$bl_file")
    debug_log "Processing binlog: $bl_name"

    BL_SIZE=$(stat -c%s "$bl_file" 2>/dev/null || stat -f%z "$bl_file" 2>/dev/null || echo "0")
    TOTAL_BINLOG_SIZE=$((TOTAL_BINLOG_SIZE + BL_SIZE))

    BINLOG_OPTS=()
    [[ "$bl_name" == "$START_BINLOG_FILE" ]] && BINLOG_OPTS+=(--start-position="$START_BINLOG_POS")
    [[ -n "$RESTORE_TO_TIMESTAMP" ]] && BINLOG_OPTS+=(--stop-datetime="$RESTORE_TO_TIMESTAMP")

    docker cp "$bl_file" "$MARIADB_CONTAINER:/tmp/binlogs/$bl_name" >/dev/null 2>&1

    if docker exec "$MARIADB_CONTAINER" mariadb-binlog "${BINLOG_OPTS[@]}" \
      --database="$DB_TO_RESTORE" "/tmp/binlogs/$bl_name" 2>/dev/null | \
      db_exec_stdin "$DB_TO_RESTORE"; then
      log_success "Applied binlog: $bl_name"
      TOTAL_BINLOGS_PROCESSED=$((TOTAL_BINLOGS_PROCESSED + 1))
    else
      log_warning "Failed to apply binlog: $bl_name (may be normal if it contains no relevant changes)"
      TOTAL_BINLOGS_ERRORS=$((TOTAL_BINLOGS_ERRORS + 1))
    fi

    docker exec "$MARIADB_CONTAINER" rm -f "/tmp/binlogs/$bl_name"
  done
done

RESTORE_DURATION=$(( $(date +%s) - RESTORE_START_TIME ))

echo
log_info "=== RESTORE SUMMARY ==="
if [[ "$DATABASE" == "ALL" ]]; then
  log_info "Databases: All (${#DBS_TO_RESTORE[@]} selected, $PROCESSED_DATABASES restored)"
else
  log_info "Database: $DATABASE"
fi
[[ -n "$RESTORE_TO_TIMESTAMP" ]] && log_info "Restored to timestamp: $RESTORE_TO_TIMESTAMP"
log_info "Duration: ${RESTORE_DURATION}s"
log_info "Backup size processed: $(human_size "$TOTAL_BACKUP_SIZE")"
if [[ $TOTAL_BINLOG_SIZE -gt 0 ]]; then
  log_info "Binlog size processed: $(human_size "$TOTAL_BINLOG_SIZE")"
  log_info "Binlogs applied: $TOTAL_BINLOGS_PROCESSED"
  [[ $TOTAL_BINLOGS_ERRORS -gt 0 ]] && log_warning "Binlogs with errors: $TOTAL_BINLOGS_ERRORS"
fi

if [[ $PROCESSED_DATABASES -eq 0 ]]; then
  log_error "No databases were restored"
  exit 1
fi

log_success "Restore process completed"
