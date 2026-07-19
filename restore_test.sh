#!/bin/bash
cd "$(dirname "$0")"

set -o pipefail

source "./lib/logging.sh"

LOG_FILE="./logs/restore_test.log"
init_logging

source .env 2>/dev/null || { log_error "Failed to source .env file"; exit 1; }

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
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Restores the latest backup of every database into a throwaway"
      echo "container and verifies the import (tables present, no errors)."
      echo "The live database is never touched."
      echo ""
      echo "OPTIONS:"
      echo "  --database DB    Test only this database's latest backup"
      echo "  --keep           Keep the test container running for inspection"
      echo "  --help           Show this help message"
      echo ""
      echo "Cron example (weekly, Sunday 05:00):"
      echo "  0 5 * * 0 cd $(pwd) && ./restore_test.sh >/dev/null 2>&1"
      exit 0
      ;;
    *)
      log_error "Unknown option: $1"
      exit 1
      ;;
  esac
done

[[ ! -f "$ENCRYPT_KEY_FILE" ]] && { log_error "Encryption key not found: $ENCRYPT_KEY_FILE"; exit 1; }

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
  [[ -x ./notify.sh ]] && ./notify.sh error "Restore test FAILED" "$1" || true
  exit 1
}

IMAGE=$(find_image)
[[ -z "$IMAGE" ]] && fail "No stack image found - build it first (cluster.sh init or docker compose build)"
log_info "Using image: $IMAGE"

# Collect latest full backup per database (grants dump is imported separately)
declare -A LATEST_BACKUPS
for db in $(ls "$BACKUP_DIR"/*_full_*.sql.gz.enc 2>/dev/null | sed -r 's/.*\/(.*)_full_.*/\1/' | sort -u); do
  [[ "$db" == "system_grants" ]] && continue
  [[ -n "$SPECIFIC_DATABASE" && "$db" != "$SPECIFIC_DATABASE" ]] && continue
  LATEST_BACKUPS[$db]=$(ls -1t "$BACKUP_DIR/${db}"_full_*.sql.gz.enc 2>/dev/null | head -1)
done

[[ ${#LATEST_BACKUPS[@]} -eq 0 ]] && fail "No full backups found to test"
log_info "Testing ${#LATEST_BACKUPS[@]} database backup(s): ${!LATEST_BACKUPS[*]}"

# Start the throwaway instance: no network, no provisioning, random password
docker rm -f "$TEST_CONTAINER" >/dev/null 2>&1
log_info "Starting throwaway MariaDB instance (isolated, --network none)..."
docker run -d --name "$TEST_CONTAINER" \
  --network none \
  -e MARIADB_ROOT_PASSWORD="$(openssl rand -base64 16 | tr -d '=+/')" \
  -e SKIP_PROVISION=yes \
  "$IMAGE" >/dev/null || fail "Could not start test container from $IMAGE"

log_info "Waiting for the test instance to become ready..."
READY=false
for i in $(seq 1 60); do
  if docker exec "$TEST_CONTAINER" mariadb-admin ping --silent >/dev/null 2>&1; then
    READY=true
    break
  fi
  sleep 2
done
[[ "$READY" != "true" ]] && fail "Test instance did not become ready within 120s"
log_success "Test instance is ready"

TESTED=0
FAILED=0
SUMMARY=""

for db in "${!LATEST_BACKUPS[@]}"; do
  BACKUP_FILE="${LATEST_BACKUPS[$db]}"
  log_info "--- Testing restore of: $db ($(basename "$BACKUP_FILE")) ---"

  if ! ./encrypt_backup.sh --decrypt "$BACKUP_FILE" --key "$ENCRYPT_KEY_FILE" >/dev/null 2>&1; then
    log_error "$db: decryption failed"
    FAILED=$((FAILED + 1))
    continue
  fi
  DECRYPTED_FILE="${BACKUP_FILE%.enc}"

  if ! gunzip -c "$DECRYPTED_FILE" | docker exec -i "$TEST_CONTAINER" mariadb -u root 2>/tmp/restore_test_err.$$; then
    log_error "$db: import FAILED: $(tail -1 /tmp/restore_test_err.$$ 2>/dev/null)"
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
    log_success "$db: restored OK ($TABLE_COUNT tables, ~$ROW_ESTIMATE rows)"
    SUMMARY+="$db: OK ($TABLE_COUNT tables) | "
  else
    # A database dumped with --include-empty legitimately has 0 tables
    if docker exec "$TEST_CONTAINER" mariadb -u root -N -e "SHOW DATABASES;" 2>/dev/null | grep -qx "$db"; then
      log_warning "$db: restored but contains no tables (empty database backup?)"
      SUMMARY+="$db: empty | "
    else
      log_error "$db: database missing after import"
      SUMMARY+="$db: MISSING | "
      FAILED=$((FAILED + 1))
      continue
    fi
  fi
  TESTED=$((TESTED + 1))
done

echo
log_info "=== RESTORE TEST SUMMARY ==="
log_info "Tested: $TESTED, Failed: $FAILED"
log_info "${SUMMARY% | }"

if [[ "$KEEP_CONTAINER" == "true" ]]; then
  log_info "Test container kept running: docker exec -it $TEST_CONTAINER mariadb -u root"
fi

if [[ $FAILED -gt 0 ]]; then
  fail "Restore test: $FAILED backup(s) are NOT restorable! ($SUMMARY)"
fi

log_success "All tested backups are restorable - the full chain (dump -> encrypt -> decrypt -> import) works"
exit 0
