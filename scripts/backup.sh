#!/bin/bash
cd "$(dirname "$0")/.."

set -o pipefail

source "./lib/logging.sh"

BACKUP_VERSION="1.1.0"

LOG_FILE="./logs/backup.log"
init_logging

handle_error() {
  local exit_code=$1
  shift
  log_error "$* (exit code: $exit_code)"
  exit "$exit_code"
}

source .env 2>/dev/null || handle_error 1 "Failed to source .env file"

BACKUP_DIR="${BACKUP_DIR:-./backups}"
BINLOG_BACKUP_DIR="${BINLOG_DIR:-$BACKUP_DIR/binlogs}"
BINLOG_INFO_DIR="$BACKUP_DIR/binlog_info"
CHECKSUM_DIR="$BACKUP_DIR/checksums"
INCR_INFO_DIR="$BACKUP_DIR/incr"
MARIADB_CONTAINER="${MARIADB_CONTAINER:-mariadb}"
CONTAINER_DATADIR="/var/lib/mysql"

ENCRYPT_KEY_FILE=".backup_encryption_key"
INCLUDE_EMPTY_DATABASES=false
BACKUP_MODE="full"
SPECIFIC_DATABASE=""
COMPRESS_BACKUPS=true
CREATE_CHECKSUMS=true
VERIFY_BACKUPS=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --full)
      BACKUP_MODE="full"
      shift
      ;;
    --incremental)
      BACKUP_MODE="incremental"
      shift
      ;;
    --database)
      SPECIFIC_DATABASE="$2"
      shift 2
      ;;
    --include-empty)
      INCLUDE_EMPTY_DATABASES=true
      shift
      ;;
    --key)
      ENCRYPT_KEY_FILE="$2"
      shift 2
      ;;
    --no-compress)
      COMPRESS_BACKUPS=false
      shift
      ;;
    --no-checksums)
      CREATE_CHECKSUMS=false
      shift
      ;;
    --verify)
      VERIFY_BACKUPS=true
      shift
      ;;
    --help)
      echo "MariaDB Backup Skript v$BACKUP_VERSION"
      echo ""
      echo "Nutzung: $0 [OPTIONS]"
      echo ""
      echo "Backup-Modi:"
      echo "  --full                 Vollständiges Backup erstellen (Standard)"
      echo "  --incremental          Inkrementelles Backup erstellen (Binlog-basiert)"
      echo ""
      echo "Optionen:"
      echo "  --database DB          Nur eine bestimmte Datenbank sichern"
      echo "  --include-empty        Auch Datenbanken ohne Tabellen sichern"
      echo "  --key FILE             Datei mit dem Verschlüsselungs-Key (Standard: .backup_encryption_key)"
      echo "  --no-compress          Backup-Dateien nicht komprimieren"
      echo "  --no-checksums         Keine Prüfsummen (Checksums) erstellen"
      echo "  --verify               Jedes Backup nach Erstellung überprüfen (Entschlüsselung + Integritätstest)"
      echo "  --help                 Diesen Hilfetext anzeigen"
      echo ""
      echo "Umgebungsvariablen (aus der .env):"
      echo "  MARIADB_CONTAINER      Name des MariaDB-Containers"
      echo "  MARIADB_ROOT_PASSWORD  MariaDB Root-Passwort"
      echo "  BACKUP_DIR             Haupt-Backupverzeichnis"
      echo "  BINLOG_DIR             Verzeichnis für Binary-Log-Backups"
      echo ""
      exit 0
      ;;
    *)
      handle_error 2 "Unbekannte Option: $1"
      ;;
  esac
done

BACKUP_START_TIME=$(date +%s)
log_info "Starte Backup-Prozess (Version $BACKUP_VERSION), Modus: $BACKUP_MODE"

# pigz compresses on all CPU cores and produces standard gzip output
if command -v pigz &>/dev/null; then
  COMPRESS_CMD="pigz"
else
  COMPRESS_CMD="gzip"
fi

for dir in "$BACKUP_DIR" "$BINLOG_BACKUP_DIR" "$BINLOG_INFO_DIR" "$CHECKSUM_DIR" "$INCR_INFO_DIR"; do
  mkdir -p "$dir" || handle_error 3 "Fehler beim Erstellen des Verzeichnisses: $dir"
done

TIMESTAMP=$(date +%Y%m%d_%H%M%S)

if [[ ! -f "$ENCRYPT_KEY_FILE" ]]; then
  log_warning "Verschlüsselungs-Key nicht gefunden, generiere einen neuen: $ENCRYPT_KEY_FILE"
  openssl rand -base64 32 > "$ENCRYPT_KEY_FILE" || handle_error 4 "Konnte keinen Verschlüsselungs-Key generieren."
  chmod 600 "$ENCRYPT_KEY_FILE"
  log_warning "Neuer Verschlüsselungs-Key unter $ENCRYPT_KEY_FILE erstellt - GUT AUFBEWAHREN! Ohne diesen Key können Backups nicht wiederhergestellt werden."
fi

# --- Database connection --------------------------------------------------
# The password is passed via MYSQL_PWD so it never shows up in process lists.
log_info "Teste Datenbankverbindung zum Container '$MARIADB_CONTAINER'..."

DOCKER_ENV=(-e MYSQL_PWD="$MARIADB_ROOT_PASSWORD")
CLIENT_ARGS=(-u root)

if docker exec "${DOCKER_ENV[@]}" "$MARIADB_CONTAINER" mariadb "${CLIENT_ARGS[@]}" -e "SELECT 1;" &>/dev/null; then
  log_success "Datenbankverbindung erfolgreich (Socket)."
elif docker exec "$MARIADB_CONTAINER" mariadb -u root -e "SELECT 1;" &>/dev/null; then
  DOCKER_ENV=()
  log_success "Datenbankverbindung erfolgreich (Socket, ohne Passwort)."
elif docker exec -e MYSQL_PWD="$MARIADB_ROOT_PASSWORD" "$MARIADB_CONTAINER" mariadb -u root -h 127.0.0.1 -P 3306 -e "SELECT 1;" &>/dev/null; then
  CLIENT_ARGS+=(-h 127.0.0.1 -P 3306)
  log_success "Datenbankverbindung erfolgreich (TCP)."
else
  handle_error 5 "Kann keine Verbindung zum MariaDB-Container '$MARIADB_CONTAINER' herstellen."
fi

db_exec() {
  docker exec "${DOCKER_ENV[@]}" "$MARIADB_CONTAINER" mariadb "${CLIENT_ARGS[@]}" "$@"
}

db_query() {
  db_exec -N -e "$1"
}

db_dump() {
  docker exec "${DOCKER_ENV[@]}" "$MARIADB_CONTAINER" mariadb-dump "${CLIENT_ARGS[@]}" "$@"
}

# Dump one database. Tries with binlog coordinates first (needed for
# incremental backups), falls back to a plain dump if the server lacks
# binary logging or the required privileges.
dump_database() {
  local database="$1" output_file="$2"
  local opts=(--single-transaction --quick --routines --triggers --events --databases "$database")

  if db_dump "${opts[@]}" --master-data=2 --flush-logs > "$output_file" 2>/dev/null; then
    return 0
  fi

  log_warning "Dump mit Binlog-Features fehlgeschlagen, nutze Fallback (ohne Binlog-Koordinaten)."
  db_dump "${opts[@]}" > "$output_file"
}

# Determine the current binlog file and position.
# Sets BINLOG_FILE / BINLOG_POS, returns 1 if unavailable.
get_binlog_position() {
  BINLOG_FILE=""
  BINLOG_POS=""

  local info
  info=$(db_query "SHOW MASTER STATUS;" 2>/dev/null | head -1)
  if [[ -n "$info" && "$info" != "NULL" ]]; then
    BINLOG_FILE=$(awk '{print $1}' <<< "$info")
    BINLOG_POS=$(awk '{print $2}' <<< "$info")
    if [[ -n "$BINLOG_FILE" && "$BINLOG_FILE" != "NULL" && -n "$BINLOG_POS" ]]; then
      return 0
    fi
  fi

  # Fallback: newest binlog file in the container, position = start of file
  local latest
  latest=$(docker exec "$MARIADB_CONTAINER" sh -c "ls $CONTAINER_DATADIR/mysql-bin.* 2>/dev/null" | grep -v '\.index$' | sort -V | tail -1)
  if [[ -n "$latest" ]]; then
    BINLOG_FILE=$(basename "$latest")
    BINLOG_POS="4"
    log_info "Binary Log-Position aus Dateisystem geschätzt: $BINLOG_FILE:$BINLOG_POS"
    return 0
  fi

  return 1
}

save_binlog_position() {
  local database="$1" file="$2" pos="$3"
  echo "$file $pos" > "$BINLOG_INFO_DIR/last_binlog_info_${database}_${TIMESTAMP}.txt"
  log_success "Binary Log-Position für $database gespeichert: $file:$pos"
}

# Copy binlog files from the container into the local backup directory.
# Incremental: files that already exist locally with the same size are
# skipped, so only new/growing binlogs are transferred.
sync_binlogs() {
  log_info "Synchronisiere Binary Logs aus dem Container..."
  local listing
  listing=$(docker exec "$MARIADB_CONTAINER" sh -c "stat -c '%s %n' $CONTAINER_DATADIR/mysql-bin.* 2>/dev/null")
  if [[ -z "$listing" ]]; then
    log_warning "Keine Binary Logs im Container gefunden. Inkrementelle Backups funktionieren erst, wenn Binary Logging aktiviert ist."
    return 1
  fi

  local copied=0 skipped=0 size f name local_size
  while read -r size f; do
    [[ -n "$f" ]] || continue
    name=$(basename "$f")

    if [[ -f "$BINLOG_BACKUP_DIR/$name" ]]; then
      local_size=$(stat -c%s "$BINLOG_BACKUP_DIR/$name" 2>/dev/null || stat -f%z "$BINLOG_BACKUP_DIR/$name" 2>/dev/null || echo -1)
      if [[ "$local_size" == "$size" ]]; then
        skipped=$((skipped + 1))
        continue
      fi
    fi

    if docker cp "$MARIADB_CONTAINER:$f" "$BINLOG_BACKUP_DIR/" >/dev/null 2>&1; then
      copied=$((copied + 1))
    else
      log_warning "Fehler beim Kopieren des Binlogs: $name"
    fi
  done <<< "$listing"
  log_success "Binlog-Sync: $copied kopiert, $skipped unverändert."
}

# Decrypt + integrity-test an encrypted backup without writing plaintext to disk.
# Tries hardened PBKDF2 iterations first, then legacy default for old backups.
verify_backup_file() {
  local enc_file="$1" iter_opts
  for iter_opts in "-iter 200000" ""; do
    if [[ "$COMPRESS_BACKUPS" == "true" ]]; then
      openssl enc -aes-256-cbc -d -pbkdf2 $iter_opts -in "$enc_file" -pass file:"$ENCRYPT_KEY_FILE" 2>/dev/null | gzip -t 2>/dev/null && return 0
    else
      openssl enc -aes-256-cbc -d -pbkdf2 $iter_opts -in "$enc_file" -pass file:"$ENCRYPT_KEY_FILE" 2>/dev/null | head -c 1 | grep -q . && return 0
    fi
  done
  return 1
}

# --- Collect databases ----------------------------------------------------
if [[ -n "$SPECIFIC_DATABASE" ]]; then
  if ! db_exec -e "USE \`$SPECIFIC_DATABASE\`;" &>/dev/null; then
    handle_error 6 "Datenbank '$SPECIFIC_DATABASE' existiert nicht."
  fi
  DATABASES=("$SPECIFIC_DATABASE")
else
  mapfile -t DATABASES < <(db_query "SHOW DATABASES;" 2>/dev/null | grep -v -E "^(information_schema|performance_schema|mysql|sys)$")
fi
log_info "${#DATABASES[@]} Datenbank(en) für das Backup gefunden: ${DATABASES[*]}"

TOTAL_DATABASES=0
SUCCESSFUL_BACKUPS=0
FAILED_BACKUPS=0
SKIPPED_DATABASES=0
TOTAL_BACKUP_SIZE=0

sync_binlogs

# --- Backup loop ----------------------------------------------------------
for DB in "${DATABASES[@]}"; do
  TOTAL_DATABASES=$((TOTAL_DATABASES + 1))
  log_info "Verarbeite Datenbank: $DB"

  if [[ "$INCLUDE_EMPTY_DATABASES" == "false" ]]; then
    TABLE_COUNT=$(db_query "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$DB';" 2>/dev/null || echo "0")
    if [[ "$TABLE_COUNT" == "0" ]]; then
      log_warning "Datenbank $DB hat keine Tabellen, wird übersprungen (nutze --include-empty, um sie trotzdem zu sichern)."
      SKIPPED_DATABASES=$((SKIPPED_DATABASES + 1))
      continue
    fi
  fi

  BACKUP_FILE="$BACKUP_DIR/${DB}_${BACKUP_MODE}_${TIMESTAMP}.sql"
  SAVE_BINLOG_FILE=""
  SAVE_BINLOG_POS=""

  if [[ "$BACKUP_MODE" == "full" ]]; then
    log_info "Erstelle vollständiges Backup: $(basename "$BACKUP_FILE")"
    if ! dump_database "$DB" "$BACKUP_FILE"; then
      log_error "Fehler beim Sichern der Datenbank: $DB"
      rm -f "$BACKUP_FILE"
      FAILED_BACKUPS=$((FAILED_BACKUPS + 1))
      continue
    fi

    # The exact binlog position at dump time is recorded in the dump itself
    # by --master-data=2. Using it avoids a gap between dump and position
    # query that would be missed by the next incremental backup.
    MASTER_LINE=$(head -60 "$BACKUP_FILE" | grep -oE "MASTER_LOG_FILE='[^']+', MASTER_LOG_POS=[0-9]+" | head -1)
    if [[ -n "$MASTER_LINE" ]]; then
      SAVE_BINLOG_FILE=$(sed -E "s/MASTER_LOG_FILE='([^']+)'.*/\1/" <<< "$MASTER_LINE")
      SAVE_BINLOG_POS=$(sed -E "s/.*MASTER_LOG_POS=([0-9]+)/\1/" <<< "$MASTER_LINE")
    fi
  else
    # Incremental backup: extract changes from binary logs since the last
    # saved position (full or incremental).
    LAST_INFO_FILE=$(find "$BINLOG_INFO_DIR" -name "last_binlog_info_${DB}_*.txt" -type f | sort | tail -1)
    if [[ -z "$LAST_INFO_FILE" ]]; then
      log_error "Keine vorherige Backup-Position für $DB gefunden. Bitte zuerst ein Full-Backup machen."
      FAILED_BACKUPS=$((FAILED_BACKUPS + 1))
      continue
    fi

    read -r LAST_BINLOG_FILE LAST_BINLOG_POS < "$LAST_INFO_FILE"
    log_info "Letzte Backup-Position: $LAST_BINLOG_FILE:$LAST_BINLOG_POS"

    if ! get_binlog_position; then
      log_error "Kann die aktuelle Binary Log-Position für $DB nicht bestimmen."
      FAILED_BACKUPS=$((FAILED_BACKUPS + 1))
      continue
    fi
    CURRENT_BINLOG_FILE="$BINLOG_FILE"
    CURRENT_BINLOG_POS="$BINLOG_POS"
    log_info "Aktuelle Position: $CURRENT_BINLOG_FILE:$CURRENT_BINLOG_POS"

    if [[ "$LAST_BINLOG_FILE" == "$CURRENT_BINLOG_FILE" && "$LAST_BINLOG_POS" == "$CURRENT_BINLOG_POS" ]]; then
      log_info "Keine Änderungen seit dem letzten Backup, überspringe $DB."
      SKIPPED_DATABASES=$((SKIPPED_DATABASES + 1))
      continue
    fi

    # Only binlogs in the range [last position, current position] are relevant.
    # Older files must be excluded, otherwise already-backed-up transactions
    # would be replayed on restore.
    BINLOG_FILES=()
    while IFS= read -r bl_file; do
      bl_name=$(basename "$bl_file")
      if [[ ! "$bl_name" < "$LAST_BINLOG_FILE" && ! "$bl_name" > "$CURRENT_BINLOG_FILE" ]]; then
        BINLOG_FILES+=("$bl_file")
      fi
    done < <(find "$BINLOG_BACKUP_DIR" -maxdepth 1 -type f -name "mysql-bin.*" ! -name "*.index" ! -name "*.idx" | sort -V)

    if [[ ${#BINLOG_FILES[@]} -eq 0 ]]; then
      log_error "Keine Binary Log-Dateien im Bereich $LAST_BINLOG_FILE..$CURRENT_BINLOG_FILE gefunden."
      FAILED_BACKUPS=$((FAILED_BACKUPS + 1))
      continue
    fi

    log_info "Verarbeite ${#BINLOG_FILES[@]} Binary Log-Datei(en) für das inkrementelle Backup..."
    : > "$BACKUP_FILE"
    docker exec "$MARIADB_CONTAINER" mkdir -p /tmp/binlogs

    for bl_file in "${BINLOG_FILES[@]}"; do
      bl_name=$(basename "$bl_file")

      BINLOG_OPTS=()
      [[ "$bl_name" == "$LAST_BINLOG_FILE" ]] && BINLOG_OPTS+=(--start-position="$LAST_BINLOG_POS")
      [[ "$bl_name" == "$CURRENT_BINLOG_FILE" ]] && BINLOG_OPTS+=(--stop-position="$CURRENT_BINLOG_POS")

      docker cp "$bl_file" "$MARIADB_CONTAINER:/tmp/binlogs/$bl_name" >/dev/null 2>&1
      if docker exec "$MARIADB_CONTAINER" mariadb-binlog "${BINLOG_OPTS[@]}" \
        --database="$DB" "/tmp/binlogs/$bl_name" >> "$BACKUP_FILE" 2>/dev/null; then
        log_info "Binary Log erfolgreich verarbeitet: $bl_name"
      else
        log_warning "Fehler beim Verarbeiten des Binary Logs: $bl_name"
      fi
      docker exec "$MARIADB_CONTAINER" rm -f "/tmp/binlogs/$bl_name"
    done

    if [[ ! -s "$BACKUP_FILE" ]]; then
      log_info "Inkrementelles Backup ist leer, keine relevanten Änderungen für $DB."
      SKIPPED_DATABASES=$((SKIPPED_DATABASES + 1))
      rm -f "$BACKUP_FILE"
      continue
    fi
    log_success "Inkrementelles Backup erstellt: $(basename "$BACKUP_FILE")"

    # The next incremental must start exactly where this one stopped
    SAVE_BINLOG_FILE="$CURRENT_BINLOG_FILE"
    SAVE_BINLOG_POS="$CURRENT_BINLOG_POS"
  fi

  BACKUP_SIZE=$(stat -c%s "$BACKUP_FILE" 2>/dev/null || stat -f%z "$BACKUP_FILE" 2>/dev/null || echo "0")
  TOTAL_BACKUP_SIZE=$((TOTAL_BACKUP_SIZE + BACKUP_SIZE))

  if [[ "$COMPRESS_BACKUPS" == "true" ]]; then
    if "$COMPRESS_CMD" "$BACKUP_FILE"; then
      BACKUP_FILE="${BACKUP_FILE}.gz"
    else
      log_error "Konnte das Backup für $DB nicht komprimieren."
      FAILED_BACKUPS=$((FAILED_BACKUPS + 1))
      rm -f "$BACKUP_FILE"
      continue
    fi
  fi

  ENCRYPT_ARGS=(--encrypt "$BACKUP_FILE" --key "$ENCRYPT_KEY_FILE")
  [[ "$CREATE_CHECKSUMS" == "false" ]] && ENCRYPT_ARGS+=(--no-checksum)
  if ./scripts/encrypt_backup.sh "${ENCRYPT_ARGS[@]}"; then
    rm -f "$BACKUP_FILE"
    BACKUP_FILE="${BACKUP_FILE}.enc"
    log_success "Backup verschlüsselt: $(basename "$BACKUP_FILE")"
  else
    log_error "Verschlüsselung für $DB fehlgeschlagen."
    rm -f "$BACKUP_FILE"
    FAILED_BACKUPS=$((FAILED_BACKUPS + 1))
    continue
  fi

  if [[ "$VERIFY_BACKUPS" == "true" ]]; then
    if verify_backup_file "$BACKUP_FILE"; then
      log_success "Backup erfolgreich verifiziert: $(basename "$BACKUP_FILE")"
    else
      log_error "Backup-Verifizierung FEHLGESCHLAGEN für $(basename "$BACKUP_FILE")"
      FAILED_BACKUPS=$((FAILED_BACKUPS + 1))
      continue
    fi
  fi

  # Save the binlog position so the next incremental backup knows where to start.
  if [[ -z "$SAVE_BINLOG_FILE" ]] && get_binlog_position; then
    SAVE_BINLOG_FILE="$BINLOG_FILE"
    SAVE_BINLOG_POS="$BINLOG_POS"
  fi

  if [[ -n "$SAVE_BINLOG_FILE" ]]; then
    save_binlog_position "$DB" "$SAVE_BINLOG_FILE" "$SAVE_BINLOG_POS"
  else
    log_warning "Konnte die Binary Log-Position nicht ermitteln. Inkrementelle Backups funktionieren erst, wenn Binary Logging aktiviert ist."
  fi

  SUCCESSFUL_BACKUPS=$((SUCCESSFUL_BACKUPS + 1))
  log_success "Backup für Datenbank $DB abgeschlossen."
done

# --- Users & grants -------------------------------------------------------
# The per-database dumps exclude the mysql system db, so users/passwords/
# grants would be lost in a full disaster. Dump them separately.
if [[ "$BACKUP_MODE" == "full" && -z "$SPECIFIC_DATABASE" ]]; then
  GRANTS_FILE="$BACKUP_DIR/system_grants_full_${TIMESTAMP}.sql"
  log_info "Sichere User und Berechtigungen (Grants)..."

  if db_dump --system=users > "$GRANTS_FILE" 2>/dev/null && [[ -s "$GRANTS_FILE" ]]; then
    "$COMPRESS_CMD" "$GRANTS_FILE" && GRANTS_FILE="${GRANTS_FILE}.gz"
    ENCRYPT_ARGS=(--encrypt "$GRANTS_FILE" --key "$ENCRYPT_KEY_FILE")
    [[ "$CREATE_CHECKSUMS" == "false" ]] && ENCRYPT_ARGS+=(--no-checksum)
    if ./scripts/encrypt_backup.sh "${ENCRYPT_ARGS[@]}" >/dev/null; then
      rm -f "$GRANTS_FILE"
      log_success "User und Berechtigungen gesichert: $(basename "$GRANTS_FILE").enc"
    else
      rm -f "$GRANTS_FILE"
      log_warning "Fehler beim Verschlüsseln der Berechtigungs-Backups."
    fi
  else
    rm -f "$GRANTS_FILE"
    log_warning "Konnte User/Berechtigungen nicht sichern (mariadb-dump --system=users fehlgeschlagen)."
  fi
fi

# --- Summary --------------------------------------------------------------
BACKUP_DURATION=$(( $(date +%s) - BACKUP_START_TIME ))

if [[ $TOTAL_BACKUP_SIZE -gt 1048576 ]]; then
  SIZE_HR="$(echo "scale=2; $TOTAL_BACKUP_SIZE/1048576" | bc -l 2>/dev/null || echo $((TOTAL_BACKUP_SIZE / 1048576))) MB"
elif [[ $TOTAL_BACKUP_SIZE -gt 1024 ]]; then
  SIZE_HR="$(echo "scale=2; $TOTAL_BACKUP_SIZE/1024" | bc -l 2>/dev/null || echo $((TOTAL_BACKUP_SIZE / 1024))) KB"
else
  SIZE_HR="$TOTAL_BACKUP_SIZE bytes"
fi

echo
log_info "=== BACKUP ZUSAMMENFASSUNG ==="
log_info "Modus: $BACKUP_MODE"
log_info "Zeitstempel: $TIMESTAMP"
log_info "Dauer: ${BACKUP_DURATION}s"
log_info "Verarbeitete Datenbanken: $TOTAL_DATABASES (Erfolgreich: $SUCCESSFUL_BACKUPS, Fehlgeschlagen: $FAILED_BACKUPS, Übersprungen: $SKIPPED_DATABASES)"
log_info "Gesamtgröße des Backups (unkomprimiert): $SIZE_HR"
log_info "Komprimierung: $([ "$COMPRESS_BACKUPS" == "true" ] && echo "aktiviert" || echo "deaktiviert"), Verschlüsselung: aktiviert, Checksums: $([ "$CREATE_CHECKSUMS" == "true" ] && echo "aktiviert" || echo "deaktiviert"), Verifizierung: $([ "$VERIFY_BACKUPS" == "true" ] && echo "aktiviert" || echo "deaktiviert")"

if [[ $FAILED_BACKUPS -gt 0 ]]; then
  log_error "$FAILED_BACKUPS Backup(s) fehlgeschlagen. Überprüfe $LOG_FILE für Details."
  [[ -x ./scripts/notify.sh ]] && ./scripts/notify.sh error "Backup FEHLGESCHLAGEN" "$FAILED_BACKUPS von $TOTAL_DATABASES Datenbank-Backups sind fehlgeschlagen (Modus: $BACKUP_MODE). Prüfe logs/backup.log" || true
  exit 1
fi

log_success "Alle Backups erfolgreich abgeschlossen! Die verschlüsselten Dateien liegen in: $BACKUP_DIR"
[[ -x ./scripts/notify.sh ]] && ./scripts/notify.sh --heartbeat || true

# Optional offsite replication after a fully successful run
if [[ "${OFFSITE_AUTO:-no}" == "yes" && $SUCCESSFUL_BACKUPS -gt 0 ]]; then
  log_info "OFFSITE_AUTO ist aktiv - repliziere Backups an den externen Speicher..."
  if ./scripts/offsite_sync.sh; then
    log_success "Offsite-Replikation abgeschlossen."
  else
    log_error "Offsite-Replikation fehlgeschlagen - Backups sind lokal vorhanden, wurden aber NICHT repliziert!"
    exit 1
  fi
fi
