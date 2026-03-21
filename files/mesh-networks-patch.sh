#!/usr/bin/env bash
# Fixes applied to this script:
#
#  BUG FIX #5 — Wrong jsonpath for EWG IP
#    BEFORE: {.spec.externalIPs[0]}
#    AFTER:  {.status.loadBalancer.ingress[0].ip}
#    Reason: The east-west gateway is a LoadBalancer service. Its assigned IP
#    appears in .status.loadBalancer.ingress, not .spec.externalIPs. Using the
#    wrong path returns an empty string, so meshNetworks and ServiceEntry
#    endpoints all resolve to an empty address — traffic goes nowhere.
#
#    NOTE FOR KIND: KinD does not have a cloud provider, so LoadBalancer
#    services stay in <pending> unless MetalLB is installed. Install MetalLB
#    first (https://metallb.universe.tf/installation/) and configure an
#    address pool covering the Docker bridge subnet (typically 172.18.0.0/24).
#    Alternative: use the node IP + NodePort by changing the service type to
#    NodePort in the IstioOperator and adjusting the IP/port extraction below.
#
#  BUG FIX #6 — ServiceEntry for kafka uses resolution: DNS with an IP endpoint
#    BEFORE: resolution: DNS
#    AFTER:  resolution: STATIC
#    Reason: "resolution: DNS" tells Istio to treat the endpoint address as a
#    hostname and resolve it via DNS at runtime. ${C2_EWG} is an IP address,
#    not a hostname, so DNS resolution fails and no traffic is forwarded.
#    "resolution: STATIC" tells Istio to use the address as-is.
#
#  BUG FIX #7 — Missing ServiceEntry for billing-service on cluster-1
#    patient-service calls billing-service via gRPC (port 9001) across clusters.
#    Without a ServiceEntry, cluster-1's istiod has no endpoint for
#    billing-service.default.svc.cluster.local and drops the connection.
#    Added a ServiceEntry mirroring the pattern used for kafka.

set -euo pipefail

# BUG FIX #5: Use .status.loadBalancer.ingress[0].ip, not .spec.externalIPs[0]
C1_EWG=$(kubectl get svc istio-eastwestgateway -n istio-system --context=cluster-1 \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
C2_EWG=$(kubectl get svc istio-eastwestgateway -n istio-system --context=cluster-2 \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

if [[ -z "$C1_EWG" ]]; then
  echo "[ERROR] cluster-1 east-west gateway has no external IP."
  echo "        If using KinD, install MetalLB and configure an address pool."
  echo "        Run: kubectl get svc istio-eastwestgateway -n istio-system --context=cluster-1"
  exit 1
fi
if [[ -z "$C2_EWG" ]]; then
  echo "[ERROR] cluster-2 east-west gateway has no external IP."
  echo "        If using KinD, install MetalLB and configure an address pool."
  exit 1
fi

echo "[INFO] cluster-1 EWG IP: $C1_EWG"
echo "[INFO] cluster-2 EWG IP: $C2_EWG"

# ── 1. Patch meshNetworks on cluster-1 ────────────────────────────────────────
kubectl patch configmap istio -n istio-system --context=cluster-1 \
  --type merge -p "{
    \"data\": {
      \"meshNetworks\": \"networks:\\n  network1:\\n    endpoints:\\n    - fromRegistry: curacloud-cluster-1\\n    gateways:\\n    - address: ${C1_EWG}\\n      port: 15443\\n  network2:\\n    endpoints:\\n    - fromRegistry: curacloud-cluster-2\\n    gateways:\\n    - address: ${C2_EWG}\\n      port: 15443\\n\"
    }
  }"
echo "[OK] meshNetworks patched on cluster-1"

# ── 2. Patch meshNetworks on cluster-2 ────────────────────────────────────────
kubectl patch configmap istio -n istio-system --context=cluster-2 \
  --type merge -p "{
    \"data\": {
      \"meshNetworks\": \"networks:\\n  network1:\\n    endpoints:\\n    - fromRegistry: curacloud-cluster-1\\n    gateways:\\n    - address: ${C1_EWG}\\n      port: 15443\\n  network2:\\n    endpoints:\\n    - fromRegistry: curacloud-cluster-2\\n    gateways:\\n    - address: ${C2_EWG}\\n      port: 15443\\n\"
    }
  }"
echo "[OK] meshNetworks patched on cluster-2"

# ── 3. ServiceEntry for kafka on cluster-1 ────────────────────────────────────
# BUG FIX #6: Changed resolution from DNS to STATIC.
# The endpoint address is an IP, not a hostname, so STATIC is required.
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
  resolution: STATIC
  endpoints:
  - address: ${C2_EWG}
    ports:
      tcp-kafka: 15443
      tcp-kafka-internal: 15443
    labels:
      security.istio.io/tlsMode: istio
EOF
echo "[OK] ServiceEntry 'kafka-cluster2' created on cluster-1"

# ── 4. ServiceEntry for billing-service on cluster-1 ─────────────────────────
# BUG FIX #7: This ServiceEntry was entirely missing.
# patient-service (cluster-1) calls billing-service (cluster-2) via gRPC on
# port 9001. Without this entry, cluster-1's istiod has no endpoint record
# for billing-service.default.svc.cluster.local and the gRPC channel fails
# to establish with "name resolution failure" or an immediate connection reset.
kubectl apply --context=cluster-1 -f - <<EOF
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
  - address: ${C2_EWG}
    ports:
      http: 15443
      grpc: 15443
    labels:
      security.istio.io/tlsMode: istio
EOF
echo "[OK] ServiceEntry 'billing-service-cluster2' created on cluster-1"

# ── 5. Restart istiod on both clusters ────────────────────────────────────────
echo "[INFO] Restarting istiod on both clusters to pick up meshNetworks..."
kubectl rollout restart deployment/istiod -n istio-system --context=cluster-1
kubectl rollout restart deployment/istiod -n istio-system --context=cluster-2

echo "[INFO] Waiting for istiod on cluster-1..."
kubectl rollout status deployment/istiod -n istio-system --context=cluster-1 --timeout=120s
echo "[INFO] Waiting for istiod on cluster-2..."
kubectl rollout status deployment/istiod -n istio-system --context=cluster-2 --timeout=120s

echo ""
echo "[OK] Done! Verifying remote cluster sync..."
sleep 10
echo "  cluster-1 view:"
istioctl remote-clusters --context=cluster-1
echo "  cluster-2 view:"
istioctl remote-clusters --context=cluster-2
