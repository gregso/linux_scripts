#!/bin/bash
# Increase Airbyte resource limits after installation

set -e

COLOR_GREEN='\033[0;32m'
COLOR_BLUE='\033[0;34m'
COLOR_YELLOW='\033[1;33m'
COLOR_RESET='\033[0m'

info() { echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $*"; }
ok() { echo -e "${COLOR_GREEN}[ OK ]${COLOR_RESET} $*"; }
warn() { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*"; }

echo "=========================================="
echo "  Airbyte Resource Limits Updater"
echo "=========================================="
echo ""

# Check if installation exists
export KUBECONFIG=~/.airbyte/abctl/abctl.kubeconfig

if ! kubectl get deployment airbyte-abctl-worker -n airbyte-abctl &>/dev/null; then
    warn "Airbyte installation not found. Install first with:"
    echo "  abctl local install --values airbyte-values.yaml"
    exit 1
fi

# Show current limits
info "Current resource limits:"
echo ""
echo "Worker:"
kubectl get deployment airbyte-abctl-worker -n airbyte-abctl -o jsonpath='{.spec.template.spec.containers[0].resources}' | jq .
echo ""
echo "Server:"
kubectl get deployment airbyte-abctl-server -n airbyte-abctl -o jsonpath='{.spec.template.spec.containers[0].resources}' | jq .
echo ""

# Prompt for new limits
echo "Enter new resource limits (press Enter to keep current):"
echo ""

read -p "Worker memory limit (e.g., 4Gi): " WORKER_MEM
read -p "Worker CPU limit (e.g., 2000m): " WORKER_CPU
read -p "Server memory limit (e.g., 2Gi): " SERVER_MEM
read -p "Server CPU limit (e.g., 1500m): " SERVER_CPU

echo ""
info "Updating resource limits..."

# Update worker
if [ -n "$WORKER_MEM" ]; then
    kubectl patch deployment airbyte-abctl-worker -n airbyte-abctl --type='json' -p='[
      {
        "op": "replace",
        "path": "/spec/template/spec/containers/0/resources/limits/memory",
        "value": "'$WORKER_MEM'"
      }
    ]'
    ok "Worker memory limit updated to $WORKER_MEM"
fi

if [ -n "$WORKER_CPU" ]; then
    kubectl patch deployment airbyte-abctl-worker -n airbyte-abctl --type='json' -p='[
      {
        "op": "replace",
        "path": "/spec/template/spec/containers/0/resources/limits/cpu",
        "value": "'$WORKER_CPU'"
      }
    ]'
    ok "Worker CPU limit updated to $WORKER_CPU"
fi

# Update server
if [ -n "$SERVER_MEM" ]; then
    kubectl patch deployment airbyte-abctl-server -n airbyte-abctl --type='json' -p='[
      {
        "op": "replace",
        "path": "/spec/template/spec/containers/0/resources/limits/memory",
        "value": "'$SERVER_MEM'"
      }
    ]'
    ok "Server memory limit updated to $SERVER_MEM"
fi

if [ -n "$SERVER_CPU" ]; then
    kubectl patch deployment airbyte-abctl-server -n airbyte-abctl --type='json' -p='[
      {
        "op": "replace",
        "path": "/spec/template/spec/containers/0/resources/limits/cpu",
        "value": "'$SERVER_CPU'"
      }
    ]'
    ok "Server CPU limit updated to $SERVER_CPU"
fi

echo ""
info "Waiting for pods to restart with new limits..."
kubectl rollout status deployment airbyte-abctl-worker -n airbyte-abctl
kubectl rollout status deployment airbyte-abctl-server -n airbyte-abctl

echo ""
ok "Resource limits updated successfully!"
echo ""
info "New resource limits:"
echo ""
echo "Worker:"
kubectl get deployment airbyte-abctl-worker -n airbyte-abctl -o jsonpath='{.spec.template.spec.containers[0].resources}' | jq .
echo ""
echo "Server:"
kubectl get deployment airbyte-abctl-server -n airbyte-abctl -o jsonpath='{.spec.template.spec.containers[0].resources}' | jq .
echo ""

warn "NOTE: These changes are temporary. To make them permanent,"
warn "update your airbyte-values.yaml and run:"
echo "  abctl local install --values airbyte-values.yaml"