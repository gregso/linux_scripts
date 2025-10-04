#!/bin/bash

echo "=========================================="
echo "  Airbyte Pre-Installation Checklist"
echo "=========================================="
echo ""

ERRORS=0
WARNINGS=0

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

check_pass() { echo -e "${GREEN}✅ PASS${NC} $1"; }
check_fail() { echo -e "${RED}❌ FAIL${NC} $1"; ((ERRORS++)); }
check_warn() { echo -e "${YELLOW}⚠️  WARN${NC} $1"; ((WARNINGS++)); }
check_info() { echo -e "${BLUE}ℹ️  INFO${NC} $1"; }

# 1. Check Docker
echo "1. Docker"
if command -v docker &> /dev/null; then
    DOCKER_VERSION=$(docker --version | awk '{print $3}' | sed 's/,//')
    check_pass "Docker installed (version: $DOCKER_VERSION)"
    
    # Check if Docker daemon is running
    if docker ps &> /dev/null; then
        check_pass "Docker daemon is running"
    else
        check_fail "Docker daemon is not running. Run: sudo systemctl start docker"
    fi
    
    # Check Docker permissions
    if docker ps &> /dev/null; then
        check_pass "Current user can run Docker commands"
    else
        check_warn "Current user may need sudo for Docker. Consider adding user to docker group."
    fi
else
    check_fail "Docker not installed. Install Docker first."
fi

# 2. Check abctl
echo ""
echo "2. Airbyte CLI (abctl)"
if command -v abctl &> /dev/null; then
    ABCTL_VERSION=$(abctl version 2>/dev/null || echo "unknown")
    check_pass "abctl installed (version: $ABCTL_VERSION)"
else
    check_fail "abctl not installed. Run: curl -LsfS https://get.airbyte.com | bash -"
fi

# 3. Check port 8000 availability
echo ""
echo "3. Port Availability"
if ! sudo ss -tlnp | grep -q ":8000 "; then
    check_pass "Port 8000 is available (Airbyte web UI)"
else
    check_fail "Port 8000 is already in use. Airbyte needs this port for web UI."
    sudo ss -tlnp | grep ":8000 "
fi

# 4. Check PostgreSQL
echo ""
echo "4. PostgreSQL Configuration"
if systemctl is-active --quiet postgresql; then
    check_pass "PostgreSQL service is running"
    
    # Check listen_addresses
    LISTEN_ADDR=$(sudo -u postgres psql -t -c "SHOW listen_addresses;" | xargs)
    if [ "$LISTEN_ADDR" = "*" ] || [ "$LISTEN_ADDR" = "0.0.0.0" ]; then
        check_pass "PostgreSQL listening on all interfaces (listen_addresses=$LISTEN_ADDR)"
    else
        check_fail "PostgreSQL not listening on all interfaces (listen_addresses=$LISTEN_ADDR). Run: ./fixairbyte.sh"
    fi
    
    # Check if airbyte database exists
    if sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw airbyte; then
        check_pass "Database 'airbyte' exists"
    else
        check_fail "Database 'airbyte' does not exist. Run: ./check_postgres.sh --configure-airbyte-db airbyte airbyte airbyte123"
    fi
    
    # Check if airbyte user exists
    if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='airbyte'" | grep -q 1; then
        check_pass "User 'airbyte' exists"
    else
        check_fail "User 'airbyte' does not exist. Run: ./check_postgres.sh --configure-airbyte-db airbyte airbyte airbyte123"
    fi
    
    # Check pg_hba.conf for Docker networks
    if sudo grep -q "172.17.0.0/16" /etc/postgresql/*/main/pg_hba.conf; then
        check_pass "pg_hba.conf allows Docker network (172.17.0.0/16)"
    else
        check_fail "pg_hba.conf missing Docker network entry. Run: ./fixairbyte.sh"
    fi
    
else
    check_fail "PostgreSQL service is not running. Run: sudo systemctl start postgresql"
fi

# 5. Check database connectivity
echo ""
echo "5. Database Connectivity Tests"
export PAGER=
PGPASSWORD=airbyte123 psql -h 172.17.0.1 -U airbyte -d airbyte -t -c "SELECT 1;" &> /dev/null
if [ $? -eq 0 ]; then
    check_pass "Can connect to PostgreSQL from host (172.17.0.1)"
else
    check_fail "Cannot connect to PostgreSQL from host. Check password and pg_hba.conf"
fi

docker run --rm -e PGPASSWORD=airbyte123 postgres:13 \
    psql "postgresql://airbyte:airbyte123@172.17.0.1:5432/airbyte" \
    -t -c "SELECT 1;" &> /dev/null
if [ $? -eq 0 ]; then
    check_pass "Can connect to PostgreSQL from Docker (simulates K8s pods)"
else
    check_fail "Cannot connect to PostgreSQL from Docker. Run: ./fixairbyte.sh"
fi

# 6. Check airbyte-values.yaml
echo ""
echo "6. Configuration Files"
if [ -f "airbyte-values.yaml" ]; then
    check_pass "airbyte-values.yaml exists"
    
    # Verify it has required fields
    if grep -q "postgresql:" airbyte-values.yaml && \
       grep -q "enabled: false" airbyte-values.yaml && \
       grep -q "externalDatabase:" airbyte-values.yaml; then
        check_pass "airbyte-values.yaml has external database configuration"
    else
        check_warn "airbyte-values.yaml may be missing required configuration"
    fi
else
    check_fail "airbyte-values.yaml not found in current directory"
fi

# 7. Check system resources
echo ""
echo "7. System Resources"
TOTAL_MEM=$(free -g | awk '/^Mem:/{print $2}')
if [ "$TOTAL_MEM" -ge 4 ]; then
    check_pass "System has ${TOTAL_MEM}GB RAM (minimum 4GB recommended)"
else
    check_warn "System has ${TOTAL_MEM}GB RAM (4GB+ recommended for Airbyte)"
fi

AVAILABLE_DISK=$(df -BG . | awk 'NR==2 {print $4}' | sed 's/G//')
if [ "$AVAILABLE_DISK" -ge 10 ]; then
    check_pass "Available disk space: ${AVAILABLE_DISK}GB (minimum 10GB recommended)"
else
    check_warn "Available disk space: ${AVAILABLE_DISK}GB (10GB+ recommended)"
fi

# 8. Check for existing Airbyte installations
echo ""
echo "8. Existing Installations"
if docker ps -a | grep -q airbyte; then
    check_warn "Found existing Airbyte Docker containers. Consider cleanup: ./cleanup_airbyte.sh"
fi

if kind get clusters 2>/dev/null | grep -q airbyte; then
    check_warn "Found existing Kind clusters with 'airbyte' in name. Consider cleanup: ./cleanup_airbyte.sh"
fi

if [ -d "$HOME/.airbyte" ]; then
    check_warn "Found existing ~/.airbyte directory. Previous installation may exist."
fi

# 9. Check Helm (used by abctl)
echo ""
echo "9. Helm"
if command -v helm &> /dev/null; then
    HELM_VERSION=$(helm version --short 2>/dev/null)
    check_pass "Helm installed ($HELM_VERSION)"
else
    check_info "Helm not found (abctl will install it automatically)"
fi

# 10. Summary
echo ""
echo "=========================================="
echo "  Pre-Installation Check Summary"
echo "=========================================="
echo ""
if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo -e "${GREEN}✅ All checks passed!${NC}"
    echo ""
    echo "You're ready to install Airbyte. Run:"
    echo ""
    echo "  abctl local install --values airbyte-values.yaml"
    echo ""
    echo "Installation will take 5-10 minutes."
    echo "Once complete, access Airbyte at: http://localhost:8000"
elif [ $ERRORS -eq 0 ]; then
    echo -e "${YELLOW}⚠️  $WARNINGS warning(s) found${NC}"
    echo ""
    echo "You can proceed with installation, but review warnings above."
    echo ""
    echo "  abctl local install --values airbyte-values.yaml"
else
    echo -e "${RED}❌ $ERRORS error(s) found${NC}"
    if [ $WARNINGS -gt 0 ]; then
        echo -e "${YELLOW}⚠️  $WARNINGS warning(s) found${NC}"
    fi
    echo ""
    echo "Please fix the errors above before installing Airbyte."
    echo ""
    echo "Common fixes:"
    echo "  - PostgreSQL setup: ./check_postgres.sh --configure-airbyte-db airbyte airbyte airbyte123"
    echo "  - Network config: ./fixairbyte.sh"
    echo "  - Install Docker: curl -fsSL https://get.docker.com | sudo sh"
    echo "  - Install abctl: curl -LsfS https://get.airbyte.com | bash -"
fi

echo ""
exit $ERRORS