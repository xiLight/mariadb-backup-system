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
    echo "Verwendung: $0 [OPTIONEN]"
    echo
    echo "Optionen:"
    echo "  --allow-root    Erlaube Ausführung als root-Benutzer"
    echo "  --help          Zeige diese Hilfe an"
    echo
    echo "Dieses Skript installiert Docker und Docker Compose auf deinem System."
    echo "Unterstützte Distributionen: Ubuntu, Debian, CentOS, RHEL, Fedora, Arch Linux"
}

# Check if running as root
check_root() {
    if [[ $EUID -eq 0 && "$ALLOW_ROOT" != "true" ]]; then
        log_error "Aus Sicherheitsgründen sollte das Skript nicht als root ausgeführt werden."
        log_info "Falls du es wirklich als root ausführen musst, nutze den Flag --allow-root"
        log_info "Es wird empfohlen, das Skript als normaler Benutzer mit sudo-Rechten auszuführen."
        exit 1
    fi
}

# Check if user has sudo privileges
check_sudo() {
    if ! sudo -n true 2>/dev/null; then
        log_error "Dieses Skript erfordert sudo-Rechte."
        log_info "Bitte stell sicher, dass dein Benutzer in der sudo-Gruppe ist."
        exit 1
    fi
    log_success "sudo-Rechte erfolgreich bestätigt."
}

# Detect the operating system
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
    else
        log_error "Betriebssystem konnte nicht erkannt werden."
        exit 1
    fi
    
    log_info "Erkanntes OS: $OS $VERSION"
}

# Check if Docker is already installed
check_docker_installed() {
    if command -v docker &> /dev/null; then
        DOCKER_VERSION=$(docker --version | cut -d' ' -f3 | tr -d ',')
        log_warning "Docker ist bereits installiert (Version: $DOCKER_VERSION)."
        return 0
    else
        log_info "Docker ist noch nicht installiert."
        return 1
    fi
}

# Check if Docker Compose is already installed
check_docker_compose_installed() {
    if command -v docker-compose &> /dev/null; then
        COMPOSE_VERSION=$(docker-compose --version | cut -d' ' -f3 | tr -d ',')
        log_warning "Docker Compose ist bereits installiert (Version: $COMPOSE_VERSION)."
        return 0
    else
        log_info "Docker Compose ist noch nicht installiert."
        return 1
    fi
}

# Install Docker on Ubuntu/Debian
install_docker_ubuntu_debian() {
    log_info "Installiere Docker auf Ubuntu/Debian..."
    
    # Update package index
    log_info "Aktualisiere Paketquellen..."
    sudo apt-get update
    
    # Install required packages
    log_info "Installiere benötigte Pakete..."
    sudo apt-get install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release
    
    # Add Docker's official GPG key
    log_info "Füge GPG-Key von Docker hinzu..."
    curl -fsSL https://download.docker.com/linux/$OS/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    
    # Add Docker repository
    log_info "Füge Docker Repository hinzu..."
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/$OS $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Update package index again
    sudo apt-get update
    
    # Install Docker
    log_info "Installiere Docker CE..."
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io
    
    log_success "Docker wurde erfolgreich installiert!"
}

# Install Docker on CentOS/RHEL/Fedora
install_docker_centos_rhel_fedora() {
    log_info "Installiere Docker auf CentOS/RHEL/Fedora..."
    
    # Install required packages
    log_info "Installiere benötigte Pakete..."
    if [[ "$OS" == "fedora" ]]; then
        sudo dnf -y install dnf-plugins-core
        sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
        sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    else
        sudo yum install -y yum-utils
        sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        sudo yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    fi
    
    log_success "Docker wurde erfolgreich installiert!"
}

# Install Docker on Arch Linux
install_docker_arch() {
    log_info "Installiere Docker auf Arch Linux..."
    
    # Update package database
    log_info "Aktualisiere Paketdatenbank..."
    sudo pacman -Sy
    
    # Install Docker
    log_info "Installiere Docker..."
    sudo pacman -S --noconfirm docker docker-compose
    
    log_success "Docker wurde erfolgreich installiert!"
}

# Install Docker Compose (if not already installed)
install_docker_compose() {
    if ! command -v docker-compose &> /dev/null; then
        log_info "Installiere Docker Compose..."
        
        # Download Docker Compose
        COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep 'tag_name' | cut -d\" -f4)
        log_info "Neueste Docker Compose Version: $COMPOSE_VERSION"
        
        sudo curl -L "https://github.com/docker/compose/releases/download/$COMPOSE_VERSION/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        
        # Make it executable
        sudo chmod +x /usr/local/bin/docker-compose
        
        # Create symlink
        sudo ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose
        
        log_success "Docker Compose erfolgreich installiert!"
    fi
}

# Configure Docker
configure_docker() {
    log_info "Konfiguriere Docker..."
    
    # Add user to docker group
    if ! groups $USER | grep -q docker; then
        log_info "Füge Benutzer $USER zur docker-Gruppe hinzu..."
        sudo usermod -aG docker $USER
        log_warning "Du musst dich einmal ab- und wieder anmelden, damit die Gruppenänderung aktiv wird."
    else
        log_info "Benutzer $USER ist bereits in der docker-Gruppe."
    fi
    
    # Enable and start Docker service
    log_info "Aktiviere und starte Docker-Dienst..."
    sudo systemctl enable docker
    sudo systemctl start docker
    
    log_success "Docker-Dienst läuft."
}

# Verify installation
verify_installation() {
    log_info "Überprüfe die Installation..."
    
    # Check Docker version
    if command -v docker &> /dev/null; then
        DOCKER_VERSION=$(docker --version)
        log_success "Docker: $DOCKER_VERSION"
    else
        log_error "Docker-Installation fehlgeschlagen."
        return 1
    fi
    
    # Check Docker Compose version
    if command -v docker-compose &> /dev/null; then
        COMPOSE_VERSION=$(docker-compose --version)
        log_success "Docker Compose: $COMPOSE_VERSION"
    else
        log_error "Docker Compose-Installation fehlgeschlagen."
        return 1
    fi
    
    # Test Docker with hello-world
    log_info "Führe Docker-Test aus..."
    if sudo docker run --rm hello-world &>/dev/null; then
        log_success "Docker-Test erfolgreich abgeschlossen."
    else
        log_warning "Docker-Test fehlgeschlagen – das kann normal sein, falls der User noch nicht aktiv in der docker-Gruppe ist."
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
                log_error "Unbekannte Option: $1"
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
                log_error "Nicht unterstütztes Betriebssystem: $OS"
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
        log_success "Installation erfolgreich abgeschlossen!"
        echo
        log_info "Wie es jetzt weitergeht:"
        log_info "1. Einmal ab- und wieder anmelden (oder 'newgrp docker' ausführen)."
        log_info "2. Docker testen mit: docker run hello-world"
        log_info "3. Docker Compose testen mit: docker-compose --version"
    else
        log_error "Installations-Überprüfung fehlgeschlagen."
        exit 1
    fi
}

# Run main function
main "$@"