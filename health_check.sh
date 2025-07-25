#!/bin/bash
# Health Check Script for MariaDB Backup System

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║               MariaDB Backup System Health Check             ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo
}

check_docker() {
    log_info "Checking Docker status..."
    
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed"
        return 1
    fi
    
    if ! docker info &> /dev/null; then
        log_error "Docker daemon is not running"
        return 1
    fi
    
    log_success "Docker is running"
    return 0
}

check_mariadb_connection() {
    log_info "Checking MariaDB connection..."
    
    # Source environment variables
    if [ -f ".env" ]; then
        source .env
    else
        log_error ".env file not found"
        return 1
    fi
    
    if docker exec mariadb mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -e "SELECT 1;" &>/dev/null; then
        log_success "MariaDB connection successful"
    else
        log_error "Cannot connect to MariaDB"
        return 1
    fi
    
    return 0
}

check_databases() {
    log_info "Checking database status..."
    
    # Get database list
    DB_LIST=$(docker exec mariadb mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -N -e "SHOW DATABASES;" 2>/dev/null | grep -v -E "^(information_schema|performance_schema|mysql|sys)$")
    
    if [ -z "$DB_LIST" ]; then
        log_warning "No user databases found"
    else
        log_success "Found databases: $(echo $DB_LIST | tr '\n' ' ')"
    fi
    
    return 0
}

check_binary_logging() {
    log_info "Checking binary logging configuration..."
    
    # Check if binary logging is enabled
    BINLOG_ENABLED=$(docker exec mariadb mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -N -e "SELECT @@log_bin;" 2>/dev/null)
    
    if [ "$BINLOG_ENABLED" = "1" ]; then
        log_success "Binary logging is enabled"
        
        # Get binlog info
        BINLOG_BASE=$(docker exec mariadb mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -N -e "SELECT @@log_bin_basename;" 2>/dev/null)
        log_info "Binary log base: $BINLOG_BASE"
        
        # Check binlog directory
        BINLOG_DIR=$(dirname "$BINLOG_BASE")
        if docker exec mariadb test -d "$BINLOG_DIR"; then
            log_success "Binary log directory exists: $BINLOG_DIR"
        else
            log_error "Binary log directory does not exist: $BINLOG_DIR"
            return 1
        fi
    else
        log_error "Binary logging is disabled"
        return 1
    fi
    
    return 0
}

check_bind_address() {
    log_info "Checking bind address configuration..."
    
    BIND_ADDRESS=$(docker exec mariadb mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -N -e "SELECT @@bind_address;" 2>/dev/null)
    
    if [ "$BIND_ADDRESS" = "0.0.0.0" ]; then
        log_success "Bind address is correctly set to 0.0.0.0"
    else
        log_warning "Bind address is set to: $BIND_ADDRESS (expected: 0.0.0.0)"
    fi
    
    return 0
}

check_backup_directories() {
    log_info "Checking backup directories..."
    
    directories=("backups" "backups/binlogs" "backups/checksums" "backups/incr" "backups/binlog_info" "logs")
    
    for dir in "${directories[@]}"; do
        if [ -d "$dir" ]; then
            log_success "Directory exists: $dir"
        else
            log_warning "Directory missing: $dir"
            mkdir -p "$dir"
            log_info "Created directory: $dir"
        fi
    done
    
    return 0
}

check_scripts() {
    log_info "Checking script permissions..."
    
    scripts=("backup.sh" "restore.sh" "encrypt_backup.sh" "cleanup_backups.sh" "cleanup_binlogs.sh" "log_cleanup.sh")
    
    for script in "${scripts[@]}"; do
        if [ -f "$script" ]; then
            if [ -x "$script" ]; then
                log_success "Script is executable: $script"
            else
                log_warning "Script is not executable: $script"
                chmod +x "$script"
                log_info "Made executable: $script"
            fi
        else
            log_error "Script missing: $script"
        fi
    done
    
    return 0
}

check_encryption_key() {
    log_info "Checking encryption key..."
    
    if [ -f ".backup_encryption_key" ]; then
        KEY_SIZE=$(wc -c < .backup_encryption_key)
        if [ "$KEY_SIZE" -gt 20 ]; then
            log_success "Encryption key exists and has good size ($KEY_SIZE bytes)"
        else
            log_warning "Encryption key seems too small ($KEY_SIZE bytes)"
        fi
        
        # Check permissions
        KEY_PERMS=$(stat -c "%a" .backup_encryption_key 2>/dev/null || stat -f "%A" .backup_encryption_key 2>/dev/null)
        if [ "$KEY_PERMS" = "600" ]; then
            log_success "Encryption key has correct permissions (600)"
        else
            log_warning "Encryption key permissions: $KEY_PERMS (should be 600)"
            chmod 600 .backup_encryption_key
            log_info "Fixed encryption key permissions"
        fi
    else
        log_error "Encryption key missing: .backup_encryption_key"
        log_info "Generate with: openssl rand -base64 32 > .backup_encryption_key && chmod 600 .backup_encryption_key"
        return 1
    fi
    
    return 0
}

check_recent_backups() {
    log_info "Checking for recent backups..."
    
    # Find backups from last 7 days
    RECENT_BACKUPS=$(find backups -name "*.sql.gz.enc" -mtime -7 2>/dev/null | wc -l)
    
    if [ "$RECENT_BACKUPS" -gt 0 ]; then
        log_success "Found $RECENT_BACKUPS recent backup(s) from last 7 days"
    else
        log_warning "No recent backups found from last 7 days"
        log_info "Run: ./backup.sh --full --include-empty"
    fi
    
    return 0
}

run_backup_test() {
    log_info "Running backup test..."
    
    if [ "$1" = "--test-backup" ]; then
        if ./backup.sh --full --include-empty >/dev/null 2>&1; then
            log_success "Backup test completed successfully"
        else
            log_error "Backup test failed"
            log_info "Check logs/backup.log for details"
            return 1
        fi
    else
        log_info "Skipping backup test (use --test-backup to run)"
    fi
    
    return 0
}

show_summary() {
    echo
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                        Health Check Summary                   ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo
    
    if [ $OVERALL_STATUS -eq 0 ]; then
        log_success "All checks passed! System is healthy."
    else
        log_warning "Some issues were found. Please review the output above."
    fi
    
    echo
    echo -e "${BLUE}Useful Commands:${NC}"
    echo "  docker logs mariadb           # View MariaDB logs"
    echo "  ./backup.sh --full           # Create full backup"
    echo "  ./health_check.sh --test-backup  # Run with backup test"
    echo "  docker-compose restart       # Restart services"
    echo
}

# Main function
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
    check_encryption_key || OVERALL_STATUS=1
    check_recent_backups || OVERALL_STATUS=1
    run_backup_test "$1" || OVERALL_STATUS=1
    
    show_summary
    
    exit $OVERALL_STATUS
}

# Run health check
main "$@"
