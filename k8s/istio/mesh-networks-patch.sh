#!/usr/bin/env bash
# Fix cross-cluster communication:
# 1. Patch meshNetworks so istiod knows to route via East-West Gateways
# 2. Add ServiceEntry for kafka on cluster-1
# 3. Restart istiod

set -e

C1_EWG=$(kubectl get svc istio-eastwestgateway -n istio-system --context=cluster-1 \
  -o jsonpath='{.spec.externalIPs[0]}')
C2_EWG=$(kubectl get svc istio-eastwestgateway -n istio-system --context=cluster-2 \
  -o jsonpath='{.spec.externalIPs[0]}')

echo "[INFO] cluster-1 EWG IP: $C1_EWG"
echo "[INFO] cluster-2 EWG IP: $C2_EWG"

# ── 1. Patch meshNetworks on cluster-1 ────────────────────────────────────────
# cluster-1 knows its own network1 via its EWG, and network2 via cluster-2's EWG
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
# Without this, cluster-1 pods can't resolve "kafka" (it only exists in cluster-2)
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
  - address: ${C2_EWG}
    ports:
      tcp-kafka: 15443
      tcp-kafka-internal: 15443
    labels:
      security.istio.io/tlsMode: istio
EOF
echo "[OK] ServiceEntry 'kafka-cluster2' created on cluster-1"

# ── 4. Restart istiod on both clusters ────────────────────────────────────────
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
