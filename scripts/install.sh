#!/bin/bash
# MariaDB Backup System Installation Script

set -e

# Load logging functions
source "./lib/logging.sh"

# Docker Compose command - resolved properly in check_prerequisites,
# this is a safe default (the plugin is standard on modern Docker)
COMPOSE="docker compose"

print_banner() {
    echo -e "${BLUE}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                MariaDB Backup System Installer              ║"
    echo "║                                                              ║"
    echo "║  A comprehensive Docker-based MariaDB backup solution       ║"
    echo "║  with encryption, binary logs, and automated cleanup        ║"
    echo "║                                                              ║"
    echo "║  Developed by: #pentrax3269                                  ║"
    echo "║  GitHub: https://github.com/xiLight/mariadb-backup-system   ║"
    echo "║  Discord: https://discord.com/invite/FaHcQnunFp             ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# Check if running as root
check_root() {
    if [[ $EUID -eq 0 ]]; then
        log_warning "Du führst das Skript als root aus. Besser wäre ein normaler User in der docker-Gruppe."
    fi
}

run_privileged() {
    if [[ $EUID -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

# --- Portolan: port/subnet manager (https://git.simbrey.com/docker-public/portolan) ---
PORTOLAN_REPO="https://git.simbrey.com/docker-public/portolan.git"

install_portolan() {
    log_info "Richte Portolan (Port/Subnet-Registry) ein..."

    if command -v portolan &> /dev/null; then
        log_success "Portolan ist bereits installiert: $(command -v portolan)"
        portolan sync &> /dev/null || true
        return 0
    fi

    # Portolan needs sqlite3; make+git for building/installing.
    # pigz is optional: backup.sh uses it for multi-core compression.
    if ! command -v sqlite3 &> /dev/null || ! command -v make &> /dev/null || ! command -v pigz &> /dev/null; then
        if command -v apt-get &> /dev/null; then
            log_info "Installiere Abhängigkeiten (sqlite3, make, pigz)..."
            run_privileged apt-get update -qq
            run_privileged apt-get install -y -qq sqlite3 make pigz
        else
            log_warning "Konnte sqlite3/make/pigz nicht automatisch installieren (kein apt-get). Bitte manuell installieren."
        fi
    fi

    local tmp_dir
    tmp_dir=$(mktemp -d)

    log_info "Klone Portolan von $PORTOLAN_REPO..."
    if ! git clone --depth 1 "$PORTOLAN_REPO" "$tmp_dir/portolan" &> /dev/null; then
        log_warning "Portolan konnte nicht geklont werden - nutze stattdessen Standard-Ports/Subnetze."
        rm -rf "$tmp_dir"
        return 1
    fi

    if (cd "$tmp_dir/portolan" && run_privileged make install); then
        log_success "Portolan installiert: $(command -v portolan)"
    else
        log_warning "Portolan-Installation fehlgeschlagen - nutze stattdessen Standard-Ports/Subnetze."
        rm -rf "$tmp_dir"
        return 1
    fi
    rm -rf "$tmp_dir"

    portolan sync &> /dev/null || true
}

# Set or append KEY=VALUE in .env
set_env_value() {
    local key="$1" value="$2"
    if grep -q "^${key}=" .env; then
        sed -i "s|^${key}=.*|${key}=${value}|" .env
    else
        echo "${key}=${value}" >> .env
    fi
}

# Ask Portolan whether a port is usable for us: free, or already reserved
# for the given service name (re-runs of the installer) while nothing
# is actually listening on it.
portolan_port_ok() {
    local port="$1" service="$2" output
    if output=$(portolan check "$port" 2>/dev/null); then
        return 0
    fi
    echo "$output" | grep -q "for.*${service}" && echo "$output" | grep -q "not listening"
}

configure_network_with_portolan() {
    if ! command -v portolan &> /dev/null; then
        log_warning "Portolan ist nicht verfügbar - behalte Standard-Ports/Subnetze in .env"
        return 0
    fi

    log_info "Suche nach freien Ports und Subnetzen mit Portolan..."
    portolan sync &> /dev/null || true

    # A subnet pool is needed for next-subnet; create a default one once
    if ! portolan pools 2>/dev/null | awk 'NR>1' | grep -q '[0-9]'; then
        portolan add-pool 172.20.0.0/16 "docker stacks" &> /dev/null || true
        log_info "Standard-Subnetz-Pool 172.20.0.0/16 wurde erstellt."
    fi

    # Main database port (single node: MariaDB, cluster: HAProxy) - prefer 3306
    local db_port=3306
    if portolan_port_ok 3306 mariadb; then
        log_success "Port 3306 ist verfügbar."
    else
        db_port=$(portolan next-ports 1 3307 2>/dev/null | head -1)
        [[ "$db_port" =~ ^[0-9]+$ ]] || db_port=3306
        log_warning "Port 3306 ist belegt - nutze den Vorschlag von Portolan: $db_port"
    fi

    # HAProxy statistics port - prefer 8404
    local stats_port=8404
    if ! portolan_port_ok 8404 haproxy-stats; then
        stats_port=$(portolan next-ports 1 8405 2>/dev/null | head -1)
        [[ "$stats_port" =~ ^[0-9]+$ ]] || stats_port=8404
        log_warning "Port 8404 ist belegt - nutze den Vorschlag von Portolan: $stats_port"
    fi

    # Read-only round-robin port - prefer 3309
    local read_port=3309
    if ! portolan_port_ok 3309 mariadb-read; then
        read_port=$(portolan next-ports 1 3310 2>/dev/null | head -1)
        [[ "$read_port" =~ ^[0-9]+$ ]] || read_port=3309
        log_warning "Port 3309 ist belegt - nutze den Vorschlag von Portolan: $read_port"
    fi

    # Collision-free subnet for the Galera cluster network
    # (strip whitespace/ANSI codes so the validation regex is reliable)
    local galera_subnet
    galera_subnet=$(portolan next-subnet 2>/dev/null | tail -1 | sed 's/\x1b\[[0-9;]*m//g' | tr -d '[:space:]')

    set_env_value MARIADB_PORT "$db_port"
    set_env_value HAPROXY_PORT "$db_port"
    set_env_value HAPROXY_STATS_PORT "$stats_port"
    set_env_value HAPROXY_READ_PORT "$read_port"
    if [[ "$galera_subnet" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
        set_env_value GALERA_SUBNET "$galera_subnet"
        log_success "Galera-Cluster-Subnetz: $galera_subnet"
    else
        log_warning "Portolan konnte kein Subnetz zuweisen (Ergebnis: '${galera_subnet:-empty}')."
        log_warning "Behalte GALERA_SUBNET aus der .env bei - bitte prüfe auf Konflikte mit: docker network ls"
    fi

    # Book the resources in Portolan's registry
    portolan reserve "$db_port" mariadb "mariadb-backup-system" &> /dev/null || true
    portolan reserve "$stats_port" haproxy-stats "mariadb-backup-system stats" &> /dev/null || true
    portolan reserve "$read_port" mariadb-read "mariadb-backup-system read pool" &> /dev/null || true

    log_success "Ports konfiguriert: write=$db_port, read=$read_port, stats=$stats_port (TLS läuft über die Standard-Ports)"
}

# Check prerequisites
check_prerequisites() {
    log_info "Überprüfe Voraussetzungen..."
    
    # Check Docker
    if ! command -v docker &> /dev/null; then
        log_error "Docker ist nicht installiert. Bitte installiere Docker zuerst."
        
        # Check if install-docker.sh exists
        if [ ! -f "./scripts/install-docker.sh" ]; then
            log_error "install-docker.sh Skript wurde nicht gefunden. Bitte Docker manuell installieren."
            echo "Siehe: https://docs.docker.com/get-docker/"
            exit 1
        fi
        
        # Execute the Docker installation script
        chmod +x ./scripts/install-docker.sh
        ./scripts/install-docker.sh
        
        # Verify Docker was installed successfully
        if ! command -v docker &> /dev/null; then
            log_error "Docker-Installation fehlgeschlagen. Eventuell musst du das System oder die Shell neu starten."
            log_info "Bitte installiere Docker manuell und führe dieses Skript erneut aus."
            echo "Siehe: https://docs.docker.com/get-docker/"
            exit 1
        fi
        
        log_success "Docker wurde erfolgreich installiert!"

    fi
    log_success "Docker gefunden: $(docker --version)"
    
    # Check Docker Compose - prefer the plugin, fall back to the legacy binary
    if docker compose version &> /dev/null; then
        COMPOSE="docker compose"
    elif command -v docker-compose &> /dev/null; then
        COMPOSE="docker-compose"
    else
        log_error "Docker Compose ist nicht installiert. Bitte installiere Docker Compose zuerst."
        echo "Siehe: https://docs.docker.com/compose/install/"
        exit 1
    fi
    log_success "Docker Compose gefunden: $($COMPOSE version | head -1)"
    
    # Check if Docker daemon is running
    if ! docker info &> /dev/null; then
        log_error "Der Docker-Dienst läuft nicht. Bitte starte Docker zuerst."
        exit 1
    fi
    log_success "Docker-Dienst läuft."
}

# Setup environment file
setup_environment() {
    log_info "Richte Umgebungskonfiguration ein..."
    
    if [ -f ".env" ]; then
        log_warning ".env Datei existiert bereits. Erstelle Backup als .env.backup"
        cp .env .env.backup
    fi
    
    if [ ! -f ".env.example" ]; then
        log_error ".env.example Datei nicht gefunden!"
        exit 1
    fi
    
    cp .env.example .env
    log_success ".env Datei erfolgreich aus .env.example erstellt."
    
    # Generate secure passwords
    log_info "Generiere sichere Passwörter..."
    ROOT_PASS=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
    APP_PASS=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
    DB1_PASS=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
    DB2_PASS=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
    DB3_PASS=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
    DB4_PASS=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
    DB5_PASS=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
    
    # Update .env file with generated passwords
    if command -v sed &> /dev/null; then
        sed -i "s/your_secure_root_password_here/$ROOT_PASS/g" .env
        sed -i "s/your_secure_app_password_here/$APP_PASS/g" .env
        sed -i "s/db1_password/$DB1_PASS/g" .env
        sed -i "s/db2_password/$DB2_PASS/g" .env
        sed -i "s/db3_password/$DB3_PASS/g" .env
        sed -i "s/db4_password/$DB4_PASS/g" .env
        sed -i "s/db5_password/$DB5_PASS/g" .env
        log_success "Sichere Passwörter für alle Datenbanken generiert."
    else
        log_warning "sed wurde nicht gefunden. Bitte aktualisiere die Passwörter manuell in der .env-Datei."
    fi
    
    echo
    log_info "Generierte Zugangsdaten:"
    echo -e "${YELLOW}Root Passwort:     $ROOT_PASS${NC}"
    echo -e "${YELLOW}App Passwort:      $APP_PASS${NC}"
    echo -e "${YELLOW}Datenbank 1 PW:    $DB1_PASS${NC}"
    echo -e "${YELLOW}Datenbank 2 PW:    $DB2_PASS${NC}"
    echo -e "${YELLOW}Datenbank 3 PW:    $DB3_PASS${NC}"
    echo -e "${YELLOW}Datenbank 4 PW:    $DB4_PASS${NC}"
    echo -e "${YELLOW}Datenbank 5 PW:    $DB5_PASS${NC}"
    echo
    log_warning "Bitte speichere diese Zugangsdaten sicher ab!"
    echo
}

# Setup directories
setup_directories() {
    log_info "Erstelle benötigte Verzeichnisse..."
    
    # Create lib directory first for logging system
    mkdir -p lib
    
    # Create other directories
    mkdir -p backups/{binlogs,checksums,incr,binlog_info}
    mkdir -p logs
    mkdir -p mariadb_data
    
    log_success "Verzeichnisstruktur wurde erstellt."
}

# Make scripts executable
setup_permissions() {
    log_info "Setze Berechtigungen für Skripte..."
    
    # Make all shell scripts executable
    chmod +x *.sh
    
    # Make lib scripts executable too
    if [ -d "lib" ]; then
        chmod +x lib/*.sh 2>/dev/null || true
    fi
    
    log_success "Alle Skripte sind nun ausführbar."
}

# Generate encryption key
setup_encryption() {
    log_info "Richte Backup-Verschlüsselung ein..."
    
    if [ ! -f ".backup_encryption_key" ]; then
        openssl rand -base64 32 > .backup_encryption_key
        chmod 600 .backup_encryption_key
        log_success "Verschlüsselungs-Key generiert."
    else
        log_warning "Verschlüsselungs-Key existiert bereits."
    fi
}

# Create Docker network
setup_network() {
    log_info "Richte Docker-Netzwerk ein..."
    
    if ! docker network ls | grep -q "web"; then
        docker network create web
        log_success "Docker-Netzwerk 'web' erstellt."
    else
        log_info "Docker-Netzwerk 'web' existiert bereits."
    fi
}

# Build and start containers
start_services() {
    log_info "Baue und starte MariaDB-Container..."

    $COMPOSE down 2>/dev/null || true
    $COMPOSE build
    $COMPOSE up -d

    log_success "MariaDB-Container gestartet."

    # Wait for MariaDB to be ready
    log_info "Warte darauf, dass MariaDB einsatzbereit ist..."

    # First wait for container to be running
    sleep 5

    # Get container name and root password from .env file
    local container root_password
    container=$(grep '^MARIADB_CONTAINER=' .env | cut -d'=' -f2)
    container="${container:-mariadb}"
    root_password=$(grep '^MARIADB_ROOT_PASSWORD=' .env | cut -d'=' -f2)

    for i in {1..60}; do
        # Try multiple connection methods (password via env, not process list)
        if docker exec -e MYSQL_PWD="$root_password" "$container" mariadb -u root -h 127.0.0.1 -P 3306 -e "SELECT 1;" &>/dev/null; then
            log_success "MariaDB ist bereit!"
            break
        elif docker exec -e MYSQL_PWD="$root_password" "$container" mariadb -u root -e "SELECT 1;" &>/dev/null; then
            log_success "MariaDB ist bereit!"
            break
        elif docker exec "$container" mariadb -u root -e "SELECT 1;" &>/dev/null; then
            log_success "MariaDB ist bereit!"
            break
        fi

        if [ $i -eq 60 ]; then
            log_error "MariaDB konnte innerhalb von 60 Sekunden nicht starten."
            log_info "Überprüfe die Logs mit: docker logs $container"
            log_info "Versuche, die letzten Container-Logs anzuzeigen:"
            docker logs --tail 20 "$container"
            exit 1
        fi
        sleep 1
        echo -n "."
    done
    echo
}

# Every installation gets a unique stack name - it prefixes the compose
# project, all container names, and the image tag, so multiple stacks
# can coexist on one host.
configure_stack_name() {
    local stack="$STACK_NAME_ARG"

    if [[ -z "$stack" ]]; then
        echo ""
        read -p "Stack-Name (einmalig pro Installation, z. B. shop, blog) [mariadb]: " stack
        stack="${stack:-mariadb}"
    fi

    if ! [[ "$stack" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        log_warning "Ungültiger Stack-Name '$stack' (erlaubt: a-z, 0-9, -, _) - verwende 'mariadb'"
        stack="mariadb"
    fi

    set_env_value STACK_NAME "$stack"

    # Unique Galera cluster name per stack: two clusters with the same
    # name on one host could merge if their ports are reachable
    set_env_value GALERA_CLUSTER_NAME "${stack}-galera"

    # Single-node mode: the container itself carries the stack name
    if [[ "$INSTALL_MODE" != "cluster" ]]; then
        set_env_value MARIADB_CONTAINER "$stack"
    fi

    log_success "Stack-Name: $stack"
}

# Choose between single-node and 3-node Galera cluster installation
choose_install_mode() {
    if [[ -n "$INSTALL_MODE" ]]; then
        log_info "Installations-Modus: $INSTALL_MODE (über Kommandozeile)"
        return 0
    fi

    echo ""
    echo -e "${BLUE}Installations-Modus:${NC}"
    echo "  [1] Single Node    - Ein einziger MariaDB Container (Standard)"
    echo "  [2] HA Cluster     - 3-Node Galera Multi-Master + HAProxy Failover + Self-Healing"
    echo ""
    read -p "Modus wählen (1/2) [1]: " mode_sel
    case "$mode_sel" in
        2) INSTALL_MODE="cluster" ;;
        *) INSTALL_MODE="single" ;;
    esac
    log_info "Installations-Modus: $INSTALL_MODE"
}

# Initialize and start the Galera cluster
start_cluster_services() {
    log_info "Richte 3-Node Galera-Cluster ein..."

    # Backup scripts talk to node1 in cluster mode
    local stack
    stack=$(grep '^STACK_NAME=' .env | cut -d= -f2)
    set_env_value MARIADB_CONTAINER "${stack:-mariadb}-node1"

    if [[ -f "./cluster_data/node1/grastate.dat" ]]; then
        log_info "Bestehende Cluster-Daten gefunden - starte Cluster"
        ./scripts/cluster.sh start
    else
        ./scripts/cluster.sh init
    fi
}

# Install the self-healing cron job (checks the cluster every minute)
setup_heal_cron() {
    log_info "Richte Self-Healing Cronjob ein..."

    if ! command -v crontab &> /dev/null; then
        log_warning "crontab ist nicht verfügbar - installiere cron oder führe './scripts/heal.sh --daemon' manuell aus"
        return 0
    fi

    local cron_line="* * * * * cd $(pwd) && ./scripts/heal.sh >/dev/null 2>&1"
    if crontab -l 2>/dev/null | grep -qF "/heal.sh"; then
        log_info "Self-Healing Cronjob ist bereits installiert."
    else
        (crontab -l 2>/dev/null; echo "$cron_line") | crontab - &&
            log_success "Self-Healing Cronjob installiert (prüft jede Minute)." ||
            log_warning "Konnte Cronjob nicht installieren - bitte manuell hinzufügen: $cron_line"
    fi
}

# Run initial backup test
test_backup() {
    log_info "Führe anfänglichen Backup-Test durch..."
    
    if ./scripts/backup.sh --full --include-empty; then
        log_success "Anfänglicher Backup-Test erfolgreich abgeschlossen!"
    else
        log_warning "Backup-Test fehlgeschlagen. Details findest du in logs/backup.log."
    fi
}

# Show post-installation information
show_completion_info() {
    echo
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                    Installation abgeschlossen!              ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo
    if [[ "$INSTALL_MODE" == "cluster" ]]; then
        echo -e "${BLUE}Cluster-Setup:${NC}"
        echo -e "   ${YELLOW}3-Node Galera Cluster${NC}            # Synchrone Multi-Master-Replikation"
        echo -e "   ${YELLOW}HAProxy auf Port $(grep '^HAPROXY_PORT=' .env | cut -d= -f2)${NC}             # Automatischer Failover"
        echo -e "   ${YELLOW}Stats: http://localhost:$(grep '^HAPROXY_STATS_PORT=' .env | cut -d= -f2)${NC}   # HAProxy Dashboard"
        echo -e "   ${YELLOW}Self-Healing Cronjob${NC}             # Prüft den Cluster jede Minute"
        echo
        echo -e "${BLUE}Cluster-Befehle:${NC}"
        echo -e "   ${YELLOW}./scripts/cluster.sh status${NC}               # Cluster-Status"
        echo -e "   ${YELLOW}./scripts/update.sh${NC}                       # Rolling Update (Zero Downtime)"
        echo -e "   ${YELLOW}./scripts/heal.sh${NC}                         # Manueller Healing-Check"
        echo
    fi
    if command -v portolan &> /dev/null; then
        echo -e "${BLUE}Portolan:${NC}"
        echo -e "   ${YELLOW}portolan dash${NC}                     # Port/Subnetz Dashboard"
        echo -e "   ${YELLOW}portolan check-live${NC}               # Was ist aktuell aktiv?"
        echo
    fi
    echo -e "${BLUE}Nächste Schritte:${NC}"
    echo "1. Überprüfe und passe deine .env-Datei an."
    echo "2. So startest du das Backup-System:"
    echo -e "   ${YELLOW}./scripts/backup.sh --full --include-empty${NC}  # Vollständiges Backup"
    echo -e "   ${YELLOW}./scripts/backup.sh --incremental${NC}            # Inkrementelles Backup"
    echo
    echo -e "${BLUE}Nützliche Befehle:${NC}"
    echo -e "   ${YELLOW}docker logs mariadb${NC}               # MariaDB Logs ansehen"
    echo -e "   ${YELLOW}./scripts/cleanup_backups.sh${NC}              # Alte Backups bereinigen"
    echo -e "   ${YELLOW}./scripts/restore.sh${NC}                      # Aus Backup wiederherstellen"
    echo -e "   ${YELLOW}./scripts/health_check.sh${NC}                 # System-Statusprüfung"
    echo -e "   ${YELLOW}./scripts/log_cleanup.sh${NC}                  # Logdateien bereinigen"
    echo
    echo -e "${BLUE}Konfigurationsdateien:${NC}"
    echo -e "   ${YELLOW}.env${NC}                             # Umgebungsvariablen"
    echo -e "   ${YELLOW}my_custom.cnf${NC}                     # MariaDB Konfiguration"
    echo -e "   ${YELLOW}.backup_encryption_key${NC}           # Backup Verschlüsselungs-Key"
    echo -e "   ${YELLOW}lib/logging.sh${NC}                   # Zentrales Logging-System"
    echo
    echo -e "${BLUE}Logdateien:${NC}"
    echo -e "   ${YELLOW}logs/backup.log${NC}                  # Backup-Vorgänge"
    echo -e "   ${YELLOW}logs/restore.log${NC}                 # Wiederherstellungs-Vorgänge"
    echo -e "   ${YELLOW}logs/cleanup_backups.log${NC}         # Backup-Bereinigungen"
    echo -e "   ${YELLOW}logs/cleanup_binlogs.log${NC}         # Binlog-Bereinigungen"
    echo -e "   ${YELLOW}logs/encrypt.log${NC}                 # Verschlüsselungs-Vorgänge"
    echo
    echo -e "${BLUE}Logging-System:${NC}"
    echo "Alle Skripte nutzen nun ein zentrales Logging-System in lib/logging.sh"
    echo "Hier kannst du Farben und Formatierung zentral anpassen."
    echo
    echo -e "${RED}Wichtig:${NC} Bitte speichere deine Zugangsdaten und den Verschlüsselungs-Key sicher ab!"
    echo
}

# Verify logging system is available
check_logging_system() {
    if [ ! -f "lib/logging.sh" ]; then
        log_error "Zentrales Logging-System nicht gefunden: lib/logging.sh"
        log_info "Bitte stelle sicher, dass lib/logging.sh existiert und korrekt konfiguriert ist."
        exit 1
    fi
    log_success "Zentrales Logging-System gefunden."
}

# Main installation function
main() {
    INSTALL_MODE=""
    STACK_NAME_ARG=""
    while [[ $# -gt 0 ]]; do
        case $1 in
            --cluster)    INSTALL_MODE="cluster"; shift ;;
            --single)     INSTALL_MODE="single"; shift ;;
            --stack)      STACK_NAME_ARG="$2"; shift 2 ;;
            --allow-root) shift ;;
            --help)
                echo "Nutzung: $0 [--single|--cluster] [--stack NAME] [--allow-root]"
                echo ""
                echo "  --single      Installiere einen Single-Node MariaDB (ohne Prompt)"
                echo "  --cluster     Installiere den 3-Node Galera HA Cluster (ohne Prompt)"
                echo "  --stack NAME  Einmaliger Stack-Name (Präfix für alle Container)"
                echo "  --allow-root  Wird zur Kompatibilität akzeptiert"
                exit 0
                ;;
            *) shift ;;
        esac
    done

    # Create lib directory early for logging system
    mkdir -p lib

    # Check if logging system exists (after creating lib directory)
    if [ -f "lib/logging.sh" ]; then
        check_logging_system
    else
        # If logging.sh doesn't exist, we need to create it or the script will fail
        log_warning "lib/logging.sh nicht gefunden. Bitte stelle sicher, dass es existiert, bevor du install.sh ausführst."
        exit 1
    fi

    print_banner
    check_root
    check_prerequisites
    install_portolan
    choose_install_mode
    setup_environment
    configure_stack_name
    configure_network_with_portolan
    setup_directories
    setup_permissions
    setup_encryption
    setup_network

    if [[ "$INSTALL_MODE" == "cluster" ]]; then
        start_cluster_services
        setup_heal_cron
    else
        start_services
    fi

    test_backup
    show_completion_info
}

# Run installation
main "$@"