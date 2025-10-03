#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Step 1: Remove CD-ROM repository
print_info "Removing CD-ROM repository..."
sudo sed -i '/cdrom/d' /etc/apt/sources.list
sudo sed -i '/cdrom/d' /etc/apt/sources.list.d/*.list 2>/dev/null || true
print_success "CD-ROM repository removed"

# Step 2: Update package list
print_info "Updating package list..."
sudo apt update

# Step 3: Check Docker installation
print_info "Checking Docker installation..."
if command -v docker &> /dev/null; then
    print_success "Docker is installed!"
    docker --version
else
    print_error "Docker is not installed"
    exit 1
fi

# Step 4: Check Docker Compose
if docker compose version &> /dev/null 2>&1 || sudo docker compose version &> /dev/null; then
    print_success "Docker Compose is installed!"
    sudo docker compose version
else
    print_error "Docker Compose is not installed"
fi

# Step 5: Enable and start Docker service
print_info "Enabling Docker service..."
sudo systemctl enable docker
sudo systemctl start docker
print_success "Docker service enabled and started"

# Step 6: Verify user is in docker group
print_info "Checking docker group membership..."
if groups $USER | grep -q docker; then
    print_success "User $USER is already in docker group"
else
    print_info "Adding user $USER to docker group..."
    sudo usermod -aG docker $USER
    print_success "User added to docker group"
fi

# Step 7: Check if we can run docker without sudo
print_info "Testing Docker permissions..."
if docker ps &> /dev/null; then
    print_success "Docker is working without sudo!"
    docker ps
else
    print_warning "Docker requires sudo or group changes haven't taken effect yet"
    
    # Test with sudo
    print_info "Testing Docker with sudo..."
    if sudo docker ps &> /dev/null; then
        print_success "Docker works with sudo!"
        sudo docker ps
        echo ""
        print_warning "To use Docker without sudo, you need to:"
        echo -e "${YELLOW}Option 1:${NC} Log out and log back in"
        echo -e "${YELLOW}Option 2:${NC} Run: ${GREEN}newgrp docker${NC} (in this terminal only)"
        echo -e "${YELLOW}Option 3:${NC} Restart your system"
        echo ""
        read -p "Do you want to apply group changes now with 'newgrp docker'? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            print_info "Starting new shell with docker group..."
            exec sg docker "$0 --verify"
        fi
    else
        print_error "Docker is not running properly"
        print_info "Checking Docker service status..."
        sudo systemctl status docker --no-pager -l
    fi
fi

# If --verify flag is passed, just verify docker works
if [[ "$1" == "--verify" ]]; then
    print_success "Docker group applied successfully!"
    print_info "Testing docker command..."
    docker ps
    print_success "Docker is now working without sudo!"
    exit 0
fi

print_success "Docker setup complete!"
echo ""
print_info "Summary:"
echo "  - Docker version: $(docker --version 2>/dev/null || sudo docker --version)"
echo "  - Docker Compose: $(docker compose version 2>/dev/null || sudo docker compose version)"
echo "  - User groups: $(groups $USER)"