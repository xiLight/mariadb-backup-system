#!/bin/bash
cd "$(dirname "$0")"

set -o pipefail

# Load logging functions
source "./lib/logging.sh"

# Verbose mode - set to true for detailed info messages
VERBOSE=false

# Debug log function - only outputs if verbose mode is enabled
debug_log() {
  if [[ "$VERBOSE" == "true" ]]; then
    log_info "[DEBUG] $1"
  fi
}

# Start timing
RESTORE_START_TIME=$(date +%s)
RESTORE_START_DATE=$(date '+%Y-%m-%d %H:%M:%S')

# Initialize statistics variables
TOTAL_BACKUP_SIZE=0
TOTAL_BINLOG_SIZE=0
TOTAL_BINLOGS_PROCESSED=0
TOTAL_BINLOGS_SKIPPED=0
TOTAL_BINLOGS_ERRORS=0
PROCESSED_DATABASES=0

# Function to create preview for fzf
create_backup_preview() {
  local backup_file="$1"
  local db_name
  local timestamp
  local file_size
  local file_date
  
  # Extract database name and timestamp from filename
  db_name=$(basename "$backup_file" | sed 's/_full_.*//')
  timestamp=$(basename "$backup_file" | sed 's/.*_full_\(.*\)\.sql\.gz\.enc/\1/')
  
  # Get file information
  if [[ -f "$backup_file" ]]; then
    file_size=$(stat -c%s "$backup_file" 2>/dev/null || stat -f%z "$backup_file" 2>/dev/null || echo "0")
    file_date=$(stat -c%y "$backup_file" 2>/dev/null || stat -f%Sm "$backup_file" 2>/dev/null || echo "Unknown")
    
    # Convert size to human readable
    if [[ $file_size -gt 1048576 ]]; then
      size_hr=$(echo "scale=2; $file_size/1048576" | bc -l 2>/dev/null || echo "$((file_size/1048576))")
      size_unit="MB"
    elif [[ $file_size -gt 1024 ]]; then
      size_hr=$(echo "scale=2; $file_size/1024" | bc -l 2>/dev/null || echo "$((file_size/1024))")
      size_unit="KB"
    else
      size_hr=$file_size
      size_unit="bytes"
    fi
    
    echo "Database: $db_name"
    echo "Timestamp: $timestamp"
    echo "File size: $size_hr $size_unit"
    echo "Created: $file_date"
    echo "Path: $backup_file"
  else
    echo "File not found: $backup_file"
  fi
}

# Function to select database interactively
select_database_interactive() {
  local databases=()
  
  # Find all databases that have backups
  while IFS= read -r -d '' backup_file; do
    local db_name
    db_name=$(basename "$backup_file" | sed 's/_full_.*//')
    if [[ ! " ${databases[@]} " =~ " ${db_name} " ]]; then
      databases+=("$db_name")
    fi
  done < <(find "./backups" -name "*_full_*.sql.gz.enc" -print0 2>/dev/null)
  
  if [[ ${#databases[@]} -eq 0 ]]; then
    log_error "No backup files found"
    exit 1
  fi
  
  log_info "Available databases:"
  for i in "${!databases[@]}"; do
    echo "  $((i+1)). ${databases[$i]}"
  done
  
  while true; do
    read -p "Select database (1-${#databases[@]}): " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#databases[@]} ]]; then
      echo "${databases[$((choice-1))]}"
      return
    else
      log_error "Invalid selection. Please enter a number between 1 and ${#databases[@]}"
    fi
  done
}

# Function to select backup interactively
select_backup_interactive() {
  local database="$1"
  local backups=()
  
  # Find all backups for this database, sorted by date (newest first)
  while IFS= read -r backup_file; do
    backups+=("$backup_file")
  done < <(ls -1t "./backups/${database}_full_"*.sql.gz.enc 2>/dev/null)
  
  if [[ ${#backups[@]} -eq 0 ]]; then
    log_error "No backups found for database: $database"
    exit 1
  fi
  
  log_info "Available backups for $database:"
  for i in "${!backups[@]}"; do
    local timestamp
    timestamp=$(basename "${backups[$i]}" | sed "s/${database}_full_\(.*\)\.sql\.gz\.enc/\1/")
    echo "  $((i+1)). $timestamp"
  done
  
  while true; do
    read -p "Select backup (1-${#backups[@]}): " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#backups[@]} ]]; then
      echo "${backups[$((choice-1))]}"
      return
    else
      log_error "Invalid selection. Please enter a number between 1 and ${#backups[@]}"
    fi
  done
}

# Robust argument parsing for all relevanten Flags
INTERACTIVE_SELECT=true
DEBUG_MODE=false
USE_LAST_BACKUP=false
RESTORE_TIMESTAMP=""
DATABASE=""
BACKUP_FILE=""
RESTORE_TO_TIMESTAMP=""
LOG_FILE="./logs/restore.log"

# Create logs directory
mkdir -p "./logs"

# Parse command line arguments
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
    --verbose)
      VERBOSE=true
      shift
      ;;
    --debug)
      DEBUG_MODE=true
      VERBOSE=true
      shift
      ;;
    --help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "OPTIONS:"
      echo "  --database DB          Specify database name"
      echo "  --backup-file FILE     Specify backup file path"
      echo "  --last                 Use the most recent backup"
      echo "  --to-timestamp TS      Restore up to specific timestamp (YYYY-MM-DD HH:MM:SS)"
      echo "  --verbose              Enable verbose output"
      echo "  --debug                Enable debug mode"
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

log_info "Starting restore process at $RESTORE_START_DATE"
log_both "INFO" "Starting restore process at $RESTORE_START_DATE" "$LOG_FILE"

# Load environment variables
if [[ -f ".env" ]]; then
  source .env
  debug_log "Loaded environment variables from .env"
else
  log_error ".env file not found"
  exit 1
fi

# Interactive selection if no parameters provided
if [[ "$INTERACTIVE_SELECT" == "true" ]]; then
  log_info "Interactive mode - select database and backup"
  DATABASE=$(select_database_interactive)
  BACKUP_FILE=$(select_backup_interactive "$DATABASE")
fi

# Auto-select last backup if requested
if [[ "$USE_LAST_BACKUP" == "true" ]]; then
  if [[ -z "$DATABASE" ]]; then
    log_error "--last requires --database parameter"
    exit 1
  fi
  
  BACKUP_FILE=$(ls -1t "./backups/${DATABASE}_full_"*.sql.gz.enc 2>/dev/null | head -1)
  if [[ -z "$BACKUP_FILE" ]]; then
    log_error "No backups found for database: $DATABASE"
    exit 1
  fi
fi

# Validate parameters
if [[ -z "$DATABASE" ]]; then
  log_error "Database not specified"
  exit 1
fi

if [[ -z "$BACKUP_FILE" ]]; then
  log_error "Backup file not specified"
  exit 1
fi

if [[ ! -f "$BACKUP_FILE" ]]; then
  log_error "Backup file not found: $BACKUP_FILE"
  exit 1
fi

log_info "Selected database: $DATABASE"
log_info "Selected backup: $BACKUP_FILE"
log_both "INFO" "Selected database: $DATABASE, backup: $BACKUP_FILE" "$LOG_FILE"

# Extract timestamp from backup filename
BACKUP_TIMESTAMP=$(basename "$BACKUP_FILE" | sed "s/${DATABASE}_full_\(.*\)\.sql\.gz\.enc/\1/")
log_info "Backup timestamp: $BACKUP_TIMESTAMP"

# Get backup file size for statistics
BACKUP_SIZE=$(stat -c%s "$BACKUP_FILE" 2>/dev/null || stat -f%z "$BACKUP_FILE" 2>/dev/null || echo "0")
TOTAL_BACKUP_SIZE=$BACKUP_SIZE

log_info "Starting restore process..."
log_both "INFO" "Starting restore process for $DATABASE from $BACKUP_TIMESTAMP" "$LOG_FILE"

# Step 1: Decrypt and restore the full backup
log_info "Step 1: Decrypting and restoring full backup..."

# Check if encryption key exists
if [[ ! -f ".backup_encryption_key" ]]; then
  log_error "Encryption key not found: .backup_encryption_key"
  exit 1
fi

# Decrypt and restore the backup
if ! ./encrypt_backup.sh --decrypt "$BACKUP_FILE" --key .backup_encryption_key; then
  log_error "Failed to decrypt backup file"
  exit 1
fi

# Get decrypted filename
DECRYPTED_FILE="${BACKUP_FILE%.enc}"

# Import the backup
log_info "Importing backup into database: $DATABASE"
if ! docker exec -i mariadb mariadb -u root -p"$MARIADB_ROOT_PASSWORD" "$DATABASE" < <(gunzip -c "$DECRYPTED_FILE"); then
  log_error "Failed to import backup"
  rm -f "$DECRYPTED_FILE"
  exit 1
fi

log_success "Full backup restored successfully"
PROCESSED_DATABASES=1

# Clean up decrypted file
rm -f "$DECRYPTED_FILE"

# Step 2: Apply binary logs if timestamp is specified
if [[ -n "$RESTORE_TO_TIMESTAMP" ]]; then
  log_info "Step 2: Applying binary logs up to timestamp: $RESTORE_TO_TIMESTAMP"
  
  # Find binlog info file
  BINLOG_INFO_FILE="./backups/binlog_info/last_binlog_info_${DATABASE}_${BACKUP_TIMESTAMP}.txt"
  if [[ ! -f "$BINLOG_INFO_FILE" ]]; then
    BINLOG_INFO_FILE="./backups/incr/last_binlog_info_${DATABASE}_${BACKUP_TIMESTAMP}.txt"
  fi
  
  if [[ -f "$BINLOG_INFO_FILE" ]]; then
    read BINLOG_FILE BINLOG_POS < "$BINLOG_INFO_FILE"
    log_info "Starting from binlog: $BINLOG_FILE at position $BINLOG_POS"
    log_both "INFO" "Applying binlogs from $BINLOG_FILE:$BINLOG_POS to $RESTORE_TO_TIMESTAMP" "$LOG_FILE"
    
    # Find all binlog files from the backup point to the restore timestamp
    BINLOG_FILES=()
    for bl_file in ./backups/binlogs/mysql-bin.*; do
      if [[ -f "$bl_file" ]]; then
        bl_name=$(basename "$bl_file")
        if [[ "$bl_name" >= "$BINLOG_FILE" ]]; then
          BINLOG_FILES+=("$bl_file")
        fi
      fi
    done
    
    # Sort binlog files
    IFS=$'\n' BINLOG_FILES=($(sort <<<"${BINLOG_FILES[*]}"))
    unset IFS
    
    log_info "Found ${#BINLOG_FILES[@]} binlog files to process"
    
    # Process each binlog file
    for bl_file in "${BINLOG_FILES[@]}"; do
      bl_name=$(basename "$bl_file")
      log_info "Processing binlog: $bl_name"
      
      # Get binlog size for statistics
      if [[ -f "$bl_file" ]]; then
        BL_SIZE=$(stat -c%s "$bl_file" 2>/dev/null || stat -f%z "$bl_file" 2>/dev/null || echo "0")
        TOTAL_BINLOG_SIZE=$((TOTAL_BINLOG_SIZE + BL_SIZE))
      fi
      
      # Determine start position (only for first file)
      START_POS=""
      if [[ "$bl_name" == "$BINLOG_FILE" ]]; then
        START_POS="--start-position=$BINLOG_POS"
      fi
      
      # Apply binlog with timestamp limit
      if docker exec mariadb mysqlbinlog \
        $START_POS \
        --stop-datetime="$RESTORE_TO_TIMESTAMP" \
        --database="$DATABASE" \
        "/var/lib/mysql/binlogs/$bl_name" | \
        docker exec -i mariadb mariadb -u root -p"$MARIADB_ROOT_PASSWORD" "$DATABASE"; then
        
        log_success "Applied binlog: $bl_name"
        TOTAL_BINLOGS_PROCESSED=$((TOTAL_BINLOGS_PROCESSED + 1))
      else
        log_warning "Failed to apply binlog: $bl_name (this might be normal if no relevant data)"
        TOTAL_BINLOGS_ERRORS=$((TOTAL_BINLOGS_ERRORS + 1))
      fi
    done
  else
    log_warning "Binlog info file not found: $BINLOG_INFO_FILE"
    log_warning "Cannot apply incremental changes"
  fi
fi

# Calculate restore duration
RESTORE_END_TIME=$(date +%s)
RESTORE_DURATION=$((RESTORE_END_TIME - RESTORE_START_TIME))

# Convert sizes to human readable format
if [[ $TOTAL_BACKUP_SIZE -gt 1048576 ]]; then
  BACKUP_SIZE_HR=$(echo "scale=2; $TOTAL_BACKUP_SIZE/1048576" | bc -l 2>/dev/null || echo "$((TOTAL_BACKUP_SIZE/1048576))")
  BACKUP_SIZE_UNIT="MB"
elif [[ $TOTAL_BACKUP_SIZE -gt 1024 ]]; then
  BACKUP_SIZE_HR=$(echo "scale=2; $TOTAL_BACKUP_SIZE/1024" | bc -l 2>/dev/null || echo "$((TOTAL_BACKUP_SIZE/1024))")
  BACKUP_SIZE_UNIT="KB"
else
  BACKUP_SIZE_HR=$TOTAL_BACKUP_SIZE
  BACKUP_SIZE_UNIT="bytes"
fi

if [[ $TOTAL_BINLOG_SIZE -gt 1048576 ]]; then
  BINLOG_SIZE_HR=$(echo "scale=2; $TOTAL_BINLOG_SIZE/1048576" | bc -l 2>/dev/null || echo "$((TOTAL_BINLOG_SIZE/1048576))")
  BINLOG_SIZE_UNIT="MB"
elif [[ $TOTAL_BINLOG_SIZE -gt 1024 ]]; then
  BINLOG_SIZE_HR=$(echo "scale=2; $TOTAL_BINLOG_SIZE/1024" | bc -l 2>/dev/null || echo "$((TOTAL_BINLOG_SIZE/1024))")
  BINLOG_SIZE_UNIT="KB"
else
  BINLOG_SIZE_HR=$TOTAL_BINLOG_SIZE
  BINLOG_SIZE_UNIT="bytes"
fi

# Show restore summary
log_success "Restore completed successfully!"
log_both "SUCCESS" "Restore completed successfully!" "$LOG_FILE"

echo
log_info "=== RESTORE SUMMARY ==="
log_info "Database: $DATABASE"
log_info "Backup file: $BACKUP_FILE"
log_info "Backup timestamp: $BACKUP_TIMESTAMP"
if [[ -n "$RESTORE_TO_TIMESTAMP" ]]; then
  log_info "Restored to timestamp: $RESTORE_TO_TIMESTAMP"
fi
log_info "Duration: ${RESTORE_DURATION}s"
log_info "Backup size processed: $BACKUP_SIZE_HR $BACKUP_SIZE_UNIT"
if [[ $TOTAL_BINLOG_SIZE -gt 0 ]]; then
  log_info "Binlog size processed: $BINLOG_SIZE_HR $BINLOG_SIZE_UNIT"
  log_info "Binlogs processed: $TOTAL_BINLOGS_PROCESSED"
  if [[ $TOTAL_BINLOGS_ERRORS -gt 0 ]]; then
    log_warning "Binlogs with errors: $TOTAL_BINLOGS_ERRORS"
  fi
fi

# Log summary to file
log_both "INFO" "=== RESTORE SUMMARY ===" "$LOG_FILE"
log_both "INFO" "Database: $DATABASE, Duration: ${RESTORE_DURATION}s" "$LOG_FILE"
log_both "INFO" "Backup size: $BACKUP_SIZE_HR $BACKUP_SIZE_UNIT, Binlog size: $BINLOG_SIZE_HR $BINLOG_SIZE_UNIT" "$LOG_FILE"
log_both "INFO" "Binlogs processed: $TOTAL_BINLOGS_PROCESSED, Errors: $TOTAL_BINLOGS_ERRORS" "$LOG_FILE"

log_info "Restore process completed at $(date '+%Y-%m-%d %H:%M:%S')"