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
MARIADB_CONTAINER="${MARIADB_CONTAINER:-mariadb}"

# Retention: 'generations' keeps the last N full backups per database,
# 'gfs' (grandfather-father-son) keeps dailies + weeklies + monthlies -
# long history at a fraction of the storage.
BACKUP_RETENTION_MODE="${BACKUP_RETENTION_MODE:-generations}"
KEEP_GENERATIONS="${BACKUP_KEEP_GENERATIONS:-7}"
BACKUP_KEEP_DAILY="${BACKUP_KEEP_DAILY:-7}"
BACKUP_KEEP_WEEKLY="${BACKUP_KEEP_WEEKLY:-4}"
BACKUP_KEEP_MONTHLY="${BACKUP_KEEP_MONTHLY:-12}"

mkdir -p "$BACKUP_DIR" "$BINLOG_INFO_DIR" "$INCR_INFO_DIR" "$CHECKSUM_DIR" 2>/dev/null

get_all_databases() {
  docker exec -e MYSQL_PWD="$MARIADB_ROOT_PASSWORD" "$MARIADB_CONTAINER" \
    mariadb -u root -N -e "SHOW DATABASES;" 2>/dev/null | \
    grep -v -E "^(information_schema|performance_schema|mysql|sys)$"
}

# Delete one full backup and everything belonging to its generation
delete_backup_file() {
  local db="$1" old_full="$2"
  local ts
  ts=$(basename "$old_full" | sed "s/${db}_full_\(.*\)\.sql\.gz\.enc/\1/")

  log_info "  - Deleting $(basename "$old_full")"
  rm -f "$old_full"
  rm -f "$BINLOG_INFO_DIR/last_binlog_info_${db}_${ts}.txt"
  rm -f "$INCR_INFO_DIR/last_binlog_info_${db}_${ts}"*.txt
  rm -f "$CHECKSUM_DIR/$(basename "$old_full").sha256"
  rm -f "${old_full}.sha256"

  local incr_file
  for incr_file in "$BACKUP_DIR/${db}"_incremental_"${ts}"*; do
    if [[ -f "$incr_file" ]]; then
      log_info "  - Deleting $(basename "$incr_file")"
      rm -f "$incr_file"
      rm -f "$CHECKSUM_DIR/$(basename "$incr_file").sha256"
    fi
  done
}

# GFS: from a newest-first list of full backups, print the files to KEEP.
# Greedy: newest backup per distinct day/week/month fills the slots.
gfs_keep_set() {
  local daily=() weekly=() monthly=()
  local f ts d w m

  for f in "$@"; do
    ts=$(basename "$f" | grep -oE '[0-9]{8}_[0-9]{6}' | head -1)
    if [[ -z "$ts" ]]; then
      echo "$f"
      continue
    fi
    d=${ts:0:8}
    m=${ts:0:6}
    w=$(date -d "$d" +%G-%V 2>/dev/null || echo "$d")

    if [[ ${#daily[@]} -lt $BACKUP_KEEP_DAILY && ! " ${daily[*]} " == *" $d "* ]]; then
      daily+=("$d")
      echo "$f"
      continue
    fi
    if [[ ${#weekly[@]} -lt $BACKUP_KEEP_WEEKLY && ! " ${weekly[*]} " == *" $w "* ]]; then
      weekly+=("$w")
      echo "$f"
      continue
    fi
    if [[ ${#monthly[@]} -lt $BACKUP_KEEP_MONTHLY && ! " ${monthly[*]} " == *" $m "* ]]; then
      monthly+=("$m")
      echo "$f"
      continue
    fi
  done
}

if [[ "$BACKUP_RETENTION_MODE" == "gfs" ]]; then
  log_info "Starting backup cleanup (GFS: $BACKUP_KEEP_DAILY daily / $BACKUP_KEEP_WEEKLY weekly / $BACKUP_KEEP_MONTHLY monthly per database)"
else
  log_info "Starting backup cleanup (keeping last $KEEP_GENERATIONS full backup generations per database)"
fi

# Detect databases: prefer the live server, fall back to existing backup files
DBS=()
DB_LIST=$(get_all_databases)
if [[ -n "$DB_LIST" ]]; then
  while IFS= read -r line; do
    if ls -1 "$BACKUP_DIR/${line}"_full_*.sql.gz.enc >/dev/null 2>&1; then
      DBS+=("$line")
    fi
  done <<< "$DB_LIST"
else
  log_warning "Could not detect databases from server, using existing backup files"
fi
# Always include DBs that only exist as backup files (dropped DBs, grants dump)
for extra in $(ls "$BACKUP_DIR"/*_full_*.sql.gz.enc 2>/dev/null | sed -r 's/.*\/(.*)_full_.*/\1/' | sort -u); do
  [[ " ${DBS[*]} " == *" $extra "* ]] || DBS+=("$extra")
done

log_info "Databases with backups: ${DBS[*]}"

TOTAL_DELETED=0

for DB in "${DBS[@]}"; do
  FULLS_NEWEST=( $(ls -1t "$BACKUP_DIR/${DB}"_full_*.sql.gz.enc 2>/dev/null) )
  N_FULLS=${#FULLS_NEWEST[@]}
  [[ $N_FULLS -eq 0 ]] && continue

  if [[ "$BACKUP_RETENTION_MODE" == "gfs" ]]; then
    KEEP_LIST=$(gfs_keep_set "${FULLS_NEWEST[@]}")
    DELETED=0
    for OLD_FULL in "${FULLS_NEWEST[@]}"; do
      if ! grep -qxF "$OLD_FULL" <<< "$KEEP_LIST"; then
        delete_backup_file "$DB" "$OLD_FULL"
        DELETED=$((DELETED + 1))
        TOTAL_DELETED=$((TOTAL_DELETED + 1))
      fi
    done
    KEPT=$(( N_FULLS - DELETED ))
    log_info "$DB: $N_FULLS backup(s) -> kept $KEPT, deleted $DELETED (GFS)"
  else
    if (( N_FULLS <= KEEP_GENERATIONS )); then
      log_info "$DB: $N_FULLS backup(s), nothing to clean up"
      continue
    fi
    log_info "$DB: $N_FULLS backups, removing $((N_FULLS - KEEP_GENERATIONS)) old one(s)"
    for ((i = KEEP_GENERATIONS; i < N_FULLS; i++)); do
      delete_backup_file "$DB" "${FULLS_NEWEST[$i]}"
      TOTAL_DELETED=$((TOTAL_DELETED + 1))
    done
  fi
done

log_success "Backup cleanup completed ($TOTAL_DELETED full backup(s) deleted)"
