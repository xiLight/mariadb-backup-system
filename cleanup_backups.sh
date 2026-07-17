#!/bin/bash
cd "$(dirname "$0")"

set -o pipefail

source "./lib/logging.sh"

LOG_FILE="./logs/cleanup_backups.log"
init_logging

source .env 2>/dev/null || { log_error "Failed to source .env file"; exit 1; }

BACKUP_DIR="${BACKUP_DIR:-./backups}"
BINLOG_INFO_DIR="${BINLOG_INFO_DIR:-$BACKUP_DIR/binlog_info}"
INCR_INFO_DIR="${INCR_INFO_DIR:-$BACKUP_DIR/incr}"
CHECKSUM_DIR="$BACKUP_DIR/checksums"
KEEP_GENERATIONS="${BACKUP_KEEP_GENERATIONS:-7}"
MARIADB_CONTAINER="${MARIADB_CONTAINER:-mariadb}"

mkdir -p "$BACKUP_DIR" "$BINLOG_INFO_DIR" "$INCR_INFO_DIR" "$CHECKSUM_DIR" 2>/dev/null

get_all_databases() {
  docker exec -e MYSQL_PWD="$MARIADB_ROOT_PASSWORD" "$MARIADB_CONTAINER" \
    mariadb -u root -N -e "SHOW DATABASES;" 2>/dev/null | \
    grep -v -E "^(information_schema|performance_schema|mysql|sys)$"
}

log_info "Starting backup cleanup (keeping last $KEEP_GENERATIONS full backup generations per database)"

# Detect databases: prefer the live server, fall back to existing backup files
DBS=()
DB_LIST=$(get_all_databases)
if [[ -n "$DB_LIST" ]]; then
  while IFS= read -r line; do
    if ls -1 "$BACKUP_DIR/${line}"_full_*.sql.gz.enc >/dev/null 2>&1; then
      DBS+=("$line")
    fi
  done <<< "$DB_LIST"
  log_info "Detected databases with backups: ${DBS[*]}"
else
  log_warning "Could not detect databases from server, using existing backup files"
  DBS=($(ls "$BACKUP_DIR"/*_full_*.sql.gz.enc 2>/dev/null | sed -r 's/.*\/(.*)_full_.*/\1/' | sort -u))
fi

TOTAL_DELETED=0

for DB in "${DBS[@]}"; do
  FULLS=( $(ls -1 "$BACKUP_DIR/${DB}"_full_*.sql.gz.enc 2>/dev/null | sort) )
  N_FULLS=${#FULLS[@]}

  if (( N_FULLS <= KEEP_GENERATIONS )); then
    log_info "$DB: $N_FULLS backup(s), nothing to clean up"
    continue
  fi

  log_info "$DB: $N_FULLS backups, removing $((N_FULLS - KEEP_GENERATIONS)) old one(s)"

  for ((i = 0; i < N_FULLS - KEEP_GENERATIONS; i++)); do
    OLD_FULL="${FULLS[$i]}"
    TS=$(basename "$OLD_FULL" | sed "s/${DB}_full_\(.*\)\.sql\.gz\.enc/\1/")

    log_info "  - Deleting $(basename "$OLD_FULL")"
    rm -f "$OLD_FULL"
    TOTAL_DELETED=$((TOTAL_DELETED + 1))

    # Remove everything belonging to this backup generation
    rm -f "$BINLOG_INFO_DIR/last_binlog_info_${DB}_${TS}.txt"
    rm -f "$INCR_INFO_DIR/last_binlog_info_${DB}_${TS}"*.txt
    rm -f "$CHECKSUM_DIR/$(basename "$OLD_FULL").sha256"
    rm -f "${OLD_FULL}.sha256"

    for INCR_FILE in "$BACKUP_DIR/${DB}"_incremental_"${TS}"*; do
      if [[ -f "$INCR_FILE" ]]; then
        log_info "  - Deleting $(basename "$INCR_FILE")"
        rm -f "$INCR_FILE"
        rm -f "$CHECKSUM_DIR/$(basename "$INCR_FILE").sha256"
      fi
    done
  done

  log_success "Cleanup for $DB completed"
done

log_success "Backup cleanup completed ($TOTAL_DELETED full backup(s) deleted)"
