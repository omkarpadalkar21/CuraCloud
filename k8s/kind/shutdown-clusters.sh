#!/usr/bin/env bash
# =============================================================================
# CuraCloud — Multi-Cluster Shutdown Script
# Run this before PC reboot or to free up resources when not developing.
# Usage: bash k8s/kind/shutdown-clusters.sh
# =============================================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC}   $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }

info "Initiating graceful shutdown of CuraCloud Kind clusters..."

# Function to gracefully stop a cluster
shutdown_cluster() {
  local node=$1
  
  STATUS=$(docker inspect -f '{{.State.Status}}' "$node" 2>/dev/null || echo "missing")
  if [ "$STATUS" = "running" ]; then
    info "  Stopping $node... this may take a moment to gracefully terminate Pods."
    docker stop -t 60 "$node" > /dev/null
    success "$node successfully stopped."
  elif [ "$STATUS" = "exited" ]; then
    success "$node is already stopped."
  else
    warn "Container $node not found. Has it been deleted?"
  fi
}

shutdown_cluster "curacloud-cluster-1-control-plane"
shutdown_cluster "curacloud-cluster-2-control-plane"

# Stop any dangling port-forward processes (optional cleanup)
info "Cleaning up background port-forwarding processes..."
pkill -f "kubectl port-forward" 2>/dev/null || true
success "Cleaned up background processes."

echo ""
success "══════════════════════════════════════════════"
success " CuraCloud mesh has been gracefully shutdown. 🛑"
success " Run 'bash k8s/kind/restart-clusters.sh' to bring it back online."
success "══════════════════════════════════════════════"
echo ""
