#!/bin/bash

# Docker and Docker Compose Installation Script
# Supports Ubuntu/Debian, CentOS/RHEL/Fedora, and Arch Linux
# Version: 1.0.0

set -e

# Load logging functions
source "./lib/logging.sh"

# Script information
SCRIPT_VERSION="1.0.0"

# Global variables
ALLOW_ROOT=false

# Banner
show_banner() {
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║          Docker & Docker Compose Installation Script            ║${NC}"
    echo -e "${BLUE}║                        Version $SCRIPT_VERSION                           ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo
}

# Show usage information
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Options:"
    echo "  --allow-root    Allow running as root user"
    echo "  --help          Show this help message"
    echo
    echo "This script will install Docker and Docker Compose on your system."
    echo "Supported distributions: Ubuntu, Debian, CentOS, RHEL, Fedora, Arch Linux"
}

# Check if running as root
check_root() {
    if [[ $EUID -eq 0 && "$ALLOW_ROOT" != "true" ]]; then
        log_error "This script should not be run as root for security reasons."
        log_info "If you really need to run as root, use --allow-root flag"
        log_info "It's recommended to run as a regular user with sudo privileges"
        exit 1
    fi
}

# Check if user has sudo privileges
check_sudo() {
    if ! sudo -n true 2>/dev/null; then
        log_error "This script requires sudo privileges"
        log_info "Please make sure your user is in the sudo group"
        exit 1
    fi
    log_success "Sudo privileges confirmed"
}

# Detect the operating system
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
    else
        log_error "Cannot detect operating system"
        exit 1
    fi
    
    log_info "Detected OS: $OS $VERSION"
}

# Check if Docker is already installed
check_docker_installed() {
    if command -v docker &> /dev/null; then
        DOCKER_VERSION=$(docker --version | cut -d' ' -f3 | tr -d ',')
        log_warning "Docker is already installed (version: $DOCKER_VERSION)"
        return 0
    else
        log_info "Docker is not installed"
        return 1
    fi
}

# Check if Docker Compose is already installed
check_docker_compose_installed() {
    if command -v docker-compose &> /dev/null; then
        COMPOSE_VERSION=$(docker-compose --version | cut -d' ' -f3 | tr -d ',')
        log_warning "Docker Compose is already installed (version: $COMPOSE_VERSION)"
        return 0
    else
        log_info "Docker Compose is not installed"
        return 1
    fi
}

# Install Docker on Ubuntu/Debian
install_docker_ubuntu_debian() {
    log_info "Installing Docker on Ubuntu/Debian..."
    
    # Update package index
    log_info "Updating package index..."
    sudo apt-get update
    
    # Install required packages
    log_info "Installing required packages..."
    sudo apt-get install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release
    
    # Add Docker's official GPG key
    log_info "Adding Docker's GPG key..."
    curl -fsSL https://download.docker.com/linux/$OS/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    
    # Add Docker repository
    log_info "Adding Docker repository..."
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/$OS $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Update package index again
    sudo apt-get update
    
    # Install Docker
    log_info "Installing Docker CE..."
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io
    
    log_success "Docker installed successfully"
}

# Install Docker on CentOS/RHEL/Fedora
install_docker_centos_rhel_fedora() {
    log_info "Installing Docker on CentOS/RHEL/Fedora..."
    
    # Install required packages
    log_info "Installing required packages..."
    if [[ "$OS" == "fedora" ]]; then
        sudo dnf -y install dnf-plugins-core
        sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
        sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    else
        sudo yum install -y yum-utils
        sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        sudo yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    fi
    
    log_success "Docker installed successfully"
}

# Install Docker on Arch Linux
install_docker_arch() {
    log_info "Installing Docker on Arch Linux..."
    
    # Update package database
    log_info "Updating package database..."
    sudo pacman -Sy
    
    # Install Docker
    log_info "Installing Docker..."
    sudo pacman -S --noconfirm docker docker-compose
    
    log_success "Docker installed successfully"
}

# Install Docker Compose (if not already installed)
install_docker_compose() {
    if ! command -v docker-compose &> /dev/null; then
        log_info "Installing Docker Compose..."
        
        # Download Docker Compose
        COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep 'tag_name' | cut -d\" -f4)
        log_info "Latest Docker Compose version: $COMPOSE_VERSION"
        
        sudo curl -L "https://github.com/docker/compose/releases/download/$COMPOSE_VERSION/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        
        # Make it executable
        sudo chmod +x /usr/local/bin/docker-compose
        
        # Create symlink
        sudo ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose
        
        log_success "Docker Compose installed successfully"
    fi
}

# Configure Docker
configure_docker() {
    log_info "Configuring Docker..."
    
    # Add user to docker group
    if ! groups $USER | grep -q docker; then
        log_info "Adding user $USER to docker group..."
        sudo usermod -aG docker $USER
        log_warning "You need to log out and back in for group changes to take effect"
    else
        log_info "User $USER is already in docker group"
    fi
    
    # Enable and start Docker service
    log_info "Enabling and starting Docker service..."
    sudo systemctl enable docker
    sudo systemctl start docker
    
    log_success "Docker service is running"
}

# Verify installation
verify_installation() {
    log_info "Verifying installation..."
    
    # Check Docker version
    if command -v docker &> /dev/null; then
        DOCKER_VERSION=$(docker --version)
        log_success "Docker: $DOCKER_VERSION"
    else
        log_error "Docker installation failed"
        return 1
    fi
    
    # Check Docker Compose version
    if command -v docker-compose &> /dev/null; then
        COMPOSE_VERSION=$(docker-compose --version)
        log_success "Docker Compose: $COMPOSE_VERSION"
    else
        log_error "Docker Compose installation failed"
        return 1
    fi
    
    # Test Docker with hello-world
    log_info "Running Docker test..."
    if sudo docker run --rm hello-world &>/dev/null; then
        log_success "Docker test completed successfully"
    else
        log_warning "Docker test failed - this might be normal if the user isn't in docker group yet"
    fi
    
    return 0
}

# Main function
main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --allow-root)
                ALLOW_ROOT=true
                shift
                ;;
            --help)
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
    
    # Check prerequisites
    check_root
    check_sudo
    detect_os
    
    # Check if already installed
    DOCKER_INSTALLED=false
    COMPOSE_INSTALLED=false
    
    if check_docker_installed; then
        DOCKER_INSTALLED=true
    fi
    
    if check_docker_compose_installed; then
        COMPOSE_INSTALLED=true
    fi
    
    # Install Docker if not already installed
    if [[ "$DOCKER_INSTALLED" == "false" ]]; then
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
                exit 1
                ;;
        esac
    fi
    
    # Install Docker Compose if not already installed
    if [[ "$COMPOSE_INSTALLED" == "false" ]]; then
        install_docker_compose
    fi
    
    # Configure Docker
    configure_docker
    
    # Verify installation
    if verify_installation; then
        log_success "Installation completed successfully!"
        echo
        log_info "Next steps:"
        log_info "1. Log out and back in (or run 'newgrp docker')"
        log_info "2. Test Docker with: docker run hello-world"
        log_info "3. Test Docker Compose with: docker-compose --version"
    else
        log_error "Installation verification failed"
        exit 1
    fi
}

# Run main function
main "$@"