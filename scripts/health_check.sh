#!/bin/bash
cd "$(dirname "$0")/.."

source "./lib/logging.sh"

LOG_FILE="./logs/health_check.log"
init_logging

if [ -f ".env" ]; then
    source .env
fi
MARIADB_CONTAINER="${MARIADB_CONTAINER:-mariadb}"

db_exec() {
    docker exec -e MYSQL_PWD="$MARIADB_ROOT_PASSWORD" "$MARIADB_CONTAINER" mariadb -u root "$@"
}

print_header() {
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║               MariaDB Backup System System-Check              ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo
}

check_docker() {
    log_info "Überprüfe Docker-Status..."

    if ! command -v docker &> /dev/null; then
        log_error "Docker ist nicht installiert."
        return 1
    fi

    if ! docker info &> /dev/null; then
        log_error "Der Docker-Dienst läuft nicht."
        return 1
    fi

    log_success "Docker läuft."
    return 0
}

check_mariadb_connection() {
    log_info "Überprüfe Verbindung zu MariaDB..."

    if [ ! -f ".env" ]; then
        log_error ".env Datei nicht gefunden."
        return 1
    fi

    if db_exec -e "SELECT 1;" &>/dev/null; then
        log_success "Verbindung zu MariaDB erfolgreich hergestellt."
    else
        log_error "Verbindung zum MariaDB-Container '$MARIADB_CONTAINER' fehlgeschlagen."
        return 1
    fi

    return 0
}

check_databases() {
    log_info "Überprüfe Datenbank-Status..."

    DB_LIST=$(db_exec -N -e "SHOW DATABASES;" 2>/dev/null | grep -v -E "^(information_schema|performance_schema|mysql|sys)$")

    if [ -z "$DB_LIST" ]; then
        log_warning "Keine Benutzer-Datenbanken gefunden."
    else
        log_success "Gefundene Datenbanken: $(echo $DB_LIST | tr '\n' ' ')"
    fi

    return 0
}

check_binary_logging() {
    log_info "Überprüfe Binlog-Konfiguration..."

    BINLOG_ENABLED=$(db_exec -N -e "SELECT @@log_bin;" 2>/dev/null)

    if [ "$BINLOG_ENABLED" = "1" ]; then
        log_success "Binary Logging ist aktiviert."

        BINLOG_BASE=$(db_exec -N -e "SELECT @@log_bin_basename;" 2>/dev/null)
        log_info "Binary Log Base: $BINLOG_BASE"

        BINLOG_COUNT=$(db_exec -N -e "SHOW BINARY LOGS;" 2>/dev/null | wc -l)
        log_info "Anzahl der Binary-Log-Dateien auf dem Server: $BINLOG_COUNT"
    else
        log_error "Binary Logging ist deaktiviert - inkrementelle Backups werden nicht funktionieren."
        return 1
    fi

    return 0
}

check_bind_address() {
    log_info "Überprüfe Bind-Address Konfiguration..."

    BIND_ADDRESS=$(db_exec -N -e "SELECT @@bind_address;" 2>/dev/null)

    if [ "$BIND_ADDRESS" = "0.0.0.0" ]; then
        log_success "Bind Address ist korrekt auf 0.0.0.0 gesetzt."
    else
        log_warning "Bind Address ist: $BIND_ADDRESS (erwartet: 0.0.0.0)"
    fi

    return 0
}

check_backup_directories() {
    log_info "Überprüfe Backup-Verzeichnisse..."

    directories=("backups" "backups/binlogs" "backups/checksums" "backups/incr" "backups/binlog_info" "logs")

    for dir in "${directories[@]}"; do
        if [ -d "$dir" ]; then
            log_success "Verzeichnis existiert: $dir"
        else
            log_warning "Verzeichnis fehlt: $dir"
            mkdir -p "$dir"
            log_info "Verzeichnis erstellt: $dir"
        fi
    done

    return 0
}

check_scripts() {
    log_info "Überprüfe Berechtigungen der Skripte..."

    scripts=("backup.sh" "restore.sh" "encrypt_backup.sh" "verify_backup.sh" "cleanup_backups.sh" "cleanup_binlogs.sh" "log_cleanup.sh" "db_admin.sh")

    for script in "${scripts[@]}"; do
        if [ -f "$script" ]; then
            if [ -x "$script" ]; then
                log_success "Skript ist ausführbar: $script"
            else
                log_warning "Skript ist nicht ausführbar: $script"
                chmod +x "$script"
                log_info "Ausführbar gemacht: $script"
            fi
        else
            log_error "Skript fehlt: $script"
        fi
    done

    return 0
}

check_env_permissions() {
    log_info "Überprüfe Berechtigungen der .env-Datei..."

    if [ ! -f ".env" ]; then
        return 0
    fi

    ENV_PERMS=$(stat -c "%a" .env 2>/dev/null || stat -f "%A" .env 2>/dev/null)
    if [ "$ENV_PERMS" = "600" ]; then
        log_success ".env hat korrekte Berechtigungen (600)."
    else
        log_warning "Berechtigungen der .env: $ENV_PERMS (enthält alle Passwörter - setze auf 600)."
        chmod 600 .env
        log_info "Berechtigungen der .env-Datei korrigiert."
    fi

    return 0
}

check_encryption_key() {
    log_info "Überprüfe Verschlüsselungs-Key..."

    if [ -f ".backup_encryption_key" ]; then
        KEY_SIZE=$(wc -c < .backup_encryption_key)
        if [ "$KEY_SIZE" -gt 20 ]; then
            log_success "Verschlüsselungs-Key existiert und hat eine gute Größe ($KEY_SIZE Bytes)."
        else
            log_warning "Verschlüsselungs-Key scheint zu klein zu sein ($KEY_SIZE Bytes)."
        fi

        KEY_PERMS=$(stat -c "%a" .backup_encryption_key 2>/dev/null || stat -f "%A" .backup_encryption_key 2>/dev/null)
        if [ "$KEY_PERMS" = "600" ]; then
            log_success "Verschlüsselungs-Key hat korrekte Berechtigungen (600)."
        else
            log_warning "Berechtigungen des Verschlüsselungs-Keys: $KEY_PERMS (sollte 600 sein)."
            chmod 600 .backup_encryption_key
            log_info "Berechtigungen des Verschlüsselungs-Keys korrigiert."
        fi
    else
        log_error "Verschlüsselungs-Key fehlt: .backup_encryption_key"
        log_info "Generiere ihn mit: openssl rand -base64 32 > .backup_encryption_key && chmod 600 .backup_encryption_key"
        return 1
    fi

    return 0
}

check_recent_backups() {
    log_info "Prüfe auf kürzlich erstellte Backups..."

    RECENT_BACKUPS=$(find backups -name "*.sql.gz.enc" -mtime -7 2>/dev/null | wc -l)

    if [ "$RECENT_BACKUPS" -gt 0 ]; then
        log_success "$RECENT_BACKUPS aktuelle(s) Backup(s) aus den letzten 7 Tagen gefunden."
    else
        log_warning "Keine Backups aus den letzten 7 Tagen gefunden!"
        log_info "Tipp: Führe ./scripts/backup.sh --full aus."
    fi

    return 0
}

check_offsite_sync() {
    log_info "Überprüfe Offsite-Replikation..."

    if [ -z "$OFFSITE_TARGET" ]; then
        log_warning "Offsite-Replikation ist nicht konfiguriert (OFFSITE_TARGET ist leer)."
        log_info "Bei einem Festplattenausfall gehen Datenbank UND alle Backups verloren - siehe offsite_sync.sh!"
        return 0
    fi

    if [ ! -f "./logs/.last_offsite_sync" ]; then
        log_warning "Offsite-Ziel konfiguriert, aber es lief noch kein Sync - führe ./scripts/offsite_sync.sh aus."
        return 1
    fi

    local last_sync age_days
    last_sync=$(cat ./logs/.last_offsite_sync 2>/dev/null || echo 0)
    age_days=$(( ($(date +%s) - last_sync) / 86400 ))

    if [ "$age_days" -ge 7 ]; then
        log_warning "Der letzte Offsite-Sync ist $age_days Tage alt - prüfe offsite_sync.sh bzw. den Cronjob."
        return 1
    fi

    log_success "Offsite-Replikation ist aktuell (letzter Sync: vor $age_days Tag(en))."
    return 0
}

check_disk_space() {
    log_info "Überprüfe freien Speicherplatz..."

    AVAIL_KB=$(df -Pk . 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -z "$AVAIL_KB" ]; then
        log_warning "Konnte freien Speicherplatz nicht ermitteln."
        return 0
    fi

    AVAIL_MB=$((AVAIL_KB / 1024))
    BACKUP_USAGE=$(du -sh backups 2>/dev/null | cut -f1 || echo "0")

    log_info "Speicherbelegung im Backup-Verzeichnis: $BACKUP_USAGE"
    if [ "$AVAIL_MB" -lt 1024 ]; then
        log_warning "Wenig Speicherplatz: Nur noch ${AVAIL_MB} MB frei!"
        return 1
    fi

    log_success "Freier Speicherplatz: ${AVAIL_MB} MB"
    return 0
}

run_backup_test() {
    if [ "$1" = "--test-backup" ]; then
        log_info "Führe Backup-Test aus..."
        if ./scripts/backup.sh --full --include-empty >/dev/null 2>&1; then
            log_success "Backup-Test erfolgreich abgeschlossen."
        else
            log_error "Backup-Test fehlgeschlagen - Details in logs/backup.log."
            return 1
        fi
    else
        log_info "Überspringe Backup-Test (nutze --test-backup zum Ausführen)."
    fi

    return 0
}

show_summary() {
    echo
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                   Zusammenfassung des System-Checks           ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo

    if [ $OVERALL_STATUS -eq 0 ]; then
        log_success "Alle Tests bestanden! Das System ist gesund."
    else
        log_warning "Es wurden Probleme gefunden. Bitte überprüfe die Ausgaben oben."
    fi

    echo
    echo -e "${BLUE}Nützliche Befehle:${NC}"
    echo "  docker logs $MARIADB_CONTAINER    # MariaDB Logs ansehen"
    echo "  ./scripts/backup.sh --full                # Vollständiges Backup erstellen"
    echo "  ./scripts/verify_backup.sh --latest       # Neueste Backups verifizieren"
    echo "  ./scripts/health_check.sh --test-backup   # Inkl. Backup-Test ausführen"
    echo
}

main() {
    print_header

    OVERALL_STATUS=0

    check_docker || OVERALL_STATUS=1
    check_mariadb_connection || OVERALL_STATUS=1
    check_databases || OVERALL_STATUS=1
    check_binary_logging || OVERALL_STATUS=1
    check_bind_address || OVERALL_STATUS=1
    check_backup_directories || OVERALL_STATUS=1
    check_scripts || OVERALL_STATUS=1
    check_env_permissions || OVERALL_STATUS=1
    check_encryption_key || OVERALL_STATUS=1
    check_recent_backups || OVERALL_STATUS=1
    check_offsite_sync || OVERALL_STATUS=1
    check_disk_space || OVERALL_STATUS=1
    run_backup_test "$1" || OVERALL_STATUS=1

    show_summary

    exit $OVERALL_STATUS
}

main "$@"
