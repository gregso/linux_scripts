#!/usr/bin/env bash
# PostgreSQL Complete Removal and Fresh Installation Script
# This script will completely remove PostgreSQL and reinstall it from scratch

set -euo pipefail

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_BLUE='\033[0;34m'
COLOR_RESET='\033[0m'

info()    { echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $*"; }
ok()      { echo -e "${COLOR_GREEN}[ OK ]${COLOR_RESET} $*"; }
warn()    { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*"; }
err()     { echo -e "${COLOR_RED}[FAIL]${COLOR_RESET} $*"; }

PG_VERSION="${1:-16}"  # Default to PostgreSQL 16
BACKUP_DIR="$HOME/postgres_backup_$(date +%Y%m%d_%H%M%S)"

show_header() {
    echo "=================================================="
    echo " PostgreSQL Complete Removal & Reinstallation"
    echo " Target Version: PostgreSQL $PG_VERSION"
    echo " Date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "=================================================="
    echo ""
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "This script must be run as root or with sudo"
        exit 1
    fi
}

backup_databases() {
    warn "Step 1: Backing up existing databases..."
    
    if ! command -v pg_dumpall >/dev/null 2>&1; then
        warn "PostgreSQL not installed or pg_dumpall not available. Skipping backup."
        return 0
    fi
    
    if ! systemctl is-active --quiet postgresql 2>/dev/null; then
        warn "PostgreSQL service not running. Attempting to start..."
        systemctl start postgresql 2>/dev/null || true
        sleep 2
    fi
    
    mkdir -p "$BACKUP_DIR"
    
    # Try to backup all databases
    if sudo -u postgres pg_dumpall > "$BACKUP_DIR/all_databases.sql" 2>/dev/null; then
        ok "Database backup created: $BACKUP_DIR/all_databases.sql"
        
        # Also backup individual databases
        sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -v -e template -e postgres -e '^\s*$' | while read -r db; do
            db_clean=$(echo "$db" | xargs)
            if [[ -n "$db_clean" ]]; then
                info "Backing up database: $db_clean"
                sudo -u postgres pg_dump "$db_clean" > "$BACKUP_DIR/${db_clean}_backup.sql" 2>/dev/null || true
            fi
        done
        
        # Backup configuration files
        if [[ -d /etc/postgresql ]]; then
            info "Backing up configuration files..."
            cp -r /etc/postgresql "$BACKUP_DIR/config_backup" 2>/dev/null || true
            ok "Configuration backed up to: $BACKUP_DIR/config_backup"
        fi
    else
        warn "Could not backup databases. Continuing anyway..."
    fi
    
    echo ""
    ok "Backup location: $BACKUP_DIR"
    echo "To restore later, use: sudo -u postgres psql < $BACKUP_DIR/all_databases.sql"
    echo ""
}

stop_postgresql() {
    warn "Step 2: Stopping PostgreSQL services..."
    
    # Stop all PostgreSQL services
    systemctl stop postgresql 2>/dev/null || true
    systemctl stop postgresql@*.service 2>/dev/null || true
    
    # Stop all clusters
    if command -v pg_ctlcluster >/dev/null 2>&1; then
        pg_lsclusters -h | while read -r version cluster rest; do
            info "Stopping cluster: $version/$cluster"
            pg_ctlcluster "$version" "$cluster" stop 2>/dev/null || true
        done
    fi
    
    # Kill any remaining postgres processes
    pkill -9 postgres 2>/dev/null || true
    
    sleep 2
    ok "PostgreSQL services stopped"
}

remove_postgresql() {
    warn "Step 3: Removing PostgreSQL packages..."
    
    # Remove all PostgreSQL packages
    apt-get --purge remove -y postgresql\* 2>/dev/null || true
    apt-get --purge remove -y postgres\* 2>/dev/null || true
    
    # Remove specific common versions
    for ver in 12 13 14 15 16 17; do
        apt-get --purge remove -y \
            postgresql-$ver \
            postgresql-client-$ver \
            postgresql-contrib-$ver \
            postgresql-server-dev-$ver 2>/dev/null || true
    done
    
    # Remove postgresql-common
    apt-get --purge remove -y postgresql-common 2>/dev/null || true
    
    # Autoremove dependencies
    apt-get autoremove -y 2>/dev/null || true
    
    ok "PostgreSQL packages removed"
}

remove_data_directories() {
    warn "Step 4: Removing data directories and configuration..."
    
    # Remove data directories
    local dirs_to_remove=(
        "/var/lib/postgresql"
        "/etc/postgresql"
        "/var/log/postgresql"
        "/var/run/postgresql"
        "/run/postgresql"
        "/usr/share/postgresql"
        "/usr/lib/postgresql"
    )
    
    for dir in "${dirs_to_remove[@]}"; do
        if [[ -d "$dir" ]]; then
            info "Removing: $dir"
            rm -rf "$dir"
        fi
    done
    
    # Remove postgres user (optional - commented out by default)
    # userdel -r postgres 2>/dev/null || true
    
    ok "Data directories removed"
}

clean_apt_cache() {
    warn "Step 5: Cleaning APT cache..."
    
    apt-get clean
    apt-get autoclean
    
    ok "APT cache cleaned"
}

install_postgresql() {
    warn "Step 6: Installing PostgreSQL $PG_VERSION..."
    
    # Update package list
    info "Updating package list..."
    apt-get update
    
    # Install PostgreSQL
    info "Installing postgresql-$PG_VERSION..."
    apt-get install -y \
        postgresql-$PG_VERSION \
        postgresql-client-$PG_VERSION \
        postgresql-contrib-$PG_VERSION
    
    ok "PostgreSQL $PG_VERSION installed"
}

configure_postgresql() {
    warn "Step 7: Configuring PostgreSQL..."
    
    # Wait for PostgreSQL to start
    sleep 3
    
    # Ensure service is running
    systemctl enable postgresql
    systemctl start postgresql
    
    sleep 2
    
    if systemctl is-active --quiet postgresql; then
        ok "PostgreSQL service is running"
    else
        err "PostgreSQL service failed to start"
        systemctl status postgresql
        exit 1
    fi
    
    # Find the main postgresql.conf
    local conf_file=$(find /etc/postgresql/$PG_VERSION -name postgresql.conf 2>/dev/null | head -1)
    
    if [[ -n "$conf_file" ]]; then
        info "Configuration file: $conf_file"
        
        # Enable remote connections (listen on all interfaces)
        if grep -q "^listen_addresses" "$conf_file"; then
            sed -i "s/^listen_addresses.*/listen_addresses = '*'/" "$conf_file"
        else
            echo "listen_addresses = '*'" >> "$conf_file"
        fi
        
        ok "Configured to listen on all interfaces"
        
        # Find pg_hba.conf
        local hba_file=$(find /etc/postgresql/$PG_VERSION -name pg_hba.conf 2>/dev/null | head -1)
        
        if [[ -n "$hba_file" ]]; then
            info "Adding trust authentication for local connections..."
            
            # Backup original
            cp "$hba_file" "${hba_file}.backup"
            
            # Add trust for local connections at the top
            {
                echo "# Trust authentication for local connections (added by reinstall script)"
                echo "local   all             all                                     trust"
                echo "host    all             all             127.0.0.1/32            trust"
                echo "host    all             all             ::1/128                 trust"
                echo ""
            } > "${hba_file}.new"
            
            # Append original content (but skip existing local/host entries to avoid duplicates)
            grep -v "^local.*all.*all" "$hba_file" | \
            grep -v "^host.*all.*all.*127.0.0.1" | \
            grep -v "^host.*all.*all.*::1" >> "${hba_file}.new"
            
            mv "${hba_file}.new" "$hba_file"
            
            ok "pg_hba.conf configured for trust authentication"
        fi
        
        # Reload configuration
        systemctl reload postgresql
        
        ok "Configuration reloaded"
    fi
}

create_user_and_database() {
    warn "Step 8: Creating user and test database..."
    
    local current_user="${SUDO_USER:-$USER}"
    
    # Create a user matching the current system user
    if [[ -n "$current_user" ]] && [[ "$current_user" != "root" ]]; then
        info "Creating PostgreSQL user: $current_user"
        sudo -u postgres createuser -s "$current_user" 2>/dev/null || warn "User $current_user already exists or creation failed"
        
        info "Creating database: $current_user"
        sudo -u postgres createdb "$current_user" 2>/dev/null || warn "Database $current_user already exists or creation failed"
    fi
    
    # Create a test database
    info "Creating test database: testdb"
    sudo -u postgres createdb testdb 2>/dev/null || warn "Database testdb already exists or creation failed"
    
    ok "User and databases created"
}

test_installation() {
    warn "Step 9: Testing installation..."
    
    # Test connection as postgres user
    if sudo -u postgres psql -c "SELECT version();" >/dev/null 2>&1; then
        ok "PostgreSQL is working correctly"
        
        info "PostgreSQL version:"
        sudo -u postgres psql -c "SELECT version();"
        
        echo ""
        info "Available databases:"
        sudo -u postgres psql -l
    else
        err "PostgreSQL connection test failed"
        exit 1
    fi
}

show_summary() {
    echo ""
    echo "=================================================="
    echo " Installation Complete!"
    echo "=================================================="
    echo ""
    ok "PostgreSQL $PG_VERSION has been successfully installed"
    echo ""
    echo "Backup location: $BACKUP_DIR"
    echo ""
    echo "Connection details:"
    echo "  Host:     localhost (127.0.0.1)"
    echo "  Port:     5432"
    echo "  Admin:    postgres (no password required locally)"
    echo ""
    echo "Quick commands:"
    echo "  Connect as postgres:  sudo -u postgres psql"
    echo "  Connect as your user: psql"
    echo "  Check status:         systemctl status postgresql"
    echo "  Check clusters:       pg_lsclusters"
    echo ""
    echo "To restore your backed up data:"
    echo "  sudo -u postgres psql < $BACKUP_DIR/all_databases.sql"
    echo ""
    echo "For diagnostics, run:"
    echo "  ./check_postgres.sh"
    echo ""
}

ask_confirmation() {
    warn "WARNING: This will completely remove PostgreSQL and all data!"
    warn "A backup will be created at: $BACKUP_DIR"
    echo ""
    read -p "Do you want to continue? (yes/no): " confirm
    
    if [[ "$confirm" != "yes" ]]; then
        info "Aborted by user"
        exit 0
    fi
}

# ===== MAIN EXECUTION =====

show_header

if [[ "$*" == *"--help"* ]] || [[ "$*" == *"-h"* ]]; then
    cat <<EOF
Usage: sudo $0 [VERSION]

Completely removes PostgreSQL and reinstalls it from scratch.

Arguments:
  VERSION    PostgreSQL version to install (default: 16)
             Examples: 14, 15, 16

Options:
  --help, -h    Show this help message
  --skip-backup Don't create a backup
  --yes, -y     Skip confirmation prompt

Examples:
  sudo $0              # Install PostgreSQL 16
  sudo $0 15           # Install PostgreSQL 15
  sudo $0 --yes        # Install without confirmation

After installation:
  - PostgreSQL will be running on port 5432
  - Local connections will use trust authentication (no password)
  - Your databases will be backed up in ~/postgres_backup_*
  
To restore data after installation:
  sudo -u postgres psql < ~/postgres_backup_*/all_databases.sql

EOF
    exit 0
fi

# Parse arguments
SKIP_BACKUP=false
AUTO_YES=false

for arg in "$@"; do
    case "$arg" in
        --skip-backup)
            SKIP_BACKUP=true
            ;;
        --yes|-y)
            AUTO_YES=true
            ;;
        [0-9]*)
            PG_VERSION="$arg"
            ;;
    esac
done

# Check if running as root
check_root

# Ask for confirmation unless --yes flag is provided
if [[ "$AUTO_YES" != true ]]; then
    ask_confirmation
fi

# Execute installation steps
if [[ "$SKIP_BACKUP" != true ]]; then
    backup_databases
fi

stop_postgresql
remove_postgresql
remove_data_directories
clean_apt_cache
install_postgresql
configure_postgresql
create_user_and_database
test_installation
show_summary

echo ""
ok "All done! PostgreSQL $PG_VERSION is ready to use."
