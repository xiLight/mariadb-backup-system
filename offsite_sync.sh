#!/bin/bash
cd "$(dirname "$0")"

set -o pipefail

source "./lib/logging.sh"

LOG_FILE="./logs/offsite.log"
init_logging

source .env 2>/dev/null || { log_error "Failed to source .env file"; exit 1; }

# Replicates the backup directory to an offsite target so a disk failure
# or server compromise cannot take out the database AND all backups.
#
# Configuration (.env):
#   OFFSITE_METHOD   rsync (over SSH) or rclone
#   OFFSITE_TARGET   rsync:  user@backuphost:/backups/mariadb
#                    rclone: remote:mariadb-backups
#   OFFSITE_DELETE   yes = mirror local retention to the remote (default: no,
#                    the remote keeps files that were cleaned up locally)
#   OFFSITE_BWLIMIT  optional bandwidth limit (rsync: KB/s, rclone: e.g. 5M)
#
# The encryption key is NEVER synced - without it the offsite dumps are
# useless to an attacker, but also to you: store .backup_encryption_key
# separately (password manager / vault), not next to the backups.

BACKUP_DIR="${BACKUP_DIR:-./backups}"
OFFSITE_METHOD="${OFFSITE_METHOD:-rsync}"
OFFSITE_TARGET="${OFFSITE_TARGET:-}"
OFFSITE_DELETE="${OFFSITE_DELETE:-no}"
OFFSITE_BWLIMIT="${OFFSITE_BWLIMIT:-}"
OFFSITE_ENCRYPT_BINLOGS="${OFFSITE_ENCRYPT_BINLOGS:-yes}"
ENCRYPT_KEY_FILE=".backup_encryption_key"
STATE_FILE="./logs/.last_offsite_sync"

DRY_RUN=false
VERIFY_FIRST=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --verify)
      VERIFY_FIRST=true
      shift
      ;;
    --help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Replicates $BACKUP_DIR to the offsite target from .env."
      echo ""
      echo "OPTIONS:"
      echo "  --dry-run    Show what would be transferred without doing it"
      echo "  --verify     Verify latest backups first, abort sync on failure"
      echo "  --help       Show this help message"
      echo ""
      echo "Cron example (hourly, after verifying):"
      echo "  0 * * * * cd $(pwd) && ./offsite_sync.sh --verify >/dev/null 2>&1"
      echo ""
      echo "IMPORTANT: back up .backup_encryption_key separately (password"
      echo "manager / vault) - it is never synced, and without it neither"
      echo "you nor an attacker can read the offsite backups."
      exit 0
      ;;
    *)
      log_error "Unknown option: $1"
      exit 1
      ;;
  esac
done

if [[ -z "$OFFSITE_TARGET" ]]; then
  log_error "OFFSITE_TARGET is not set in .env"
  log_info "Example (rsync over SSH):  OFFSITE_TARGET=user@backuphost:/backups/mariadb"
  log_info "Example (rclone):          OFFSITE_METHOD=rclone / OFFSITE_TARGET=remote:mariadb-backups"
  exit 1
fi

if [[ ! -d "$BACKUP_DIR" ]]; then
  log_error "Backup directory not found: $BACKUP_DIR - nothing to sync"
  exit 1
fi

if [[ "$VERIFY_FIRST" == "true" ]]; then
  log_info "Verifying latest backups before sync..."
  if ! ./verify_backup.sh --latest >/dev/null 2>&1; then
    log_error "Backup verification FAILED - not syncing corrupted backups offsite"
    log_error "Details: ./verify_backup.sh --latest"
    exit 1
  fi
  log_success "Verification passed"
fi

# The SQL dumps are encrypted, but the binlog copies contain the same data
# in PLAINTEXT. For offsite they are mirrored into binlogs_enc/ (encrypted,
# incremental by mtime) and the plaintext binlogs/ dir is excluded.
stage_encrypted_binlogs() {
  local src="$BACKUP_DIR/binlogs" dst="$BACKUP_DIR/binlogs_enc"
  [[ -d "$src" ]] || return 0
  mkdir -p "$dst"

  local bl enc staged=0
  for bl in "$src"/mysql-bin.*; do
    [[ -f "$bl" ]] || continue
    enc="$dst/$(basename "$bl").enc"
    if [[ ! -f "$enc" || "$bl" -nt "$enc" ]]; then
      if openssl enc -aes-256-cbc -salt -pbkdf2 -iter 200000 -in "$bl" -out "$enc" -pass file:"$ENCRYPT_KEY_FILE" 2>/dev/null; then
        staged=$((staged + 1))
      else
        log_warning "Failed to encrypt binlog for offsite: $(basename "$bl")"
        rm -f "$enc"
      fi
    fi
  done

  # Prune encrypted copies whose source binlog was cleaned up
  for enc in "$dst"/mysql-bin.*.enc; do
    [[ -f "$enc" ]] || continue
    bl="$src/$(basename "$enc" .enc)"
    [[ -f "$bl" ]] || rm -f "$enc"
  done

  log_info "Binlog offsite staging: $staged newly encrypted (decrypt with encrypt_backup.sh --decrypt)"
}

SYNC_START=$(date +%s)
log_info "Starting offsite sync: $BACKUP_DIR -> $OFFSITE_TARGET (method: $OFFSITE_METHOD)"

EXTRA_EXCLUDES=()
if [[ "$OFFSITE_ENCRYPT_BINLOGS" == "yes" ]]; then
  [[ -f "$ENCRYPT_KEY_FILE" ]] || { log_error "Encryption key not found: $ENCRYPT_KEY_FILE"; exit 1; }
  stage_encrypted_binlogs
  EXTRA_EXCLUDES=(binlogs)
else
  log_warning "OFFSITE_ENCRYPT_BINLOGS=no - binlogs will be replicated in PLAINTEXT"
fi

case "$OFFSITE_METHOD" in
  rsync)
    command -v rsync &>/dev/null || { log_error "rsync is not installed"; exit 1; }

    RSYNC_ARGS=(-az --partial)
    [[ "$DRY_RUN" == "true" ]] && RSYNC_ARGS+=(--dry-run --verbose)
    [[ "$OFFSITE_DELETE" == "yes" ]] && RSYNC_ARGS+=(--delete)
    [[ -n "$OFFSITE_BWLIMIT" ]] && RSYNC_ARGS+=(--bwlimit="$OFFSITE_BWLIMIT")
    RSYNC_ARGS+=(--exclude=".*")
    for excl in "${EXTRA_EXCLUDES[@]}"; do
      RSYNC_ARGS+=(--exclude="$excl")
    done

    if rsync "${RSYNC_ARGS[@]}" "$BACKUP_DIR/" "$OFFSITE_TARGET/" 2>&1 | tail -5; then
      SYNC_OK=true
    else
      SYNC_OK=false
    fi
    ;;
  rclone)
    command -v rclone &>/dev/null || { log_error "rclone is not installed"; exit 1; }

    RCLONE_CMD="copy"
    [[ "$OFFSITE_DELETE" == "yes" ]] && RCLONE_CMD="sync"
    RCLONE_ARGS=("$RCLONE_CMD" "$BACKUP_DIR" "$OFFSITE_TARGET" --exclude ".*")
    [[ "$DRY_RUN" == "true" ]] && RCLONE_ARGS+=(--dry-run)
    [[ -n "$OFFSITE_BWLIMIT" ]] && RCLONE_ARGS+=(--bwlimit "$OFFSITE_BWLIMIT")
    for excl in "${EXTRA_EXCLUDES[@]}"; do
      RCLONE_ARGS+=(--exclude "${excl}/**")
    done

    if rclone "${RCLONE_ARGS[@]}" 2>&1 | tail -5; then
      SYNC_OK=true
    else
      SYNC_OK=false
    fi
    ;;
  *)
    log_error "Unknown OFFSITE_METHOD: $OFFSITE_METHOD (use rsync or rclone)"
    exit 1
    ;;
esac

SYNC_DURATION=$(( $(date +%s) - SYNC_START ))

if [[ "$SYNC_OK" != "true" ]]; then
  log_error "Offsite sync FAILED after ${SYNC_DURATION}s - backups are NOT replicated"
  [[ -x ./notify.sh ]] && ./notify.sh error "Offsite sync FAILED" "Backups could not be replicated to $OFFSITE_TARGET. They exist locally only!" || true
  exit 1
fi

if [[ "$DRY_RUN" == "true" ]]; then
  log_info "Dry run completed in ${SYNC_DURATION}s - nothing was transferred"
  exit 0
fi

date +%s > "$STATE_FILE"
log_success "Offsite sync completed in ${SYNC_DURATION}s"
log_info "Reminder: keep a copy of .backup_encryption_key in a separate safe place - it is deliberately not synced"
