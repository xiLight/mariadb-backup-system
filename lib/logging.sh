#!/bin/bash
# Shared logging library.
#
# Console output is colored; if LOG_FILE is set, every message is also written
# to that file (plain text). Call init_logging after setting LOG_FILE to create
# the log directory and apply size-based rotation (rolling logs).
#
# Tunables (via environment / .env):
#   LOG_MAX_SIZE_KB  rotate when the log exceeds this size (default: 5120 = 5 MB)
#   LOG_KEEP         number of rotated files to keep, e.g. file.log.1 .. .5 (default: 5)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

LOG_MAX_SIZE_KB="${LOG_MAX_SIZE_KB:-5120}"
LOG_KEEP="${LOG_KEEP:-5}"

_file_size_bytes() {
  stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || echo 0
}

# Rotate a log file if it exceeds LOG_MAX_SIZE_KB: file.log -> file.log.1 -> ... -> file.log.$LOG_KEEP
rotate_log() {
  local file="${1:-$LOG_FILE}"
  [[ -z "$file" || ! -f "$file" ]] && return 0

  local size_kb=$(( $(_file_size_bytes "$file") / 1024 ))
  (( size_kb < LOG_MAX_SIZE_KB )) && return 0

  local i
  rm -f "${file}.${LOG_KEEP}"
  for ((i = LOG_KEEP - 1; i >= 1; i--)); do
    [[ -f "${file}.${i}" ]] && mv "${file}.${i}" "${file}.$((i + 1))"
  done
  mv "$file" "${file}.1"
  : > "$file"
}

# Prepare file logging: ensure directory exists and rotate if needed.
# Usage: init_logging [logfile]  (defaults to $LOG_FILE)
init_logging() {
  [[ -n "$1" ]] && LOG_FILE="$1"
  [[ -z "$LOG_FILE" ]] && return 0
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
  rotate_log "$LOG_FILE"
}

_log() {
  local level="$1" color="$2"
  shift 2
  local timestamp
  timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  echo -e "${color}[$timestamp] [$level] $*${NC}"
  if [[ -n "$LOG_FILE" ]]; then
    echo "[$timestamp] [$level] $*" >> "$LOG_FILE"
  fi
}

log_info()    { _log "INFO"    "$BLUE"   "$@"; }
log_success() { _log "SUCCESS" "$GREEN"  "$@"; }
log_warning() { _log "WARNING" "$YELLOW" "$@"; }
log_error()   { _log "ERROR"   "$RED"    "$@"; }
log_debug()   { _log "DEBUG"   "$PURPLE" "$@"; }
log_trace()   { _log "TRACE"   "$CYAN"   "$@"; }
