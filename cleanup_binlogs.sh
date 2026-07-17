#!/bin/bash
cd "$(dirname "$0")"

set -o pipefail

source "./lib/logging.sh"

LOG_FILE="./logs/cleanup_binlogs.log"
init_logging

source .env 2>/dev/null || { log_error "Failed to source .env file"; exit 1; }

BACKUP_DIR="${BACKUP_DIR:-./backups}"
BINLOG_DIR="${BINLOG_DIR:-$BACKUP_DIR/binlogs}"
BINLOG_INFO_DIR="${BINLOG_INFO_DIR:-$BACKUP_DIR/binlog_info}"
INCR_INFO_DIR="${INCR_INFO_DIR:-$BACKUP_DIR/incr}"
KEEP_GENERATIONS="${BACKUP_KEEP_GENERATIONS:-7}"
MARIADB_CONTAINER="${MARIADB_CONTAINER:-mariadb}"

mkdir -p "$BACKUP_DIR" "$BINLOG_DIR" "$BINLOG_INFO_DIR" "$INCR_INFO_DIR" 2>/dev/null

get_all_databases() {
  docker exec -e MYSQL_PWD="$MARIADB_ROOT_PASSWORD" "$MARIADB_CONTAINER" \
    mariadb -u root -N -e "SHOW DATABASES;" 2>/dev/null | \
    grep -v -E "^(information_schema|performance_schema|mysql|sys)$"
}

log_info "Starting binlog cleanup process"

# Detect databases: prefer the live server, fall back to backup files on disk
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

if [[ ${#DBS[@]} -eq 0 ]]; then
  log_info "No databases with backups found, nothing to do"
  exit 0
fi

log_info "Found ${#DBS[@]} database(s) to check: ${DBS[*]}"

# Find the oldest binlog still needed by any kept backup generation.
# Binlogs older than that can safely be deleted.
OLDEST_BINLOG=""

for DB in "${DBS[@]}"; do
  FULLS=( $(ls -1 "$BACKUP_DIR/${DB}"_full_*.sql.gz.enc 2>/dev/null | sort) )
  N_FULLS=${#FULLS[@]}

  if [[ $N_FULLS -eq 0 ]]; then
    continue
  fi

  if (( N_FULLS < KEEP_GENERATIONS )); then
    log_info "$DB: only $N_FULLS backup(s) (less than $KEEP_GENERATIONS), keeping all binlogs"
    OLDEST_TO_KEEP="${FULLS[0]}"
  else
    OLDEST_TO_KEEP="${FULLS[N_FULLS - KEEP_GENERATIONS]}"
  fi

  TS=$(basename "$OLDEST_TO_KEEP" | sed "s/${DB}_full_\(.*\)\.sql\.gz\.enc/\1/")

  INFO_TXT="$BINLOG_INFO_DIR/last_binlog_info_${DB}_${TS}.txt"
  [[ ! -f "$INFO_TXT" ]] && INFO_TXT="$INCR_INFO_DIR/last_binlog_info_${DB}_${TS}.txt"

  if [[ -f "$INFO_TXT" ]]; then
    read -r BINLOG_FILE BINLOG_POS < "$INFO_TXT"
    log_info "$DB: oldest kept backup requires binlog $BINLOG_FILE (position $BINLOG_POS)"

    if [[ -z "$OLDEST_BINLOG" || "$BINLOG_FILE" < "$OLDEST_BINLOG" ]]; then
      OLDEST_BINLOG="$BINLOG_FILE"
    fi
  else
    log_warning "$DB: no binlog info found for backup at $TS - keeping all binlogs to be safe"
    exit 0
  fi
done

if [[ -z "$OLDEST_BINLOG" ]]; then
  log_info "No binlog cleanup possible (no binlog info found)"
  exit 0
fi

log_info "Oldest required binlog: $OLDEST_BINLOG - deleting everything older"

DELETED_COUNT=0
TOTAL_SIZE=0

for BL in "$BINLOG_DIR"/mysql-bin.*; do
  [[ -f "$BL" ]] || continue
  BLBASE=$(basename "$BL")

  [[ "$BLBASE" == *.index ]] && continue

  if [[ "$BLBASE" < "$OLDEST_BINLOG" ]]; then
    FILE_SIZE=$(stat -c%s "$BL" 2>/dev/null || stat -f%z "$BL" 2>/dev/null || echo "0")
    TOTAL_SIZE=$((TOTAL_SIZE + FILE_SIZE))

    if rm -f "$BL"; then
      DELETED_COUNT=$((DELETED_COUNT + 1))
      log_info "Deleted old binlog: $BLBASE ($FILE_SIZE bytes)"
    else
      log_error "Failed to delete: $BLBASE"
    fi
  fi
done

if [[ $TOTAL_SIZE -gt 1048576 ]]; then
  SIZE_HR="$(echo "scale=2; $TOTAL_SIZE/1048576" | bc -l 2>/dev/null || echo $((TOTAL_SIZE / 1048576))) MB"
elif [[ $TOTAL_SIZE -gt 1024 ]]; then
  SIZE_HR="$(echo "scale=2; $TOTAL_SIZE/1024" | bc -l 2>/dev/null || echo $((TOTAL_SIZE / 1024))) KB"
else
  SIZE_HR="$TOTAL_SIZE bytes"
fi

log_success "Binlog cleanup completed: deleted $DELETED_COUNT file(s), freed $SIZE_HR"
log_info "Oldest kept binlog: $OLDEST_BINLOG"
