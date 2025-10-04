#!/bin/bash
# Pre-pull Airbyte Docker images to avoid downloading during install

set -e

COLOR_GREEN='\033[0;32m'
COLOR_BLUE='\033[0;34m'
COLOR_YELLOW='\033[1;33m'
COLOR_RESET='\033[0m'

info() { echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $*"; }
ok() { echo -e "${COLOR_GREEN}[ OK ]${COLOR_RESET} $*"; }
warn() { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*"; }

echo "=========================================="
echo "  Airbyte Image Pre-pull Script"
echo "=========================================="
echo ""

# Airbyte version (update this to match your version)
VERSION="1.8.5"

# List of Airbyte images
IMAGES=(
    "airbyte/server:${VERSION}"
    "airbyte/worker:${VERSION}"
    "airbyte/webapp:${VERSION}"
    "airbyte/container-orchestrator:${VERSION}"
    "airbyte/workload-init-container:${VERSION}"
    "airbyte/workload-launcher:${VERSION}"
    "airbyte/workload-api-server:${VERSION}"
    "airbyte/connector-builder-server:${VERSION}"
    "airbyte/cron:${VERSION}"
    "airbyte/temporal:${VERSION}"
    "kindest/node:v1.32.2"
)

info "Pulling Airbyte images..."
echo ""

for image in "${IMAGES[@]}"; do
    if docker image inspect "$image" &> /dev/null; then
        ok "Already cached: $image"
    else
        info "Pulling: $image"
        if docker pull "$image"; then
            ok "Downloaded: $image"
        else
            warn "Failed to pull: $image (might not exist)"
        fi
    fi
done

echo ""
ok "All images ready!"
echo ""
info "You can now run: abctl local install --values airbyte-values.yaml"
