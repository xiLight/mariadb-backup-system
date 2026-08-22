#!/bin/bash
cd "$(dirname "$0")/.."

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
      echo "Nutzung: $0 [OPTIONS]"
      echo ""
      echo "Überprüft, ob verschlüsselte Backups intakt und wiederherstellbar sind"
      echo "(Prüfsumme + Entschlüsselung + GZIP-Integrität). Kein Datenbankzugriff nötig."
      echo ""
      echo "OPTIONEN:"
      echo "  --latest         Nur das aktuellste Backup pro Datenbank überprüfen"
      echo "  --database DB    Nur Backups einer bestimmten Datenbank überprüfen"
      echo "  --key FILE       Datei mit dem Verschlüsselungs-Key (Standard: .backup_encryption_key)"
      echo "  --help           Diesen Hilfetext anzeigen"
      exit 0
      ;;
    *)
      log_error "Unbekannte Option: $1"
      exit 1
      ;;
  esac
done

if [[ ! -f "$ENCRYPT_KEY_FILE" ]]; then
  log_error "Verschlüsselungs-Key nicht gefunden: $ENCRYPT_KEY_FILE"
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
  log_warning "Keine Backup-Dateien zur Überprüfung gefunden."
  exit 0
fi

log_info "Überprüfe ${#BACKUP_FILES[@]} Backup-Datei(en)..."

VERIFIED=0
FAILED=0
NO_CHECKSUM=0

for BACKUP_FILE in "${BACKUP_FILES[@]}"; do
  NAME=$(basename "$BACKUP_FILE")

  CHECKSUM_RESULT=$(verify_checksum "$BACKUP_FILE")
  if [[ "$CHECKSUM_RESULT" == "fail" ]]; then
    log_error "$NAME: Prüfsumme STIMMT NICHT ÜBEREIN - Datei ist beschädigt!"
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
    log_success "$NAME: OK$([ "$CHECKSUM_RESULT" == "none" ] && echo " (keine Prüfsumme in Datei)")"
    VERIFIED=$((VERIFIED + 1))
  else
    log_error "$NAME: Entschlüsselung oder GZIP-Integritätstest FEHLGESCHLAGEN"
    FAILED=$((FAILED + 1))
  fi
done

echo
log_info "=== VERIFY ZUSAMMENFASSUNG ==="
log_info "Erfolgreich überprüft: $VERIFIED"
[[ $NO_CHECKSUM -gt 0 ]] && log_warning "Ohne Prüfsumme: $NO_CHECKSUM"
if [[ $FAILED -gt 0 ]]; then
  log_error "Fehlgeschlagen: $FAILED - Diese Backups sind NICHT wiederherstellbar!"
  exit 1
fi

log_success "Alle Backups wurden erfolgreich überprüft."
