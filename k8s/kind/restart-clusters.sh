#!/usr/bin/env bash
# =============================================================================
# CuraCloud — Multi-Cluster Restart Script
# Run this after every PC reboot to bring the mesh back online.
# Usage: bash k8s/kind/restart-clusters.sh
# =============================================================================

set -e

ISTIO_BIN="/home/caffeine/istio-1.29.0/bin"
export PATH="$ISTIO_BIN:$PATH"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC}   $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERR]${NC}  $1"; exit 1; }

# ─────────────────────────────────────────────────────────
# STEP 1 — Restart Docker nodes (Kind clusters are just
#           Docker containers; they stop on PC shutdown)
# ─────────────────────────────────────────────────────────
info "Step 1 — Starting Kind cluster Docker containers..."

for node in curacloud-cluster-1-control-plane curacloud-cluster-2-control-plane; do
  STATUS=$(docker inspect -f '{{.State.Status}}' "$node" 2>/dev/null || echo "missing")
  if [ "$STATUS" = "running" ]; then
    success "$node is already running"
  elif [ "$STATUS" = "exited" ]; then
    docker start "$node"
    success "$node started"
  else
    error "Container $node not found. Did you delete the clusters? Run the full setup instead."
  fi
done

# ─────────────────────────────────────────────────────────
# STEP 1B — Refresh kubeconfig credentials
# Kind tokens go stale after a reboot; re-exporting fixes
# the "Unauthorized" error on kubectl port-forward.
# ─────────────────────────────────────────────────────────
info "Step 1B — Refreshing kubeconfig credentials..."
kind export kubeconfig --name curacloud-cluster-1 &>/dev/null
kind export kubeconfig --name curacloud-cluster-2 &>/dev/null
success "kubeconfig refreshed for both clusters"

# ─────────────────────────────────────────────────────────
# STEP 1C — Fix kubelet.conf IP (Docker may assign new IPs
#   after a reboot; kubelet.conf has the old IP hardcoded,
#   causing x509 cert errors and nodes staying NotReady)
# ─────────────────────────────────────────────────────────
info "Step 1C — Patching kubelet.conf with current Docker IPs..."

C1_IP_EARLY=$(docker inspect curacloud-cluster-1-control-plane \
  --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
C2_IP_EARLY=$(docker inspect curacloud-cluster-2-control-plane \
  --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')

docker exec curacloud-cluster-1-control-plane \
  sed -i "s|server: https://[0-9.]*:6443|server: https://${C1_IP_EARLY}:6443|g" \
  /etc/kubernetes/kubelet.conf
docker exec curacloud-cluster-2-control-plane \
  sed -i "s|server: https://[0-9.]*:6443|server: https://${C2_IP_EARLY}:6443|g" \
  /etc/kubernetes/kubelet.conf

docker exec curacloud-cluster-1-control-plane systemctl restart kubelet
docker exec curacloud-cluster-2-control-plane systemctl restart kubelet

success "kubelet.conf patched and kubelet restarted on both nodes"

info "  Waiting 30s for nodes to become Ready..."
sleep 30

for ctx in cluster-1 cluster-2; do
  for i in {1..15}; do
    STATUS=$(kubectl get nodes --context="$ctx" --no-headers 2>/dev/null | awk '{print $2}' | head -1)
    if [ "$STATUS" = "Ready" ]; then
      success "$ctx node is Ready"
      break
    fi
    [ $i -eq 15 ] && warn "$ctx node still NotReady — continuing anyway"
    sleep 5
  done
done

# ─────────────────────────────────────────────────────────
# STEP 2 — Wait for API servers to become ready
# ─────────────────────────────────────────────────────────
info "Step 2 — Waiting for API servers to be ready..."
sleep 10

for ctx in cluster-1 cluster-2; do
  for i in {1..20}; do
    if kubectl cluster-info --context="$ctx" &>/dev/null; then
      success "$ctx API server is ready"
      break
    fi
    [ $i -eq 20 ] && error "$ctx API server never became ready"
    sleep 3
  done
done

# ─────────────────────────────────────────────────────────
# STEP 3 — Fix remote secrets (Docker may assign new IPs
#           after a reboot, causing cross-cluster timeouts)
# ─────────────────────────────────────────────────────────
info "Step 3 — Refreshing remote secrets with current Docker IPs..."

C1_IP=$(docker inspect curacloud-cluster-1-control-plane \
  --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
C2_IP=$(docker inspect curacloud-cluster-2-control-plane \
  --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')

info "  cluster-1 IP → $C1_IP"
info "  cluster-2 IP → $C2_IP"

# Delete old secrets first (ignore errors if they don't exist)
kubectl delete secret istio-remote-secret-curacloud-cluster-1 \
  -n istio-system --context=cluster-2 --ignore-not-found
kubectl delete secret istio-remote-secret-curacloud-cluster-2 \
  -n istio-system --context=cluster-1 --ignore-not-found

# Recreate with current IPs
istioctl create-remote-secret \
  --context=cluster-1 \
  --name=curacloud-cluster-1 \
  --server="https://${C1_IP}:6443" | kubectl apply -f - --context=cluster-2

istioctl create-remote-secret \
  --context=cluster-2 \
  --name=curacloud-cluster-2 \
  --server="https://${C2_IP}:6443" | kubectl apply -f - --context=cluster-1

success "Remote secrets updated"

# ─────────────────────────────────────────────────────────
# STEP 3B — Patch East-West Gateways with Node IPs
# ─────────────────────────────────────────────────────────
info "Step 3B — Patching East-West Gateways so cross-cluster traffic works without MetalLB..."

kubectl patch svc istio-eastwestgateway -n istio-system --context=cluster-1 \
  --type='json' -p="[{\"op\": \"add\", \"path\": \"/spec/externalIPs\", \"value\": [\"${C1_IP}\"]}]" || true

kubectl patch svc istio-eastwestgateway -n istio-system --context=cluster-2 \
  --type='json' -p="[{\"op\": \"add\", \"path\": \"/spec/externalIPs\", \"value\": [\"${C2_IP}\"]}]" || true

success "East-West Gateways patched"

# ─────────────────────────────────────────────────────────
# STEP 3C — Patch meshNetworks so istiod knows to route
#   cross-network traffic through the East-West Gateways.
#   Without this the global-mtls DestinationRule cannot
#   select the right EWG endpoint and gRPC/mTLS to remote
#   services (e.g. billing-service) will fail with
#   CERTIFICATE_VERIFY_FAILED.
#   Also (re-)apply the kafka ServiceEntry so cluster-1
#   pods can reach kafka which lives on cluster-2.
# ─────────────────────────────────────────────────────────
info "Step 3C — Patching meshNetworks and re-applying kafka ServiceEntry..."

MESH_NETWORKS_YAML="networks:
  network1:
    endpoints:
    - fromRegistry: curacloud-cluster-1
    gateways:
    - address: ${C1_IP}
      port: 15443
  network2:
    endpoints:
    - fromRegistry: curacloud-cluster-2
    gateways:
    - address: ${C2_IP}
      port: 15443"

kubectl patch configmap istio -n istio-system --context=cluster-1 \
  --type merge -p "{\"data\":{\"meshNetworks\":$(echo "$MESH_NETWORKS_YAML" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')}}"

kubectl patch configmap istio -n istio-system --context=cluster-2 \
  --type merge -p "{\"data\":{\"meshNetworks\":$(echo "$MESH_NETWORKS_YAML" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')}}"

# ServiceEntry so cluster-1 pods can reach kafka (lives only on cluster-2)
kubectl apply --context=cluster-1 -f - <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: ServiceEntry
metadata:
  name: kafka-cluster2
  namespace: default
spec:
  hosts:
  - kafka.default.svc.cluster.local
  location: MESH_INTERNAL
  ports:
  - number: 9092
    name: tcp-kafka
    protocol: TCP
  - number: 29092
    name: tcp-kafka-internal
    protocol: TCP
  resolution: DNS
  endpoints:
  - address: ${C2_IP}
    ports:
      tcp-kafka: 15443
      tcp-kafka-internal: 15443
    labels:
      security.istio.io/tlsMode: istio
EOF

success "meshNetworks patched and kafka ServiceEntry applied"

# ─────────────────────────────────────────────────────────
# STEP 4 — Restart istiod to pick up new secrets +
#           meshNetworks changes
# (rollout status is best-effort — istiod may take >90s
#  on resource-constrained nodes; script continues anyway)
# ─────────────────────────────────────────────────────────
info "Step 4 — Restarting istiod on both clusters..."
kubectl rollout restart deployment/istiod -n istio-system --context=cluster-1
kubectl rollout restart deployment/istiod -n istio-system --context=cluster-2
info "  Waiting up to 3 min for istiod on cluster-1..."
kubectl rollout status deployment/istiod -n istio-system --context=cluster-1 --timeout=180s || \
  warn "cluster-1 istiod rollout timed out — continuing anyway (check manually)"
info "  Waiting up to 3 min for istiod on cluster-2..."
kubectl rollout status deployment/istiod -n istio-system --context=cluster-2 --timeout=180s || \
  warn "cluster-2 istiod rollout timed out — continuing anyway (check manually)"
success "istiod restart triggered on both clusters"

# ─────────────────────────────────────────────────────────
# STEP 5 — Verify cross-cluster sync
# ─────────────────────────────────────────────────────────
info "Step 5 — Verifying cross-cluster sync (waiting 15s for istiod)..."
sleep 15

echo ""
echo "  cluster-1 view:"
istioctl remote-clusters --context=cluster-1
echo ""
echo "  cluster-2 view:"
istioctl remote-clusters --context=cluster-2
echo ""

# ─────────────────────────────────────────────────────────
# STEP 6 — Show pod health
# ─────────────────────────────────────────────────────────
info "Step 6 — Pod status:"
echo ""
echo "  --- cluster-1 ---"
kubectl get pods --context=cluster-1
echo ""
echo "  --- cluster-2 ---"
kubectl get pods --context=cluster-2

echo ""
success "══════════════════════════════════════════════"
success " CuraCloud mesh is back online! 🚀"
success "══════════════════════════════════════════════"
echo ""
echo "  Quick access commands:"
echo "  Kiali:      kubectl port-forward svc/kiali -n istio-system 20001:20001 --context=cluster-1"
echo "  Grafana:    kubectl port-forward svc/grafana -n istio-system 3000:3000 --context=cluster-1"
echo "  Prometheus: kubectl port-forward svc/prometheus -n istio-system 9090:9090 --context=cluster-1"
echo "  Jaeger:     kubectl port-forward svc/tracing -n istio-system 16686:80 --context=cluster-1"
echo ""
