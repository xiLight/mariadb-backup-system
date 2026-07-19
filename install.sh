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
        log_warning "Running as root. Consider running as a regular user with Docker permissions."
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
    log_info "Setting up Portolan (port/subnet registry)..."

    if command -v portolan &> /dev/null; then
        log_success "Portolan already installed: $(command -v portolan)"
        portolan sync &> /dev/null || true
        return 0
    fi

    # Portolan needs sqlite3; make+git for building/installing.
    # pigz is optional: backup.sh uses it for multi-core compression.
    if ! command -v sqlite3 &> /dev/null || ! command -v make &> /dev/null || ! command -v pigz &> /dev/null; then
        if command -v apt-get &> /dev/null; then
            log_info "Installing dependencies (sqlite3, make, pigz)..."
            run_privileged apt-get update -qq
            run_privileged apt-get install -y -qq sqlite3 make pigz
        else
            log_warning "Cannot auto-install sqlite3/make/pigz (no apt-get). Install them manually."
        fi
    fi

    local tmp_dir
    tmp_dir=$(mktemp -d)

    log_info "Cloning Portolan from $PORTOLAN_REPO..."
    if ! git clone --depth 1 "$PORTOLAN_REPO" "$tmp_dir/portolan" &> /dev/null; then
        log_warning "Could not clone Portolan - continuing with default ports/subnets"
        rm -rf "$tmp_dir"
        return 1
    fi

    if (cd "$tmp_dir/portolan" && run_privileged make install); then
        log_success "Portolan installed: $(command -v portolan)"
    else
        log_warning "Portolan installation failed - continuing with default ports/subnets"
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
        log_warning "Portolan not available - keeping default ports/subnets in .env"
        return 0
    fi

    log_info "Determining free ports and subnets with Portolan..."
    portolan sync &> /dev/null || true

    # A subnet pool is needed for next-subnet; create a default one once
    if ! portolan pools 2>/dev/null | awk 'NR>1' | grep -q '[0-9]'; then
        portolan add-pool 172.20.0.0/16 "docker stacks" &> /dev/null || true
        log_info "Created default subnet pool 172.20.0.0/16"
    fi

    # Main database port (single node: MariaDB, cluster: HAProxy) - prefer 3306
    local db_port=3306
    if portolan_port_ok 3306 mariadb; then
        log_success "Port 3306 is available"
    else
        db_port=$(portolan next-ports 1 3307 2>/dev/null | head -1)
        [[ "$db_port" =~ ^[0-9]+$ ]] || db_port=3306
        log_warning "Port 3306 is taken - using Portolan's suggestion: $db_port"
    fi

    # HAProxy statistics port - prefer 8404
    local stats_port=8404
    if ! portolan_port_ok 8404 haproxy-stats; then
        stats_port=$(portolan next-ports 1 8405 2>/dev/null | head -1)
        [[ "$stats_port" =~ ^[0-9]+$ ]] || stats_port=8404
        log_warning "Port 8404 is taken - using Portolan's suggestion: $stats_port"
    fi

    # Read-only round-robin port - prefer 3309
    local read_port=3309
    if ! portolan_port_ok 3309 mariadb-read; then
        read_port=$(portolan next-ports 1 3310 2>/dev/null | head -1)
        [[ "$read_port" =~ ^[0-9]+$ ]] || read_port=3309
        log_warning "Port 3309 is taken - using Portolan's suggestion: $read_port"
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
        log_success "Galera cluster subnet: $galera_subnet"
    else
        log_warning "Could not get a subnet from Portolan (got: '${galera_subnet:-empty}')"
        log_warning "Keeping GALERA_SUBNET from .env - check for conflicts with: docker network ls"
    fi

    # Book the resources in Portolan's registry
    portolan reserve "$db_port" mariadb "mariadb-backup-system" &> /dev/null || true
    portolan reserve "$stats_port" haproxy-stats "mariadb-backup-system stats" &> /dev/null || true
    portolan reserve "$read_port" mariadb-read "mariadb-backup-system read pool" &> /dev/null || true

    log_success "Ports configured: write=$db_port, read=$read_port, stats=$stats_port (TLS runs on the normal ports)"
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check Docker
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed. Please install Docker first."
        
        # Check if install-docker.sh exists
        if [ ! -f "./install-docker.sh" ]; then
            log_error "install-docker.sh script not found. Please install Docker manually."
            echo "Visit: https://docs.docker.com/get-docker/"
            exit 1
        fi
        
        # Execute the Docker installation script
        chmod +x ./install-docker.sh
        ./install-docker.sh
        
        # Verify Docker was installed successfully
        if ! command -v docker &> /dev/null; then
            log_error "Docker installation failed. You may need to restart your shell or system."
            log_info "Please install Docker manually and then run this script again."
            echo "Visit: https://docs.docker.com/get-docker/"
            exit 1
        fi
        
        log_success "Docker installation completed successfully!"

    fi
    log_success "Docker found: $(docker --version)"
    
    # Check Docker Compose - prefer the plugin, fall back to the legacy binary
    if docker compose version &> /dev/null; then
        COMPOSE="docker compose"
    elif command -v docker-compose &> /dev/null; then
        COMPOSE="docker-compose"
    else
        log_error "Docker Compose is not installed. Please install Docker Compose first."
        echo "Visit: https://docs.docker.com/compose/install/"
        exit 1
    fi
    log_success "Docker Compose found: $($COMPOSE version | head -1)"
    
    # Check if Docker daemon is running
    if ! docker info &> /dev/null; then
        log_error "Docker daemon is not running. Please start Docker first."
        exit 1
    fi
    log_success "Docker daemon is running"
}

# Setup environment file
setup_environment() {
    log_info "Setting up environment configuration..."
    
    if [ -f ".env" ]; then
        log_warning ".env file already exists. Backing up to .env.backup"
        cp .env .env.backup
    fi
    
    if [ ! -f ".env.example" ]; then
        log_error ".env.example file not found!"
        exit 1
    fi
    
    cp .env.example .env
    log_success "Created .env from .env.example"
    
    # Generate secure passwords
    log_info "Generating secure passwords..."
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
        log_success "Generated secure passwords for all databases"
    else
        log_warning "sed not found. Please manually update passwords in .env file"
    fi
    
    echo
    log_info "Generated credentials:"
    echo -e "${YELLOW}Root Password:     $ROOT_PASS${NC}"
    echo -e "${YELLOW}App Password:      $APP_PASS${NC}"
    echo -e "${YELLOW}Database 1 Pass:   $DB1_PASS${NC}"
    echo -e "${YELLOW}Database 2 Pass:   $DB2_PASS${NC}"
    echo -e "${YELLOW}Database 3 Pass:   $DB3_PASS${NC}"
    echo -e "${YELLOW}Database 4 Pass:   $DB4_PASS${NC}"
    echo -e "${YELLOW}Database 5 Pass:   $DB5_PASS${NC}"
    echo
    log_warning "Please save these credentials securely!"
    echo
}

# Setup directories
setup_directories() {
    log_info "Creating necessary directories..."
    
    # Create lib directory first for logging system
    mkdir -p lib
    
    # Create other directories
    mkdir -p backups/{binlogs,checksums,incr,binlog_info}
    mkdir -p logs
    mkdir -p mariadb_data
    
    log_success "Created directory structure"
}

# Make scripts executable
setup_permissions() {
    log_info "Setting up script permissions..."
    
    # Make all shell scripts executable
    chmod +x *.sh
    
    # Make lib scripts executable too
    if [ -d "lib" ]; then
        chmod +x lib/*.sh 2>/dev/null || true
    fi
    
    log_success "Made all scripts executable"
}

# Generate encryption key
setup_encryption() {
    log_info "Setting up backup encryption..."
    
    if [ ! -f ".backup_encryption_key" ]; then
        openssl rand -base64 32 > .backup_encryption_key
        chmod 600 .backup_encryption_key
        log_success "Generated encryption key"
    else
        log_warning "Encryption key already exists"
    fi
}

# Create Docker network
setup_network() {
    log_info "Setting up Docker network..."
    
    if ! docker network ls | grep -q "web"; then
        docker network create web
        log_success "Created 'web' Docker network"
    else
        log_info "Docker network 'web' already exists"
    fi
}

# Build and start containers
start_services() {
    log_info "Building and starting MariaDB container..."

    $COMPOSE down 2>/dev/null || true
    $COMPOSE build
    $COMPOSE up -d

    log_success "MariaDB container started"

    # Wait for MariaDB to be ready
    log_info "Waiting for MariaDB to be ready..."

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
            log_success "MariaDB is ready!"
            break
        elif docker exec -e MYSQL_PWD="$root_password" "$container" mariadb -u root -e "SELECT 1;" &>/dev/null; then
            log_success "MariaDB is ready!"
            break
        elif docker exec "$container" mariadb -u root -e "SELECT 1;" &>/dev/null; then
            log_success "MariaDB is ready!"
            break
        fi

        if [ $i -eq 60 ]; then
            log_error "MariaDB failed to start within 60 seconds"
            log_info "Check logs with: docker logs $container"
            log_info "Trying to show recent container logs:"
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
        read -p "Stack name (unique per installation, e.g. shop, blog) [mariadb]: " stack
        stack="${stack:-mariadb}"
    fi

    if ! [[ "$stack" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        log_warning "Invalid stack name '$stack' (allowed: a-z, 0-9, -, _) - using 'mariadb'"
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

    log_success "Stack name: $stack"
}

# Choose between single-node and 3-node Galera cluster installation
choose_install_mode() {
    if [[ -n "$INSTALL_MODE" ]]; then
        log_info "Installation mode: $INSTALL_MODE (from command line)"
        return 0
    fi

    echo ""
    echo -e "${BLUE}Installation mode:${NC}"
    echo "  [1] Single node    - one MariaDB container (default)"
    echo "  [2] HA cluster     - 3-node Galera multi-master + HAProxy failover + self-healing"
    echo ""
    read -p "Select mode (1/2) [1]: " mode_sel
    case "$mode_sel" in
        2) INSTALL_MODE="cluster" ;;
        *) INSTALL_MODE="single" ;;
    esac
    log_info "Installation mode: $INSTALL_MODE"
}

# Initialize and start the Galera cluster
start_cluster_services() {
    log_info "Setting up 3-node Galera cluster..."

    # Backup scripts talk to node1 in cluster mode
    local stack
    stack=$(grep '^STACK_NAME=' .env | cut -d= -f2)
    set_env_value MARIADB_CONTAINER "${stack:-mariadb}-node1"

    if [[ -f "./cluster_data/node1/grastate.dat" ]]; then
        log_info "Existing cluster data found - starting cluster"
        ./cluster.sh start
    else
        ./cluster.sh init
    fi
}

# Install the self-healing cron job (checks the cluster every minute)
setup_heal_cron() {
    log_info "Setting up self-healing cron job..."

    if ! command -v crontab &> /dev/null; then
        log_warning "crontab not available - install cron or run './heal.sh --daemon' instead"
        return 0
    fi

    local cron_line="* * * * * cd $(pwd) && ./heal.sh >/dev/null 2>&1"
    if crontab -l 2>/dev/null | grep -qF "/heal.sh"; then
        log_info "Self-healing cron job already installed"
    else
        (crontab -l 2>/dev/null; echo "$cron_line") | crontab - &&
            log_success "Self-healing cron job installed (checks every minute)" ||
            log_warning "Could not install cron job - add manually: $cron_line"
    fi
}

# Run initial backup test
test_backup() {
    log_info "Running initial backup test..."
    
    if ./backup.sh --full --include-empty; then
        log_success "Initial backup test completed successfully"
    else
        log_warning "Initial backup test failed. Check logs/backup.log for details"
    fi
}

# Show post-installation information
show_completion_info() {
    echo
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                    Installation Complete!                   ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo
    if [[ "$INSTALL_MODE" == "cluster" ]]; then
        echo -e "${BLUE}Cluster Setup:${NC}"
        echo -e "   ${YELLOW}3-node Galera cluster${NC}            # Synchronous multi-master replication"
        echo -e "   ${YELLOW}HAProxy on port $(grep '^HAPROXY_PORT=' .env | cut -d= -f2)${NC}             # Automatic failover"
        echo -e "   ${YELLOW}Stats: http://localhost:$(grep '^HAPROXY_STATS_PORT=' .env | cut -d= -f2)${NC}   # HAProxy dashboard"
        echo -e "   ${YELLOW}Self-healing cron${NC}                # Checks the cluster every minute"
        echo
        echo -e "${BLUE}Cluster Commands:${NC}"
        echo -e "   ${YELLOW}./cluster.sh status${NC}               # Cluster health"
        echo -e "   ${YELLOW}./update.sh${NC}                       # Rolling update (zero downtime)"
        echo -e "   ${YELLOW}./heal.sh${NC}                         # Manual healing check"
        echo
    fi
    if command -v portolan &> /dev/null; then
        echo -e "${BLUE}Portolan:${NC}"
        echo -e "   ${YELLOW}portolan dash${NC}                     # Port/subnet dashboard"
        echo -e "   ${YELLOW}portolan check-live${NC}               # What is listening right now?"
        echo
    fi
    echo -e "${BLUE}Next Steps:${NC}"
    echo "1. Review and customize your .env file"
    echo "2. Start using the backup system:"
    echo -e "   ${YELLOW}./backup.sh --full --include-empty${NC}  # Full backup"
    echo -e "   ${YELLOW}./backup.sh --incremental${NC}            # Incremental backup"
    echo
    echo -e "${BLUE}Useful Commands:${NC}"
    echo -e "   ${YELLOW}docker logs mariadb${NC}               # View MariaDB logs"
    echo -e "   ${YELLOW}./cleanup_backups.sh${NC}              # Clean old backups"
    echo -e "   ${YELLOW}./restore.sh${NC}                      # Restore from backup"
    echo -e "   ${YELLOW}./health_check.sh${NC}                 # System health check"
    echo -e "   ${YELLOW}./log_cleanup.sh${NC}                  # Clean log files"
    echo
    echo -e "${BLUE}Configuration Files:${NC}"
    echo -e "   ${YELLOW}.env${NC}                             # Environment variables"
    echo -e "   ${YELLOW}my_custom.cnf${NC}                     # MariaDB configuration"
    echo -e "   ${YELLOW}.backup_encryption_key${NC}           # Backup encryption key"
    echo -e "   ${YELLOW}lib/logging.sh${NC}                   # Central logging system"
    echo
    echo -e "${BLUE}Log Files:${NC}"
    echo -e "   ${YELLOW}logs/backup.log${NC}                  # Backup operations"
    echo -e "   ${YELLOW}logs/restore.log${NC}                 # Restore operations"
    echo -e "   ${YELLOW}logs/cleanup_backups.log${NC}         # Backup cleanup operations"
    echo -e "   ${YELLOW}logs/cleanup_binlogs.log${NC}         # Binlog cleanup operations"
    echo -e "   ${YELLOW}logs/encrypt.log${NC}                 # Encryption operations"
    echo
    echo -e "${BLUE}Logging System:${NC}"
    echo "All scripts now use a centralized logging system located in lib/logging.sh"
    echo "You can customize colors and logging format in one central location."
    echo
    echo -e "${RED}Important:${NC} Please save your credentials and encryption key securely!"
    echo
}

# Verify logging system is available
check_logging_system() {
    if [ ! -f "lib/logging.sh" ]; then
        log_error "Central logging system not found at lib/logging.sh"
        log_info "Please ensure the lib/logging.sh file exists and is properly configured"
        exit 1
    fi
    log_success "Central logging system found"
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
                echo "Usage: $0 [--single|--cluster] [--stack NAME] [--allow-root]"
                echo ""
                echo "  --single      Install a single MariaDB node (no prompt)"
                echo "  --cluster     Install the 3-node Galera HA cluster (no prompt)"
                echo "  --stack NAME  Unique stack name (prefixes all container names)"
                echo "  --allow-root  Accepted for compatibility"
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
        log_warning "lib/logging.sh not found. Please ensure it exists before running install.sh"
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