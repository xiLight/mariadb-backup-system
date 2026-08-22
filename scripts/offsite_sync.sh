#!/bin/bash
cd "$(dirname "$0")/.."

set -o pipefail

source "./lib/logging.sh"

LOG_FILE="./logs/offsite.log"
init_logging

source .env 2>/dev/null || { log_error ".env Datei konnte nicht geladen werden."; exit 1; }

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
      echo "Nutzung: $0 [OPTIONS]"
      echo ""
      echo "Repliziert $BACKUP_DIR zum Offsite-Ziel aus der .env-Datei."
      echo ""
      echo "OPTIONEN:"
      echo "  --dry-run    Zeigt, was übertragen werden würde (ohne es zu tun)"
      echo "  --verify     Die neuesten Backups vorher verifizieren; bricht bei Fehlern ab"
      echo "  --help       Diesen Hilfetext anzeigen"
      echo ""
      echo "Cron-Beispiel (stündlich, mit vorheriger Überprüfung):"
      echo "  0 * * * * cd $(pwd) && ./scripts/offsite_sync.sh --verify >/dev/null 2>&1"
      echo ""
      echo "WICHTIG: Sichere .backup_encryption_key separat an einem anderen Ort"
      echo "(Passwort-Manager / Vault). Er wird niemals synchronisiert, und ohne ihn"
      echo "können weder du noch ein Angreifer die Offsite-Backups lesen."
      exit 0
      ;;
    *)
      log_error "Unbekannte Option: $1"
      exit 1
      ;;
  esac
done

if [[ -z "$OFFSITE_TARGET" ]]; then
  log_error "OFFSITE_TARGET ist in der .env-Datei nicht gesetzt."
  log_info "Beispiel (rsync über SSH):  OFFSITE_TARGET=user@backuphost:/backups/mariadb"
  log_info "Beispiel (rclone):          OFFSITE_METHOD=rclone / OFFSITE_TARGET=remote:mariadb-backups"
  exit 1
fi

if [[ ! -d "$BACKUP_DIR" ]]; then
  log_error "Backup-Verzeichnis nicht gefunden: $BACKUP_DIR - nichts zu synchronisieren."
  exit 1
fi

if [[ "$VERIFY_FIRST" == "true" ]]; then
  log_info "Überprüfe die neuesten Backups vor der Synchronisation..."
  if ! ./scripts/verify_backup.sh --latest >/dev/null 2>&1; then
    log_error "Backup-Überprüfung FEHLGESCHLAGEN - beschädigte Backups werden nicht Offsite synchronisiert!"
    log_error "Details: ./scripts/verify_backup.sh --latest"
    exit 1
  fi
  log_success "Überprüfung erfolgreich bestanden."
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
        log_warning "Fehler beim Verschlüsseln des Binlogs für Offsite: $(basename "$bl")"
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

  log_info "Binlog Offsite-Staging: $staged neu verschlüsselt (Entschlüsselung mit encrypt_backup.sh --decrypt)"
}

SYNC_START=$(date +%s)
log_info "Starte Offsite-Synchronisation: $BACKUP_DIR -> $OFFSITE_TARGET (Methode: $OFFSITE_METHOD)"

EXTRA_EXCLUDES=()
if [[ "$OFFSITE_ENCRYPT_BINLOGS" == "yes" ]]; then
  [[ -f "$ENCRYPT_KEY_FILE" ]] || { log_error "Verschlüsselungs-Key nicht gefunden: $ENCRYPT_KEY_FILE"; exit 1; }
  stage_encrypted_binlogs
  EXTRA_EXCLUDES=(binlogs)
else
  log_warning "OFFSITE_ENCRYPT_BINLOGS=no - Binlogs werden UNVERSCHLÜSSELT repliziert!"
fi

case "$OFFSITE_METHOD" in
  rsync)
    command -v rsync &>/dev/null || { log_error "rsync ist nicht installiert."; exit 1; }

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
    command -v rclone &>/dev/null || { log_error "rclone ist nicht installiert."; exit 1; }

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
    log_error "Unbekannte OFFSITE_METHOD: $OFFSITE_METHOD (Nutze rsync oder rclone)."
    exit 1
    ;;
esac

SYNC_DURATION=$(( $(date +%s) - SYNC_START ))

if [[ "$SYNC_OK" != "true" ]]; then
  log_error "Offsite-Synchronisation nach ${SYNC_DURATION}s FEHLGESCHLAGEN - Backups wurden NICHT repliziert!"
  [[ -x ./scripts/notify.sh ]] && ./scripts/notify.sh error "Offsite-Sync FEHLGESCHLAGEN" "Backups konnten nicht auf $OFFSITE_TARGET repliziert werden. Sie existieren nur lokal!" || true
  exit 1
fi

if [[ "$DRY_RUN" == "true" ]]; then
  log_info "Dry-Run in ${SYNC_DURATION}s abgeschlossen - es wurde nichts übertragen."
  exit 0
fi

date +%s > "$STATE_FILE"
log_success "Offsite-Synchronisation in ${SYNC_DURATION}s erfolgreich abgeschlossen."
log_info "Zur Erinnerung: Bewahre eine Kopie von .backup_encryption_key sicher an einem separaten Ort auf (er wird absichtlich nicht mit synchronisiert)!"
