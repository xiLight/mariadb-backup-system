#!/bin/bash
cd "$(dirname "$0")"

set -o pipefail

source "./lib/logging.sh"

BACKUP_VERSION="1.1.0"

LOG_FILE="./logs/backup.log"
init_logging

handle_error() {
  local exit_code=$1
  shift
  log_error "$* (exit code: $exit_code)"
  exit "$exit_code"
}

source .env 2>/dev/null || handle_error 1 "Failed to source .env file"

BACKUP_DIR="${BACKUP_DIR:-./backups}"
BINLOG_BACKUP_DIR="${BINLOG_DIR:-$BACKUP_DIR/binlogs}"
BINLOG_INFO_DIR="$BACKUP_DIR/binlog_info"
CHECKSUM_DIR="$BACKUP_DIR/checksums"
INCR_INFO_DIR="$BACKUP_DIR/incr"
MARIADB_CONTAINER="${MARIADB_CONTAINER:-mariadb}"
CONTAINER_DATADIR="/var/lib/mysql"

ENCRYPT_KEY_FILE=".backup_encryption_key"
INCLUDE_EMPTY_DATABASES=false
BACKUP_MODE="full"
SPECIFIC_DATABASE=""
COMPRESS_BACKUPS=true
CREATE_CHECKSUMS=true
VERIFY_BACKUPS=false

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
    --verify)
      VERIFY_BACKUPS=true
      shift
      ;;
    --help)
      echo "MariaDB Backup Script v$BACKUP_VERSION"
      echo ""
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Backup modes:"
      echo "  --full                 Create full backup (default)"
      echo "  --incremental          Create incremental backup (binlog based)"
      echo ""
      echo "Options:"
      echo "  --database DB          Backup specific database only"
      echo "  --include-empty        Include databases with no tables"
      echo "  --key FILE             Encryption key file (default: .backup_encryption_key)"
      echo "  --no-compress          Don't compress backup files"
      echo "  --no-checksums         Don't create checksum files"
      echo "  --verify               Verify each backup after creation (decrypt + integrity test)"
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

BACKUP_START_TIME=$(date +%s)
log_info "Starting backup process (version $BACKUP_VERSION), mode: $BACKUP_MODE"

for dir in "$BACKUP_DIR" "$BINLOG_BACKUP_DIR" "$BINLOG_INFO_DIR" "$CHECKSUM_DIR" "$INCR_INFO_DIR"; do
  mkdir -p "$dir" || handle_error 3 "Failed to create directory: $dir"
done

TIMESTAMP=$(date +%Y%m%d_%H%M%S)

if [[ ! -f "$ENCRYPT_KEY_FILE" ]]; then
  log_warning "Encryption key not found, generating new one: $ENCRYPT_KEY_FILE"
  openssl rand -base64 32 > "$ENCRYPT_KEY_FILE" || handle_error 4 "Failed to generate encryption key"
  chmod 600 "$ENCRYPT_KEY_FILE"
  log_warning "New encryption key created at $ENCRYPT_KEY_FILE - KEEP THIS SAFE! Without it, backups cannot be restored."
fi

# --- Database connection --------------------------------------------------
# The password is passed via MYSQL_PWD so it never shows up in process lists.
log_info "Testing database connection to container '$MARIADB_CONTAINER'..."

DOCKER_ENV=(-e MYSQL_PWD="$MARIADB_ROOT_PASSWORD")
CLIENT_ARGS=(-u root)

if docker exec "${DOCKER_ENV[@]}" "$MARIADB_CONTAINER" mariadb "${CLIENT_ARGS[@]}" -e "SELECT 1;" &>/dev/null; then
  log_success "Database connection successful (socket)"
elif docker exec "$MARIADB_CONTAINER" mariadb -u root -e "SELECT 1;" &>/dev/null; then
  DOCKER_ENV=()
  log_success "Database connection successful (socket, no password)"
elif docker exec -e MYSQL_PWD="$MARIADB_ROOT_PASSWORD" "$MARIADB_CONTAINER" mariadb -u root -h 127.0.0.1 -P 3306 -e "SELECT 1;" &>/dev/null; then
  CLIENT_ARGS+=(-h 127.0.0.1 -P 3306)
  log_success "Database connection successful (TCP)"
else
  handle_error 5 "Cannot connect to MariaDB container: $MARIADB_CONTAINER"
fi

db_exec() {
  docker exec "${DOCKER_ENV[@]}" "$MARIADB_CONTAINER" mariadb "${CLIENT_ARGS[@]}" "$@"
}

db_query() {
  db_exec -N -e "$1"
}

db_dump() {
  docker exec "${DOCKER_ENV[@]}" "$MARIADB_CONTAINER" mariadb-dump "${CLIENT_ARGS[@]}" "$@"
}

# Dump one database. Tries with binlog coordinates first (needed for
# incremental backups), falls back to a plain dump if the server lacks
# binary logging or the required privileges.
dump_database() {
  local database="$1" output_file="$2"
  local opts=(--single-transaction --quick --routines --triggers --events --databases "$database")

  if db_dump "${opts[@]}" --master-data=2 --flush-logs > "$output_file" 2>/dev/null; then
    return 0
  fi

  log_warning "Dump with binary log features failed, using fallback (no binlog coordinates)"
  db_dump "${opts[@]}" > "$output_file"
}

# Determine the current binlog file and position.
# Sets BINLOG_FILE / BINLOG_POS, returns 1 if unavailable.
get_binlog_position() {
  BINLOG_FILE=""
  BINLOG_POS=""

  local info
  info=$(db_query "SHOW MASTER STATUS;" 2>/dev/null | head -1)
  if [[ -n "$info" && "$info" != "NULL" ]]; then
    BINLOG_FILE=$(awk '{print $1}' <<< "$info")
    BINLOG_POS=$(awk '{print $2}' <<< "$info")
    if [[ -n "$BINLOG_FILE" && "$BINLOG_FILE" != "NULL" && -n "$BINLOG_POS" ]]; then
      return 0
    fi
  fi

  # Fallback: newest binlog file in the container, position = start of file
  local latest
  latest=$(docker exec "$MARIADB_CONTAINER" sh -c "ls $CONTAINER_DATADIR/mysql-bin.* 2>/dev/null" | grep -v '\.index$' | sort -V | tail -1)
  if [[ -n "$latest" ]]; then
    BINLOG_FILE=$(basename "$latest")
    BINLOG_POS="4"
    log_info "Binary log position estimated from filesystem: $BINLOG_FILE:$BINLOG_POS"
    return 0
  fi

  return 1
}

save_binlog_position() {
  local database="$1" file="$2" pos="$3"
  echo "$file $pos" > "$BINLOG_INFO_DIR/last_binlog_info_${database}_${TIMESTAMP}.txt"
  log_success "Binary log position saved for $database: $file:$pos"
}

# Copy all binlog files from the container into the local backup directory.
sync_binlogs() {
  log_info "Syncing binary logs from container..."
  local files
  files=$(docker exec "$MARIADB_CONTAINER" sh -c "ls $CONTAINER_DATADIR/mysql-bin.* 2>/dev/null")
  if [[ -z "$files" ]]; then
    log_warning "No binary logs found in container. Incremental backups will not work until binary logging is enabled."
    return 1
  fi

  local count=0 f
  while IFS= read -r f; do
    if docker cp "$MARIADB_CONTAINER:$f" "$BINLOG_BACKUP_DIR/" >/dev/null 2>&1; then
      count=$((count + 1))
    else
      log_warning "Failed to copy binlog: $(basename "$f")"
    fi
  done <<< "$files"
  log_success "Synced $count binary log file(s) to $BINLOG_BACKUP_DIR"
}

# Decrypt + integrity-test an encrypted backup without writing plaintext to disk.
verify_backup_file() {
  local enc_file="$1"
  if [[ "$COMPRESS_BACKUPS" == "true" ]]; then
    openssl enc -aes-256-cbc -d -pbkdf2 -in "$enc_file" -pass file:"$ENCRYPT_KEY_FILE" 2>/dev/null | gzip -t 2>/dev/null
  else
    openssl enc -aes-256-cbc -d -pbkdf2 -in "$enc_file" -pass file:"$ENCRYPT_KEY_FILE" 2>/dev/null | head -c 1 | grep -q .
  fi
}

# --- Collect databases ----------------------------------------------------
if [[ -n "$SPECIFIC_DATABASE" ]]; then
  if ! db_exec -e "USE \`$SPECIFIC_DATABASE\`;" &>/dev/null; then
    handle_error 6 "Database '$SPECIFIC_DATABASE' does not exist"
  fi
  DATABASES=("$SPECIFIC_DATABASE")
else
  mapfile -t DATABASES < <(db_query "SHOW DATABASES;" 2>/dev/null | grep -v -E "^(information_schema|performance_schema|mysql|sys)$")
fi
log_info "Found ${#DATABASES[@]} database(s) to backup: ${DATABASES[*]}"

TOTAL_DATABASES=0
SUCCESSFUL_BACKUPS=0
FAILED_BACKUPS=0
SKIPPED_DATABASES=0
TOTAL_BACKUP_SIZE=0

sync_binlogs

# --- Backup loop ----------------------------------------------------------
for DB in "${DATABASES[@]}"; do
  TOTAL_DATABASES=$((TOTAL_DATABASES + 1))
  log_info "Processing database: $DB"

  if [[ "$INCLUDE_EMPTY_DATABASES" == "false" ]]; then
    TABLE_COUNT=$(db_query "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$DB';" 2>/dev/null || echo "0")
    if [[ "$TABLE_COUNT" == "0" ]]; then
      log_warning "Database $DB has no tables, skipping (use --include-empty to backup anyway)"
      SKIPPED_DATABASES=$((SKIPPED_DATABASES + 1))
      continue
    fi
  fi

  BACKUP_FILE="$BACKUP_DIR/${DB}_${BACKUP_MODE}_${TIMESTAMP}.sql"
  SAVE_BINLOG_FILE=""
  SAVE_BINLOG_POS=""

  if [[ "$BACKUP_MODE" == "full" ]]; then
    log_info "Creating full backup: $(basename "$BACKUP_FILE")"
    if ! dump_database "$DB" "$BACKUP_FILE"; then
      log_error "Failed to create backup for database: $DB"
      rm -f "$BACKUP_FILE"
      FAILED_BACKUPS=$((FAILED_BACKUPS + 1))
      continue
    fi

    # The exact binlog position at dump time is recorded in the dump itself
    # by --master-data=2. Using it avoids a gap between dump and position
    # query that would be missed by the next incremental backup.
    MASTER_LINE=$(head -60 "$BACKUP_FILE" | grep -oE "MASTER_LOG_FILE='[^']+', MASTER_LOG_POS=[0-9]+" | head -1)
    if [[ -n "$MASTER_LINE" ]]; then
      SAVE_BINLOG_FILE=$(sed -E "s/MASTER_LOG_FILE='([^']+)'.*/\1/" <<< "$MASTER_LINE")
      SAVE_BINLOG_POS=$(sed -E "s/.*MASTER_LOG_POS=([0-9]+)/\1/" <<< "$MASTER_LINE")
    fi
  else
    # Incremental backup: extract changes from binary logs since the last
    # saved position (full or incremental).
    LAST_INFO_FILE=$(find "$BINLOG_INFO_DIR" -name "last_binlog_info_${DB}_*.txt" -type f | sort | tail -1)
    if [[ -z "$LAST_INFO_FILE" ]]; then
      log_error "No previous backup position found for $DB. Run a full backup first."
      FAILED_BACKUPS=$((FAILED_BACKUPS + 1))
      continue
    fi

    read -r LAST_BINLOG_FILE LAST_BINLOG_POS < "$LAST_INFO_FILE"
    log_info "Last backup position: $LAST_BINLOG_FILE:$LAST_BINLOG_POS"

    if ! get_binlog_position; then
      log_error "Cannot determine current binary log position for $DB"
      FAILED_BACKUPS=$((FAILED_BACKUPS + 1))
      continue
    fi
    CURRENT_BINLOG_FILE="$BINLOG_FILE"
    CURRENT_BINLOG_POS="$BINLOG_POS"
    log_info "Current position: $CURRENT_BINLOG_FILE:$CURRENT_BINLOG_POS"

    if [[ "$LAST_BINLOG_FILE" == "$CURRENT_BINLOG_FILE" && "$LAST_BINLOG_POS" == "$CURRENT_BINLOG_POS" ]]; then
      log_info "No changes since last backup, skipping $DB"
      SKIPPED_DATABASES=$((SKIPPED_DATABASES + 1))
      continue
    fi

    # Only binlogs in the range [last position, current position] are relevant.
    # Older files must be excluded, otherwise already-backed-up transactions
    # would be replayed on restore.
    BINLOG_FILES=()
    while IFS= read -r bl_file; do
      bl_name=$(basename "$bl_file")
      if [[ ! "$bl_name" < "$LAST_BINLOG_FILE" && ! "$bl_name" > "$CURRENT_BINLOG_FILE" ]]; then
        BINLOG_FILES+=("$bl_file")
      fi
    done < <(find "$BINLOG_BACKUP_DIR" -maxdepth 1 -type f -name "mysql-bin.*" ! -name "*.index" ! -name "*.idx" | sort -V)

    if [[ ${#BINLOG_FILES[@]} -eq 0 ]]; then
      log_error "No binary log files found in range $LAST_BINLOG_FILE..$CURRENT_BINLOG_FILE"
      FAILED_BACKUPS=$((FAILED_BACKUPS + 1))
      continue
    fi

    log_info "Processing ${#BINLOG_FILES[@]} binary log file(s) for incremental backup"
    : > "$BACKUP_FILE"
    docker exec "$MARIADB_CONTAINER" mkdir -p /tmp/binlogs

    for bl_file in "${BINLOG_FILES[@]}"; do
      bl_name=$(basename "$bl_file")

      BINLOG_OPTS=()
      [[ "$bl_name" == "$LAST_BINLOG_FILE" ]] && BINLOG_OPTS+=(--start-position="$LAST_BINLOG_POS")
      [[ "$bl_name" == "$CURRENT_BINLOG_FILE" ]] && BINLOG_OPTS+=(--stop-position="$CURRENT_BINLOG_POS")

      docker cp "$bl_file" "$MARIADB_CONTAINER:/tmp/binlogs/$bl_name" >/dev/null 2>&1
      if docker exec "$MARIADB_CONTAINER" mariadb-binlog "${BINLOG_OPTS[@]}" \
        --database="$DB" "/tmp/binlogs/$bl_name" >> "$BACKUP_FILE" 2>/dev/null; then
        log_info "Processed binary log: $bl_name"
      else
        log_warning "Failed to process binary log: $bl_name"
      fi
      docker exec "$MARIADB_CONTAINER" rm -f "/tmp/binlogs/$bl_name"
    done

    if [[ ! -s "$BACKUP_FILE" ]]; then
      log_info "Incremental backup is empty, no relevant changes for $DB"
      SKIPPED_DATABASES=$((SKIPPED_DATABASES + 1))
      rm -f "$BACKUP_FILE"
      continue
    fi
    log_success "Incremental backup created: $(basename "$BACKUP_FILE")"

    # The next incremental must start exactly where this one stopped
    SAVE_BINLOG_FILE="$CURRENT_BINLOG_FILE"
    SAVE_BINLOG_POS="$CURRENT_BINLOG_POS"
  fi

  BACKUP_SIZE=$(stat -c%s "$BACKUP_FILE" 2>/dev/null || stat -f%z "$BACKUP_FILE" 2>/dev/null || echo "0")
  TOTAL_BACKUP_SIZE=$((TOTAL_BACKUP_SIZE + BACKUP_SIZE))

  if [[ "$COMPRESS_BACKUPS" == "true" ]]; then
    if gzip "$BACKUP_FILE"; then
      BACKUP_FILE="${BACKUP_FILE}.gz"
    else
      log_error "Failed to compress backup for $DB"
      FAILED_BACKUPS=$((FAILED_BACKUPS + 1))
      rm -f "$BACKUP_FILE"
      continue
    fi
  fi

  ENCRYPT_ARGS=(--encrypt "$BACKUP_FILE" --key "$ENCRYPT_KEY_FILE")
  [[ "$CREATE_CHECKSUMS" == "false" ]] && ENCRYPT_ARGS+=(--no-checksum)
  if ./encrypt_backup.sh "${ENCRYPT_ARGS[@]}"; then
    rm -f "$BACKUP_FILE"
    BACKUP_FILE="${BACKUP_FILE}.enc"
    log_success "Backup encrypted: $(basename "$BACKUP_FILE")"
  else
    log_error "Failed to encrypt backup for $DB"
    rm -f "$BACKUP_FILE"
    FAILED_BACKUPS=$((FAILED_BACKUPS + 1))
    continue
  fi

  if [[ "$VERIFY_BACKUPS" == "true" ]]; then
    if verify_backup_file "$BACKUP_FILE"; then
      log_success "Backup verified: $(basename "$BACKUP_FILE")"
    else
      log_error "Backup verification FAILED for $(basename "$BACKUP_FILE")"
      FAILED_BACKUPS=$((FAILED_BACKUPS + 1))
      continue
    fi
  fi

  # Save the binlog position so the next incremental backup knows where to start.
  if [[ -z "$SAVE_BINLOG_FILE" ]] && get_binlog_position; then
    SAVE_BINLOG_FILE="$BINLOG_FILE"
    SAVE_BINLOG_POS="$BINLOG_POS"
  fi

  if [[ -n "$SAVE_BINLOG_FILE" ]]; then
    save_binlog_position "$DB" "$SAVE_BINLOG_FILE" "$SAVE_BINLOG_POS"
  else
    log_warning "Could not determine binary log position. Incremental backups will not work until binary logging is enabled."
  fi

  SUCCESSFUL_BACKUPS=$((SUCCESSFUL_BACKUPS + 1))
  log_success "Backup completed for database: $DB"
done

# --- Summary --------------------------------------------------------------
BACKUP_DURATION=$(( $(date +%s) - BACKUP_START_TIME ))

if [[ $TOTAL_BACKUP_SIZE -gt 1048576 ]]; then
  SIZE_HR="$(echo "scale=2; $TOTAL_BACKUP_SIZE/1048576" | bc -l 2>/dev/null || echo $((TOTAL_BACKUP_SIZE / 1048576))) MB"
elif [[ $TOTAL_BACKUP_SIZE -gt 1024 ]]; then
  SIZE_HR="$(echo "scale=2; $TOTAL_BACKUP_SIZE/1024" | bc -l 2>/dev/null || echo $((TOTAL_BACKUP_SIZE / 1024))) KB"
else
  SIZE_HR="$TOTAL_BACKUP_SIZE bytes"
fi

echo
log_info "=== BACKUP SUMMARY ==="
log_info "Backup mode: $BACKUP_MODE"
log_info "Timestamp: $TIMESTAMP"
log_info "Duration: ${BACKUP_DURATION}s"
log_info "Databases processed: $TOTAL_DATABASES (success: $SUCCESSFUL_BACKUPS, failed: $FAILED_BACKUPS, skipped: $SKIPPED_DATABASES)"
log_info "Total backup size (uncompressed): $SIZE_HR"
log_info "Compression: $([ "$COMPRESS_BACKUPS" == "true" ] && echo "enabled" || echo "disabled"), Encryption: enabled, Checksums: $([ "$CREATE_CHECKSUMS" == "true" ] && echo "enabled" || echo "disabled"), Verify: $([ "$VERIFY_BACKUPS" == "true" ] && echo "enabled" || echo "disabled")"

if [[ $FAILED_BACKUPS -gt 0 ]]; then
  log_error "$FAILED_BACKUPS backup(s) failed. Check $LOG_FILE for details."
  exit 1
fi

log_success "All backups completed successfully! Encrypted files stored in: $BACKUP_DIR"
