#!/usr/bin/env bash
# =============================================================================
# CuraCloud — First-Time Setup / Apply All Fixes
# Run this ONCE after a fresh Istio install on both clusters, or any time
# you need to reapply everything from scratch (e.g. after wiping istio-system).
#
# Prerequisites:
#   1. Both KinD clusters are running  (kind get clusters should show both)
#   2. Istio is installed on both clusters using the fixed IstioOperator configs:
#        istioctl install -f k8s/istio/cluster-1-istio.yaml --context=cluster-1 -y
#        istioctl install -f k8s/istio/cluster-2-istio.yaml --context=cluster-2 -y
#   3. kubectl contexts named "cluster-1" and "cluster-2" exist
#        (run: kind export kubeconfig --name curacloud-cluster-1)
#        (run: kind export kubeconfig --name curacloud-cluster-2)
#
# Usage:
#   chmod +x k8s/setup-mesh.sh
#   bash k8s/setup-mesh.sh
# =============================================================================

set -euo pipefail

ISTIO_BIN="/home/caffeine/istio-1.29.0/bin"
export PATH="$ISTIO_BIN:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC}   $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERR]${NC}  $1"; exit 1; }

# ─────────────────────────────────────────────────────────
# wait_for_webhook <context>
#
# Root cause of the "context deadline exceeded" error:
#   Istio installs a ValidatingWebhookConfiguration that
#   intercepts every apply of a networking.istio.io resource
#   (Gateway, ServiceEntry, VirtualService, etc.) and sends
#   it to istiod for validation. On a fresh install, or
#   right after a reboot, istiod's pod may not yet be Ready
#   and the kube-apiserver cannot reach the webhook endpoint.
#   The apiserver then returns "Internal error: context
#   deadline exceeded" and the apply fails hard.
#
# This function:
#   1. Polls until the istiod pod is Running + Ready.
#   2. Temporarily patches the webhook failurePolicy to
#      "Ignore" so that — even if the webhook is briefly
#      unreachable during a timing window — the apply goes
#      through instead of hard-failing.
#   3. Applies the resource(s) passed as arguments.
#   4. Restores failurePolicy back to "Fail" so the webhook
#      resumes enforcing validation normally.
# ─────────────────────────────────────────────────────────
wait_for_webhook() {
  local ctx="$1"
  info "  Waiting for istiod webhook to be Ready on $ctx..."
  for i in {1..40}; do
    READY=$(kubectl get pods -n istio-system --context="$ctx" \
      -l app=istiod --no-headers 2>/dev/null \
      | awk '{print $2}' | grep -c '^1/1$' || true)
    if [ "$READY" -ge 1 ]; then
      success "  istiod is Ready on $ctx"
      return 0
    fi
    [ $i -eq 40 ] && warn "  istiod not Ready after 120s on $ctx — applying anyway"
    sleep 3
  done
}

# istio_apply <context> <file_or_dash>
# Applies an Istio CRD manifest with webhook-failure-proof logic:
#   - sets failurePolicy=Ignore before the apply
#   - applies the manifest
#   - restores failurePolicy=Fail afterward
# Pass "-" as the file argument to read from stdin.
istio_apply() {
  local ctx="$1"
  local file="$2"

  # Temporarily set webhook to Ignore so a slow-starting
  # istiod doesn't hard-block the apply
  kubectl patch validatingwebhookconfiguration istio-validator-"$ctx" \
    --context="$ctx" \
    --type='json' \
    -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Ignore"}]' \
    2>/dev/null || true

  if [ "$file" = "-" ]; then
    cat | kubectl apply --context="$ctx" -f -
  else
    kubectl apply --context="$ctx" -f "$file"
  fi
  local rc=$?

  # Always restore to Fail
  kubectl patch validatingwebhookconfiguration istio-validator-"$ctx" \
    --context="$ctx" \
    --type='json' \
    -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Fail"}]' \
    2>/dev/null || true

  return $rc
}

# ─────────────────────────────────────────────────────────
# Preflight checks
# ─────────────────────────────────────────────────────────
info "Preflight — checking tools and waiting for webhooks..."
for tool in kubectl istioctl kind docker python3; do
  command -v "$tool" &>/dev/null || error "'$tool' not found in PATH"
done

for ctx in cluster-1 cluster-2; do
  kubectl cluster-info --context="$ctx" &>/dev/null \
    || error "kubectl context '$ctx' not reachable. Run: kind export kubeconfig --name curacloud-$ctx"
done
success "All tools and contexts found"

# Wait for istiod on both clusters before attempting any Istio CRD applies.
# This prevents the "context deadline exceeded" webhook error that occurs when
# istiod pods are not yet Ready and the kube-apiserver cannot reach the
# validation webhook endpoint.
wait_for_webhook cluster-1
wait_for_webhook cluster-2
# (KinD has no cloud LoadBalancer; we use externalIPs on
#  the EWG service pointing to the Docker node IP instead)
# ─────────────────────────────────────────────────────────
info "Resolving Docker node IPs..."
C1_IP=$(docker inspect curacloud-cluster-1-control-plane \
  --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
C2_IP=$(docker inspect curacloud-cluster-2-control-plane \
  --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')

[[ -z "$C1_IP" ]] && error "Could not get IP for curacloud-cluster-1-control-plane"
[[ -z "$C2_IP" ]] && error "Could not get IP for curacloud-cluster-2-control-plane"

info "  cluster-1 node IP → $C1_IP"
info "  cluster-2 node IP → $C2_IP"

# ─────────────────────────────────────────────────────────
# STEP 1 — Enable sidecar injection on the default namespace
# Pods need the Envoy sidecar to participate in the mesh.
# Apply BEFORE deploying workloads; restart them afterward.
# ─────────────────────────────────────────────────────────
info "Step 1 — Enabling sidecar injection on namespace 'default'..."
kubectl apply --context=cluster-1 -f "${SCRIPT_DIR}/manifest/namespace.yaml"
kubectl apply --context=cluster-2 -f "${SCRIPT_DIR}/manifest/namespace.yaml"
success "Sidecar injection label set on default namespace (both clusters)"

# ─────────────────────────────────────────────────────────
# STEP 2 — Apply the AUTO_PASSTHROUGH Gateway resource
# This tells the EWG pods what to do with traffic on 15443.
# Without it the EWG drops every cross-cluster connection.
# ─────────────────────────────────────────────────────────
info "Step 2 — Applying AUTO_PASSTHROUGH Gateway on both clusters..."
istio_apply cluster-1 "${SCRIPT_DIR}/istio/expose-services.yaml"
istio_apply cluster-2 "${SCRIPT_DIR}/istio/expose-services.yaml"
success "Gateway/cross-network-gateway applied on both clusters"

# ─────────────────────────────────────────────────────────
# STEP 3 — Patch East-West Gateway services with node IPs
# KinD has no cloud LoadBalancer so .status.loadBalancer
# stays empty. We manually set externalIPs to the Docker
# node IP so the EWG is reachable from the other cluster.
# ─────────────────────────────────────────────────────────
info "Step 3 — Patching EWG services with Docker node IPs..."

kubectl patch svc istio-eastwestgateway -n istio-system --context=cluster-1 \
  --type='json' -p="[{\"op\":\"add\",\"path\":\"/spec/externalIPs\",\"value\":[\"${C1_IP}\"]}]" || true

kubectl patch svc istio-eastwestgateway -n istio-system --context=cluster-2 \
  --type='json' -p="[{\"op\":\"add\",\"path\":\"/spec/externalIPs\",\"value\":[\"${C2_IP}\"]}]" || true

success "EWG externalIPs set"

# ─────────────────────────────────────────────────────────
# STEP 4 — Remote secret exchange
# Each istiod must be able to query the other cluster's
# API server to discover services and endpoints.
# ─────────────────────────────────────────────────────────
info "Step 4 — Exchanging remote secrets..."

kubectl delete secret istio-remote-secret-curacloud-cluster-1 \
  -n istio-system --context=cluster-2 --ignore-not-found
kubectl delete secret istio-remote-secret-curacloud-cluster-2 \
  -n istio-system --context=cluster-1 --ignore-not-found

istioctl create-remote-secret \
  --context=cluster-1 \
  --name=curacloud-cluster-1 \
  --server="https://${C1_IP}:6443" | kubectl apply -f - --context=cluster-2

istioctl create-remote-secret \
  --context=cluster-2 \
  --name=curacloud-cluster-2 \
  --server="https://${C2_IP}:6443" | kubectl apply -f - --context=cluster-1

success "Remote secrets applied"

# ─────────────────────────────────────────────────────────
# STEP 5 — Patch meshNetworks configmap
# Tells istiod in each cluster which gateway IP/port to
# use when routing traffic to the other network.
# ─────────────────────────────────────────────────────────
info "Step 5 — Patching meshNetworks on both clusters..."

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

MESH_JSON=$(echo "$MESH_NETWORKS_YAML" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')

kubectl patch configmap istio -n istio-system --context=cluster-1 \
  --type merge -p "{\"data\":{\"meshNetworks\":${MESH_JSON}}}"

kubectl patch configmap istio -n istio-system --context=cluster-2 \
  --type merge -p "{\"data\":{\"meshNetworks\":${MESH_JSON}}}"

success "meshNetworks patched on both clusters"

# ─────────────────────────────────────────────────────────
# STEP 6 — Apply ServiceEntries on cluster-1
#
# kafka: patient-service publishes events to kafka which
#   lives only on cluster-2. resolution: STATIC is required
#   because ${C2_IP} is an IP, not a resolvable hostname.
#
# billing-service: patient-service calls billing-service
#   via gRPC (port 9001) on cluster-2. This ServiceEntry
#   was entirely missing from the original project.
# ─────────────────────────────────────────────────────────
info "Step 6 — Applying ServiceEntries on cluster-1..."

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

success "ServiceEntries applied on cluster-1"

# ─────────────────────────────────────────────────────────
# STEP 6B — Apply DestinationRules on cluster-1
#
# CRITICAL — without these, cross-cluster traffic FAILS with:
#   "CERTIFICATE_VERIFY_FAILED: self signed certificate in chain"
#
# ServiceEntries route billing-service and kafka to the EWG on
# port 15443. The EWG uses AUTO_PASSTHROUGH (mTLS), so the
# outbound sidecar MUST initiate ISTIO_MUTUAL TLS. Without a
# DestinationRule, Envoy sends plaintext and the TLS handshake
# fails at the EWG.
# ─────────────────────────────────────────────────────────
info "Step 6B — Applying DestinationRules for cross-cluster mTLS..."
istio_apply cluster-1 "${SCRIPT_DIR}/manifest/istio/destination-rules.yaml"
success "DestinationRules applied on cluster-1"

# ─────────────────────────────────────────────────────────
# STEP 7 — Restart istiod to pick up all config changes
# ─────────────────────────────────────────────────────────
info "Step 7 — Restarting istiod on both clusters..."
kubectl rollout restart deployment/istiod -n istio-system --context=cluster-1
kubectl rollout restart deployment/istiod -n istio-system --context=cluster-2

info "  Waiting for istiod on cluster-1 (up to 3 min)..."
kubectl rollout status deployment/istiod -n istio-system --context=cluster-1 --timeout=180s || \
  warn "cluster-1 istiod rollout timed out — check manually"
info "  Waiting for istiod on cluster-2 (up to 3 min)..."
kubectl rollout status deployment/istiod -n istio-system --context=cluster-2 --timeout=180s || \
  warn "cluster-2 istiod rollout timed out — check manually"
success "istiod restarted"

# ─────────────────────────────────────────────────────────
# STEP 8 — Deploy application manifests
# ─────────────────────────────────────────────────────────
info "Step 8 — Deploying infrastructure manifests..."
kubectl apply --context=cluster-1 -f "${SCRIPT_DIR}/manifest/infrastructure/auth-service-db.yaml"
kubectl apply --context=cluster-1 -f "${SCRIPT_DIR}/manifest/infrastructure/patient-service-db.yaml"
kubectl apply --context=cluster-2 -f "${SCRIPT_DIR}/manifest/infrastructure/zookeeper.yaml"
kubectl apply --context=cluster-2 -f "${SCRIPT_DIR}/manifest/infrastructure/kafka.yaml"

info "  Waiting 20s for databases and kafka to initialise..."
sleep 20

info "Step 8B — Deploying application manifests..."
kubectl apply --context=cluster-1 -f "${SCRIPT_DIR}/manifest/application/auth-service.yaml"
kubectl apply --context=cluster-1 -f "${SCRIPT_DIR}/manifest/application/patient-service.yaml"
kubectl apply --context=cluster-1 -f "${SCRIPT_DIR}/manifest/application/api-gateway.yaml"
kubectl apply --context=cluster-2 -f "${SCRIPT_DIR}/manifest/application/billing-service.yaml"
kubectl apply --context=cluster-2 -f "${SCRIPT_DIR}/manifest/application/analytics-service.yaml"
success "All manifests applied"

# ─────────────────────────────────────────────────────────
# STEP 8C — Install observability stack + Kiali
#
# Prometheus must be on BOTH clusters so Kiali can query
# metrics from each cluster's own Envoy sidecars.
# Kiali runs only on cluster-1 but monitors both clusters
# via the kiali-multi-cluster-secret which contains a
# kubeconfig for cluster-2's API server.
# The remote RBAC (kiali-remote-rbac.yaml) grants the
# istio-reader-service-account on cluster-2 the permissions
# Kiali needs (deployments, pods, portforward, webhooks).
# ─────────────────────────────────────────────────────────
info "Step 8C — Installing observability stack..."

KIALI_ADDONS="/home/caffeine/istio-1.29.0/samples/addons"

# Prometheus on both clusters (needed for Kiali metrics from each cluster)
kubectl apply --context=cluster-1 -f "${KIALI_ADDONS}/prometheus.yaml"
kubectl apply --context=cluster-2 -f "${KIALI_ADDONS}/prometheus.yaml"

# Grafana + Jaeger on cluster-1 only
kubectl apply --context=cluster-1 -f "${KIALI_ADDONS}/grafana.yaml"
kubectl apply --context=cluster-1 -f "${KIALI_ADDONS}/jaeger.yaml"

success "Prometheus/Grafana/Jaeger applied"

# ── Kiali multi-cluster setup ─────────────────────────────
info "  Installing Kiali with multi-cluster config..."
kubectl apply --context=cluster-1 -f "${SCRIPT_DIR}/kiali/kiali-multicluster.yaml"

# Apply remote RBAC on cluster-2 so the istio-reader-service-account
# has the permissions Kiali needs to read workloads and proxy istiod
kubectl apply --context=cluster-2 -f "${SCRIPT_DIR}/kiali/kiali-remote-rbac.yaml"

# Build the kiali-multi-cluster-secret from the cluster-2 remote secret.
# This kubeconfig is what Kiali uses to connect to cluster-2's API server.
info "  Creating kiali-multi-cluster-secret from cluster-2 remote secret..."
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

# Label the remote secrets for Kiali's autodetect (belt-and-suspenders)
kubectl label secret istio-remote-secret-curacloud-cluster-2 \
  -n istio-system --context=cluster-1 \
  kiali.io/multiCluster=true --overwrite
kubectl label secret istio-remote-secret-curacloud-cluster-1 \
  -n istio-system --context=cluster-2 \
  kiali.io/multiCluster=true --overwrite

success "Kiali multi-cluster config applied"

info "  Waiting for Kiali to become Ready (up to 2 min)..."
kubectl rollout status deployment/kiali -n istio-system --context=cluster-1 --timeout=120s || \
  warn "Kiali rollout timed out — check manually"

# ─────────────────────────────────────────────────────────
# STEP 9 — Verify
# ─────────────────────────────────────────────────────────
info "Step 9 — Verifying cross-cluster sync (waiting 15s)..."
sleep 15

echo ""
echo "  cluster-1 remote clusters:"
istioctl remote-clusters --context=cluster-1
echo ""
echo "  cluster-2 remote clusters:"
istioctl remote-clusters --context=cluster-2
echo ""

info "Pod status:"
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
success " CuraCloud mesh is set up! 🚀"
success "══════════════════════════════════════════════"
echo ""
echo "  On every reboot, run instead:"
echo "    bash k8s/kind/restart-clusters.sh"
echo ""
echo "  Quick access:"
echo "  Kiali:      kubectl port-forward svc/kiali      -n istio-system 20001:20001 --context=cluster-1"
echo "  Grafana:    kubectl port-forward svc/grafana    -n istio-system 3000:3000   --context=cluster-1"
echo "  Prometheus: kubectl port-forward svc/prometheus -n istio-system 9090:9090   --context=cluster-1"
echo "  Jaeger:     kubectl port-forward svc/tracing    -n istio-system 16686:80    --context=cluster-1"
echo ""
