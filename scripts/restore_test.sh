#!/bin/bash
cd "$(dirname "$0")/.."

set -o pipefail

source "./lib/logging.sh"

LOG_FILE="./logs/restore_test.log"
init_logging

source .env 2>/dev/null || { log_error ".env Datei konnte nicht geladen werden."; exit 1; }

# Restore drill: proves that backups are actually restorable by importing
# the latest backup of each database into a THROWAWAY MariaDB container
# (isolated, --network none) and checking the result. The live database
# and the cluster are never touched. Ideal as a weekly cron job.

BACKUP_DIR="${BACKUP_DIR:-./backups}"
STACK_NAME="${STACK_NAME:-mariadb}"
ENCRYPT_KEY_FILE=".backup_encryption_key"
TEST_CONTAINER="${STACK_NAME}-restore-test"
SPECIFIC_DATABASE=""
KEEP_CONTAINER=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --database)
      SPECIFIC_DATABASE="$2"
      shift 2
      ;;
    --keep)
      KEEP_CONTAINER=true
      shift
      ;;
    --help)
      echo "Nutzung: $0 [OPTIONS]"
      echo ""
      echo "Stellt das neueste Backup jeder Datenbank in einem Wegwerf-Container"
      echo "wieder her und überprüft den Import (Tabellen vorhanden, keine Fehler)."
      echo "Die Live-Datenbank wird dabei nie berührt."
      echo ""
      echo "OPTIONEN:"
      echo "  --database DB    Nur das neueste Backup dieser Datenbank testen"
      echo "  --keep           Den Test-Container zur Inspektion weiterlaufen lassen"
      echo "  --help           Diesen Hilfetext anzeigen"
      echo ""
      echo "Cron-Beispiel (wöchentlich, Sonntag 05:00 Uhr):"
      echo "  0 5 * * 0 cd $(pwd) && ./scripts/restore_test.sh >/dev/null 2>&1"
      exit 0
      ;;
    *)
      log_error "Unbekannte Option: $1"
      exit 1
      ;;
  esac
done

[[ ! -f "$ENCRYPT_KEY_FILE" ]] && { log_error "Verschlüsselungs-Key nicht gefunden: $ENCRYPT_KEY_FILE"; exit 1; }

# Find the image this stack uses (cluster image first, then single-node)
find_image() {
  local candidate
  for candidate in "${STACK_NAME}-galera:local" "${STACK_NAME}-mariadb:latest"; do
    if docker image inspect "$candidate" >/dev/null 2>&1; then
      echo "$candidate"
      return 0
    fi
  done
  docker images --format '{{.Repository}}:{{.Tag}}' | grep -m1 -E "galera:local$"
}

cleanup() {
  if [[ "$KEEP_CONTAINER" != "true" ]]; then
    docker rm -f "$TEST_CONTAINER" >/dev/null 2>&1
  fi
  rm -f "$DECRYPTED_FILE" 2>/dev/null
}
trap cleanup EXIT

fail() {
  log_error "$1"
  [[ -x ./scripts/notify.sh ]] && ./scripts/notify.sh error "Restore-Test FEHLGESCHLAGEN" "$1" || true
  exit 1
}

IMAGE=$(find_image)
[[ -z "$IMAGE" ]] && fail "Kein passendes Image gefunden - bitte zuerst bauen (cluster.sh init oder docker compose build)."
log_info "Verwende Image: $IMAGE"

# Collect latest full backup per database (grants dump is imported separately)
declare -A LATEST_BACKUPS
for db in $(ls "$BACKUP_DIR"/*_full_*.sql.gz.enc 2>/dev/null | sed -r 's/.*\/(.*)_full_.*/\1/' | sort -u); do
  [[ "$db" == "system_grants" ]] && continue
  [[ -n "$SPECIFIC_DATABASE" && "$db" != "$SPECIFIC_DATABASE" ]] && continue
  LATEST_BACKUPS[$db]=$(ls -1t "$BACKUP_DIR/${db}"_full_*.sql.gz.enc 2>/dev/null | head -1)
done

[[ ${#LATEST_BACKUPS[@]} -eq 0 ]] && fail "Keine Full-Backups zum Testen gefunden."
log_info "Teste Backup(s) von ${#LATEST_BACKUPS[@]} Datenbank(en): ${!LATEST_BACKUPS[*]}"

# Start the throwaway instance: no network, no provisioning, random password
docker rm -f "$TEST_CONTAINER" >/dev/null 2>&1
log_info "Starte Wegwerf-MariaDB-Instanz (isoliert, --network none)..."
docker run -d --name "$TEST_CONTAINER" \
  --network none \
  -e MARIADB_ROOT_PASSWORD="$(openssl rand -base64 16 | tr -d '=+/')" \
  -e SKIP_PROVISION=yes \
  "$IMAGE" >/dev/null || fail "Konnte Test-Container aus $IMAGE nicht starten."

log_info "Warte darauf, dass die Test-Instanz bereit ist..."
READY=false
for i in $(seq 1 60); do
  if docker exec "$TEST_CONTAINER" mariadb-admin ping --silent >/dev/null 2>&1; then
    READY=true
    break
  fi
  sleep 2
done
[[ "$READY" != "true" ]] && fail "Test-Instanz wurde innerhalb von 120s nicht bereit."
log_success "Test-Instanz ist bereit."

TESTED=0
FAILED=0
SUMMARY=""

for db in "${!LATEST_BACKUPS[@]}"; do
  BACKUP_FILE="${LATEST_BACKUPS[$db]}"
  log_info "--- Teste Restore von: $db ($(basename "$BACKUP_FILE")) ---"

  if ! ./scripts/encrypt_backup.sh --decrypt "$BACKUP_FILE" --key "$ENCRYPT_KEY_FILE" >/dev/null 2>&1; then
    log_error "$db: Entschlüsselung fehlgeschlagen"
    FAILED=$((FAILED + 1))
    continue
  fi
  DECRYPTED_FILE="${BACKUP_FILE%.enc}"

  if ! gunzip -c "$DECRYPTED_FILE" | docker exec -i "$TEST_CONTAINER" mariadb -u root 2>/tmp/restore_test_err.$$; then
    log_error "$db: Import FEHLGESCHLAGEN: $(tail -1 /tmp/restore_test_err.$$ 2>/dev/null)"
    rm -f "$DECRYPTED_FILE" /tmp/restore_test_err.$$
    FAILED=$((FAILED + 1))
    continue
  fi
  rm -f "$DECRYPTED_FILE" /tmp/restore_test_err.$$

  TABLE_COUNT=$(docker exec "$TEST_CONTAINER" mariadb -u root -N -e \
    "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$db';" 2>/dev/null)
  ROW_ESTIMATE=$(docker exec "$TEST_CONTAINER" mariadb -u root -N -e \
    "SELECT COALESCE(SUM(table_rows),0) FROM information_schema.tables WHERE table_schema='$db';" 2>/dev/null)

  if [[ "$TABLE_COUNT" =~ ^[0-9]+$ ]] && [[ "$TABLE_COUNT" -gt 0 ]]; then
    log_success "$db: Restore OK ($TABLE_COUNT Tabellen, ~$ROW_ESTIMATE Einträge)"
    SUMMARY+="$db: OK ($TABLE_COUNT Tabellen) | "
  else
    # A database dumped with --include-empty legitimately has 0 tables
    if docker exec "$TEST_CONTAINER" mariadb -u root -N -e "SHOW DATABASES;" 2>/dev/null | grep -qx "$db"; then
      log_warning "$db: Wiederhergestellt, aber enthält keine Tabellen (leeres Backup?)"
      SUMMARY+="$db: leer | "
    else
      log_error "$db: Datenbank fehlt nach dem Import"
      SUMMARY+="$db: FEHLT | "
      FAILED=$((FAILED + 1))
      continue
    fi
  fi
  TESTED=$((TESTED + 1))
done

echo
log_info "=== RESTORE-TEST ZUSAMMENFASSUNG ==="
log_info "Getestet: $TESTED, Fehlgeschlagen: $FAILED"
log_info "${SUMMARY% | }"

if [[ "$KEEP_CONTAINER" == "true" ]]; then
  log_info "Test-Container läuft weiter: docker exec -it $TEST_CONTAINER mariadb -u root"
fi

if [[ $FAILED -gt 0 ]]; then
  fail "Restore-Test: $FAILED Backup(s) sind NICHT wiederherstellbar! ($SUMMARY)"
fi

log_success "Alle getesteten Backups sind wiederherstellbar - die gesamte Kette (Dump -> Verschlüsselung -> Entschlüsselung -> Import) funktioniert!"
exit 0
