#!/bin/bash
cd "$(dirname "$0")/.."

set -e

source "./lib/logging.sh"

LOG_FILE="./logs/encrypt.log"
init_logging

ACTION=""
FILE=""
KEY_FILE=".backup_encryption_key"
CHECKSUM_DIR="./backups/checksums"
CREATE_CHECKSUM=true

# PBKDF2 iteration count for key derivation. Decryption falls back to
# OpenSSL's default (10000) so backups made before this hardening still work.
PBKDF2_ITER=200000

handle_error() {
  local exit_code=$1
  shift
  log_error "$* (exit code: $exit_code)"
  exit "$exit_code"
}

if ! command -v openssl &> /dev/null; then
  handle_error 1 "OpenSSL ist nicht installiert. Bitte installieren und erneut versuchen."
fi

while [[ $# -gt 0 ]]; do
  case $1 in
    --encrypt)
      ACTION="encrypt"
      shift
      ;;
    --decrypt)
      ACTION="decrypt"
      shift
      ;;
    --key)
      KEY_FILE="$2"
      shift 2
      ;;
    --checksum-dir)
      CHECKSUM_DIR="$2"
      shift 2
      ;;
    --no-checksum)
      CREATE_CHECKSUM=false
      shift
      ;;
    --help)
      echo "Nutzung: ./scripts/encrypt_backup.sh [--encrypt|--decrypt] FILE [OPTIONS]"
      echo "  --encrypt            Die angegebene Datei verschlüsseln (erstellt FILE.enc)"
      echo "  --decrypt            Die angegebene Datei entschlüsseln"
      echo "  --key FILE           Key-Datei (Standard: .backup_encryption_key)"
      echo "  --checksum-dir DIR   Verzeichnis für Prüfsummen (Standard: ./backups/checksums)"
      echo "  --no-checksum        Beim Verschlüsseln keine Prüfsumme erstellen"
      echo "  --help               Diesen Hilfetext anzeigen"
      exit 0
      ;;
    *)
      FILE="$1"
      shift
      ;;
  esac
done

[[ -z "$ACTION" ]] && handle_error 2 "Keine Aktion angegeben. Nutze --encrypt oder --decrypt."
[[ -z "$FILE" ]] && handle_error 3 "Keine Datei angegeben."
[[ ! -f "$FILE" ]] && handle_error 4 "Datei '$FILE' wurde nicht gefunden."

if [[ ! -f "$KEY_FILE" && "$ACTION" == "encrypt" ]]; then
  log_info "Generiere neuen Verschlüsselungs-Key..."
  openssl rand -base64 32 > "$KEY_FILE"
  chmod 600 "$KEY_FILE"
  log_warning "Verschlüsselungs-Key generiert und in $KEY_FILE gespeichert. GUT AUFBEWAHREN!"
fi

[[ ! -f "$KEY_FILE" ]] && handle_error 5 "Key-Datei '$KEY_FILE' wurde nicht gefunden."

write_checksum() {
  local target="$1" checksum_file="$2"
  if command -v sha256sum &> /dev/null; then
    sha256sum "$target" > "$checksum_file"
  else
    echo "$(openssl dgst -sha256 "$target" | awk '{print $NF}')  $target" > "$checksum_file"
  fi
}

verify_checksum() {
  local target="$1" checksum_file="$2"
  if command -v sha256sum &> /dev/null; then
    sha256sum -c "$checksum_file" >/dev/null 2>&1
  else
    local expected actual
    expected=$(awk '{print $1}' "$checksum_file")
    actual=$(openssl dgst -sha256 "$target" | awk '{print $NF}')
    [[ "$expected" == "$actual" ]]
  fi
}

if [[ "$ACTION" == "encrypt" ]]; then
  OUTPUT_FILE="${FILE}.enc"
  log_info "Verschlüssele: $FILE -> $OUTPUT_FILE"

  openssl enc -aes-256-cbc -salt -pbkdf2 -iter "$PBKDF2_ITER" -in "$FILE" -out "$OUTPUT_FILE" -pass file:"$KEY_FILE" ||
    handle_error 6 "Verschlüsselung fehlgeschlagen."

  if [[ "$CREATE_CHECKSUM" == "true" ]]; then
    mkdir -p "$CHECKSUM_DIR"
    CHECKSUM_FILE="$CHECKSUM_DIR/$(basename "$OUTPUT_FILE").sha256"
    write_checksum "$OUTPUT_FILE" "$CHECKSUM_FILE"
    log_info "Checksumme gespeichert: $CHECKSUM_FILE"
  fi

  log_success "Verschlüsselung erfolgreich abgeschlossen."

elif [[ "$ACTION" == "decrypt" ]]; then
  if [[ "$FILE" == *.enc ]]; then
    OUTPUT_FILE="${FILE%.enc}"
  else
    OUTPUT_FILE="${FILE}.decrypted"
  fi

  log_info "Entschlüssele: $FILE -> $OUTPUT_FILE"

  # Verify integrity first if a checksum exists (new location, then legacy)
  CHECKSUM_FILE="$CHECKSUM_DIR/$(basename "$FILE").sha256"
  [[ ! -f "$CHECKSUM_FILE" ]] && CHECKSUM_FILE="${FILE}.sha256"

  if [[ -f "$CHECKSUM_FILE" ]]; then
    log_info "Überprüfe Checksumme vor der Entschlüsselung..."
    if verify_checksum "$FILE" "$CHECKSUM_FILE"; then
      log_success "Checksumme erfolgreich verifiziert."
    else
      handle_error 7 "Checksummen-Prüfung fehlgeschlagen! Die Datei könnte beschädigt sein."
    fi
  fi

  if ! openssl enc -aes-256-cbc -d -pbkdf2 -iter "$PBKDF2_ITER" -in "$FILE" -out "$OUTPUT_FILE" -pass file:"$KEY_FILE" 2>/dev/null; then
    log_info "Versuche veraltete Entschlüsselungs-Parameter (Backup vor Iterations-Härtung)..."
    rm -f "$OUTPUT_FILE"
    openssl enc -aes-256-cbc -d -pbkdf2 -in "$FILE" -out "$OUTPUT_FILE" -pass file:"$KEY_FILE" ||
      { rm -f "$OUTPUT_FILE"; handle_error 9 "Entschlüsselung fehlgeschlagen. Ist der Key korrekt?"; }
  fi

  log_success "Entschlüsselung erfolgreich abgeschlossen."
fi

exit 0
