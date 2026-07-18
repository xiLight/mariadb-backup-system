#!/bin/bash
cd "$(dirname "$0")"

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
  handle_error 1 "OpenSSL is not installed. Please install it and try again."
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
      echo "Usage: ./encrypt_backup.sh [--encrypt|--decrypt] FILE [OPTIONS]"
      echo "  --encrypt            Encrypt the specified file (creates FILE.enc)"
      echo "  --decrypt            Decrypt the specified file"
      echo "  --key FILE           Key file (default: .backup_encryption_key)"
      echo "  --checksum-dir DIR   Checksum directory (default: ./backups/checksums)"
      echo "  --no-checksum        Skip checksum creation on encrypt"
      echo "  --help               Show this help message"
      exit 0
      ;;
    *)
      FILE="$1"
      shift
      ;;
  esac
done

[[ -z "$ACTION" ]] && handle_error 2 "No action specified. Use --encrypt or --decrypt"
[[ -z "$FILE" ]] && handle_error 3 "No file specified"
[[ ! -f "$FILE" ]] && handle_error 4 "File '$FILE' not found"

if [[ ! -f "$KEY_FILE" && "$ACTION" == "encrypt" ]]; then
  log_info "Generating new encryption key..."
  openssl rand -base64 32 > "$KEY_FILE"
  chmod 600 "$KEY_FILE"
  log_warning "Encryption key generated and saved to $KEY_FILE. KEEP THIS SAFE!"
fi

[[ ! -f "$KEY_FILE" ]] && handle_error 5 "Key file '$KEY_FILE' not found"

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
  log_info "Encrypting: $FILE -> $OUTPUT_FILE"

  openssl enc -aes-256-cbc -salt -pbkdf2 -iter "$PBKDF2_ITER" -in "$FILE" -out "$OUTPUT_FILE" -pass file:"$KEY_FILE" ||
    handle_error 6 "Encryption failed"

  if [[ "$CREATE_CHECKSUM" == "true" ]]; then
    mkdir -p "$CHECKSUM_DIR"
    CHECKSUM_FILE="$CHECKSUM_DIR/$(basename "$OUTPUT_FILE").sha256"
    write_checksum "$OUTPUT_FILE" "$CHECKSUM_FILE"
    log_info "Checksum saved: $CHECKSUM_FILE"
  fi

  log_success "Encryption completed successfully"

elif [[ "$ACTION" == "decrypt" ]]; then
  if [[ "$FILE" == *.enc ]]; then
    OUTPUT_FILE="${FILE%.enc}"
  else
    OUTPUT_FILE="${FILE}.decrypted"
  fi

  log_info "Decrypting: $FILE -> $OUTPUT_FILE"

  # Verify integrity first if a checksum exists (new location, then legacy)
  CHECKSUM_FILE="$CHECKSUM_DIR/$(basename "$FILE").sha256"
  [[ ! -f "$CHECKSUM_FILE" ]] && CHECKSUM_FILE="${FILE}.sha256"

  if [[ -f "$CHECKSUM_FILE" ]]; then
    log_info "Verifying checksum before decryption..."
    if verify_checksum "$FILE" "$CHECKSUM_FILE"; then
      log_success "Checksum verified successfully"
    else
      handle_error 7 "Checksum verification failed! File may be corrupted."
    fi
  fi

  if ! openssl enc -aes-256-cbc -d -pbkdf2 -iter "$PBKDF2_ITER" -in "$FILE" -out "$OUTPUT_FILE" -pass file:"$KEY_FILE" 2>/dev/null; then
    log_info "Trying legacy decryption parameters (backup from before iteration hardening)..."
    rm -f "$OUTPUT_FILE"
    openssl enc -aes-256-cbc -d -pbkdf2 -in "$FILE" -out "$OUTPUT_FILE" -pass file:"$KEY_FILE" ||
      { rm -f "$OUTPUT_FILE"; handle_error 9 "Decryption failed. Is the key correct?"; }
  fi

  log_success "Decryption completed successfully"
fi

exit 0
