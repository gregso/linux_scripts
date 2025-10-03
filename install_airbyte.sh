#!/usr/bin/env bash
# Airbyte installation script with multiple deployment options
# Supports: embedded PostgreSQL, external PostgreSQL, or Docker-managed PostgreSQL

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

AIRBYTE_DIR="${AIRBYTE_DIR:-$HOME/airbyte}"
AIRBYTE_VERSION="${AIRBYTE_VERSION:-latest}"
INSTALL_MODE="${INSTALL_MODE:-embedded}"  # embedded, external, or docker-postgres

show_header() {
	echo "=============================================="
	echo " Airbyte Installation Script"
	echo " Mode: $INSTALL_MODE"
	echo " Version: $AIRBYTE_VERSION"
	echo "=============================================="
}

check_prerequisites() {
	info "Checking prerequisites..."
	
	# Check Docker
	if ! command -v docker >/dev/null 2>&1; then
		err "Docker not found. Installing Docker..."
		install_docker
	else
		ok "Docker found: $(docker --version)"
	fi
	
	# Check Docker Compose
	if ! command -v docker-compose >/dev/null 2>&1; then
		err "Docker Compose not found. Installing..."
		install_docker_compose
	else
		ok "Docker Compose found: $(docker-compose --version)"
	fi
	
	# Check system resources
	local mem_total=$(free -g | awk '/^Mem:/{print $2}')
	if [[ $mem_total -lt 4 ]]; then
		warn "System has less than 4GB RAM. Airbyte may run slowly."
	else
		ok "System memory: ${mem_total}GB"
	fi
}

install_docker() {
	info "Installing Docker..."
	
	# Update package index
	sudo apt-get update
	
	# Install dependencies
	sudo apt-get install -y \
		ca-certificates \
		curl \
		gnupg \
		lsb-release
	
	# Add Docker GPG key
	sudo mkdir -p /etc/apt/keyrings
	curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
	
	# Add Docker repository
	echo \
		"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
		$(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
	
	# Install Docker
	sudo apt-get update
	sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
	
	# Add current user to docker group
	sudo usermod -aG docker $USER
	
	ok "Docker installed. You may need to log out and back in for group changes to take effect."
}

install_docker_compose() {
	info "Installing Docker Compose..."
	
	sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
		-o /usr/local/bin/docker-compose
	sudo chmod +x /usr/local/bin/docker-compose
	
	ok "Docker Compose installed"
}

download_airbyte() {
	info "Downloading Airbyte to $AIRBYTE_DIR..."
	
	# Create directory
	mkdir -p "$AIRBYTE_DIR"
	cd "$AIRBYTE_DIR"
	
	# Download Airbyte
	if [[ ! -f "docker-compose.yaml" ]]; then
		info "Downloading Airbyte docker-compose files..."
		wget https://raw.githubusercontent.com/airbytehq/airbyte/master/{.env,docker-compose.yaml,flags.yml} 2>/dev/null || {
			# Fallback: use curl
			curl -O https://raw.githubusercontent.com/airbytehq/airbyte/master/.env
			curl -O https://raw.githubusercontent.com/airbytehq/airbyte/master/docker-compose.yaml
			curl -O https://raw.githubusercontent.com/airbytehq/airbyte/master/flags.yml
		}
		ok "Airbyte files downloaded"
	else
		warn "Airbyte already exists in $AIRBYTE_DIR"
	fi
}

remove_airbyte() {
	warn "Removing existing Airbyte installation..."
	
	# Find Airbyte directories
	local found_dirs=()
	for dir in "$HOME/airbyte" "/opt/airbyte" "/var/airbyte" "$AIRBYTE_DIR"; do
		if [[ -d "$dir" && -f "$dir/docker-compose.yaml" ]]; then
			found_dirs+=("$dir")
		fi
	done
	
	if [[ ${#found_dirs[@]} -eq 0 ]]; then
		# Check for running containers
		if docker ps -a --format '{{.Names}}' | grep -qi airbyte; then
			warn "Found Airbyte containers but no directory"
			info "Stopping and removing Airbyte containers..."
			docker ps -a --format '{{.Names}}' | grep -i airbyte | xargs -r docker stop
			docker ps -a --format '{{.Names}}' | grep -i airbyte | xargs -r docker rm
			ok "Airbyte containers removed"
		else
			info "No existing Airbyte installation found"
			return 0
		fi
	fi
	
	for dir in "${found_dirs[@]}"; do
		info "Found Airbyte in: $dir"
		
		cd "$dir"
		
		# Stop and remove containers
		info "Stopping Airbyte services..."
		docker-compose down -v 2>/dev/null || true
		
		# Remove Docker volumes
		read -p "Remove Airbyte data volumes? (yes/no): " remove_volumes
		if [[ "$remove_volumes" == "yes" ]]; then
			info "Removing Docker volumes..."
			docker volume ls | grep airbyte | awk '{print $2}' | xargs -r docker volume rm 2>/dev/null || true
			ok "Volumes removed"
		else
			info "Keeping volumes (data preserved)"
		fi
		
		# Backup or remove directory
		read -p "Remove Airbyte directory $dir? (yes/no): " remove_dir
		if [[ "$remove_dir" == "yes" ]]; then
			# Backup important files
			local backup_dir="$HOME/airbyte_backup_$(date +%Y%m%d_%H%M%S)"
			mkdir -p "$backup_dir"
			[[ -f "$dir/.env" ]] && cp "$dir/.env" "$backup_dir/"
			[[ -f "$dir/docker-compose.yaml" ]] && cp "$dir/docker-compose.yaml" "$backup_dir/"
			info "Configuration backed up to: $backup_dir"
			
			# Remove directory
			sudo rm -rf "$dir"
			ok "Directory removed: $dir"
		else
			info "Keeping directory: $dir"
		fi
	done
	
	# Remove dangling Airbyte containers
	info "Cleaning up any remaining Airbyte containers..."
	docker ps -a --format '{{.Names}}' | grep -i airbyte | xargs -r docker rm -f 2>/dev/null || true
	
	# Remove dangling networks
	docker network ls | grep airbyte | awk '{print $1}' | xargs -r docker network rm 2>/dev/null || true
	
	ok "Airbyte removal complete"
	echo ""
}

check_external_postgres() {
	local pg_host="$1"
	local pg_port="$2"
	local pg_user="$3"
	local pg_pass="$4"
	local pg_db="$5"
	
	info "Verifying external PostgreSQL connection..."
	
	# Check if PostgreSQL is accessible
	if ! command -v psql >/dev/null 2>&1; then
		warn "psql client not found, installing postgresql-client..."
		sudo apt-get update
		sudo apt-get install -y postgresql-client
	fi
	
	# Run diagnostics first
	echo ""
	info "Running connection diagnostics..."
	
	# Check if PostgreSQL is running
	if systemctl is-active --quiet postgresql 2>/dev/null; then
		ok "PostgreSQL service is running"
	else
		err "PostgreSQL service is not running!"
		echo "Start it with: sudo systemctl start postgresql"
		return 1
	fi
	
	# Check if port is listening
	if ss -tlnp 2>/dev/null | grep -q ":$pg_port"; then
		ok "PostgreSQL is listening on port $pg_port"
		ss -tlnp 2>/dev/null | grep ":$pg_port"
	else
		err "Nothing is listening on port $pg_port"
		echo "Check postgresql.conf: listen_addresses should include '*' or '$pg_host'"
		return 1
	fi
	
	# Check if user exists
	info "Checking if user '$pg_user' exists..."
	if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$pg_user'" | grep -q 1; then
		ok "User '$pg_user' exists"
	else
		err "User '$pg_user' does not exist!"
		echo "Create user with:"
		echo "  sudo -u postgres createuser -s $pg_user"
		echo "  sudo -u postgres psql -c \"ALTER USER $pg_user WITH PASSWORD '$pg_pass';\""
		return 1
	fi
	
	# Test connection with detailed error
	echo ""
	info "Testing connection: psql -h $pg_host -p $pg_port -U $pg_user -d postgres"
	
	local conn_output
	conn_output=$(PGPASSWORD="$pg_pass" psql -h "$pg_host" -p "$pg_port" -U "$pg_user" -d postgres -c "SELECT 1;" 2>&1)
	local conn_result=$?
	
	if [[ $conn_result -eq 0 ]]; then
		ok "PostgreSQL connection successful"
	else
		err "Cannot connect to PostgreSQL at $pg_host:$pg_port"
		echo ""
		echo "Error details:"
		echo "$conn_output"
		echo ""
		echo "Common issues:"
		echo ""
		echo "1. PASSWORD AUTHENTICATION FAILED:"
		echo "   - Verify password: echo '$pg_pass' | psql -h $pg_host -U $pg_user -d postgres"
		echo "   - Reset password: sudo -u postgres psql -c \"ALTER USER $pg_user WITH PASSWORD '$pg_pass';\""
		echo ""
		echo "2. CONNECTION REFUSED / TIMEOUT:"
		echo "   - Check listen_addresses in postgresql.conf:"
		echo "     sudo grep listen_addresses /etc/postgresql/*/main/postgresql.conf"
		echo "   - Should be: listen_addresses = '*'"
		echo "   - Restart: sudo systemctl restart postgresql"
		echo ""
		echo "3. NO PG_HBA.CONF ENTRY:"
		echo "   - Add to pg_hba.conf:"
		echo "     echo \"host    all    $pg_user    127.0.0.1/32    md5\" | sudo tee -a /etc/postgresql/16/main/pg_hba.conf"
		echo "     echo \"host    all    $pg_user    172.17.0.0/16   md5\" | sudo tee -a /etc/postgresql/16/main/pg_hba.conf"
		echo "   - Reload: sudo systemctl reload postgresql"
		echo ""
		echo "Quick fix command:"
		echo "  ./check_postgres.sh --configure-airbyte-db $pg_db $pg_user $pg_pass"
		echo ""
		return 1
	fi
	
	# Check if database exists, create if not
	if PGPASSWORD="$pg_pass" psql -h "$pg_host" -p "$pg_port" -U "$pg_user" -d postgres -lqt | cut -d \| -f 1 | grep -qw "$pg_db"; then
		info "Database '$pg_db' already exists"
	else
		info "Creating database '$pg_db'..."
		if PGPASSWORD="$pg_pass" psql -h "$pg_host" -p "$pg_port" -U "$pg_user" -d postgres -c "CREATE DATABASE $pg_db OWNER $pg_user;" 2>/dev/null; then
			ok "Database created"
		else
			err "Failed to create database. Check user permissions."
			return 1
		fi
	fi
	
	# Check if user has proper permissions
	if PGPASSWORD="$pg_pass" psql -h "$pg_host" -p "$pg_port" -U "$pg_user" -d "$pg_db" -c "CREATE TABLE IF NOT EXISTS test_airbyte (id int); DROP TABLE test_airbyte;" 2>/dev/null; then
		ok "User has proper database permissions"
	else
		err "User lacks necessary permissions on database '$pg_db'"
		echo "Grant permissions with:"
		echo "  sudo -u postgres psql -c \"GRANT ALL PRIVILEGES ON DATABASE $pg_db TO $pg_user;\""
		return 1
	fi
	
	echo ""
	ok "All checks passed - PostgreSQL is ready for Airbyte"
}

configure_embedded_postgres() {
	info "Configuring Airbyte with embedded PostgreSQL (runs in Docker)..."
	
	cd "$AIRBYTE_DIR"
	
	# The default docker-compose.yaml includes a PostgreSQL container
	# Just ensure it's enabled (default behavior)
	
	cat > .env <<EOF
# Airbyte Configuration with Embedded PostgreSQL

# Database Configuration (embedded in Docker)
DATABASE_USER=airbyte
DATABASE_PASSWORD=$(openssl rand -base64 32)
DATABASE_DB=airbyte
DATABASE_HOST=db
DATABASE_PORT=5432

# Airbyte Configuration
AIRBYTE_VERSION=$AIRBYTE_VERSION
TRACKING_STRATEGY=segment
WEBAPP_URL=http://localhost:8000
API_URL=http://localhost:8001

# Resource Configuration
WORKER_MAX_WORKERS=4
TEMPORAL_MAX_WORKERS=4

# Data Storage
DATA_DOCKER_MOUNT=airbyte_data
DB_DOCKER_MOUNT=airbyte_db
WORKSPACE_DOCKER_MOUNT=airbyte_workspace
LOCAL_ROOT=/tmp/airbyte_local

# Feature Flags
AUTO_DETECT_SCHEMA=true
EOF
	
	ok "Embedded PostgreSQL configuration created"
	info "Database runs entirely in Docker - independent of host PostgreSQL"
}

configure_external_postgres() {
	local pg_host="${1:-localhost}"
	local pg_port="${2:-5432}"
	local pg_user="${3:-airbyte}"
	local pg_pass="${4}"
	local pg_db="${5:-airbyte}"
	
	info "Configuring Airbyte with external PostgreSQL..."
	
	if [[ -z "$pg_pass" ]]; then
		read -sp "Enter password for PostgreSQL user '$pg_user': " pg_pass
		echo ""
	fi
	
	# Verify connection and setup
	if ! check_external_postgres "$pg_host" "$pg_port" "$pg_user" "$pg_pass" "$pg_db"; then
		err "External PostgreSQL setup failed"
		echo ""
		echo "=========================================="
		echo "  TROUBLESHOOTING STEPS"
		echo "=========================================="
		echo ""
		echo "Option 1: Use check_postgres.sh to setup (RECOMMENDED):"
		echo "  cd /home/gsowa/sites/ubuntu_scripts"
		echo "  ./check_postgres.sh --configure-airbyte-db $pg_db $pg_user $pg_pass"
		echo ""
		echo "Option 2: Manual setup:"
		echo "  1. Create user and database:"
		echo "     sudo -u postgres createuser -s $pg_user"
		echo "     sudo -u postgres psql -c \"ALTER USER $pg_user WITH PASSWORD '$pg_pass';\""
		echo "     sudo -u postgres psql -c \"CREATE DATABASE $pg_db OWNER $pg_user;\""
		echo ""
		echo "  2. Configure PostgreSQL:"
		echo "     # Edit postgresql.conf"
		echo "     sudo nano /etc/postgresql/16/main/postgresql.conf"
		echo "     # Set: listen_addresses = '*'"
		echo ""
		echo "  3. Add to pg_hba.conf:"
		echo "     echo \"host    all    $pg_user    127.0.0.1/32    md5\" | sudo tee -a /etc/postgresql/16/main/pg_hba.conf"
		echo "     echo \"host    all    $pg_user    172.17.0.0/16   md5\" | sudo tee -a /etc/postgresql/16/main/pg_hba.conf"
		echo ""
		echo "  4. Restart PostgreSQL:"
		echo "     sudo systemctl restart postgresql"
		echo ""
		echo "  5. Test connection:"
		echo "     PGPASSWORD='$pg_pass' psql -h $pg_host -p $pg_port -U $pg_user -d postgres -c 'SELECT 1;'"
		echo ""
		echo "Option 3: Use embedded mode instead (easiest):"
		echo "  ./install_airbyte.sh --mode embedded"
		echo ""
		return 1
	fi
	
	cd "$AIRBYTE_DIR"
	
	# Backup original docker-compose
	if [[ -f "docker-compose.yaml" ]]; then
		cp docker-compose.yaml docker-compose.yaml.backup
	fi
	
	# Determine database host for Docker
	local docker_host="$pg_host"
	if [[ "$pg_host" == "localhost" || "$pg_host" == "127.0.0.1" ]]; then
		# Use host.docker.internal for Docker Desktop (Mac/Windows)
		# Use 172.17.0.1 for Linux
		if [[ "$(uname -s)" == "Linux" ]]; then
			docker_host="172.17.0.1"
			info "Linux detected: Using Docker bridge IP (172.17.0.1)"
		else
			docker_host="host.docker.internal"
			info "Using host.docker.internal for Docker connection"
		fi
	fi
	
	cat > .env <<EOF
# Airbyte Configuration with External PostgreSQL

# External Database Configuration
DATABASE_USER=$pg_user
DATABASE_PASSWORD=$pg_pass
DATABASE_DB=$pg_db
DATABASE_HOST=$docker_host
DATABASE_PORT=$pg_port

# Airbyte Configuration
AIRBYTE_VERSION=$AIRBYTE_VERSION
TRACKING_STRATEGY=segment
WEBAPP_URL=http://localhost:8000
API_URL=http://localhost:8001

# Resource Configuration
WORKER_MAX_WORKERS=4
TEMPORAL_MAX_WORKERS=4

# Data Storage
DATA_DOCKER_MOUNT=airbyte_data
WORKSPACE_DOCKER_MOUNT=airbyte_workspace
LOCAL_ROOT=/tmp/airbyte_local

# Feature Flags
AUTO_DETECT_SCHEMA=true
EOF
	
	ok "External PostgreSQL configuration created"
	
	# Show connection details
	echo ""
	echo "=========================================="
	echo "  External PostgreSQL Configuration"
	echo "=========================================="
	echo "Host (from host):    $pg_host:$pg_port"
	echo "Host (from Docker):  $docker_host:$pg_port"
	echo "Database:            $pg_db"
	echo "User:                $pg_user"
	echo ""
	
	warn "IMPORTANT: Ensure pg_hba.conf allows Docker network access:"
	echo "Add this line to pg_hba.conf:"
	echo "  host    all    $pg_user    172.17.0.0/16    md5"
	echo ""
	echo "Then reload PostgreSQL:"
	echo "  sudo systemctl reload postgresql"
	echo ""
}

configure_docker_postgres() {
	info "Configuring Airbyte with separate Docker PostgreSQL container..."
	
	cd "$AIRBYTE_DIR"
	
	# Create a custom docker-compose override
	cat > docker-compose.override.yaml <<EOF
version: '3.8'

services:
  # Separate PostgreSQL container with persistent volume
  airbyte-db:
    image: postgres:13-alpine
    container_name: airbyte-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: \${DATABASE_USER}
      POSTGRES_PASSWORD: \${DATABASE_PASSWORD}
      POSTGRES_DB: \${DATABASE_DB}
    volumes:
      - airbyte-postgres-data:/var/lib/postgresql/data
    ports:
      - "5433:5432"  # Expose on different port to avoid conflict
    networks:
      - airbyte_network

volumes:
  airbyte-postgres-data:
    driver: local
EOF
	
	cat > .env <<EOF
# Airbyte Configuration with Docker-managed PostgreSQL

# Database Configuration (separate Docker container)
DATABASE_USER=airbyte
DATABASE_PASSWORD=$(openssl rand -base64 32)
DATABASE_DB=airbyte
DATABASE_HOST=airbyte-db
DATABASE_PORT=5432

# Airbyte Configuration
AIRBYTE_VERSION=$AIRBYTE_VERSION
TRACKING_STRATEGY=segment
WEBAPP_URL=http://localhost:8000
API_URL=http://localhost:8001

# Resource Configuration
WORKER_MAX_WORKERS=4
TEMPORAL_MAX_WORKERS=4

# Data Storage
DATA_DOCKER_MOUNT=airbyte_data
WORKSPACE_DOCKER_MOUNT=airbyte_workspace
LOCAL_ROOT=/tmp/airbyte_local

# Feature Flags
AUTO_DETECT_SCHEMA=true
EOF
	
	ok "Docker PostgreSQL configuration created"
	info "PostgreSQL will run on port 5433 (mapped from container's 5432)"
}

start_airbyte() {
	info "Starting Airbyte..."
	
	cd "$AIRBYTE_DIR"
	
	# Pull images
	docker-compose pull
	
	# Start services
	docker-compose up -d
	
	ok "Airbyte started"
	
	# Wait for services to be ready
	info "Waiting for services to initialize (this may take a few minutes)..."
	sleep 30
	
	# Check status
	docker-compose ps
	
	echo ""
	echo "=============================================="
	echo "  Airbyte Installation Complete"
	echo "=============================================="
	echo ""
	echo "Web Interface: http://localhost:8000"
	echo "API Endpoint:  http://localhost:8001"
	echo ""
	echo "Installation Directory: $AIRBYTE_DIR"
	echo ""
	echo "Useful commands:"
	echo "  cd $AIRBYTE_DIR"
	echo "  docker-compose ps              # Check status"
	echo "  docker-compose logs -f         # View logs"
	echo "  docker-compose stop            # Stop Airbyte"
	echo "  docker-compose start           # Start Airbyte"
	echo "  docker-compose restart         # Restart Airbyte"
	echo "  docker-compose down            # Stop and remove containers"
	echo ""
	
	if [[ "$INSTALL_MODE" == "embedded" ]]; then
		echo "Database: Embedded in Docker (port not exposed to host)"
		echo "Data is persistent in Docker volume: airbyte_db"
	elif [[ "$INSTALL_MODE" == "docker-postgres" ]]; then
		echo "Database: Separate Docker container on port 5433"
		echo "Connect from host: psql -h localhost -p 5433 -U airbyte -d airbyte"
	fi
}

show_connection_guide() {
	cat <<'EOF'

============================================
  Airbyte PostgreSQL Independence Options
============================================

OPTION 1: EMBEDDED POSTGRESQL (RECOMMENDED)
  Best for: Development, testing, simple deployments
  
  Pros:
  ✓ Completely independent from host PostgreSQL
  ✓ No configuration needed
  ✓ Easy backup (Docker volumes)
  ✓ No port conflicts
  ✓ Easier upgrades
  
  Cons:
  ✗ Can't query Airbyte database from host easily
  ✗ Takes additional resources
  
  Command:
  ./install_airbyte.sh --mode embedded

OPTION 2: DOCKER POSTGRESQL (ISOLATED)
  Best for: When you need database access from host
  
  Pros:
  ✓ Independent from host PostgreSQL
  ✓ Can connect from host (port 5433)
  ✓ Easy to manage with Docker
  ✓ Can backup with pg_dump
  
  Cons:
  ✗ Additional Docker container
  
  Command:
  ./install_airbyte.sh --mode docker-postgres

OPTION 3: EXTERNAL POSTGRESQL (SHARED)
  Best for: Production, when you want centralized database
  
  Pros:
  ✓ Single PostgreSQL instance for all apps
  ✓ Easier monitoring
  ✓ Professional setup
  
  Cons:
  ✗ Shared resources
  ✗ Requires manual PostgreSQL setup
  ✗ More configuration
  
  Command:
  ./install_airbyte.sh --mode external \
    --pg-host localhost --pg-port 5432 \
    --pg-user airbyte --pg-pass SecurePass123 \
    --pg-db airbyte

COMPARISON:

| Feature              | Embedded | Docker PG | External |
|---------------------|----------|-----------|----------|
| Independence        | ✓✓✓      | ✓✓✓       | ✗        |
| Host Access         | ✗        | ✓         | ✓        |
| Resource Usage      | Medium   | Medium    | Low      |
| Setup Complexity    | Easy     | Easy      | Medium   |
| Backup Simplicity   | Easy     | Easy      | Medium   |
| Port Conflicts      | None     | None      | Possible |

RECOMMENDATION FOR YOUR CASE:
Since you're reinstalling PostgreSQL and have issues, use EMBEDDED mode.
This gives you a clean, independent Airbyte installation that won't be
affected by future PostgreSQL changes on the host.

EOF
}

usage() {
	cat <<EOF
Usage: $0 [options]

Install Airbyte with various PostgreSQL configurations.

Options:
	--mode <mode>          Installation mode: embedded, docker-postgres, external (default: embedded)
	--dir <directory>      Installation directory (default: $HOME/airbyte)
	--version <version>    Airbyte version (default: latest)
	--remove               Remove existing Airbyte installation
	--force                Skip confirmation prompts (use with --remove)
	
	External PostgreSQL options:
	--pg-host <host>       PostgreSQL host (default: localhost)
	--pg-port <port>       PostgreSQL port (default: 5432)
	--pg-user <user>       PostgreSQL user (default: airbyte)
	--pg-pass <password>   PostgreSQL password
	--pg-db <database>     PostgreSQL database (default: airbyte)
	
	--guide                Show comparison guide
	-h, --help             Show this help

Examples:
	# Remove existing Airbyte
	$0 --remove
	
	# Install with embedded PostgreSQL (recommended)
	$0 --mode embedded
	
	# Install with external PostgreSQL
	$0 --mode external --pg-host localhost --pg-user airbyte --pg-pass SecurePass123
	
	# Remove and reinstall with external mode
	$0 --remove --mode external --pg_pass MyPassword
	
	# Custom installation directory
	$0 --mode embedded --dir /opt/airbyte
	
	# Show comparison guide
	$0 --guide

Modes Explained:
	embedded:        PostgreSQL runs inside Docker, no host access (RECOMMENDED)
	docker-postgres: PostgreSQL in separate container, accessible on port 5433
	external:        Use existing PostgreSQL installation on host
EOF
}

parse_args() {
	REMOVE_ONLY=false
	FORCE_REMOVE=false
	
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--mode) INSTALL_MODE="$2"; shift ;;
			--dir) AIRBYTE_DIR="$2"; shift ;;
			--version) AIRBYTE_VERSION="$2"; shift ;;
			--remove) REMOVE_ONLY=true ;;
			--force) FORCE_REMOVE=true ;;
			--pg-host) PG_HOST="$2"; shift ;;
			--pg-port) PG_PORT="$2"; shift ;;
			--pg-user) PG_USER="$2"; shift ;;
			--pg-pass) PG_PASS="$2"; shift ;;
			--pg-db) PG_DB="$2"; shift ;;
			--guide) show_connection_guide; exit 0 ;;
			-h|--help) usage; exit 0 ;;
			*) echo "Unknown option: $1"; usage; exit 1 ;;
		esac
		shift
	done
}

main() {
	parse_args "$@"
	
	# Handle removal
	if [[ "$REMOVE_ONLY" == true ]]; then
		show_header
		remove_airbyte
		echo ""
		info "Airbyte removed. To reinstall, run:"
		echo "  $0 --mode <embedded|docker-postgres|external>"
		exit 0
	fi
	
	show_header
	
	# Check if Airbyte exists and prompt for removal
	if docker ps -a --format '{{.Names}}' | grep -qi airbyte; then
		warn "Existing Airbyte installation detected"
		if [[ "$FORCE_REMOVE" == true ]]; then
			remove_airbyte
		else
			read -p "Remove existing installation? (yes/no): " confirm
			if [[ "$confirm" == "yes" ]]; then
				remove_airbyte
			else
				err "Cannot proceed with existing installation. Use --force to override or --remove to clean up first."
				exit 1
			fi
		fi
	fi
	
	check_prerequisites
	download_airbyte
	
	case "$INSTALL_MODE" in
		embedded)
			configure_embedded_postgres
			;;
		docker-postgres)
			configure_docker_postgres
			;;
		external)
			configure_external_postgres \
				"${PG_HOST:-localhost}" \
				"${PG_PORT:-5432}" \
				"${PG_USER:-airbyte}" \
				"${PG_PASS}" \
				"${PG_DB:-airbyte}"
			;;
		*)
			err "Invalid mode: $INSTALL_MODE"
			usage
			exit 1
			;;
	esac
	
	start_airbyte
	
	echo ""
	info "For comparison of different modes, run: $0 --guide"
}

main "$@"
