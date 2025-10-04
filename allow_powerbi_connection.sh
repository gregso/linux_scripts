#!/bin/bash
# Allow Power BI from Windows host to connect to PostgreSQL

set -e

COLOR_GREEN='\033[0;32m'
COLOR_BLUE='\033[0;34m'
COLOR_YELLOW='\033[1;33m'
COLOR_RED='\033[0;31m'
COLOR_RESET='\033[0m'

info() { echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $*"; }
ok() { echo -e "${COLOR_GREEN}[ OK ]${COLOR_RESET} $*"; }
warn() { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*"; }
error() { echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $*"; }

echo "=========================================="
echo "  PostgreSQL Power BI Connection Setup"
echo "=========================================="
echo ""

# Find PostgreSQL version
PG_VERSION=$(ls /etc/postgresql/ | head -1)
PG_CONF="/etc/postgresql/$PG_VERSION/main/postgresql.conf"
PG_HBA="/etc/postgresql/$PG_VERSION/main/pg_hba.conf"

if [ ! -f "$PG_CONF" ]; then
    error "PostgreSQL configuration not found at $PG_CONF"
    exit 1
fi

info "PostgreSQL version: $PG_VERSION"
echo ""

# Check current SSL setting
SSL_STATUS=$(sudo grep "^ssl = " "$PG_CONF" | awk '{print $3}')
info "Current SSL status: $SSL_STATUS"

if [ "$SSL_STATUS" != "off" ]; then
    warn "SSL is currently enabled. Disabling SSL..."
    sudo sed -i "s/^ssl = on/ssl = off/" "$PG_CONF"
    ok "SSL disabled in postgresql.conf"
else
    ok "SSL is already disabled"
fi

echo ""
info "Current pg_hba.conf entries for external connections:"
sudo grep "^host" "$PG_HBA" | grep -v "127.0.0.1\|::1"
echo ""

# Prompt for Windows host IP
info "To allow Power BI to connect, we need the Windows host IP address."
echo "Common scenarios:"
echo "  - VirtualBox NAT: Windows host is usually 10.0.2.2"
echo "  - VMware NAT: Windows host is usually 192.168.x.1"
echo "  - Hyper-V: Windows host IP varies"
echo ""

read -p "Enter Windows host IP address (or subnet like 10.0.2.2/32): " WINDOWS_IP

if [ -z "$WINDOWS_IP" ]; then
    error "No IP address provided"
    exit 1
fi

# Check if entry already exists
if sudo grep -q "$WINDOWS_IP" "$PG_HBA"; then
    warn "Entry for $WINDOWS_IP already exists in pg_hba.conf"
else
    info "Adding entry for $WINDOWS_IP to pg_hba.conf..."
    echo "host    all             all             $WINDOWS_IP            md5" | sudo tee -a "$PG_HBA" > /dev/null
    ok "Entry added"
fi

echo ""
info "Restarting PostgreSQL to apply changes..."
sudo systemctl restart postgresql
ok "PostgreSQL restarted"

echo ""
echo "=========================================="
ok "Setup complete!"
echo "=========================================="
echo ""
echo "Power BI Connection Details:"
echo "  Server: 10.0.2.15 (or your VM IP)"
echo "  Port: 5432"
echo "  Database: your_database_name"
echo "  SSL Mode: Disable"
echo ""
echo "In Power BI connection string, use:"
echo "  Host=10.0.2.15;Port=5432;Database=your_db;sslmode=disable"
echo ""
echo "Or in Advanced Options:"
echo "  SSL Mode: Disable"
echo "  Trust Server Certificate: Yes"
echo ""
