#!/bin/bash

# Docker and Docker Compose Installation Script
# Supports Ubuntu/Debian, CentOS/RHEL/Fedora, and Arch Linux
# Version: 1.0.0

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# Script information
SCRIPT_VERSION="1.0.0"

# Global variables
ALLOW_ROOT=false

# Banner
show_banner() {
    echo -e "${PURPLE}"
    echo "╔══════════════════════════════════════════════════════════════════════════════╗"
    echo "║                          Docker Installation Script                         ║"
    echo "║                                                                              ║"
    echo "║  Automatically installs Docker Engine and Docker Compose                   ║"
    echo "║  Supports: Ubuntu, Debian, CentOS, RHEL, Fedora, Arch Linux               ║"
    echo "║                                                                              ║"
    echo "╚══════════════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo
}

# Show usage information
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Docker and Docker Compose Installation Script"
    echo
    echo "OPTIONS:"
    echo "  --allow-root    Allow running as root user (not recommended)"
    echo "  -h, --help      Show this help message"
    echo
    echo "EXAMPLES:"
    echo "  $0                    # Install Docker as regular user"
    echo "  $0 --allow-root       # Install Docker as root (not recommended)"
    echo
}

# Logging functions
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

# Check if running as root
check_root() {
    if [[ $EUID -eq 0 ]]; then
        if [[ "$ALLOW_ROOT" == "true" ]]; then
            log_warning "Running as root with --allow-root flag. This is not recommended for security reasons."
            log_info "Script will continue but please consider running as a regular user."
        else
            log_error "This script should not be run as root for security reasons."
            log_info "Please run as a regular user. The script will use sudo when needed."
            log_info "Or use --allow-root flag if you must run as root."
            exit 1
        fi
    fi
}

# Check if user has sudo privileges
check_sudo() {
    # Skip sudo check if running as root
    if [[ $EUID -eq 0 ]]; then
        log_info "Running as root, skipping sudo privilege check"
        return 0
    fi
    
    if ! sudo -n true 2>/dev/null; then
        log_error "This script requires sudo privileges."
        log_info "Please ensure your user is in the sudo group and can run sudo commands."
        exit 1
    fi
}

# Detect the operating system
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
    else
        log_error "Cannot detect operating system. /etc/os-release not found."
        exit 1
    fi
    
    log_info "Detected OS: $PRETTY_NAME"
}

# Check if Docker is already installed
check_docker_installed() {
    if command -v docker &> /dev/null; then
        DOCKER_VERSION=$(docker --version | cut -d' ' -f3 | sed 's/,$//')
        log_warning "Docker is already installed (version: $DOCKER_VERSION)"
        
        read -p "Do you want to reinstall Docker? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Skipping Docker installation"
            SKIP_DOCKER=true
        else
            log_info "Proceeding with Docker reinstallation"
            SKIP_DOCKER=false
        fi
    else
        SKIP_DOCKER=false
    fi
}

# Check if Docker Compose is already installed
check_docker_compose_installed() {
    if command -v docker-compose &> /dev/null || docker compose version &> /dev/null 2>&1; then
        if command -v docker-compose &> /dev/null; then
            COMPOSE_VERSION=$(docker-compose --version | cut -d' ' -f3 | sed 's/,$//')
            log_warning "Docker Compose is already installed (version: $COMPOSE_VERSION)"
        else
            COMPOSE_VERSION=$(docker compose version --short 2>/dev/null || echo "unknown")
            log_warning "Docker Compose (plugin) is already installed (version: $COMPOSE_VERSION)"
        fi
        
        read -p "Do you want to reinstall Docker Compose? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Skipping Docker Compose installation"
            SKIP_COMPOSE=true
        else
            log_info "Proceeding with Docker Compose reinstallation"
            SKIP_COMPOSE=false
        fi
    else
        SKIP_COMPOSE=false
    fi
}

# Install Docker on Ubuntu/Debian
install_docker_ubuntu_debian() {
    log_info "Installing Docker on Ubuntu/Debian..."
    
    # Remove old versions
    if [[ $EUID -eq 0 ]]; then
        apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
        apt-get update
        apt-get install -y ca-certificates curl gnupg lsb-release
        mkdir -p /etc/apt/keyrings
    else
        sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
        sudo apt-get update
        sudo apt-get install -y ca-certificates curl gnupg lsb-release
        sudo mkdir -p /etc/apt/keyrings
    fi
    
    # Add Docker's official GPG key
    if [[ $EUID -eq 0 ]]; then
        curl -fsSL https://download.docker.com/linux/$OS/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    else
        curl -fsSL https://download.docker.com/linux/$OS/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    fi
    
    # Set up the repository
    if [[ $EUID -eq 0 ]]; then
        echo \
            "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS \
            $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt-get update
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    else
        echo \
            "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS \
            $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt-get update
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi
    
    log_success "Docker installed successfully on Ubuntu/Debian"
}

# Install Docker on CentOS/RHEL/Fedora
install_docker_centos_rhel_fedora() {
    log_info "Installing Docker on CentOS/RHEL/Fedora..."
    
    # Remove old versions
    if [[ $EUID -eq 0 ]]; then
        yum remove -y docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine 2>/dev/null || true
    else
        sudo yum remove -y docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine 2>/dev/null || true
    fi
    
    # Install prerequisites
    if [[ "$OS" == "fedora" ]]; then
        if [[ $EUID -eq 0 ]]; then
            dnf install -y dnf-plugins-core
            dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
            dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        else
            sudo dnf install -y dnf-plugins-core
            sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
            sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        fi
    else
        if [[ $EUID -eq 0 ]]; then
            yum install -y yum-utils
            yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        else
            sudo yum install -y yum-utils
            sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            sudo yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        fi
    fi
    
    log_success "Docker installed successfully on CentOS/RHEL/Fedora"
}

# Install Docker on Arch Linux
install_docker_arch() {
    log_info "Installing Docker on Arch Linux..."
    
    # Update package database and install Docker
    if [[ $EUID -eq 0 ]]; then
        pacman -Sy
        pacman -S --noconfirm docker docker-compose
    else
        sudo pacman -Sy
        sudo pacman -S --noconfirm docker docker-compose
    fi
    
    log_success "Docker installed successfully on Arch Linux"
}

# Install Docker based on detected OS
install_docker() {
    if [[ "$SKIP_DOCKER" == "true" ]]; then
        return
    fi
    
    case $OS in
        ubuntu|debian)
            install_docker_ubuntu_debian
            ;;
        centos|rhel|rocky|almalinux)
            install_docker_centos_rhel_fedora
            ;;
        fedora)
            install_docker_centos_rhel_fedora
            ;;
        arch|manjaro)
            install_docker_arch
            ;;
        *)
            log_error "Unsupported operating system: $OS"
            log_info "Supported systems: Ubuntu, Debian, CentOS, RHEL, Fedora, Arch Linux"
            exit 1
            ;;
    esac
}

# Install Docker Compose (standalone) if not installed via plugin
install_docker_compose() {
    if [[ "$SKIP_COMPOSE" == "true" ]]; then
        return
    fi
    
    # Check if Docker Compose plugin is available
    if docker compose version &> /dev/null; then
        log_info "Docker Compose plugin is already available"
        return
    fi
    
    log_info "Installing Docker Compose standalone..."
    
    # Get latest version
    COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep -Po '"tag_name": "\K.*?(?=")')
    
    # Download and install
    if [[ $EUID -eq 0 ]]; then
        curl -L "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
        ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose
    else
        sudo curl -L "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        sudo chmod +x /usr/local/bin/docker-compose
        sudo ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose
    fi
    
    log_success "Docker Compose $COMPOSE_VERSION installed successfully"
}

# Configure Docker
configure_docker() {
    log_info "Configuring Docker..."
    
    # Start and enable Docker service
    if [[ $EUID -eq 0 ]]; then
        systemctl start docker
        systemctl enable docker
    else
        sudo systemctl start docker
        sudo systemctl enable docker
    fi
    
    # Add current user to docker group (skip if running as root)
    if [[ $EUID -ne 0 ]]; then
        sudo usermod -aG docker $USER
        log_info "User $USER added to docker group"
        log_warning "Please log out and log back in for group changes to take effect"
    else
        log_info "Running as root, skipping docker group assignment"
    fi
    
    log_success "Docker service started and enabled"
}

# Test Docker installation
test_docker() {
    log_info "Testing Docker installation..."
    
    # Test Docker (use sudo only if not running as root)
    if [[ $EUID -eq 0 ]]; then
        if docker run --rm hello-world &> /dev/null; then
            log_success "Docker is working correctly"
        else
            log_error "Docker test failed"
        fi
    else
        if sudo docker run --rm hello-world &> /dev/null; then
            log_success "Docker is working correctly"
        else
            log_error "Docker test failed"
        fi
    fi
    
    # Test Docker Compose
    if command -v docker-compose &> /dev/null; then
        COMPOSE_VERSION=$(docker-compose --version)
        log_success "Docker Compose is available: $COMPOSE_VERSION"
    elif docker compose version &> /dev/null; then
        COMPOSE_VERSION=$(docker compose version)
        log_success "Docker Compose plugin is available: $COMPOSE_VERSION"
    else
        log_error "Docker Compose test failed"
    fi
}

# Show installation summary
show_summary() {
    echo
    log_info "Installation Summary:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Docker version
    if command -v docker &> /dev/null; then
        DOCKER_VERSION=$(docker --version)
        echo -e "${GREEN}✓${NC} Docker: $DOCKER_VERSION"
    else
        echo -e "${RED}✗${NC} Docker: Not installed"
    fi
    
    # Docker Compose version
    if command -v docker-compose &> /dev/null; then
        COMPOSE_VERSION=$(docker-compose --version)
        echo -e "${GREEN}✓${NC} Docker Compose: $COMPOSE_VERSION"
    elif docker compose version &> /dev/null 2>&1; then
        COMPOSE_VERSION=$(docker compose version)
        echo -e "${GREEN}✓${NC} Docker Compose Plugin: $COMPOSE_VERSION"
    else
        echo -e "${RED}✗${NC} Docker Compose: Not installed"
    fi
    
    # Docker service status
    if systemctl is-active --quiet docker; then
        echo -e "${GREEN}✓${NC} Docker Service: Running"
    else
        echo -e "${RED}✗${NC} Docker Service: Not running"
    fi
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    log_info "Next Steps:"
    if [[ $EUID -ne 0 ]]; then
        echo "1. Log out and log back in to apply group changes"
        echo "2. Run 'docker --version' to verify installation"
        echo "3. Run 'docker compose --version' to verify Docker Compose"
        echo "4. Start using Docker with your MariaDB Backup System!"
    else
        echo "1. Run 'docker --version' to verify installation"
        echo "2. Run 'docker compose --version' to verify Docker Compose"
        echo "3. Start using Docker with your MariaDB Backup System!"
        echo "4. Consider creating a non-root user for regular Docker usage"
    fi
    echo
    log_success "Docker installation completed successfully!"
}

# Main installation function
main() {
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --allow-root)
                ALLOW_ROOT=true
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
    
    show_banner
    
    log_info "Starting Docker installation process..."
    
    # Perform checks
    check_root
    check_sudo
    detect_os
    check_docker_installed
    check_docker_compose_installed
    
    # Install components
    install_docker
    install_docker_compose
    configure_docker
    
    # Test installation
    test_docker
    
    # Show summary
    show_summary
}

# Handle script interruption
trap 'log_error "Installation interrupted by user"; exit 1' INT TERM

# Run main function
main "$@"
