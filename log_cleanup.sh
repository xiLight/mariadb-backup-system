#!/bin/bash
cd "$(dirname "$0")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to log with timestamp
log_info() {
  local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  echo -e "${BLUE}[$timestamp] [INFO] $1${NC}"
}

log_success() {
  local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  echo -e "${GREEN}[$timestamp] [SUCCESS] $1${NC}"
}

log_warning() {
  local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  echo -e "${YELLOW}[$timestamp] [WARNING] $1${NC}"
}

log_error() {
  local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  echo -e "${RED}[$timestamp] [ERROR] $1${NC}"
}

log_info "Starting log cleanup process..."

# Create logs directory if it doesn't exist
mkdir -p "./logs"

# Define log files to clean
LOG_FILES=(
  "logs/backup.log"
  "logs/cleanup_backups.log"
  "logs/cleanup_binlogs.log"
  "logs/cleanup.log"
  "logs/encrypt.log"
  "logs/restore.log"
)

# Count how many files will be cleaned
CLEANED_COUNT=0
SKIPPED_COUNT=0

for LOG_FILE in "${LOG_FILES[@]}"; do
  if [[ -f "$LOG_FILE" ]]; then
    # Get file size before cleanup
    if [[ -s "$LOG_FILE" ]]; then
      SIZE_BEFORE=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo "0")
      
      # Clear the log file
      > "$LOG_FILE"
      
      log_success "Cleared $LOG_FILE (was ${SIZE_BEFORE} bytes)"
      CLEANED_COUNT=$((CLEANED_COUNT + 1))
    else
      log_info "Skipped $LOG_FILE (already empty)"
      SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    fi
  else
    log_warning "Log file $LOG_FILE not found - creating empty file"
    touch "$LOG_FILE"
    CLEANED_COUNT=$((CLEANED_COUNT + 1))
  fi
done

log_info "Log cleanup completed!"
log_success "Files cleaned: $CLEANED_COUNT"
log_info "Files skipped (already empty): $SKIPPED_COUNT"

# Show disk space freed (optional)
log_info "Log files are now ready for new entries."
