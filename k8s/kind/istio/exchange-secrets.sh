#!/usr/bin/env bash
# BUG FIX #3: Remote secret exchange was completely absent from the project.
#
# In Istio multi-primary multi-network setup, each cluster's istiod must be
# able to query the OTHER cluster's Kubernetes API server to discover its
# services and endpoints. Without this, istiod in cluster-1 has no knowledge
# of billing-service or kafka running in cluster-2, so it cannot generate the
# correct Envoy xDS config for routing cross-cluster calls.
#
# "istioctl create-remote-secret" creates a Kubernetes Secret containing a
# kubeconfig that grants read access to the source cluster's API server.
# When that secret is applied to the target cluster, istiod there uses it
# to watch services, endpoints, and pods in the source cluster.
#
# RUN THIS ONCE after installing Istio on both clusters and before
# deploying any application workloads.

set -euo pipefail

echo "[INFO] Exchanging remote secrets between clusters..."

# Allow cluster-2's istiod to discover services in cluster-1
echo "[INFO] Creating remote secret for cluster-1 → apply to cluster-2"
istioctl create-remote-secret \
  --context=cluster-1 \
  --name=curacloud-cluster-1 \
  | kubectl apply --context=cluster-2 -f -

echo "[OK] cluster-2 can now discover cluster-1 services"

# Allow cluster-1's istiod to discover services in cluster-2
echo "[INFO] Creating remote secret for cluster-2 → apply to cluster-1"
istioctl create-remote-secret \
  --context=cluster-2 \
  --name=curacloud-cluster-2 \
  | kubectl apply --context=cluster-1 -f -

echo "[OK] cluster-1 can now discover cluster-2 services"

echo ""
echo "[INFO] Verifying remote cluster sync (allow ~15s for istiod to sync)..."
sleep 15

echo "  cluster-1 sees:"
istioctl remote-clusters --context=cluster-1

echo "  cluster-2 sees:"
istioctl remote-clusters --context=cluster-2

echo ""
echo "[OK] Secret exchange complete."
echo "     Both clusters should now appear in each other's remote-clusters list."
echo "     If a cluster shows STATUS=istiodNotReady, wait 30s and retry."
