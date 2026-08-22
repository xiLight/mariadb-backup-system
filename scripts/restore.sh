#!/bin/bash
cd "$(dirname "$0")/.."

set -o pipefail

source "./lib/logging.sh"

LOG_FILE="./logs/restore.log"
init_logging

VERBOSE=false

debug_log() {
  [[ "$VERBOSE" == "true" ]] && log_debug "$1"
}

RESTORE_START_TIME=$(date +%s)

BACKUP_DIR="./backups"
BINLOG_BACKUP_DIR="$BACKUP_DIR/binlogs"
BINLOG_INFO_DIR="$BACKUP_DIR/binlog_info"
INCR_INFO_DIR="$BACKUP_DIR/incr"
ENCRYPT_KEY_FILE=".backup_encryption_key"

TOTAL_BACKUP_SIZE=0
TOTAL_BINLOG_SIZE=0
TOTAL_BINLOGS_PROCESSED=0
TOTAL_BINLOGS_ERRORS=0
PROCESSED_DATABASES=0

human_size() {
  local bytes=$1
  if [[ $bytes -gt 1048576 ]]; then
    echo "$(echo "scale=2; $bytes/1048576" | bc -l 2>/dev/null || echo $((bytes / 1048576))) MB"
  elif [[ $bytes -gt 1024 ]]; then
    echo "$(echo "scale=2; $bytes/1024" | bc -l 2>/dev/null || echo $((bytes / 1024))) KB"
  else
    echo "$bytes bytes"
  fi
}

get_databases_with_backups() {
  local dbs=()
  for backup_file in "$BACKUP_DIR"/*_full_*.sql.gz.enc; do
    [[ -f "$backup_file" ]] || continue
    db_name=$(basename "$backup_file" | sed 's/_full_.*//')
    if [[ ! " ${dbs[*]} " =~ " ${db_name} " ]] && [[ "$db_name" != "binlogs" ]] && [[ "$db_name" != "system_grants" ]]; then
      dbs+=("$db_name")
    fi
  done
  echo "${dbs[@]}"
}

select_database_interactive() {
  local DBS=("$@")
  if [[ ${#DBS[@]} -eq 0 ]]; then
    log_error "Keine Datenbanken mit vorhandenen Backups gefunden." >&2
    exit 1
  fi

  echo "" >&2
  echo "Verfügbare Datenbanken zur Wiederherstellung:" >&2
  echo "==============================================" >&2
  echo "  [1] ALL_DATABASES (alle Datenbanken wiederherstellen)" >&2
  for i in "${!DBS[@]}"; do
    echo "  [$((i + 2))] ${DBS[$i]}" >&2
  done

  echo "" >&2
  read -p "Bitte wähle eine Option (1-$((1 + ${#DBS[@]}))): " selection

  if [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 1 ]] && [[ "$selection" -le $((1 + ${#DBS[@]})) ]]; then
    if [[ "$selection" -eq 1 ]]; then
      echo "ALL_DATABASES"
    else
      echo "${DBS[$((selection - 2))]}"
    fi
  else
    log_error "Ungültige Auswahl: $selection" >&2
    exit 1
  fi
}

select_backup_interactive() {
  local DB=$1
  shift
  local FULLS=("$@")

  if [[ ${#FULLS[@]} -eq 0 ]]; then
    log_error "Keine gültigen Backups für Datenbank '$DB' gefunden." >&2
    exit 1
  fi

  echo "" >&2
  echo "Verfügbare Backups für Datenbank '$DB':" >&2
  echo "======================================" >&2

  for i in "${!FULLS[@]}"; do
    local backup_file="${FULLS[$i]}"
    local backup_size backup_date size_hr age_text
    backup_size=$(stat -c%s "$backup_file" 2>/dev/null || stat -f%z "$backup_file" 2>/dev/null || echo "0")
    backup_date=$(stat -c%Y "$backup_file" 2>/dev/null || stat -f%m "$backup_file" 2>/dev/null || echo "")
    size_hr=$(human_size "$backup_size")

    if [[ -n "$backup_date" ]]; then
      local age_seconds=$(( $(date +%s) - backup_date ))
      if (( age_seconds >= 86400 )); then
        age_text="vor $((age_seconds / 86400)) Tag(en)"
      elif (( age_seconds >= 3600 )); then
        age_text="vor $((age_seconds / 3600)) Stunde(n)"
      elif (( age_seconds >= 60 )); then
        age_text="vor $((age_seconds / 60)) Minute(n)"
      else
        age_text="vor ${age_seconds} Sekunde(n)"
      fi
    else
      age_text="unbekanntes Datum"
    fi

    local backup_timestamp
    backup_timestamp=$(basename "$backup_file" | sed -E "s/^${DB}_full_(.*)\.sql\.gz\.enc$/\1/")
    echo "[$((i + 1))] $backup_timestamp ($size_hr, $age_text)" >&2
  done

  echo "" >&2
  read -p "Bitte wähle eine Backup-Nummer (1-${#FULLS[@]}): " selection

  if [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 1 ]] && [[ "$selection" -le ${#FULLS[@]} ]]; then
    echo "${FULLS[$((selection - 1))]}"
  else
    log_error "Ungültige Auswahl: $selection" >&2
    exit 1
  fi
}

INTERACTIVE_SELECT=true
USE_LAST_BACKUP=false
DATABASE=""
BACKUP_FILE=""
RESTORE_TO_TIMESTAMP=""
SKIP_CONFIRM=false
RESTORE_GRANTS=false
GRANTS_ONLY=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --database)
      DATABASE="$2"
      INTERACTIVE_SELECT=false
      shift 2
      ;;
    --backup-file)
      BACKUP_FILE="$2"
      INTERACTIVE_SELECT=false
      shift 2
      ;;
    --last)
      USE_LAST_BACKUP=true
      INTERACTIVE_SELECT=false
      shift
      ;;
    --to-timestamp)
      RESTORE_TO_TIMESTAMP="$2"
      shift 2
      ;;
    --yes)
      SKIP_CONFIRM=true
      shift
      ;;
    --with-grants)
      RESTORE_GRANTS=true
      shift
      ;;
    --grants-only)
      RESTORE_GRANTS=true
      GRANTS_ONLY=true
      INTERACTIVE_SELECT=false
      shift
      ;;
    --verbose)
      VERBOSE=true
      shift
      ;;
    --debug)
      VERBOSE=true
      shift
      ;;
    --help)
      echo "Nutzung: $0 [OPTIONS]"
      echo ""
      echo "OPTIONEN:"
      echo "  --database DB          Den Namen der Datenbank angeben"
      echo "  --backup-file FILE     Den genauen Pfad zur Backup-Datei angeben"
      echo "  --last                 Das aktuellste Backup verwenden (erfordert --database)"
      echo "  --to-timestamp TS      Bis zu einem bestimmten Zeitpunkt wiederherstellen (YYYY-MM-DD HH:MM:SS)"
      echo "  --with-grants          Auch User und Berechtigungen aus dem aktuellsten Grants-Backup wiederherstellen"
      echo "  --grants-only          NUR User und Berechtigungen wiederherstellen, keine Datenbanken"
      echo "  --yes                  Sicherheitsabfrage überspringen"
      echo "  --verbose              Ausführliche Ausgabe aktivieren"
      echo "  --help                 Diesen Hilfetext anzeigen"
      echo ""
      echo "Wenn keine Optionen übergeben werden, startet der interaktive Modus."
      exit 0
      ;;
    *)
      log_error "Unbekannte Option: $1"
      exit 1
      ;;
  esac
done

log_info "Starte Wiederherstellung (Restore-Prozess)"

if [[ -f ".env" ]]; then
  source .env
  debug_log "Umgebungsvariablen aus der .env-Datei geladen."
else
  log_error ".env Datei nicht gefunden."
  exit 1
fi

MARIADB_CONTAINER="${MARIADB_CONTAINER:-mariadb}"

if [[ ! -f "$ENCRYPT_KEY_FILE" ]]; then
  log_error "Verschlüsselungs-Key nicht gefunden: $ENCRYPT_KEY_FILE - Backups können nicht entschlüsselt werden!"
  exit 1
fi

if [[ "$INTERACTIVE_SELECT" == "true" ]]; then
  log_info "Interaktiver Modus - wähle Datenbank und Backup aus."

  DBS_WITH_BACKUPS=( $(get_databases_with_backups) )
  SELECTED_DB=$(select_database_interactive "${DBS_WITH_BACKUPS[@]}")

  if [[ "$SELECTED_DB" == "ALL_DATABASES" ]]; then
    log_info "Auswahl: ALL_DATABASES. Stelle alle Datenbanken aus ihren aktuellsten Backups wieder her."
    DATABASE="ALL"
    BACKUP_FILE="LATEST"
  else
    DATABASE="$SELECTED_DB"
    BACKUP_FILES=( $(ls -1t "$BACKUP_DIR/${DATABASE}"_full_*.sql.gz.enc 2>/dev/null) )
    BACKUP_FILE=$(select_backup_interactive "$DATABASE" "${BACKUP_FILES[@]}")
  fi
fi

if [[ "$USE_LAST_BACKUP" == "true" ]]; then
  if [[ -z "$DATABASE" ]]; then
    log_error "--last erfordert auch den Parameter --database"
    exit 1
  fi

  BACKUP_FILE=$(ls -1t "$BACKUP_DIR/${DATABASE}_full_"*.sql.gz.enc 2>/dev/null | head -1)
  if [[ -z "$BACKUP_FILE" ]]; then
    log_error "Keine Backups für die Datenbank gefunden: $DATABASE"
    exit 1
  fi
fi

if [[ "$GRANTS_ONLY" == "true" ]]; then
  DBS_TO_RESTORE=()
elif [[ "$DATABASE" == "ALL" ]]; then
  DBS_TO_RESTORE=( $(get_databases_with_backups) )
  log_info "Stelle alle Datenbanken wieder her: ${DBS_TO_RESTORE[*]}"
else
  DBS_TO_RESTORE=("$DATABASE")
fi

# Restoring overwrites live data - make sure the user really wants this.
if [[ "$SKIP_CONFIRM" != "true" ]]; then
  echo "" >&2
  if [[ "$GRANTS_ONLY" == "true" ]]; then
    log_warning "Dies wird User und Berechtigungen im Container '$MARIADB_CONTAINER' wiederherstellen."
  else
    log_warning "Dies wird die folgenden Datenbanken im Container '$MARIADB_CONTAINER' ÜBERSCHREIBEN: ${DBS_TO_RESTORE[*]}$([ "$RESTORE_GRANTS" == "true" ] && echo " (+ User/Berechtigungen)")!"
  fi
  read -p "Wirklich fortfahren? (Tippe 'yes' zum Bestätigen): " confirm
  if [[ "$confirm" != "yes" ]]; then
    log_info "Wiederherstellung durch Benutzer abgebrochen."
    exit 0
  fi
fi

# Determine connection method (password via MYSQL_PWD, not on the command line)
DOCKER_ENV=(-e MYSQL_PWD="$MARIADB_ROOT_PASSWORD")
if docker exec "${DOCKER_ENV[@]}" "$MARIADB_CONTAINER" mariadb -u root -e "SELECT 1;" &>/dev/null; then
  :
elif docker exec "$MARIADB_CONTAINER" mariadb -u root -e "SELECT 1;" &>/dev/null; then
  DOCKER_ENV=()
else
  log_error "Kann keine Verbindung zum MariaDB-Container '$MARIADB_CONTAINER' herstellen."
  exit 1
fi

db_exec() {
  docker exec "${DOCKER_ENV[@]}" "$MARIADB_CONTAINER" mariadb -u root "$@"
}

db_exec_stdin() {
  docker exec -i "${DOCKER_ENV[@]}" "$MARIADB_CONTAINER" mariadb -u root "$@"
}

for DB_TO_RESTORE in "${DBS_TO_RESTORE[@]}"; do
  if [[ "$DATABASE" == "ALL" ]]; then
    CURRENT_BACKUP_FILE=$(ls -1t "$BACKUP_DIR/${DB_TO_RESTORE}_full_"*.sql.gz.enc 2>/dev/null | head -1)
    if [[ -z "$CURRENT_BACKUP_FILE" ]]; then
      log_warning "Kein Backup für $DB_TO_RESTORE gefunden. Wird übersprungen."
      continue
    fi
  else
    CURRENT_BACKUP_FILE="$BACKUP_FILE"
  fi

  if [[ -z "$DB_TO_RESTORE" || -z "$CURRENT_BACKUP_FILE" ]]; then
    log_error "Datenbank oder Backup-Datei nicht angegeben."
    continue
  fi

  if [[ ! -f "$CURRENT_BACKUP_FILE" ]]; then
    log_error "Backup-Datei nicht gefunden: $CURRENT_BACKUP_FILE"
    continue
  fi

  log_info "--- Verarbeite Datenbank: $DB_TO_RESTORE ---"
  log_info "Ausgewähltes Backup: $CURRENT_BACKUP_FILE"

  BACKUP_TIMESTAMP=$(basename "$CURRENT_BACKUP_FILE" | sed "s/${DB_TO_RESTORE}_full_\(.*\)\.sql\.gz\.enc/\1/")
  debug_log "Backup Zeitstempel: $BACKUP_TIMESTAMP"

  BACKUP_SIZE=$(stat -c%s "$CURRENT_BACKUP_FILE" 2>/dev/null || stat -f%z "$CURRENT_BACKUP_FILE" 2>/dev/null || echo "0")
  TOTAL_BACKUP_SIZE=$((TOTAL_BACKUP_SIZE + BACKUP_SIZE))

  # Step 1: Decrypt and import the full backup
  log_info "Schritt 1: Entschlüssele und importiere vollständiges Backup..."

  if ! ./scripts/encrypt_backup.sh --decrypt "$CURRENT_BACKUP_FILE" --key "$ENCRYPT_KEY_FILE"; then
    log_error "Fehler beim Entschlüsseln der Backup-Datei für $DB_TO_RESTORE."
    continue
  fi

  DECRYPTED_FILE="${CURRENT_BACKUP_FILE%.enc}"

  log_info "Importiere Backup in Datenbank: $DB_TO_RESTORE"
  db_exec -e "CREATE DATABASE IF NOT EXISTS \`$DB_TO_RESTORE\`;"

  if ! db_exec_stdin "$DB_TO_RESTORE" < <(gunzip -c "$DECRYPTED_FILE"); then
    log_error "Fehler beim Importieren des Backups für $DB_TO_RESTORE."
    rm -f "$DECRYPTED_FILE"
    continue
  fi

  rm -f "$DECRYPTED_FILE"
  log_success "Vollständiges Backup für $DB_TO_RESTORE erfolgreich wiederhergestellt."
  PROCESSED_DATABASES=$((PROCESSED_DATABASES + 1))

  # Step 2: Roll forward using binary logs
  log_info "Schritt 2: Wende Binary Logs an..."

  BINLOG_INFO_FILE="$BINLOG_INFO_DIR/last_binlog_info_${DB_TO_RESTORE}_${BACKUP_TIMESTAMP}.txt"
  if [[ ! -f "$BINLOG_INFO_FILE" ]]; then
    BINLOG_INFO_FILE="$INCR_INFO_DIR/last_binlog_info_${DB_TO_RESTORE}_${BACKUP_TIMESTAMP}.txt"
  fi

  if [[ ! -f "$BINLOG_INFO_FILE" ]]; then
    log_warning "Die Binlog-Info-Datei für das Backup $BACKUP_TIMESTAMP wurde nicht gefunden."
    log_warning "Kann keine inkrementellen Änderungen für $DB_TO_RESTORE anwenden. Nur das Full-Backup wurde wiederhergestellt."
    continue
  fi

  read -r START_BINLOG_FILE START_BINLOG_POS < "$BINLOG_INFO_FILE"
  log_info "Starte mit Binlog: $START_BINLOG_FILE an Position $START_BINLOG_POS"

  BINLOG_FILES=()
  while IFS= read -r bl_file; do
    bl_name=$(basename "$bl_file")
    if [[ ! "$bl_name" < "$START_BINLOG_FILE" ]]; then
      BINLOG_FILES+=("$bl_file")
    fi
  done < <(find "$BINLOG_BACKUP_DIR" -name "mysql-bin.*" -not -name "*.index" -not -name "*.idx" 2>/dev/null | sort -V)

  log_info "${#BINLOG_FILES[@]} Binlog-Datei(en) zur Verarbeitung gefunden."
  docker exec "$MARIADB_CONTAINER" mkdir -p /tmp/binlogs 2>/dev/null

  for bl_file in "${BINLOG_FILES[@]}"; do
    bl_name=$(basename "$bl_file")
    debug_log "Verarbeite Binlog: $bl_name"

    BL_SIZE=$(stat -c%s "$bl_file" 2>/dev/null || stat -f%z "$bl_file" 2>/dev/null || echo "0")
    TOTAL_BINLOG_SIZE=$((TOTAL_BINLOG_SIZE + BL_SIZE))

    BINLOG_OPTS=()
    [[ "$bl_name" == "$START_BINLOG_FILE" ]] && BINLOG_OPTS+=(--start-position="$START_BINLOG_POS")
    [[ -n "$RESTORE_TO_TIMESTAMP" ]] && BINLOG_OPTS+=(--stop-datetime="$RESTORE_TO_TIMESTAMP")

    docker cp "$bl_file" "$MARIADB_CONTAINER:/tmp/binlogs/$bl_name" >/dev/null 2>&1

    if docker exec "$MARIADB_CONTAINER" mariadb-binlog "${BINLOG_OPTS[@]}" \
      --database="$DB_TO_RESTORE" "/tmp/binlogs/$bl_name" 2>/dev/null | \
      db_exec_stdin "$DB_TO_RESTORE"; then
      log_success "Binlog erfolgreich angewendet: $bl_name"
      TOTAL_BINLOGS_PROCESSED=$((TOTAL_BINLOGS_PROCESSED + 1))
    else
      log_warning "Fehler beim Anwenden des Binlogs: $bl_name (kann normal sein, wenn es keine relevanten Änderungen enthält)"
      TOTAL_BINLOGS_ERRORS=$((TOTAL_BINLOGS_ERRORS + 1))
    fi

    docker exec "$MARIADB_CONTAINER" rm -f "/tmp/binlogs/$bl_name"
  done
done

# --- Users & grants -------------------------------------------------------
if [[ "$RESTORE_GRANTS" == "true" ]]; then
  log_info "Stelle User und Berechtigungen wieder her..."
  GRANTS_BACKUP=$(ls -1t "$BACKUP_DIR"/system_grants_full_*.sql.gz.enc 2>/dev/null | head -1)

  if [[ -z "$GRANTS_BACKUP" ]]; then
    log_warning "Kein Berechtigungs-Backup gefunden (system_grants_full_*.sql.gz.enc) - erstelle zuerst ein Full-Backup!"
  elif ./scripts/encrypt_backup.sh --decrypt "$GRANTS_BACKUP" --key "$ENCRYPT_KEY_FILE"; then
    GRANTS_DECRYPTED="${GRANTS_BACKUP%.enc}"
    # --force: existing users produce errors that are safe to skip
    if gunzip -c "$GRANTS_DECRYPTED" | db_exec_stdin --force 2>/dev/null; then
      db_exec -e "FLUSH PRIVILEGES;"
      log_success "User und Berechtigungen aus $(basename "$GRANTS_BACKUP") erfolgreich wiederhergestellt."
      PROCESSED_DATABASES=$((PROCESSED_DATABASES + 1))
    else
      log_error "Fehler beim Importieren der User/Berechtigungen."
    fi
    rm -f "$GRANTS_DECRYPTED"
  else
    log_error "Fehler beim Entschlüsseln des Grants-Backups."
  fi
fi

RESTORE_DURATION=$(( $(date +%s) - RESTORE_START_TIME ))

echo
log_info "=== RESTORE ZUSAMMENFASSUNG ==="
if [[ "$DATABASE" == "ALL" ]]; then
  log_info "Datenbanken: Alle (${#DBS_TO_RESTORE[@]} ausgewählt, $PROCESSED_DATABASES wiederhergestellt)"
else
  log_info "Datenbank: $DATABASE"
fi
[[ -n "$RESTORE_TO_TIMESTAMP" ]] && log_info "Wiederhergestellt bis Zeitpunkt: $RESTORE_TO_TIMESTAMP"
log_info "Dauer: ${RESTORE_DURATION}s"
log_info "Verarbeitete Backup-Größe: $(human_size "$TOTAL_BACKUP_SIZE")"
if [[ $TOTAL_BINLOG_SIZE -gt 0 ]]; then
  log_info "Verarbeitete Binlog-Größe: $(human_size "$TOTAL_BINLOG_SIZE")"
  log_info "Angewandte Binlogs: $TOTAL_BINLOGS_PROCESSED"
  [[ $TOTAL_BINLOGS_ERRORS -gt 0 ]] && log_warning "Binlogs mit Fehlern: $TOTAL_BINLOGS_ERRORS"
fi

if [[ $PROCESSED_DATABASES -eq 0 ]]; then
  log_error "Es wurden keine Datenbanken wiederhergestellt."
  exit 1
fi

log_success "Restore-Prozess erfolgreich abgeschlossen!"
