#!/bin/bash
# Complete Airbyte cleanup script
# Removes all Airbyte installations, Kubernetes clusters, Docker resources, and configuration

set -e

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_BLUE='\033[0;34m'
COLOR_RESET='\033[0m'

info() { echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $*"; }
ok() { echo -e "${COLOR_GREEN}[ OK ]${COLOR_RESET} $*"; }
warn() { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*"; }
err() { echo -e "${COLOR_RED}[FAIL]${COLOR_RESET} $*"; }

echo "=========================================="
echo "  Airbyte Complete Cleanup Script"
echo "=========================================="
echo ""

# 1. UNINSTALL VIA ABCTL (Most Important)
if command -v abctl &> /dev/null; then
    info "Found abctl, attempting to uninstall Airbyte..."
    
    # Export kubeconfig if it exists
    if [ -f "$HOME/.airbyte/abctl/abctl.kubeconfig" ]; then
        export KUBECONFIG="$HOME/.airbyte/abctl/abctl.kubeconfig"
        info "Using kubeconfig: $KUBECONFIG"
    fi
    
    # Try to uninstall using abctl
    if abctl local uninstall 2>&1; then
        ok "Airbyte uninstalled via abctl"
    else
        warn "abctl uninstall failed or nothing to uninstall"
    fi
    
    # Wait for cleanup to complete
    sleep 3
else
    warn "abctl not found, skipping abctl uninstall"
fi

# 2. REMOVE KIND CLUSTERS (used by abctl)
info "Checking for Kind clusters..."
if command -v kind &> /dev/null; then
    CLUSTERS=$(kind get clusters 2>/dev/null || true)
    if [ -n "$CLUSTERS" ]; then
        info "Found Kind clusters:"
        echo "$CLUSTERS"
        echo "$CLUSTERS" | while read -r cluster; do
            if [[ "$cluster" == *"airbyte"* ]]; then
                info "Deleting Kind cluster: $cluster"
                kind delete cluster --name "$cluster"
                ok "Deleted cluster: $cluster"
            fi
        done
    else
        info "No Kind clusters found"
    fi
else
    warn "kind command not found, skipping cluster cleanup"
fi

# 3. STOP AND REMOVE DOCKER CONTAINERS
info "Checking for Airbyte Docker containers..."
AIRBYTE_CONTAINERS=$(docker ps -a --filter "name=airbyte" --format "{{.Names}}" 2>/dev/null || true)
if [ -n "$AIRBYTE_CONTAINERS" ]; then
    info "Stopping and removing Airbyte containers..."
    echo "$AIRBYTE_CONTAINERS" | while read -r container; do
        info "Removing container: $container"
        docker rm -f "$container" 2>/dev/null || true
    done
    ok "Removed Airbyte containers"
else
    info "No Airbyte containers found"
fi

# 4. REMOVE DOCKER VOLUMES (abctl creates persistent volumes)
info "Checking for Airbyte Docker volumes..."
AIRBYTE_VOLUMES=$(docker volume ls --filter "name=airbyte" --format "{{.Name}}" 2>/dev/null || true)
if [ -n "$AIRBYTE_VOLUMES" ]; then
    warn "Found Airbyte volumes:"
    echo "$AIRBYTE_VOLUMES"
    warn "Remove them? (y/n) - This will delete all Airbyte data!"
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        echo "$AIRBYTE_VOLUMES" | while read -r volume; do
            info "Removing volume: $volume"
            docker volume rm "$volume" 2>/dev/null || true
        done
        ok "Removed Airbyte volumes"
    else
        info "Skipping volume removal"
    fi
else
    info "No Airbyte volumes found"
fi

# 5. REMOVE DOCKER IMAGES
info "Checking for Airbyte Docker images..."
AIRBYTE_IMAGES=$(docker images --filter "reference=airbyte/*" --format "{{.Repository}}:{{.Tag}}" 2>/dev/null || true)
if [ -n "$AIRBYTE_IMAGES" ]; then
    warn "Found Airbyte images. Remove them? (y/n)"
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        echo "$AIRBYTE_IMAGES" | while read -r image; do
            info "Removing image: $image"
            docker rmi "$image" 2>/dev/null || true
        done
        ok "Removed Airbyte images"
    else
        info "Skipping image removal"
    fi
else
    info "No Airbyte images found"
fi

# 6. REMOVE DOCKER NETWORKS
info "Checking for Airbyte Docker networks..."
AIRBYTE_NETWORKS=$(docker network ls --filter "name=airbyte" --format "{{.Name}}" 2>/dev/null || true)
KIND_NETWORK=$(docker network ls --filter "name=kind" --format "{{.Name}}" 2>/dev/null || true)

if [ -n "$AIRBYTE_NETWORKS" ]; then
    echo "$AIRBYTE_NETWORKS" | while read -r network; do
        info "Removing network: $network"
        docker network rm "$network" 2>/dev/null || true
    done
    ok "Removed Airbyte networks"
fi

if [ -n "$KIND_NETWORK" ]; then
    warn "Found Kind networks: $KIND_NETWORK"
    warn "Remove them? (y/n)"
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        echo "$KIND_NETWORK" | while read -r network; do
            info "Removing network: $network"
            docker network rm "$network" 2>/dev/null || true
        done
        ok "Removed Kind networks"
    fi
fi

# 7. REMOVE ABCTL CONFIGURATION DIRECTORY (Important!)
if [ -d "$HOME/.airbyte" ]; then
    warn "Found abctl config directory: $HOME/.airbyte"
    warn "Remove it? (y/n) - This will delete all abctl configuration, kubeconfig, and data!"
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        info "Removing $HOME/.airbyte..."
        rm -rf "$HOME/.airbyte"
        ok "Removed abctl config directory"
    else
        info "Skipping config directory removal"
    fi
else
    info "No abctl config directory found"
fi

# 8. REMOVE OTHER AIRBYTE DIRECTORIES
if [ -d "$HOME/airbyte" ]; then
    warn "Found Airbyte data directory: $HOME/airbyte"
    warn "Remove it? (y/n)"
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        info "Removing $HOME/airbyte..."
        rm -rf "$HOME/airbyte"
        ok "Removed Airbyte data directory"
    else
        info "Skipping data directory removal"
    fi
fi

# 9. REMOVE WORKSPACE AIRBYTE FILES
WORKSPACE_AIRBYTE=$(find /home/gsowa/sites -maxdepth 2 -type d -name "airbyte" 2>/dev/null || true)
if [ -n "$WORKSPACE_AIRBYTE" ]; then
    warn "Found Airbyte directories in workspace:"
    echo "$WORKSPACE_AIRBYTE"
    warn "Remove them? (y/n)"
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        echo "$WORKSPACE_AIRBYTE" | while read -r dir; do
            info "Removing: $dir"
            rm -rf "$dir"
        done
        ok "Removed workspace Airbyte directories"
    fi
fi

# 10. REMOVE VALUES FILE
if [ -f "/home/gsowa/sites/ubuntu_scripts/airbyte-values.yaml" ]; then
    warn "Found airbyte-values.yaml configuration file"
    warn "Remove it? (y/n)"
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        rm -f "/home/gsowa/sites/ubuntu_scripts/airbyte-values.yaml"
        ok "Removed values file"
    fi
fi

# 11. OPTIONAL: REMOVE ABCTL BINARY
if command -v abctl &> /dev/null; then
    ABCTL_PATH=$(which abctl)
    warn ""
    warn "Found abctl binary at: $ABCTL_PATH"
    warn "Remove abctl binary? (y/n) - You'll need to reinstall it to use Airbyte again"
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        info "Removing abctl..."
        sudo rm -f "$ABCTL_PATH"
        ok "Removed abctl binary"
    else
        info "Keeping abctl binary"
    fi
fi

# 12. OPTIONAL: CLEAN POSTGRESQL AIRBYTE DATABASE
warn ""
warn "Do you want to also drop the PostgreSQL 'airbyte' database and user? (y/n)"
read -r response
if [[ "$response" =~ ^[Yy]$ ]]; then
    info "Dropping PostgreSQL airbyte database and user..."
    sudo -u postgres psql <<EOF
DROP DATABASE IF EXISTS airbyte;
DROP USER IF EXISTS airbyte;
EOF
    ok "Dropped PostgreSQL airbyte database and user"
else
    info "Keeping PostgreSQL airbyte database and user"
fi

# 13. CLEANUP HELM REPOSITORIES
if command -v helm &> /dev/null; then
    info "Checking for Airbyte Helm repository..."
    if helm repo list 2>/dev/null | grep -q airbyte; then
        warn "Remove Airbyte Helm repository? (y/n)"
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            helm repo remove airbyte
            ok "Removed Airbyte Helm repository"
        fi
    fi
fi

echo ""
ok "=========================================="
ok "  Airbyte Cleanup Complete!"
ok "=========================================="
echo ""
info "Summary of what was checked/cleaned:"
echo "  ✓ Airbyte local installation (abctl uninstall)"
echo "  ✓ Kind Kubernetes clusters"
echo "  ✓ Docker containers, volumes, networks, images"
echo "  ✓ abctl configuration directory (~/.airbyte)"
echo "  ✓ Workspace and data directories"
echo "  ✓ Configuration files (values.yaml)"
echo "  ✓ abctl binary (optional)"
echo "  ✓ PostgreSQL database (optional)"
echo "  ✓ Helm repositories (optional)"
echo ""
info "To reinstall Airbyte with abctl, run:"
echo "  1. curl -LsfS https://get.airbyte.com | bash -"
echo "  2. ./fixairbyte.sh"
echo "  3. ./check_postgres.sh --configure-airbyte-db airbyte airbyte yourpassword"
echo "  4. abctl local install --values airbyte-values.yaml"
echo ""