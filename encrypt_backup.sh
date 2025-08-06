#!/bin/bash
cd "$(dirname "$0")"

# Load logging functions
source "./lib/logging.sh"

# Encryption script for MariaDB backups
# This script encrypts backup files using OpenSSL
# Usage: ./encrypt_backup.sh [--encrypt|--decrypt] [file] [--key keyfile]

set -e

# Set default values
ACTION=""
FILE=""
KEY_FILE=".backup_encryption_key"
LOG_FILE="./logs/encrypt.log"

# Create logs directory if it doesn't exist
mkdir -p "./logs"

# Error handling function
function handle_error {
  local exit_code=$1
  local error_msg=$2
  log_error "$error_msg (exit code: $exit_code)"
  exit $exit_code
}

# Check if openssl is installed
if ! command -v openssl &> /dev/null; then
  handle_error 1 "OpenSSL is not installed. Please install it and try again."
fi

# Parse arguments
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
    --help)
      echo "Usage: ./encrypt_backup.sh [--encrypt|--decrypt] [file] [--key keyfile]"
      echo "  --encrypt: Encrypt the specified file"
      echo "  --decrypt: Decrypt the specified file"
      echo "  --key: Specify a key file (default: .backup_encryption_key)"
      echo "  --help: Show this help message"
      exit 0
      ;;
    *)
      FILE="$1"
      shift
      ;;
  esac
done

# Check if action is specified
if [[ -z "$ACTION" ]]; then
  handle_error 2 "No action specified. Use --encrypt or --decrypt"
fi

# Check if file is specified
if [[ -z "$FILE" ]]; then
  handle_error 3 "No file specified"
fi

# Check if file exists
if [[ ! -f "$FILE" ]]; then
  handle_error 4 "File '$FILE' not found"
fi

# Create key if it doesn't exist and we're encrypting
if [[ ! -f "$KEY_FILE" && "$ACTION" == "encrypt" ]]; then
  log_info "Generating new encryption key..."
  openssl rand -base64 32 > "$KEY_FILE"
  chmod 600 "$KEY_FILE"
  log_warning "Encryption key generated and saved to $KEY_FILE. KEEP THIS SAFE!"
fi

# Check if key file exists
if [[ ! -f "$KEY_FILE" ]]; then
  handle_error 5 "Key file '$KEY_FILE' not found"
fi

# Perform encryption/decryption
if [[ "$ACTION" == "encrypt" ]]; then
  OUTPUT_FILE="${FILE}.enc"
  log_info "Encrypting file: $FILE -> $OUTPUT_FILE"
  
  openssl enc -aes-256-cbc -salt -pbkdf2 -in "$FILE" -out "$OUTPUT_FILE" -pass file:"$KEY_FILE" || 
    handle_error 6 "Encryption failed"
  
  # Generate checksum of encrypted file
  if command -v sha256sum &> /dev/null; then
    sha256sum "$OUTPUT_FILE" > "${OUTPUT_FILE}.sha256"
  else
    openssl dgst -sha256 "$OUTPUT_FILE" | sed 's/^.* //' > "${OUTPUT_FILE}.sha256"
  fi
  
  log_success "Encryption completed successfully"
  log_info "Checksum saved to ${OUTPUT_FILE}.sha256"
  
elif [[ "$ACTION" == "decrypt" ]]; then
  # Determine output file name by removing .enc extension
  if [[ "$FILE" == *.enc ]]; then
    OUTPUT_FILE="${FILE%.enc}"
  else
    OUTPUT_FILE="${FILE}.decrypted"
  fi
  
  log_info "Decrypting file: $FILE -> $OUTPUT_FILE"
  
  # Verify checksum if exists
  CHECKSUM_FILE="${FILE}.sha256"
  if [[ -f "$CHECKSUM_FILE" ]]; then
    log_info "Verifying checksum before decryption..."
    
    if command -v sha256sum &> /dev/null; then
      if ! sha256sum -c "$CHECKSUM_FILE"; then
        handle_error 7 "Checksum verification failed! File may be corrupted."
      fi
    else
      EXPECTED=$(cat "$CHECKSUM_FILE")
      ACTUAL=$(openssl dgst -sha256 "$FILE" | sed 's/^.* //')
      if [[ "$EXPECTED" != "$ACTUAL" ]]; then
        handle_error 8 "Checksum verification failed! File may be corrupted."
      fi
    fi
    
    log_success "Checksum verified successfully"
  fi
  
  openssl enc -aes-256-cbc -d -pbkdf2 -in "$FILE" -out "$OUTPUT_FILE" -pass file:"$KEY_FILE" ||
    handle_error 9 "Decryption failed. Is the key correct?"
    
  log_success "Decryption completed successfully"
fi

exit 0