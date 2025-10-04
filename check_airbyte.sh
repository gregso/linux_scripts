#!/usr/bin/env bash
# Check Airbyte installation status

set -euo pipefail

COLOR_GREEN='\033[0;32m'
COLOR_BLUE='\033[0;34m'
COLOR_YELLOW='\033[1;33m'
COLOR_RESET='\033[0m'

info() { echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $*"; }
ok() { echo -e "${COLOR_GREEN}[ OK ]${COLOR_RESET} $*"; }
warn() { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*"; }

echo "=============================================="
echo " Airbyte Status Check"
echo "=============================================="
echo ""

# Check if abctl is installed
if command -v abctl >/dev/null 2>&1; then
    ok "abctl is installed"
else
    warn "abctl is not installed"
    exit 1
fi

# Check cluster status
info "Checking Kubernetes cluster..."
export KUBECONFIG=~/.airbyte/abctl/abctl.kubeconfig
if kubectl get nodes 2>/dev/null | grep -q "Ready"; then
    ok "Kubernetes cluster is running"
    kubectl get nodes
else
    warn "Kubernetes cluster not found or not ready"
fi

echo ""
info "Checking Airbyte pods..."
if kubectl get pods -n airbyte-abctl 2>/dev/null; then
    echo ""
    ok "Airbyte namespace exists"
else
    warn "Airbyte namespace not found - installation may still be in progress"
fi

echo ""
info "Checking PostgreSQL connection from host..."
if PGPASSWORD=airbyte123 psql -h 172.17.0.1 -U airbyte -d airbyte -c "SELECT version();" 2>/dev/null | grep -q PostgreSQL; then
    ok "PostgreSQL is accessible from Docker network (172.17.0.1)"
else
    warn "Cannot connect to PostgreSQL from Docker network"
    echo "    Try: PGPASSWORD=airbyte123 psql -h 172.17.0.1 -U airbyte -d airbyte"
fi

echo ""
info "Checking Airbyte web interface..."
if curl -s http://localhost:8000 >/dev/null 2>&1; then
    ok "Airbyte is accessible at http://localhost:8000"
    echo ""
    echo "    Open in browser: http://localhost:8000"
else
    warn "Airbyte web interface not yet available"
    echo "    Installation may still be in progress"
fi

echo ""
echo "To view installation logs:"
echo "  tail -f ~/sites/ubuntu_scripts/airbyte-install.log"
echo ""
echo "To check pod status:"
echo "  kubectl get pods -n airbyte-abctl --kubeconfig ~/.airbyte/abctl/abctl.kubeconfig"
echo ""
echo "To view pod logs:"
echo "  kubectl logs -n airbyte-abctl <pod-name> --kubeconfig ~/.airbyte/abctl/abctl.kubeconfig"
