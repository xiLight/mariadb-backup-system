#!/bin/bash
# MariaDB Backup System Installation Script

set -e

# Load logging functions
source "./lib/logging.sh"

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
    
    # Check Docker Compose
    if ! command -v docker compose &> /dev/null && ! docker compose version &> /dev/null; then
        log_error "Docker Compose is not installed. Please install Docker Compose first."
        echo "Visit: https://docs.docker.com/compose/install/"
        exit 1
    fi
    
    if command -v docker compose &> /dev/null; then
        log_success "Docker Compose found: $(docker-compose --version)"
    else
        log_success "Docker Compose found: $(docker compose version)"
    fi
    
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
    
    if command -v docker-compose &> /dev/null; then
        docker-compose down 2>/dev/null || true
        docker-compose build
        docker-compose up -d
    else
        docker compose down 2>/dev/null || true
        docker compose build
        docker compose up -d
    fi
    
    log_success "MariaDB container started"
    
    # Wait for MariaDB to be ready
    log_info "Waiting for MariaDB to be ready..."
    
    # First wait for container to be running
    sleep 5
    
    # Get the root password from .env file
    ROOT_PASSWORD=$(grep MARIADB_ROOT_PASSWORD .env | cut -d'=' -f2)
    
    for i in {1..60}; do
        # Try multiple connection methods
        if docker exec mariadb mariadb -u root -p"$ROOT_PASSWORD" -h 127.0.0.1 -P 3306 -e "SELECT 1;" &>/dev/null; then
            log_success "MariaDB is ready!"
            break
        elif docker exec mariadb mariadb -u root -p"$ROOT_PASSWORD" --protocol=tcp --host=localhost --port=3306 -e "SELECT 1;" &>/dev/null; then
            log_success "MariaDB is ready!"
            break
        elif docker exec mariadb mariadb -u root -p"$ROOT_PASSWORD" -e "SELECT 1;" &>/dev/null; then
            log_success "MariaDB is ready!"
            break
        fi
        
        if [ $i -eq 60 ]; then
            log_error "MariaDB failed to start within 60 seconds"
            log_info "Check logs with: docker logs mariadb"
            log_info "Trying to show recent container logs:"
            docker logs --tail 20 mariadb
            exit 1
        fi
        sleep 1
        echo -n "."
    done
    echo
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
    setup_environment
    setup_directories
    setup_permissions
    setup_encryption
    setup_network
    start_services
    test_backup
    show_completion_info
}

# Run installation
main "$@"