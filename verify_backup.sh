#!/bin/bash
cd "$(dirname "$0")"

set -o pipefail

source "./lib/logging.sh"

LOG_FILE="./logs/verify.log"
init_logging

# Verifies backup integrity without touching the database:
#   1. checksum matches (if a checksum file exists)
#   2. file can be decrypted with the configured key
#   3. decompressed stream is valid gzip data

BACKUP_DIR="${BACKUP_DIR:-./backups}"
CHECKSUM_DIR="$BACKUP_DIR/checksums"
ENCRYPT_KEY_FILE=".backup_encryption_key"
LATEST_ONLY=false
SPECIFIC_DATABASE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --latest)
      LATEST_ONLY=true
      shift
      ;;
    --database)
      SPECIFIC_DATABASE="$2"
      shift 2
      ;;
    --key)
      ENCRYPT_KEY_FILE="$2"
      shift 2
      ;;
    --help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Verifies that encrypted backups are intact and restorable"
      echo "(checksum + decryption + gzip integrity). No database access needed."
      echo ""
      echo "OPTIONS:"
      echo "  --latest         Only verify the most recent backup per database"
      echo "  --database DB    Only verify backups of a specific database"
      echo "  --key FILE       Encryption key file (default: .backup_encryption_key)"
      echo "  --help           Show this help message"
      exit 0
      ;;
    *)
      log_error "Unknown option: $1"
      exit 1
      ;;
  esac
done

if [[ ! -f "$ENCRYPT_KEY_FILE" ]]; then
  log_error "Encryption key not found: $ENCRYPT_KEY_FILE"
  exit 1
fi

verify_checksum() {
  local file="$1"
  local checksum_file="$CHECKSUM_DIR/$(basename "$file").sha256"
  [[ ! -f "$checksum_file" ]] && checksum_file="${file}.sha256"

  if [[ ! -f "$checksum_file" ]]; then
    echo "none"
    return 0
  fi

  local expected actual
  expected=$(awk '{print $1}' "$checksum_file")
  if command -v sha256sum &> /dev/null; then
    actual=$(sha256sum "$file" | awk '{print $1}')
  else
    actual=$(openssl dgst -sha256 "$file" | awk '{print $NF}')
  fi

  if [[ "$expected" == "$actual" ]]; then
    echo "ok"
  else
    echo "fail"
  fi
}

# Collect backup files to verify
PATTERN="*"
[[ -n "$SPECIFIC_DATABASE" ]] && PATTERN="${SPECIFIC_DATABASE}"

BACKUP_FILES=()
if [[ "$LATEST_ONLY" == "true" ]]; then
  for db in $(ls "$BACKUP_DIR"/${PATTERN}_full_*.sql.gz.enc 2>/dev/null | sed -r 's/.*\/(.*)_full_.*/\1/' | sort -u); do
    latest=$(ls -1t "$BACKUP_DIR/${db}"_full_*.sql.gz.enc 2>/dev/null | head -1)
    [[ -n "$latest" ]] && BACKUP_FILES+=("$latest")
  done
else
  while IFS= read -r f; do
    BACKUP_FILES+=("$f")
  done < <(ls -1 "$BACKUP_DIR"/${PATTERN}_*.sql.gz.enc 2>/dev/null)
fi

if [[ ${#BACKUP_FILES[@]} -eq 0 ]]; then
  log_warning "No backup files found to verify"
  exit 0
fi

log_info "Verifying ${#BACKUP_FILES[@]} backup file(s)..."

VERIFIED=0
FAILED=0
NO_CHECKSUM=0

for BACKUP_FILE in "${BACKUP_FILES[@]}"; do
  NAME=$(basename "$BACKUP_FILE")

  CHECKSUM_RESULT=$(verify_checksum "$BACKUP_FILE")
  if [[ "$CHECKSUM_RESULT" == "fail" ]]; then
    log_error "$NAME: checksum MISMATCH - file is corrupted"
    FAILED=$((FAILED + 1))
    continue
  fi
  [[ "$CHECKSUM_RESULT" == "none" ]] && NO_CHECKSUM=$((NO_CHECKSUM + 1))

  DECRYPT_OK=false
  for ITER_OPTS in "-iter 200000" ""; do
    if openssl enc -aes-256-cbc -d -pbkdf2 $ITER_OPTS -in "$BACKUP_FILE" -pass file:"$ENCRYPT_KEY_FILE" 2>/dev/null | gzip -t 2>/dev/null; then
      DECRYPT_OK=true
      break
    fi
  done

  if [[ "$DECRYPT_OK" == "true" ]]; then
    log_success "$NAME: OK$([ "$CHECKSUM_RESULT" == "none" ] && echo " (no checksum on file)")"
    VERIFIED=$((VERIFIED + 1))
  else
    log_error "$NAME: decryption or gzip integrity test FAILED"
    FAILED=$((FAILED + 1))
  fi
done

echo
log_info "=== VERIFY SUMMARY ==="
log_info "Verified OK: $VERIFIED"
[[ $NO_CHECKSUM -gt 0 ]] && log_warning "Without checksum: $NO_CHECKSUM"
if [[ $FAILED -gt 0 ]]; then
  log_error "Failed: $FAILED - these backups are NOT restorable!"
  exit 1
fi

log_success "All backups verified successfully"
