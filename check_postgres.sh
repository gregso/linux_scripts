#!/usr/bin/env bash
# Comprehensive PostgreSQL diagnostic & helper script
# Purpose: help determine why connections to 127.0.0.1:5432 are refused.
# Safe to run multiple times; does not modify data unless you pass --install.

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

show_header() {
	echo "==============================================="
	echo " PostgreSQL Diagnostic $(date '+%Y-%m-%d %H:%M:%S')"
	echo "==============================================="
}

need_root_actions=false

# Default connection parameters (override via flags or env)
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-5432}"
USER="${USER:-postgres}"
DB="${DB:-postgres}"
PG_VERSION="${PG_VERSION:-16}"
NEW_PASSWORD=""
REMOTE_IP=""

# Will accumulate notes (best-effort)
declare -a FOUND_PORTS=()

check_service() {
	echo "\n--- Service Presence & Status ---"
	if systemctl list-unit-files | grep -q '^postgresql\.service'; then
		ok "postgresql.service unit exists"
		if systemctl is-active --quiet postgresql; then
			ok "Service state: active"
		else
			warn "Service state: $(systemctl is-active postgresql || true)"
			need_root_actions=true
		fi
		info "systemd status (short):"
		systemctl status postgresql --no-pager -l | sed -n '1,25p'
	else
		warn "No systemd unit 'postgresql.service' found (maybe not installed or using Docker)."
	fi
}

check_binaries() {
	echo "\n--- Client / Server Binaries ---"
	if command -v psql >/dev/null 2>&1; then
		ok "psql found: $(psql --version)"
	else
		warn "psql not found in PATH"
	fi
	if command -v postgres >/dev/null 2>&1; then
		ok "postgres binary present: $(postgres --version)"
	else
		warn "postgres server binary not found"
	fi
}

check_port() {
	echo "\n--- Port 5432 Listeners ---"
	if ss -tnlp 2>/dev/null | grep -q ':5432'; then
		ok "Something is listening on 5432"
		ss -tnlp | grep ':5432'
	else
		warn "Nothing listening on TCP 5432"
	fi
	if command -v lsof >/dev/null 2>&1; then
		lsof -nP -iTCP:5432 -sTCP:LISTEN || true
	fi
}

check_unix_socket() {
	echo "\n--- Unix Domain Socket (local connections) ---"
	# Common directories
	for d in /var/run/postgresql /run/postgresql; do
		if [[ -d $d ]]; then
			info "Checking $d"
			ls -l $d || true
			if compgen -G "$d/.s.PGSQL.5432" > /dev/null; then
				ok "Socket file exists: $d/.s.PGSQL.5432"
			fi
		fi
	done
}

check_clusters() {
	echo "\n--- Cluster Definitions (Debian/Ubuntu) ---"
	if command -v pg_lsclusters >/dev/null 2>&1; then
		pg_lsclusters || true
	else
		info "pg_lsclusters not available (package 'postgresql-common' provides it)."
	fi
}

detect_ports() {
	# Collect listening postgres ports (tcp)
	while read -r line; do
		p=$(awk '{print $4}' <<<"$line" | sed -E 's/.*:([0-9]+)$/\1/')
		cmd=$(awk -F'"' '{print $2}' <<<"$line")
		[[ -n "$p" ]] && [[ "$cmd" =~ postgres ]] && FOUND_PORTS+=("$p")
	done < <(ss -tnlp 2>/dev/null | grep -i postgres || true)

	# From running postmaster pid files (socket ports may differ)
	while read -r conf; do
		grep -E '^[[:space:]]*port[[:space:]]*=' "$conf" 2>/dev/null | \
			sed -E 's/.*port[[:space:]]*=[[:space:]]*([0-9]+).*/\1/' | while read -r cp; do
				[[ -n "$cp" ]] && FOUND_PORTS+=("$cp")
			done
	done < <(find /etc/postgresql -maxdepth 3 -name postgresql.conf 2>/dev/null || true)

	# Unique
	if [[ ${#FOUND_PORTS[@]} -gt 0 ]]; then
		mapfile -t FOUND_PORTS < <(printf "%s\n" "${FOUND_PORTS[@]}" | sort -u)
	fi
}

print_connect_help() {
	echo -e "\n--- Connection Helper ---"
	echo "Current target: host=$HOST port=$PORT user=$USER db=$DB"
	echo "Try:"
	echo "  psql -h $HOST -p $PORT -U $USER -d $DB"
	echo "Socket variants (if enabled):"
	for sockdir in /run/postgresql /var/run/postgresql /tmp; do
		if [[ -S $sockdir/.s.PGSQL.$PORT ]]; then
			echo "  psql -h $sockdir -p $PORT -U $USER -d $DB"
		fi
	done
	if [[ -f $HOME/.pg_service.conf ]]; then
		echo "Service file detected (~/.pg_service.conf); you may use: psql service=<name>"
	fi
	if [[ ${#FOUND_PORTS[@]} -gt 0 ]]; then
		echo "Discovered postgres-related ports: ${FOUND_PORTS[*]}"
	fi
}

attempt_connect() {
	echo "\n--- Connection Test (configurable) ---"
	if command -v pg_isready >/dev/null 2>&1; then
		pg_isready -h "$HOST" -p "$PORT" -U "$USER" || true
	fi
	if command -v psql >/dev/null 2>&1; then
		# TCP attempt
		if ! psql -h "$HOST" -p "$PORT" -U "$USER" -d "$DB" -c 'SELECT 1;' -v ON_ERROR_STOP=1 2>&1 | head -n 4; then
			warn "TCP connect failed (host=$HOST port=$PORT user=$USER db=$DB)"
		else
			ok "TCP query succeeded"
		fi
		# Socket attempt (only if host looked like 127.* or localhost)
		for sockdir in /run/postgresql /var/run/postgresql /tmp; do
			if [[ -S $sockdir/.s.PGSQL.$PORT ]]; then
				if psql -h "$sockdir" -p "$PORT" -U "$USER" -d "$DB" -c 'SELECT 1;' -v ON_ERROR_STOP=1 >/dev/null 2>&1; then
					ok "Socket connect succeeded via $sockdir/.s.PGSQL.$PORT"
					break
				fi
			fi
		done
	fi
	print_connect_help
}

show_logs_hint() {
	echo "\n--- Logs Hint ---"
	if systemctl list-unit-files | grep -q '^postgresql\.service'; then
		info "Recent journal entries:"
		journalctl -u postgresql -n 30 --no-pager 2>/dev/null || true
	fi
	# Typical Debian log directory
	if [[ -d /var/log/postgresql ]]; then
		info "Tail of /var/log/postgresql:"
		tail -n 20 /var/log/postgresql/*.log 2>/dev/null || true
	fi
}

fix_authentication() {
	warn "Fixing PostgreSQL authentication..."
	
	# Find pg_hba.conf
	local hba_conf=""
	for conf in /etc/postgresql/*/main/pg_hba.conf /etc/postgresql/*/*/pg_hba.conf; do
		if [[ -f "$conf" ]]; then
			hba_conf="$conf"
			break
		fi
	done
	
	if [[ -z "$hba_conf" ]]; then
		err "Could not find pg_hba.conf"
		return 1
	fi
	
	info "Found pg_hba.conf: $hba_conf"
	
	# Backup original
	sudo cp "$hba_conf" "${hba_conf}.backup.$(date +%s)"
	ok "Backup created: ${hba_conf}.backup.*"
	
	# Update pg_hba.conf to allow local connections
	info "Updating pg_hba.conf for local trust authentication..."
	sudo tee "$hba_conf" > /dev/null <<'EOF'
# PostgreSQL Client Authentication Configuration File
# TYPE  DATABASE        USER            ADDRESS                 METHOD

# "local" is for Unix domain socket connections only
local   all             all                                     peer

# IPv4 local connections:
host    all             all             127.0.0.1/32            trust
host    all             all             ::1/128                 trust

# Allow replication connections
local   replication     all                                     peer
host    replication     all             127.0.0.1/32            trust
host    replication     all             ::1/128                 trust
EOF
	
	ok "pg_hba.conf updated with trust authentication for localhost"
	
	# Find postgresql.conf to ensure listening on localhost
	local pg_conf="${hba_conf/pg_hba.conf/postgresql.conf}"
	if [[ -f "$pg_conf" ]]; then
		if ! grep -q "^listen_addresses.*=.*'localhost'" "$pg_conf"; then
			info "Ensuring listen_addresses includes localhost..."
			sudo sed -i "s/^#*listen_addresses.*/listen_addresses = 'localhost'/" "$pg_conf"
		fi
	fi
	
	# Reload configuration
	info "Reloading PostgreSQL configuration..."
	sudo systemctl reload postgresql || sudo systemctl restart postgresql
	
	ok "Authentication fixed - localhost connections now use 'trust' method"
	warn "This allows passwordless access from localhost. For production, use md5/scram-sha-256 with passwords."
	
	# Set password if requested
	if [[ -n "$NEW_PASSWORD" ]]; then
		info "Setting password for user $USER..."
		sudo -u postgres psql -c "ALTER USER $USER WITH PASSWORD '$NEW_PASSWORD';" 2>/dev/null
		ok "Password set for user $USER"
		
		# Update to md5 authentication
		info "Switching to md5 authentication..."
		sudo sed -i 's/trust$/md5/' "$hba_conf"
		sudo systemctl reload postgresql
		ok "Authentication method changed to md5"
	fi
	
	echo ""
	info "Testing connection now..."
	sleep 2
	psql -h 127.0.0.1 -p 5432 -U "$USER" -d postgres -c "SELECT 'Authentication working!' as status;"
}

reset_postgres_password() {
	warn "Resetting postgres user password..."
	
	# First ensure trust auth temporarily
	local hba_conf=""
	for conf in /etc/postgresql/*/main/pg_hba.conf /etc/postgresql/*/*/pg_hba.conf; do
		if [[ -f "$conf" ]]; then
			hba_conf="$conf"
			break
		fi
	done
	
	if [[ -z "$hba_conf" ]]; then
		err "Could not find pg_hba.conf"
		return 1
	fi
	
	# Backup and set trust temporarily
	sudo cp "$hba_conf" "${hba_conf}.backup.$(date +%s)"
	sudo sed -i.tmp 's/\(host.*127\.0\.0\.1.*\)md5/\1trust/' "$hba_conf"
	sudo sed -i 's/\(host.*127\.0\.0\.1.*\)scram-sha-256/\1trust/' "$hba_conf"
	sudo systemctl reload postgresql
	
	sleep 2
	
	# Set new password
	if [[ -z "$NEW_PASSWORD" ]]; then
		read -sp "Enter new password for postgres user: " NEW_PASSWORD
		echo ""
	fi
	
	sudo -u postgres psql -h 127.0.0.1 -c "ALTER USER postgres WITH PASSWORD '$NEW_PASSWORD';" 2>/dev/null
	ok "Password updated for postgres user"
	
	# Restore md5/scram
	sudo mv "${hba_conf}.tmp" "$hba_conf" 2>/dev/null || true
	sudo sed -i 's/\(host.*127\.0\.0\.1.*\)trust/\1md5/' "$hba_conf"
	sudo systemctl reload postgresql
	
	ok "Authentication restored. Test with: psql -h 127.0.0.1 -U postgres"
	info "Password: $NEW_PASSWORD"
}

show_auth_config() {
	echo -e "\n--- Current Authentication Configuration ---"
	for hba in /etc/postgresql/*/main/pg_hba.conf /etc/postgresql/*/*/pg_hba.conf; do
		if [[ -f "$hba" ]]; then
			info "File: $hba"
			grep -v '^#' "$hba" | grep -v '^$' || true
			echo ""
		fi
	done
}

check_network_config() {
	echo -e "\n--- Network Configuration (VM Setup) ---"
	
	# Get VM IP addresses
	info "VM IP addresses:"
	ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.' || warn "No non-localhost IPs found"
	
	# Detect VirtualBox NAT
	if ip route | grep -q "10.0.2.2"; then
		info "VirtualBox NAT detected (default gateway: 10.0.2.2)"
		warn "For NAT, you need port forwarding in VirtualBox settings"
		echo "   VirtualBox → VM Settings → Network → Port Forwarding"
		echo "   Rule: Host Port 5432 → Guest Port 5432"
	fi
	
	# Check if listening on all interfaces
	info "PostgreSQL listening addresses:"
	for conf in /etc/postgresql/*/main/postgresql.conf /etc/postgresql/*/*/postgresql.conf; do
		if [[ -f "$conf" ]]; then
			grep "^listen_addresses" "$conf" || grep "^#listen_addresses" "$conf" | head -1
		fi
	done
	
	# Check firewall
	echo ""
	info "Firewall status:"
	if command -v ufw >/dev/null 2>&1; then
		sudo ufw status | grep -E "5432|Status:" || true
	fi
	
	if command -v firewall-cmd >/dev/null 2>&1; then
		sudo firewall-cmd --list-ports 2>/dev/null || true
	fi
	
	# Check what's actually listening
	echo ""
	info "PostgreSQL network listeners:"
	ss -tlnp 2>/dev/null | grep postgres || warn "No postgres listeners found"
}

configure_remote_access() {
	warn "Configuring PostgreSQL for remote access from Windows host..."
	
	# Find configs
	local hba_conf=""
	local pg_conf=""
	for conf in /etc/postgresql/*/main/pg_hba.conf /etc/postgresql/*/*/pg_hba.conf; do
		if [[ -f "$conf" ]]; then
			hba_conf="$conf"
			pg_conf="${conf/pg_hba.conf/postgresql.conf}"
			break
		fi
	done
	
	if [[ -z "$hba_conf" ]]; then
		err "Could not find pg_hba.conf"
		return 1
	fi
	
	# Backup configs
	sudo cp "$hba_conf" "${hba_conf}.backup.$(date +%s)"
	sudo cp "$pg_conf" "${pg_conf}.backup.$(date +%s)"
	ok "Backups created"
	
	# Get VM IP for reference
	local vm_ip=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.' | head -1)
	info "VM IP detected: ${vm_ip:-none}"
	
	# Configure postgresql.conf to listen on all interfaces
	info "Configuring postgresql.conf to listen on all interfaces..."
	sudo sed -i "s/^#*listen_addresses.*/listen_addresses = '*'/" "$pg_conf"
	ok "listen_addresses set to '*'"
	
	# Add remote access to pg_hba.conf
	info "Adding remote access rules to pg_hba.conf..."
	
	if [[ -n "$REMOTE_IP" ]]; then
		# Specific IP provided
		echo "" | sudo tee -a "$hba_conf" >/dev/null
		echo "# Remote access from Windows host" | sudo tee -a "$hba_conf" >/dev/null
		echo "host    all             all             ${REMOTE_IP}/32            md5" | sudo tee -a "$hba_conf" >/dev/null
		ok "Added access rule for ${REMOTE_IP}"
	else
		# Allow from common VirtualBox networks
		echo "" | sudo tee -a "$hba_conf" >/dev/null
		echo "# Remote access from VirtualBox host networks" | sudo tee -a "$hba_conf" >/dev/null
		echo "host    all             all             192.168.56.0/24         md5" | sudo tee -a "$hba_conf" >/dev/null
		echo "host    all             all             10.0.2.0/24             md5" | sudo tee -a "$hba_conf" >/dev/null
		ok "Added access rules for VirtualBox default networks"
	fi
	
	# Configure firewall
	info "Configuring firewall..."
	if command -v ufw >/dev/null 2>&1; then
		sudo ufw allow 5432/tcp 2>/dev/null || true
		ok "UFW rule added for port 5432"
	fi
	
	# Restart PostgreSQL
	info "Restarting PostgreSQL to apply changes..."
	sudo systemctl restart postgresql
	sleep 2
	
	ok "PostgreSQL configured for remote access"
	
	# Show connection info
	echo ""
	echo "=========================================="
	echo "  Remote Connection Information"
	echo "=========================================="
	echo "From your Windows machine, use:"
	echo ""
	echo "Connection string:"
	echo "  Host: ${vm_ip:-<VM_IP>}"
	echo "  Port: 5432"
	echo "  User: postgres"
	echo "  Database: postgres"
	echo ""
	echo "psql command:"
	echo "  psql -h ${vm_ip:-<VM_IP>} -p 5432 -U postgres -d postgres"
	echo ""
	echo "pgAdmin / DBeaver / HeidiSQL:"
	echo "  Host: ${vm_ip:-<VM_IP>}"
	echo "  Port: 5432"
	echo "  Username: postgres"
	echo "  Password: (set with --set-password)"
	echo ""
	echo "JDBC URL:"
	echo "  jdbc:postgresql://${vm_ip:-<VM_IP>}:5432/postgres"
	echo ""
	warn "Make sure you have set a password: $0 --reset-password"
}

test_remote_connection() {
	echo -e "\n--- Testing Remote Connection ---"
	
	# Get all non-localhost IPs
	local ips=($(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.'))
	
	if [[ ${#ips[@]} -eq 0 ]]; then
		warn "No external IP addresses found on this VM"
		return 1
	fi
	
	info "Testing PostgreSQL accessibility from network IPs..."
	
	for ip in "${ips[@]}"; do
		echo ""
		info "Testing connection to $ip:5432..."
		
		# Test with pg_isready
		if command -v pg_isready >/dev/null 2>&1; then
			if pg_isready -h "$ip" -p 5432 2>/dev/null; then
				ok "pg_isready: $ip:5432 is accepting connections"
			else
				warn "pg_isready: $ip:5432 connection failed"
			fi
		fi
		
		# Test with nc/netcat
		if command -v nc >/dev/null 2>&1; then
			if timeout 2 nc -zv "$ip" 5432 2>&1 | grep -q succeeded; then
				ok "Port 5432 is open on $ip"
			else
				warn "Port 5432 not accessible on $ip"
			fi
		fi
		
		# Test with psql
		if command -v psql >/dev/null 2>&1; then
			if psql -h "$ip" -U postgres -c "SELECT 'Remote connection OK' as status;" 2>/dev/null | grep -q "Remote connection OK"; then
				ok "psql: Successfully connected to $ip:5432"
			else
				warn "psql: Connection to $ip:5432 requires password or failed"
			fi
		fi
	done
	
	echo ""
	info "Connection test complete. If all tests failed, check:"
	echo "  1. Run: $0 --enable-remote"
	echo "  2. Ensure VirtualBox network is bridged or host-only"
	echo "  3. Verify Windows firewall allows outbound to port 5432"
}

show_windows_guide() {
	cat <<'EOF'

========================================
  Windows Connection Guide
========================================

1. FIND YOUR VM IP (run in Ubuntu VM):
   hostname -I
   # or
   ip addr show

2. TEST FROM WINDOWS (PowerShell):
   Test-NetConnection -ComputerName <VM_IP> -Port 5432
   # Should show "TcpTestSucceeded : True"

3. INSTALL PostgreSQL CLIENT ON WINDOWS:
   Option A: Download from https://www.postgresql.org/download/windows/
   Option B: Use Chocolatey: choco install postgresql
   Option C: Use pgAdmin: https://www.pgadmin.org/download/

4. CONNECT FROM WINDOWS:
   psql -h <VM_IP> -p 5432 -U postgres -d postgres

5. VIRTUALBOX NETWORK SETTINGS:
   For VirtualBox, you need either:
   
   Option A - Port Forwarding (NAT) - EASIEST:
   - VirtualBox → Settings → Network → Adapter 1 (NAT)
   - Advanced → Port Forwarding → Add rule (+)
   - Name: PostgreSQL
   - Protocol: TCP
   - Host IP: 127.0.0.1
   - Host Port: 5432
   - Guest IP: (leave empty)
   - Guest Port: 5432
   - Connect from Windows: psql -h localhost -p 5432 -U postgres
   
   Option B - Host-Only Network:
   - VirtualBox → Settings → Network → Adapter 2
   - Enable Network Adapter
   - Attached to: Host-only Adapter
   - Name: VirtualBox Host-Only Ethernet Adapter
   - VM will get IP like 192.168.56.x
   - Connect from Windows: psql -h 192.168.56.x -p 5432 -U postgres
   
   Option C - Bridged Adapter:
   - VirtualBox → Settings → Network → Adapter 1
   - Attached to: Bridged Adapter
   - Name: Your physical network adapter
   - VM will get IP from your router (192.168.1.x or similar)
   - Connect from Windows: psql -h 192.168.1.x -p 5432 -U postgres

6. IF USING NAT WITH PORT FORWARDING:
   Your Test-NetConnection showed TcpTestSucceeded: True ✓
   This means port forwarding is configured correctly!
   
   Now just connect with password:
   psql -h localhost -p 5432 -U postgres -d postgres
   
   Or use connection string:
   postgresql://postgres:YOUR_PASSWORD@localhost:5432/postgres

7. TROUBLESHOOTING:
   - Ping from Windows: ping <VM_IP>
   - Check VM firewall: sudo ufw status
   - Check PostgreSQL logs: journalctl -u postgresql -n 50
   - Verify listen_addresses = '*' in postgresql.conf
   - In VM, check: ss -tlnp | grep 5432
   - Ensure postgres user has password set

EOF
}

test_nat_forwarding() {
	echo -e "\n--- Testing NAT Port Forwarding ---"
	
	# Check if we're on NAT network
	if ! ip route | grep -q "10.0.2.2"; then
		info "Not on VirtualBox NAT network, skipping NAT tests"
		return 0
	fi
	
	ok "VirtualBox NAT detected"
	
	# Check if PostgreSQL is listening on 0.0.0.0 (all interfaces)
	if ss -tlnp 2>/dev/null | grep -q "0.0.0.0:5432"; then
		ok "PostgreSQL listening on all interfaces (0.0.0.0:5432)"
	else
		warn "PostgreSQL not listening on 0.0.0.0"
		warn "For NAT port forwarding, PostgreSQL must listen on all interfaces"
		echo "Fix: Set listen_addresses = '*' in postgresql.conf"
		return 1
	fi
	
	# Check if we can connect locally
	if command -v psql >/dev/null 2>&1; then
		if psql -h 10.0.2.15 -U postgres -c "SELECT 1;" >/dev/null 2>&1; then
			ok "Local connection to VM IP successful"
		else
			warn "Cannot connect to VM IP (10.0.2.15) - may need password"
		fi
	fi
	
	echo ""
	info "From Windows PowerShell, verify port forwarding:"
	echo "  Test-NetConnection -ComputerName localhost -Port 5432"
	echo ""
	info "If TcpTestSucceeded: True, connect with:"
	echo "  psql -h localhost -p 5432 -U postgres -d postgres"
}

configure_for_nat() {
	warn "Configuring PostgreSQL for VirtualBox NAT with port forwarding..."
	
	# Find configs
	local hba_conf=""
	local pg_conf=""
	for conf in /etc/postgresql/*/main/pg_hba.conf /etc/postgresql/*/*/pg_hba.conf; do
		if [[ -f "$conf" ]]; then
			hba_conf="$conf"
			pg_conf="${conf/pg_hba.conf/postgresql.conf}"
			break
		fi
	done
	
	if [[ -z "$hba_conf" ]]; then
		err "Could not find pg_hba.conf"
		return 1
	fi
	
	# Backup configs
	sudo cp "$hba_conf" "${hba_conf}.backup.$(date +%s)"
	sudo cp "$pg_conf" "${pg_conf}.backup.$(date +%s)"
	ok "Backups created"
	
	# Configure postgresql.conf to listen on all interfaces
	info "Configuring postgresql.conf to listen on all interfaces..."
	sudo sed -i "s/^#*listen_addresses.*/listen_addresses = '*'/" "$pg_conf"
	ok "listen_addresses set to '*'"
	
	# Add access rule for NAT gateway
	info "Adding pg_hba.conf rules for NAT access..."
	echo "" | sudo tee -a "$hba_conf" >/dev/null
	echo "# VirtualBox NAT port forwarding" | sudo tee -a "$hba_conf" >/dev/null
	echo "host    all             all             10.0.2.2/32             md5" | sudo tee -a "$hba_conf" >/dev/null
	echo "host    all             all             127.0.0.1/32            md5" | sudo tee -a "$hba_conf" >/dev/null
	ok "pg_hba.conf updated for NAT"
	
	# Restart PostgreSQL
	info "Restarting PostgreSQL..."
	sudo systemctl restart postgresql
	sleep 2
	
	ok "PostgreSQL configured for NAT port forwarding"
	
	echo ""
	echo "=========================================="
	echo "  NAT Port Forwarding Setup"
	echo "=========================================="
	echo "1. In VirtualBox:"
	echo "   → Settings → Network → Adapter 1 (NAT)"
	echo "   → Advanced → Port Forwarding"
	echo "   → Add rule: Host Port 5432 → Guest Port 5432"
	echo ""
	echo "2. From Windows PowerShell, test:"
	echo "   Test-NetConnection -ComputerName localhost -Port 5432"
	echo ""
	echo "3. Connect from Windows:"
	echo "   psql -h localhost -p 5432 -U postgres -d postgres"
	echo ""
	warn "Make sure postgres user has a password!"
	echo "Set password: $0 --reset-password"
}

show_powerbi_guide() {
	cat <<'EOF'

========================================
  Power BI PostgreSQL Connection Guide
========================================

YOUR ERROR: "The remote certificate is invalid according to the validation procedure"

SOLUTION: Power BI requires SSL but PostgreSQL needs proper configuration.

QUICK FIX OPTIONS:

Option 1: DISABLE SSL REQUIREMENT (Recommended for development/internal use)
   In Power BI Desktop:
   1. Get Data → PostgreSQL
   2. Advanced Options → Command timeout (optional)
   3. In "SQL statement" box, leave empty
   4. Click OK
   5. When it fails, go back and try connection string in Server field:
      localhost:5432?sslmode=disable
   
   OR edit the connection after import:
   - Right-click query → Advanced Editor
   - Change connection line to:
     PostgreSQL.Database("localhost:5432", "postgres", [SslMode="disable"])

Option 2: CONFIGURE SELF-SIGNED CERTIFICATE (More secure)
   Run in Ubuntu VM:
   sudo /home/gsowa/sites/ubuntu_scripts/check_postgres.sh --enable-ssl

Option 3: USE DIFFERENT DRIVER
   Power BI can use ODBC driver which handles SSL differently:
   1. Install PostgreSQL ODBC driver on Windows
   2. Use "ODBC" data source instead of "PostgreSQL"

POWER BI CONNECTION SETTINGS:

For NAT (localhost):
   Server: localhost
   Database: postgres
   Username: postgres
   Password: [your password]
   Advanced: sslmode=disable

For Host-Only Network (192.168.56.x):
   Server: 192.168.56.x
   Database: postgres
   Username: postgres
   Password: [your password]
   Advanced: sslmode=disable

CONNECTION STRING FORMAT:
   Host=localhost;Port=5432;Database=postgres;Username=postgres;Password=yourpass;SSL Mode=Disable

TROUBLESHOOTING CHECKLIST:
   □ PostgreSQL is running (check with: systemctl status postgresql)
   □ Port forwarding configured in VirtualBox (if using NAT)
   □ Password is set for postgres user
   □ listen_addresses = '*' in postgresql.conf
   □ pg_hba.conf allows md5 authentication
   □ Windows can reach port 5432 (Test-NetConnection)
   □ SSL mode is set to 'disable' in Power BI

COMMON POWER BI ERRORS:

1. "Unable to connect" / "Timeout"
   → Check network connectivity: Test-NetConnection -ComputerName localhost -Port 5432
   → Verify PostgreSQL is running: systemctl status postgresql
   → Check firewall: sudo ufw status

2. "Authentication failed"
   → Ensure password is set: ./check_postgres.sh --reset-password
   → Verify pg_hba.conf has: host all all 0.0.0.0/0 md5

3. "SSL certificate error" (YOUR ERROR)
   → Add sslmode=disable to server field: localhost?sslmode=disable
   → OR enable SSL: ./check_postgres.sh --enable-ssl

4. "Could not load file or assembly Npgsql"
   → Update Power BI Desktop to latest version
   → Install .NET Framework 4.8

EOF
}

check_ssl_config() {
	echo -e "\n--- SSL/TLS Configuration ---"
	
	local pg_conf=""
	for conf in /etc/postgresql/*/main/postgresql.conf /etc/postgresql/*/*/postgresql.conf; do
		if [[ -f "$conf" ]]; then
			pg_conf="$conf"
			break
		fi
	done
	
	if [[ -z "$pg_conf" ]]; then
		warn "postgresql.conf not found"
		return 1
	fi
	
	info "SSL settings in postgresql.conf:"
	grep -E "^ssl|^#ssl" "$pg_conf" | head -5 || echo "ssl = off (default)"
	
	# Check for SSL certificates
	local data_dir=$(dirname "$(dirname "$pg_conf")")
	if [[ -f "$data_dir/server.crt" ]]; then
		ok "SSL certificate exists: $data_dir/server.crt"
		info "Certificate info:"
		openssl x509 -in "$data_dir/server.crt" -noout -dates 2>/dev/null || true
	else
		info "No SSL certificate found (SSL disabled or using default)"
	fi
}

enable_ssl_self_signed() {
	warn "Configuring self-signed SSL certificate for PostgreSQL..."
	
	local pg_conf=""
	local data_dir=""
	
	for conf in /etc/postgresql/*/main/postgresql.conf /etc/postgresql/*/*/postgresql.conf; do
		if [[ -f "$conf" ]]; then
			pg_conf="$conf"
			data_dir="/var/lib/postgresql/$(basename $(dirname $(dirname $conf)))/main"
			break
		fi
	done
	
	if [[ -z "$pg_conf" ]]; then
		err "postgresql.conf not found"
		return 1
	fi
	
	info "Generating self-signed SSL certificate..."
	
	# Generate private key and certificate
	sudo openssl req -new -x509 -days 365 -nodes -text \
		-out "$data_dir/server.crt" \
		-keyout "$data_dir/server.key" \
		-subj "/CN=postgres-vm" 2>/dev/null
	
	# Set proper permissions
	sudo chmod 600 "$data_dir/server.key"
	sudo chown postgres:postgres "$data_dir/server.key" "$data_dir/server.crt"
	
	ok "SSL certificate generated"
	
	# Enable SSL in postgresql.conf
	sudo sed -i "s/^#*ssl =.*/ssl = on/" "$pg_conf"
	sudo sed -i "s/^#*ssl_cert_file =.*/ssl_cert_file = 'server.crt'/" "$pg_conf"
	sudo sed -i "s/^#*ssl_key_file =.*/ssl_key_file = 'server.key'/" "$pg_conf"
	
	ok "SSL enabled in postgresql.conf"
	
	# Restart PostgreSQL
	info "Restarting PostgreSQL..."
	sudo systemctl restart postgresql
	sleep 2
	
	ok "PostgreSQL restarted with SSL enabled"
	
	echo ""
	echo "=========================================="
	echo "  SSL Configuration Complete"
	echo "=========================================="
	echo "Self-signed certificate generated and enabled."
	echo ""
	warn "For Power BI, you still may need sslmode=require instead of verify-full"
	echo ""
	echo "Power BI connection options:"
	echo "1. Server: localhost?sslmode=require"
	echo "2. Server: localhost?sslmode=disable (if SSL not needed)"
	echo ""
	echo "To export certificate for Windows (optional):"
	echo "  sudo cat $data_dir/server.crt"
}

disable_ssl() {
	warn "Disabling SSL in PostgreSQL (for Power BI compatibility)..."
	
	local pg_conf=""
	for conf in /etc/postgresql/*/main/postgresql.conf /etc/postgresql/*/*/postgresql.conf; do
		if [[ -f "$conf" ]]; then
			pg_conf="$conf"
			break
		fi
	done
	
	if [[ -z "$pg_conf" ]]; then
		err "postgresql.conf not found"
		return 1
	fi
	
	# Backup
	sudo cp "$pg_conf" "${pg_conf}.backup.$(date +%s)"
	
	# Disable SSL
	sudo sed -i "s/^#*ssl =.*/ssl = off/" "$pg_conf"
	
	ok "SSL disabled in postgresql.conf"
	
	# Restart PostgreSQL
	info "Restarting PostgreSQL..."
	sudo systemctl restart postgresql
	sleep 2
	
	ok "PostgreSQL restarted with SSL disabled"
	
	echo ""
	echo "=========================================="
	echo "  SSL Disabled"
	echo "=========================================="
	echo "Power BI can now connect without SSL."
	echo ""
	echo "Connection string for Power BI:"
	echo "  Server: localhost"
	echo "  Database: postgres"
	echo "  (No need for sslmode parameter)"
	echo ""
	warn "This is fine for local/development use"
	warn "For production, use proper SSL certificates"
}

configure_for_powerbi() {
	warn "Configuring PostgreSQL specifically for Power BI connectivity..."
	
	# First configure for NAT if applicable
	if ip route | grep -q "10.0.2.2"; then
		info "VirtualBox NAT detected, configuring NAT settings..."
		configure_for_nat
	fi
	
	# Disable SSL (most common Power BI issue)
	disable_ssl
	
	# Ensure password auth is set
	local hba_conf=""
	for conf in /etc/postgresql/*/main/pg_hba.conf /etc/postgresql/*/*/pg_hba.conf; do
		if [[ -f "$conf" ]]; then
			hba_conf="$conf"
			break
		fi
	done
	
	if [[ -n "$hba_conf" ]]; then
		# Ensure we have md5 auth for all hosts
		if ! grep -q "host.*all.*all.*0.0.0.0/0.*md5" "$hba_conf"; then
			echo "host    all             all             0.0.0.0/0               md5" | sudo tee -a "$hba_conf" >/dev/null
			sudo systemctl reload postgresql
			ok "Added permissive md5 authentication rule"
		fi
	fi
	
	echo ""
	echo "=========================================="
	echo "  Power BI Configuration Complete"
	echo "=========================================="
	echo ""
	echo "CONNECTION DETAILS FOR POWER BI:"
	echo "  Server:   localhost"
	echo "  Port:     5432"
	echo "  Database: postgres"
	echo "  Username: postgres"
	echo "  Password: [your password]"
	echo ""
	echo "STEPS IN POWER BI DESKTOP:"
	echo "1. Home → Get Data → More"
	echo "2. Select 'PostgreSQL database'"
	echo "3. Enter Server: localhost"
	echo "4. Enter Database: postgres"
	echo "5. Select 'Database' authentication"
	echo "6. Enter Username: postgres"
	echo "7. Enter Password: [your password]"
	echo "8. Click Connect"
	echo ""
	warn "IMPORTANT: Ensure postgres password is set!"
	echo "If not set, run: $0 --reset-password"
	echo ""
	echo "If still getting SSL errors, try these in Power BI:"
	echo "  • In Server field: localhost?sslmode=disable"
	echo "  • Or use ODBC driver instead of native PostgreSQL connector"
}

create_analytics_user() {
	local username="${1:-analytics}"
	local password="${2}"
	local schema="${3:-analytics}"
	
	warn "Creating analytics user and schema..."
	
	# Prompt for password if not provided
	if [[ -z "$password" ]]; then
		read -sp "Enter password for user '$username': " password
		echo ""
		if [[ -z "$password" ]]; then
			err "Password cannot be empty"
			return 1
		fi
	fi
	
	info "Creating user: $username"
	info "Creating schema: $schema"
	
	# Connect as postgres user and create user + schema
	sudo -u postgres psql <<-EOSQL
		-- Create user if not exists
		DO \$\$
		BEGIN
		   IF NOT EXISTS (SELECT FROM pg_catalog.pg_user WHERE usename = '$username') THEN
		      CREATE USER $username WITH PASSWORD '$password';
		      RAISE NOTICE 'User $username created';
		   ELSE
		      RAISE NOTICE 'User $username already exists';
		   END IF;
		END
		\$\$;
		
		-- Grant connection to postgres database
		GRANT CONNECT ON DATABASE postgres TO $username;
		
		-- Create schema if not exists
		CREATE SCHEMA IF NOT EXISTS $schema AUTHORIZATION $username;
		
		-- Grant usage and create on schema
		GRANT USAGE, CREATE ON SCHEMA $schema TO $username;
		
		-- Set default privileges for future tables
		ALTER DEFAULT PRIVILEGES IN SCHEMA $schema 
		GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO $username;
		
		ALTER DEFAULT PRIVILEGES IN SCHEMA $schema 
		GRANT USAGE, SELECT ON SEQUENCES TO $username;
		
		-- Set search path for user
		ALTER USER $username SET search_path TO $schema, public;
		
		-- Display summary
		\echo ''
		\echo '=========================================='
		\echo 'Analytics User & Schema Created'
		\echo '=========================================='
		\echo 'Username: $username'
		\echo 'Schema:   $schema'
		\echo 'Database: postgres'
		\echo ''
	EOSQL
	
	if [[ $? -eq 0 ]]; then
		ok "User '$username' and schema '$schema' created successfully"
		
		echo ""
		echo "=========================================="
		echo "  Connection Details"
		echo "=========================================="
		echo "Username: $username"
		echo "Password: $password"
		echo "Database: postgres"
		echo "Schema:   $schema"
		echo ""
		echo "Connection commands:"
		echo "  psql -U $username -d postgres"
		echo "  psql -h localhost -U $username -d postgres"
		echo ""
		echo "Power BI connection:"
		echo "  Server:   localhost"
		echo "  Database: postgres"
		echo "  Username: $username"
		echo "  Password: $password"
		echo ""
		echo "Test connection:"
		echo "  PGPASSWORD='$password' psql -h localhost -U $username -d postgres -c 'SELECT current_schema();'"
		
		# Update pg_hba.conf to allow this user
		update_hba_for_user "$username"
	else
		err "Failed to create user or schema"
		return 1
	fi
}

update_hba_for_user() {
	local username="$1"
	
	local hba_conf=""
	for conf in /etc/postgresql/*/main/pg_hba.conf /etc/postgresql/*/*/pg_hba.conf; do
		if [[ -f "$conf" ]]; then
			hba_conf="$conf"
			break
		fi
	done
	
	if [[ -z "$hba_conf" ]]; then
		warn "pg_hba.conf not found, skipping update"
		return 0
	fi
	
	# Check if user already has entry
	if grep -q "host.*all.*$username.*" "$hba_conf"; then
		info "pg_hba.conf already has entry for $username"
		return 0
	fi
	
	info "Adding pg_hba.conf entry for user $username..."
	echo "host    all             $username       0.0.0.0/0               md5" | sudo tee -a "$hba_conf" >/dev/null
	sudo systemctl reload postgresql
	ok "pg_hba.conf updated for user $username"
}

list_users_and_schemas() {
	echo -e "\n--- PostgreSQL Users & Schemas ---"
	
	info "Database users:"
	sudo -u postgres psql -c "\du" 2>/dev/null || warn "Failed to list users"
	
	echo ""
	info "Schemas in 'postgres' database:"
	sudo -u postgres psql -d postgres -c "\dn+" 2>/dev/null || warn "Failed to list schemas"
	
	echo ""
	info "User privileges on schemas:"
	sudo -u postgres psql -d postgres <<-'EOSQL' 2>/dev/null || warn "Failed to list privileges"
		SELECT 
		    n.nspname as "Schema",
		    u.usename as "Owner",
		    array_to_string(n.nspacl, E'\n') as "Access privileges"
		FROM pg_namespace n
		LEFT JOIN pg_user u ON n.nspowner = u.usesysid
		WHERE n.nspname NOT LIKE 'pg_%' 
		  AND n.nspname != 'information_schema'
		ORDER BY n.nspname;
	EOSQL
}

create_sample_analytics_tables() {
	local schema="${1:-analytics}"
	
	warn "Creating sample analytics tables in schema '$schema'..."
	
	sudo -u postgres psql -d postgres <<-EOSQL
		-- Switch to analytics schema
		SET search_path TO $schema;
		
		-- Create sample dimension table
		CREATE TABLE IF NOT EXISTS dim_date (
		    date_id SERIAL PRIMARY KEY,
		    full_date DATE NOT NULL UNIQUE,
		    year INTEGER NOT NULL,
		    quarter INTEGER NOT NULL,
		    month INTEGER NOT NULL,
		    month_name VARCHAR(20) NOT NULL,
		    day_of_month INTEGER NOT NULL,
		    day_of_week INTEGER NOT NULL,
		    day_name VARCHAR(20) NOT NULL,
		    is_weekend BOOLEAN NOT NULL,
		    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
		);
		
		-- Create sample fact table
		CREATE TABLE IF NOT EXISTS fact_metrics (
		    metric_id SERIAL PRIMARY KEY,
		    date_id INTEGER REFERENCES dim_date(date_id),
		    metric_name VARCHAR(100) NOT NULL,
		    metric_value NUMERIC(18,2) NOT NULL,
		    metric_category VARCHAR(50),
		    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
		);
		
		-- Create sample staging table
		CREATE TABLE IF NOT EXISTS stg_raw_data (
		    id SERIAL PRIMARY KEY,
		    data_source VARCHAR(100),
		    raw_json JSONB,
		    loaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
		);
		
		-- Create indexes
		CREATE INDEX IF NOT EXISTS idx_dim_date_full_date ON dim_date(full_date);
		CREATE INDEX IF NOT EXISTS idx_fact_metrics_date ON fact_metrics(date_id);
		CREATE INDEX IF NOT EXISTS idx_fact_metrics_category ON fact_metrics(metric_category);
		
		-- Insert sample date dimension data
		INSERT INTO dim_date (full_date, year, quarter, month, month_name, day_of_month, day_of_week, day_name, is_weekend)
		SELECT 
		    date::date,
		    EXTRACT(YEAR FROM date)::int,
		    EXTRACT(QUARTER FROM date)::int,
		    EXTRACT(MONTH FROM date)::int,
		    TO_CHAR(date, 'Month'),
		    EXTRACT(DAY FROM date)::int,
		    EXTRACT(DOW FROM date)::int,
		    TO_CHAR(date, 'Day'),
		    EXTRACT(DOW FROM date) IN (0, 6)
		FROM generate_series('2024-01-01'::date, '2024-12-31'::date, '1 day'::interval) date
		ON CONFLICT (full_date) DO NOTHING;
		
		\echo ''
		\echo 'Sample analytics tables created:'
		\echo '  - dim_date (date dimension)'
		\echo '  - fact_metrics (metrics fact table)'
		\echo '  - stg_raw_data (staging table)'
		\echo ''
		\echo 'Tables summary:'
		\dt $schema.*
	EOSQL
	
	if [[ $? -eq 0 ]]; then
		ok "Sample analytics tables created in schema '$schema'"
		
		echo ""
		echo "Quick test queries:"
		echo "  SELECT COUNT(*) FROM $schema.dim_date;"
		echo "  SELECT * FROM $schema.dim_date LIMIT 5;"
	else
		err "Failed to create sample tables"
	fi
}

grant_schema_access() {
	local username="$1"
	local schema="$2"
	local access_level="${3:-read}"  # read, write, or full
	
	if [[ -z "$username" ]] || [[ -z "$schema" ]]; then
		err "Username and schema are required"
		return 1
	fi
	
	info "Granting '$access_level' access to user '$username' on schema '$schema'..."
	
	case "$access_level" in
		read)
			sudo -u postgres psql -d postgres <<-EOSQL
				GRANT USAGE ON SCHEMA $schema TO $username;
				GRANT SELECT ON ALL TABLES IN SCHEMA $schema TO $username;
				ALTER DEFAULT PRIVILEGES IN SCHEMA $schema GRANT SELECT ON TABLES TO $username;
			EOSQL
			;;
		write)
			sudo -u postgres psql -d postgres <<-EOSQL
				GRANT USAGE ON SCHEMA $schema TO $username;
				GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA $schema TO $username;
				GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA $schema TO $username;
				ALTER DEFAULT PRIVILEGES IN SCHEMA $schema GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO $username;
				ALTER DEFAULT PRIVILEGES IN SCHEMA $schema GRANT USAGE, SELECT ON SEQUENCES TO $username;
			EOSQL
			;;
		full)
			sudo -u postgres psql -d postgres <<-EOSQL
				GRANT ALL PRIVILEGES ON SCHEMA $schema TO $username;
				GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA $schema TO $username;
				GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA $schema TO $username;
				ALTER DEFAULT PRIVILEGES IN SCHEMA $schema GRANT ALL PRIVILEGES ON TABLES TO $username;
				ALTER DEFAULT PRIVILEGES IN SCHEMA $schema GRANT ALL PRIVILEGES ON SEQUENCES TO $username;
			EOSQL
			;;
		*)
			err "Invalid access level: $access_level (use: read, write, or full)"
			return 1
			;;
	esac
	
	if [[ $? -eq 0 ]]; then
		ok "Access granted: $username -> $schema ($access_level)"
	else
		err "Failed to grant access"
		return 1
	fi
}

configure_airbyte_database() {
	warn "Configuring PostgreSQL for Airbyte..."
	
	local airbyte_db="${1:-airbyte}"
	local airbyte_user="${2:-airbyte}"
	local airbyte_password="${3}"
	
	# Prompt for password if not provided
	if [[ -z "$airbyte_password" ]]; then
		read -sp "Enter password for Airbyte database user '$airbyte_user': " airbyte_password
		echo ""
		if [[ -z "$airbyte_password" ]]; then
			err "Password cannot be empty"
			return 1
		fi
	fi
	
	info "Creating Airbyte database and user..."
	
	sudo -u postgres psql <<-EOSQL
		-- Create Airbyte user
		DO \$\$
		BEGIN
		   IF NOT EXISTS (SELECT FROM pg_catalog.pg_user WHERE usename = '$airbyte_user') THEN
		      CREATE USER $airbyte_user WITH PASSWORD '$airbyte_password';
		      RAISE NOTICE 'User $airbyte_user created';
		   ELSE
		      RAISE NOTICE 'User $airbyte_user already exists';
		      ALTER USER $airbyte_user WITH PASSWORD '$airbyte_password';
		   END IF;
		END
		\$\$;
		
		-- Create Airbyte database
		SELECT 'CREATE DATABASE $airbyte_db OWNER $airbyte_user'
		WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$airbyte_db')\gexec
		
		-- Grant all privileges
		GRANT ALL PRIVILEGES ON DATABASE $airbyte_db TO $airbyte_user;
		
		\echo ''
		\echo '=========================================='
		\echo 'Airbyte Database Configuration'
		\echo '=========================================='
		\echo 'Database: $airbyte_db'
		\echo 'User:     $airbyte_user'
		\echo 'Password: (set)'
		\echo ''
	EOSQL
	
	if [[ $? -eq 0 ]]; then
		ok "Airbyte database '$airbyte_db' and user '$airbyte_user' configured"
		
		# Update pg_hba.conf for Airbyte
		update_hba_for_user "$airbyte_user"
		
		echo ""
		echo "=========================================="
		echo "  Airbyte Connection Configuration"
		echo "=========================================="
		echo "Database: $airbyte_db"
		echo "User:     $airbyte_user"
		echo "Password: $airbyte_password"
		echo "Host:     localhost (or 127.0.0.1)"
		echo "Port:     5432"
		echo ""
		echo "JDBC URL:"
		echo "  jdbc:postgresql://localhost:5432/$airbyte_db?user=$airbyte_user&password=$airbyte_password"
		echo ""
		echo "PostgreSQL URL:"
		echo "  postgresql://$airbyte_user:$airbyte_password@localhost:5432/$airbyte_db"
		echo ""
		
		# Show where to update Airbyte config
		show_airbyte_config_locations "$airbyte_user" "$airbyte_password" "$airbyte_db"
	else
		err "Failed to create Airbyte database"
		return 1
	fi
}

show_airbyte_config_locations() {
	local user="$1"
	local pass="$2"
	local db="$3"
	
	echo "=========================================="
	echo "  Update Airbyte Configuration"
	echo "=========================================="
	echo ""
	echo "1. DOCKER COMPOSE SETUP:"
	echo "   If using docker-compose, update .env file:"
	echo ""
	echo "   DATABASE_USER=$user"
	echo "   DATABASE_PASSWORD=$pass"
	echo "   DATABASE_DB=$db"
	echo "   DATABASE_HOST=host.docker.internal  # or host machine IP"
	echo "   DATABASE_PORT=5432"
	echo ""
	echo "2. STANDALONE DOCKER:"
	echo "   Update environment variables:"
	echo ""
	echo "   docker run -d \\"
	echo "     -e DATABASE_USER=$user \\"
	echo "     -e DATABASE_PASSWORD=$pass \\"
	echo "     -e DATABASE_DB=$db \\"
	echo "     -e DATABASE_HOST=host.docker.internal \\"
	echo "     -e DATABASE_PORT=5432 \\"
	echo "     airbyte/server:latest"
	echo ""
	echo "3. KUBERNETES/HELM:"
	echo "   Update values.yaml or secrets:"
	echo ""
	echo "   postgresql:"
	echo "     enabled: false"
	echo "   externalDatabase:"
	echo "     host: localhost"
	echo "     port: 5432"
	echo "     database: $db"
	echo "     user: $user"
	echo "     password: $pass"
	echo ""
	echo "4. COMMON CONFIG FILES:"
	find /var/airbyte /opt/airbyte ~/airbyte -name ".env" -o -name "docker-compose.yaml" 2>/dev/null | head -5 || echo "   (No Airbyte directories found)"
}

find_airbyte_installation() {
	echo -e "\n--- Airbyte Installation Detection ---"
	
	local found=false
	
	# Check Docker containers
	if command -v docker >/dev/null 2>&1; then
		info "Checking Docker containers..."
		if docker ps -a --format '{{.Names}}' | grep -qi airbyte; then
			ok "Airbyte Docker containers found:"
			docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' | grep -i airbyte
			found=true
		fi
	fi
	
	# Check common directories
	local airbyte_dirs=(
		"/var/airbyte"
		"/opt/airbyte"
		"$HOME/airbyte"
		"/usr/local/airbyte"
	)
	
	for dir in "${airbyte_dirs[@]}"; do
		if [[ -d "$dir" ]]; then
			ok "Airbyte directory found: $dir"
			if [[ -f "$dir/.env" ]]; then
				info "Environment file: $dir/.env"
			fi
			if [[ -f "$dir/docker-compose.yaml" ]]; then
				info "Docker Compose file: $dir/docker-compose.yaml"
			fi
			found=true
		fi
	done
	
	# Check for running processes
	if pgrep -f airbyte >/dev/null 2>&1; then
		ok "Airbyte processes running:"
		ps aux | grep -i airbyte | grep -v grep
		found=true
	fi
	
	if [[ "$found" == false ]]; then
		warn "No Airbyte installation detected"
		echo "If Airbyte is installed elsewhere, provide the path:"
		echo "  $0 --configure-airbyte-db --airbyte-path /path/to/airbyte"
	fi
}

backup_airbyte_metadata() {
	warn "Backing up Airbyte metadata from old PostgreSQL instance..."
	
	local backup_dir="${1:-$HOME/airbyte_backup_$(date +%Y%m%d_%H%M%S)}"
	mkdir -p "$backup_dir"
	
	info "Backup directory: $backup_dir"
	
	# Try to dump Airbyte databases
	local old_dbs=("airbyte" "airbyte_db" "airbyte_config")
	
	for db in "${old_dbs[@]}"; do
		if sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw "$db"; then
			info "Backing up database: $db"
			sudo -u postgres pg_dump "$db" > "$backup_dir/${db}_backup.sql" 2>/dev/null
			if [[ $? -eq 0 ]]; then
				ok "Backed up: $backup_dir/${db}_backup.sql"
			else
				warn "Failed to backup: $db"
			fi
		fi
	done
	
	ok "Backup complete: $backup_dir"
	echo ""
	echo "To restore later:"
	echo "  psql -h localhost -U airbyte -d airbyte < $backup_dir/airbyte_backup.sql"
}

restore_airbyte_metadata() {
	local backup_file="$1"
	local target_db="${2:-airbyte}"
	
	if [[ -z "$backup_file" ]] || [[ ! -f "$backup_file" ]]; then
		err "Backup file not found: $backup_file"
		return 1
	fi
	
	warn "Restoring Airbyte metadata from: $backup_file"
	
	# Restore the backup
	sudo -u postgres psql -d "$target_db" < "$backup_file"
	
	if [[ $? -eq 0 ]]; then
		ok "Airbyte metadata restored to database: $target_db"
	else
		err "Failed to restore metadata"
		return 1
	fi
}

update_airbyte_env_file() {
	local env_file="$1"
	local db_user="$2"
	local db_pass="$3"
	local db_name="$4"
	local db_host="${5:-localhost}"
	
	if [[ ! -f "$env_file" ]]; then
		err "Environment file not found: $env_file"
		return 1
	fi
	
	warn "Updating Airbyte .env file: $env_file"
	
	# Backup original
	cp "$env_file" "${env_file}.backup.$(date +%s)"
	ok "Backup created: ${env_file}.backup.*"
	
	# Update database configuration
	sed -i "s/^DATABASE_USER=.*/DATABASE_USER=$db_user/" "$env_file"
	sed -i "s/^DATABASE_PASSWORD=.*/DATABASE_PASSWORD=$db_pass/" "$env_file"
	sed -i "s/^DATABASE_DB=.*/DATABASE_DB=$db_name/" "$env_file"
	sed -i "s/^DATABASE_HOST=.*/DATABASE_HOST=$db_host/" "$env_file"
	sed -i "s/^DATABASE_PORT=.*/DATABASE_PORT=5432/" "$env_file"
	
	# If variables don't exist, add them
	grep -q "^DATABASE_USER=" "$env_file" || echo "DATABASE_USER=$db_user" >> "$env_file"
	grep -q "^DATABASE_PASSWORD=" "$env_file" || echo "DATABASE_PASSWORD=$db_pass" >> "$env_file"
	grep -q "^DATABASE_DB=" "$env_file" || echo "DATABASE_DB=$db_name" >> "$env_file"
	grep -q "^DATABASE_HOST=" "$env_file" || echo "DATABASE_HOST=$db_host" >> "$env_file"
	grep -q "^DATABASE_PORT=" "$env_file" || echo "DATABASE_PORT=5432" >> "$env_file"
	
	ok "Environment file updated"
	
	info "Updated configuration:"
	grep "^DATABASE_" "$env_file" || true
}

show_airbyte_migration_guide() {
	cat <<'EOF'

========================================
  Airbyte PostgreSQL Migration Guide
========================================

IMPORTANT: CONSIDER INDEPENDENT INSTALLATION

Instead of using host PostgreSQL, you can install Airbyte with its own
embedded database for complete independence:

  ./install_airbyte.sh --mode embedded

This is RECOMMENDED if you're having PostgreSQL issues or reinstalling often.

AFTER REINSTALLING POSTGRESQL:

Step 1: BACKUP OLD AIRBYTE DATA (if possible)
   If old PostgreSQL still accessible:
   ./check_postgres.sh --backup-airbyte-data

Step 2: CONFIGURE NEW POSTGRESQL FOR AIRBYTE
   ./check_postgres.sh --configure-airbyte-db [dbname] [user] [password]
   
   Example:
   ./check_postgres.sh --configure-airbyte-db airbyte airbyte_user SecurePass123

Step 3: UPDATE AIRBYTE CONFIGURATION

   A. Find Airbyte installation:
      ./check_postgres.sh --find-airbyte

   B. Update .env file manually:
      nano /path/to/airbyte/.env
      
      Set these variables:
      DATABASE_USER=airbyte_user
      DATABASE_PASSWORD=SecurePass123
      DATABASE_DB=airbyte
      DATABASE_HOST=host.docker.internal  # or VM IP if remote
      DATABASE_PORT=5432

   C. Or use auto-update:
      ./check_postgres.sh --update-airbyte-env /path/to/airbyte/.env airbyte_user SecurePass123 airbyte

Step 4: ALLOW DOCKER ACCESS TO HOST POSTGRESQL

   Add to pg_hba.conf:
   host    all             airbyte_user    172.17.0.0/16           md5
   
   Then reload:
   sudo systemctl reload postgresql

Step 5: RESTART AIRBYTE

   Docker Compose:
   cd /path/to/airbyte
   docker-compose down
   docker-compose up -d

   Standalone Docker:
   docker restart $(docker ps -a -q --filter name=airbyte)

Step 6: RESTORE METADATA (if backed up)
   ./check_postgres.sh --restore-airbyte-data /path/to/backup.sql airbyte

Step 7: VERIFY CONNECTION

   Check Airbyte logs:
   docker logs airbyte-server 2>&1 | grep -i database
   docker logs airbyte-server 2>&1 | grep -i postgres

   Test database connection:
   PGPASSWORD='SecurePass123' psql -h localhost -U airbyte_user -d airbyte -c "SELECT COUNT(*) FROM airbyte_configs;"

TROUBLESHOOTING:

1. "Connection refused" from Docker
   → Ensure listen_addresses = '*' in postgresql.conf
   → Add Docker network to pg_hba.conf
   → Use host.docker.internal instead of localhost (Mac/Windows)
   → Use host machine IP (Linux)

2. "password authentication failed"
   → Verify password in .env matches PostgreSQL
   → Check pg_hba.conf has md5 or scram-sha-256
   → Reload PostgreSQL: sudo systemctl reload postgresql

3. "database does not exist"
   → Run: ./check_postgres.sh --configure-airbyte-db

4. Airbyte starts but no connectors/connections
   → Metadata not migrated - run fresh setup
   → Check airbyte_configs table exists

DOCKER NETWORK CONFIGURATION:

For Linux (Docker on same host as PostgreSQL):
   DATABASE_HOST=172.17.0.1  # Docker bridge gateway
   
   Or add to pg_hba.conf:
   host all airbyte_user 172.17.0.0/16 md5

For Mac/Windows Docker Desktop:
   DATABASE_HOST=host.docker.internal

For VirtualBox VM (Airbyte in Docker on host Windows):
   DATABASE_HOST=10.0.2.2  # NAT gateway
   Ensure port forwarding is set up

EOF
}

suggest_fixes() {
	# If nothing listening on 5432
	if ! ss -tnlp 2>/dev/null | grep -q ':5432'; then
		echo "1. Service not listening on 5432. Actions:" 
		echo "   - If using OS package: sudo systemctl start postgresql"
		echo "   - Check cluster status: sudo pg_lsclusters (look for 'down')"
		echo "   - Start cluster: sudo pg_ctlcluster <version> <name> start"
		echo "   - Examine logs: journalctl -u postgresql -n 100"
		echo "   - If not installed, install: sudo apt-get update && sudo apt-get install -y postgresql"
	fi
	if command -v docker >/dev/null 2>&1 && docker ps | grep -qi postgres; then
		echo "2. If Docker container is running but port not exposed, restart with -p 5432:5432"
	fi
	if [[ ! -d /var/lib/postgresql ]] && [[ ! -d /var/lib/postgresql/14 ]] && [[ ! -d /var/lib/postgresql/16 ]]; then
		echo "3. Data directory not found; likely not installed or custom install path."
	fi
	echo "4. If you expect socket auth only, try: sudo -u postgres psql -c 'SELECT 1;'"
	echo "5. To enable remote TCP, ensure in postgresql.conf: listen_addresses='*' and pg_hba.conf has proper host lines. Restart after changes."
	# Append auth / user oriented hints
	if grep -qi "role .* does not exist" <<<"${LAST_ERROR:-}"; then
		echo "6. Create role: sudo -u postgres createuser -s $USER"
	fi
	echo "7. If password auth failing, ensure: ALTER USER $USER WITH PASSWORD 'secret'; and pg_hba.conf has 'md5' or 'scram-sha-256'. Reload with: SELECT pg_reload_conf();"
	echo ""
	echo "Quick fixes available:"
	echo "   $0 --fix-auth                    # Allow passwordless localhost access (trust)"
	echo "   $0 --fix-auth --set-password     # Set password and use md5 auth"
	echo "   $0 --reset-password              # Reset postgres password"
	echo "   $0 --show-auth                   # Display current pg_hba.conf"
	echo ""
	echo "Remote access (VirtualBox VM):"
	echo "   $0 --enable-remote               # Configure for remote access from Windows"
	echo "   $0 --enable-remote --from-ip <IP>  # Allow specific Windows IP"
	echo "   $0 --configure-nat               # Configure for VirtualBox NAT + port forwarding"
	echo "   $0 --test-remote                 # Test remote connectivity"
	echo "   $0 --test-nat                    # Test NAT port forwarding setup"
	echo "   $0 --windows-guide               # Show Windows connection instructions"
	echo ""
	echo "Power BI specific:"
	echo "   $0 --configure-powerbi           # Configure PostgreSQL for Power BI (disable SSL, etc)"
	echo "   $0 --powerbi-guide               # Show Power BI connection guide & troubleshooting"
	echo "   $0 --enable-ssl                  # Enable SSL with self-signed certificate"
	echo "   $0 --disable-ssl                 # Disable SSL (fixes Power BI certificate errors)"
	echo "   $0 --check-ssl                   # Check current SSL configuration"
	echo ""
	echo "User & Schema management:"
	echo "   $0 --create-analytics-user [name] [password] [schema]  # Create analytics user & schema"
	echo "   $0 --list-users                  # List all users and schemas"
	echo "   $0 --create-sample-tables [schema]  # Create sample analytics tables"
	echo "   $0 --grant-access <user> <schema> <level>  # Grant access (read/write/full)"
	echo ""
	echo "Airbyte integration:"
	echo "   $0 --configure-airbyte-db [db] [user] [pass]  # Setup PostgreSQL for Airbyte"
	echo "   $0 --find-airbyte                # Detect Airbyte installation"
	echo "   $0 --backup-airbyte-data         # Backup Airbyte metadata before reinstall"
	echo "   $0 --restore-airbyte-data <file> [db]  # Restore Airbyte metadata"
	echo "   $0 --update-airbyte-env <file> <user> <pass> <db> [host]  # Update .env file"
	echo "   $0 --airbyte-guide               # Show complete migration guide"
	echo ""
	echo "Airbyte independent installation:"
	echo "   ./install_airbyte.sh --mode embedded  # Install with embedded PostgreSQL (RECOMMENDED)"
	echo "   ./install_airbyte.sh --guide          # Compare installation modes"
}

# ===== MAIN EXECUTION =====

# If no arguments provided, run default diagnostic
if [[ $# -eq 0 ]]; then
	show_header
	check_service
	detect_ports
	print_connect_help
	attempt_connect
	suggest_fixes
	exit 0
fi

# Parse command line arguments
while [[ $# -gt 0 ]]; do
	case "$1" in
		--help|-h)
			suggest_fixes
			exit 0
			;;
		--configure-airbyte-db)
			shift
			db_name="${1:-airbyte}"
			shift
			db_user="${1:-airbyte}"
			shift
			db_pass="${1:-}"
			configure_airbyte_database "$db_name" "$db_user" "$db_pass"
			exit 0
			;;
		--find-airbyte)
			find_airbyte_installation
			exit 0
			;;
		--backup-airbyte-data)
			shift
			backup_dir="${1:-}"
			backup_airbyte_metadata "$backup_dir"
			exit 0
			;;
		--restore-airbyte-data)
			shift
			backup_file="${1:-}"
			shift
			target_db="${1:-airbyte}"
			restore_airbyte_metadata "$backup_file" "$target_db"
			exit 0
			;;
		--update-airbyte-env)
			shift
			env_file="${1:-}"
			shift
			db_user="${1:-}"
			shift
			db_pass="${1:-}"
			shift
			db_name="${1:-}"
			shift
			db_host="${1:-localhost}"
			update_airbyte_env_file "$env_file" "$db_user" "$db_pass" "$db_name" "$db_host"
			exit 0
			;;
		--airbyte-guide)
			show_airbyte_migration_guide
			exit 0
			;;
		*)
			echo "Unknown option: $1"
			echo ""
			suggest_fixes
			exit 1
			;;
	esac
	shift
done