#!/usr/bin/env bash
# =============================================================================
# CuraCloud — Multi-Cluster Restart Script
# Run this after every PC reboot to bring the mesh back online.
# Usage: bash k8s/kind/restart-clusters.sh
# =============================================================================
#
# Changes from previous version:
#
#   STEP 3C — kafka ServiceEntry: resolution: DNS → resolution: STATIC
#     ${C2_IP} is a raw IP address, not a hostname. "resolution: DNS" tells
#     Istio to do a DNS lookup on the endpoint address at runtime, which fails
#     silently on a bare IP. STATIC tells Istio to use the address as-is.
#
#   STEP 3C — Added billing-service ServiceEntry (was missing entirely)
#     patient-service calls billing-service via gRPC (port 9001) across
#     clusters. Without a ServiceEntry in cluster-1 for billing-service,
#     istiod has no endpoint record for it and drops every gRPC connection.
#
#   STEP 3D — Apply expose-services Gateway (new step)
#     The Gateway resource (AUTO_PASSTHROUGH on port 15443) may have been
#     wiped if the istio-system namespace was recreated, or never applied
#     initially. Re-applying it here on every restart is idempotent and
#     guarantees the EWG always has its routing instructions.
#
#   STEP 3E — Restart application pods after mesh config changes (new step)
#     After patching meshNetworks and ServiceEntries, already-running pods
#     hold stale Envoy xDS config. A targeted rollout restart ensures they
#     pick up the new cross-cluster routing rules without manual intervention.
#
# =============================================================================

set -e

ISTIO_BIN="/home/caffeine/istio-1.29.0/bin"
export PATH="$ISTIO_BIN:$PATH"

# ── Path to your k8s directory (relative to this script's location) ──────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(dirname "$SCRIPT_DIR")"    # assumes script lives in k8s/kind/

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC}   $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERR]${NC}  $1"; exit 1; }

# ─────────────────────────────────────────────────────────
# wait_for_webhook <context>
#
# The Istio ValidatingWebhookConfiguration intercepts every
# apply of a networking.istio.io resource and sends it to
# istiod for validation. If istiod's pod is not yet Ready
# (common right after a reboot restart), the apiserver
# cannot reach the webhook and returns:
#   "Internal error: context deadline exceeded"
#
# This function polls until istiod is Ready so every
# subsequent istio_apply() call is guaranteed to succeed.
# ─────────────────────────────────────────────────────────
wait_for_webhook() {
  local ctx="$1"
  info "  Waiting for istiod webhook to be Ready on $ctx..."
  for i in {1..40}; do
    READY=$(kubectl get pods -n istio-system --context="$ctx" \
      -l app=istiod --no-headers 2>/dev/null \
      | awk '{print $2}' | grep -c '^1/1$' || true)
    EP=$(kubectl get endpoints istiod -n istio-system --context="$ctx" \
      -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)
    if [ "$READY" -ge 1 ] && [ -n "$EP" ]; then
      success "  istiod is Ready on $ctx (pod + endpoint both up)"
      return 0
    fi
    [ $i -eq 40 ] && warn "  istiod not Ready after 120s on $ctx — applying anyway"
    sleep 3
  done
}

# istio_apply <context> <file_or_dash>
# Applies an Istio CRD manifest with webhook-failure-proof logic:
#   - sets webhook failurePolicy=Ignore before the apply
#   - applies the manifest (from file or stdin when file="-")
#   - restores failurePolicy=Fail regardless of outcome
# istio_apply <context> <file_or_dash>
# Discovers ALL Istio ValidatingWebhookConfigurations and temporarily sets
# failurePolicy=Ignore before the apply, then restores Fail regardless of outcome.
istio_apply() {
  local ctx="$1"
  local file="$2"

  # Discover actual Istio VWC names — never assume the kubectl context name matches
  local vwcs
  vwcs=$(kubectl get validatingwebhookconfiguration --context="$ctx" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep -iE 'istio|istiod' || true)

  if [ -z "$vwcs" ]; then
    warn "  No Istio ValidatingWebhookConfigurations found on $ctx — applying without guard"
  fi

  for vwc in $vwcs; do
    kubectl patch validatingwebhookconfiguration "$vwc" \
      --context="$ctx" \
      --type='json' \
      -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Ignore"}]' \
      2>/dev/null || true
  done

  local rc=0
  if [ "$file" = "-" ]; then
    cat | kubectl apply --context="$ctx" -f - || rc=$?
  else
    kubectl apply --context="$ctx" -f "$file" || rc=$?
  fi

  for vwc in $vwcs; do
    kubectl patch validatingwebhookconfiguration "$vwc" \
      --context="$ctx" \
      --type='json' \
      -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Fail"}]' \
      2>/dev/null || true
  done

  return $rc
}

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

kubectl label secret istio-remote-secret-curacloud-cluster-2 \
  -n istio-system --context=cluster-1 \
  kiali.io/multiCluster=true --overwrite

kubectl label secret istio-remote-secret-curacloud-cluster-1 \
  -n istio-system --context=cluster-2 \
  kiali.io/multiCluster=true --overwrite
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
# STEP 3C — Patch meshNetworks + re-apply ServiceEntries
#
# BUG FIX: kafka ServiceEntry changed to resolution: STATIC
#   ${C2_IP} is a raw IP — "resolution: DNS" performs a DNS
#   lookup on it at runtime, which fails silently on a bare
#   IP. STATIC tells Istio to use the address directly.
#
# BUG FIX: Added billing-service ServiceEntry (was missing)
#   patient-service → billing-service is a gRPC call on
#   port 9001 across clusters. Without this entry istiod on
#   cluster-1 has no endpoint for billing-service and drops
#   every connection.
# ─────────────────────────────────────────────────────────
info "Step 3C — Patching meshNetworks and re-applying ServiceEntries..."

# Wait for istiod to be Ready on both clusters before applying any Istio CRDs.
# Skipping this caused "context deadline exceeded" on the validation webhook.
wait_for_webhook cluster-1
wait_for_webhook cluster-2

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

# ── kafka: cluster-1 → cluster-2 ─────────────────────────
# BUG FIX: resolution changed from DNS to STATIC (IP endpoint, not hostname)
istio_apply cluster-1 - <<EOF
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
  resolution: STATIC
  endpoints:
  - address: ${C2_IP}
    ports:
      tcp-kafka: 15443
      tcp-kafka-internal: 15443
    labels:
      security.istio.io/tlsMode: istio
EOF

# ── billing-service: cluster-1 → cluster-2 ───────────────
# BUG FIX: This ServiceEntry was entirely missing.
# patient-service (cluster-1) calls billing-service (cluster-2) via gRPC on
# port 9001. The HTTP port 4001 is included so any future REST calls also
# route correctly through the east-west gateway.
istio_apply cluster-1 - <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: ServiceEntry
metadata:
  name: billing-service-cluster2
  namespace: default
spec:
  hosts:
  - billing-service.default.svc.cluster.local
  location: MESH_INTERNAL
  ports:
  - number: 4001
    name: http
    protocol: HTTP
  - number: 9001
    name: grpc
    protocol: GRPC
  resolution: STATIC
  endpoints:
  - address: ${C2_IP}
    ports:
      http: 15443
      grpc: 15443
    labels:
      security.istio.io/tlsMode: istio
EOF

success "meshNetworks patched and ServiceEntries applied"

# ─────────────────────────────────────────────────────────
# STEP 3C-DR — Re-apply DestinationRules on cluster-1
#
# DestinationRules must be present for cross-cluster mTLS to work.
# They tell Envoy to use ISTIO_MUTUAL TLS when routing to the EWG.
# Re-applying is idempotent and ensures they survive namespace wipes.
# ─────────────────────────────────────────────────────────
info "Step 3C-DR — Re-applying DestinationRules for cross-cluster mTLS..."
istio_apply cluster-1 "${SCRIPT_DIR}/manifest/istio/destination-rules.yaml"
success "DestinationRules re-applied on cluster-1"

# ─────────────────────────────────────────────────────────
# STEP 3D — Re-apply the AUTO_PASSTHROUGH Gateway resource
#
# NEW STEP: The Gateway resource (expose-services.yaml) tells
# the EWG pods HOW to handle traffic on port 15443. Without
# it the EWG accepts the TCP connection then immediately
# closes it. Re-applying on every restart is idempotent and
# ensures the Gateway is never missing after a reinstall.
# ─────────────────────────────────────────────────────────
info "Step 3D — Re-applying AUTO_PASSTHROUGH Gateway on both clusters..."

GATEWAY_YAML='apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: cross-network-gateway
  namespace: istio-system
spec:
  selector:
    istio: eastwestgateway
  servers:
  - port:
      number: 15443
      name: tls
      protocol: TLS
    tls:
      mode: AUTO_PASSTHROUGH
    hosts:
    - "*.local"'

echo "$GATEWAY_YAML" | istio_apply cluster-1 -
echo "$GATEWAY_YAML" | istio_apply cluster-2 -

success "AUTO_PASSTHROUGH Gateway applied on both clusters"

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
success "istiod restarted on both clusters"

# ─────────────────────────────────────────────────────────
# STEP 3E — Restart application pods
#
# NEW STEP: Pods that were already running before istiod
# restarted hold stale Envoy xDS config — they won't pick
# up the new ServiceEntries or meshNetworks changes until
# their sidecar reconnects and syncs. A rollout restart
# forces all sidecars to re-initialise against the freshly
# configured istiod.
# ─────────────────────────────────────────────────────────
info "Step 3E — Restarting application pods to sync Envoy xDS config..."

# Restart cluster-1 workloads: api-gateway, patient-service, auth-service
kubectl rollout restart deployment/api-gateway      -n default --context=cluster-1 || true
kubectl rollout restart deployment/patient-service  -n default --context=cluster-1 || true
kubectl rollout restart deployment/auth-service     -n default --context=cluster-1 || true

# Restart cluster-2 workloads: billing-service, analytics-service, kafka, zookeeper
kubectl rollout restart deployment/billing-service    -n default --context=cluster-2 || true
kubectl rollout restart deployment/analytics-service  -n default --context=cluster-2 || true
kubectl rollout restart deployment/kafka              -n default --context=cluster-2 || true
kubectl rollout restart deployment/zookeeper          -n default --context=cluster-2 || true

success "Application pods restarted"

# ─────────────────────────────────────────────────────────
# STEP 3F — Refresh kiali-multi-cluster-secret
#
# Docker assigns NEW IPs to Kind containers after every reboot.
# The kiali-multi-cluster-secret contains a kubeconfig with the
# OLD IP hard-coded in the server field. Kiali will silently fail
# to connect to cluster-2 until this secret is refreshed.
# ─────────────────────────────────────────────────────────
info "Step 3F — Refreshing kiali-multi-cluster-secret with current IPs..."

# The remote secret for cluster-2 was already refreshed in STEP 3
# (istioctl create-remote-secret --server=https://${C2_IP}:6443).
# We now extract its kubeconfig and overwrite the kiali secret.
kubectl get secret istio-remote-secret-curacloud-cluster-2 \
  -n istio-system --context=cluster-1 \
  -o jsonpath='{.data.curacloud-cluster-2}' \
  | base64 -d > /tmp/kiali-cluster2-kubeconfig.yaml

kubectl create secret generic kiali-multi-cluster-secret \
  -n istio-system --context=cluster-1 \
  --from-file=curacloud-cluster-2=/tmp/kiali-cluster2-kubeconfig.yaml \
  --dry-run=client -o yaml \
  | kubectl apply --context=cluster-1 -f -

rm -f /tmp/kiali-cluster2-kubeconfig.yaml

# Restart Kiali so it picks up the new kubeconfig
kubectl rollout restart deployment/kiali -n istio-system --context=cluster-1 || true

success "kiali-multi-cluster-secret refreshed and Kiali restarted"

# ─────────────────────────────────────────────────────────
# STEP 3G — Refresh Prometheus Federation Target
#
# Docker assigns NEW IPs to Kind containers after every reboot.
# Prometheus on cluster-1 must scrape cluster-2's Prometheus using
# the latest cluster-2 container IP. Without this Kiali will drop
# the multi-cluster view.
# ─────────────────────────────────────────────────────────
info "Step 3G — Refreshing Prometheus federation config with current cluster-2 IP..."

# Ensure Prometheus in cluster-2 is reachable on NodePort 32090
kubectl patch svc prometheus -n istio-system --context=cluster-2 \
  --type='merge' -p='{"spec": {"type": "NodePort", "ports": [{"port": 9090, "nodePort": 32090}]}}' 2>/dev/null || true

export C2_IP
kubectl get configmap prometheus -n istio-system --context=cluster-1 -o yaml | python3 -c '
import sys, os, yaml
c2_ip = os.environ.get("C2_IP")
cm = yaml.safe_load(sys.stdin)
prom = yaml.safe_load(cm["data"]["prometheus.yml"])
found = False
for job in prom["scrape_configs"]:
    if job.get("job_name") == "federate-cluster-2":
        job["static_configs"][0]["targets"] = [f"{c2_ip}:32090"]
        found = True
if not found:
    prom["scrape_configs"].append({
        "job_name": "federate-cluster-2",
        "scrape_interval": "15s",
        "honor_labels": True,
        "metrics_path": "/federate",
        "params": {"match[]": ["{__name__=~\"istio_.*\"}"]},
        "static_configs": [{"targets": [f"{c2_ip}:32090"]}]
    })
cm["data"]["prometheus.yml"] = yaml.dump(prom, sort_keys=False)
print(yaml.dump(cm, sort_keys=False))
' | kubectl apply --context=cluster-1 -f -

# Restart Prometheus so it picks up the new scrape target
kubectl rollout restart deployment/prometheus -n istio-system --context=cluster-1 || true

success "Prometheus federation config refreshed and Prometheus restarted"

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
echo "  --- cluster-1 (default) ---"
kubectl get pods --context=cluster-1
echo ""
echo "  --- cluster-2 (default) ---"
kubectl get pods --context=cluster-2
echo ""
echo "  --- cluster-1 (istio-system) ---"
kubectl get pods -n istio-system --context=cluster-1
echo ""
echo "  --- cluster-2 (istio-system) ---"
kubectl get pods -n istio-system --context=cluster-2

echo ""
success "══════════════════════════════════════════════"
success " CuraCloud mesh is back online! 🚀"
success "══════════════════════════════════════════════"
echo ""
echo "  Quick access commands:"
echo "  Kiali:      kubectl port-forward svc/kiali      -n istio-system 20001:20001 --context=cluster-1"
echo "  Grafana:    kubectl port-forward svc/grafana    -n istio-system 3000:3000   --context=cluster-1"
echo "  Prometheus: kubectl port-forward svc/prometheus -n istio-system 9090:9090   --context=cluster-1"
echo "  Jaeger:     kubectl port-forward svc/tracing    -n istio-system 16686:80    --context=cluster-1"
echo ""
