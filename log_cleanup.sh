#!/bin/bash
cd "$(dirname "$0")"

source "./lib/logging.sh"

# Log maintenance for the rolling log system:
#   default : rotate oversized logs and delete rotated files older than LOG_RETENTION_DAYS
#   --all   : additionally truncate all current log files
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-14}"
TRUNCATE_ALL=false

case "$1" in
  --all)
    TRUNCATE_ALL=true
    ;;
  --help)
    echo "Usage: $0 [--all]"
    echo "  (no option)  Rotate oversized logs, delete rotated logs older than $LOG_RETENTION_DAYS days"
    echo "  --all        Also truncate all current log files"
    exit 0
    ;;
esac

mkdir -p "./logs"

log_info "Starting log maintenance (retention: $LOG_RETENTION_DAYS days, max size: ${LOG_MAX_SIZE_KB} KB)"

ROTATED_COUNT=0
DELETED_COUNT=0
TRUNCATED_COUNT=0

for CURRENT_LOG in ./logs/*.log; do
  [[ -f "$CURRENT_LOG" ]] || continue

  if [[ "$TRUNCATE_ALL" == "true" ]]; then
    if [[ -s "$CURRENT_LOG" ]]; then
      SIZE_BEFORE=$(stat -c%s "$CURRENT_LOG" 2>/dev/null || stat -f%z "$CURRENT_LOG" 2>/dev/null || echo "0")
      : > "$CURRENT_LOG"
      log_success "Truncated $CURRENT_LOG (was ${SIZE_BEFORE} bytes)"
      TRUNCATED_COUNT=$((TRUNCATED_COUNT + 1))
    fi
  else
    SIZE_KB=$(( $(stat -c%s "$CURRENT_LOG" 2>/dev/null || stat -f%z "$CURRENT_LOG" 2>/dev/null || echo 0) / 1024 ))
    if (( SIZE_KB >= LOG_MAX_SIZE_KB )); then
      rotate_log "$CURRENT_LOG"
      log_success "Rotated $CURRENT_LOG (was ${SIZE_KB} KB)"
      ROTATED_COUNT=$((ROTATED_COUNT + 1))
    fi
  fi
done

# Delete rotated logs (*.log.1, *.log.2, ...) older than the retention period
while IFS= read -r OLD_LOG; do
  rm -f "$OLD_LOG"
  log_info "Deleted old rotated log: $OLD_LOG"
  DELETED_COUNT=$((DELETED_COUNT + 1))
done < <(find ./logs -type f -name "*.log.[0-9]*" -mtime "+$LOG_RETENTION_DAYS" 2>/dev/null)

log_success "Log maintenance completed (rotated: $ROTATED_COUNT, deleted: $DELETED_COUNT, truncated: $TRUNCATED_COUNT)"
