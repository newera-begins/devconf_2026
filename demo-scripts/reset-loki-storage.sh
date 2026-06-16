#!/bin/bash
# ============================================================
# Reset Loki Storage — Wipe flow data and recreate fresh PVs
# Run this when Loki PVs are full or before recording the demo
# SAFE: Only touches Loki storage, not the demo-app or NOO
# ============================================================

set -euo pipefail

NODE="m0.c1.ocplabs.bm"  # Change this if using a different cluster
LOKI_NS="netobserv-loki"

echo ""
echo "========================================================"
echo "  Resetting Loki Storage (wipe data + fresh PVs)"
echo "========================================================"
echo ""

# Step 1: Scale down LokiStack StatefulSets
echo "Step 1: Scaling down Loki StatefulSets..."
oc scale statefulset -n $LOKI_NS lokistack-network-ingester --replicas=0 2>/dev/null
oc scale statefulset -n $LOKI_NS lokistack-network-compactor --replicas=0 2>/dev/null
oc scale statefulset -n $LOKI_NS lokistack-network-index-gateway --replicas=0 2>/dev/null
sleep 5
echo "  Done."

# Step 2: Delete PVCs
echo ""
echo "Step 2: Deleting PVCs..."
oc delete pvc -n $LOKI_NS --all --force --grace-period=0 2>/dev/null || true
sleep 3
echo "  Done."

# Step 3: Delete old PVs
echo ""
echo "Step 3: Deleting old PVs..."
oc delete pv loki-pv-compactor loki-pv-ingester loki-pv-ingester-wal loki-pv-index-gateway --force --grace-period=0 2>/dev/null || true
sleep 3
echo "  Done."

# Step 4: Wipe data directories on the node
echo ""
echo "Step 4: Wiping data on node $NODE..."
oc debug node/$NODE -- chroot /host bash -c "rm -rf /var/loki/* && mkdir -p /var/loki/{compactor,ingester,ingester-wal,index-gateway} && chmod 777 /var/loki/*" 2>/dev/null
echo "  Done."

# Step 5: Recreate PVs
echo ""
echo "Step 5: Creating fresh PVs..."
cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: loki-pv-compactor
spec:
  capacity:
    storage: 10Gi
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  local:
    path: /var/loki/compactor
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values: [$NODE]
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: loki-pv-ingester
spec:
  capacity:
    storage: 10Gi
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  local:
    path: /var/loki/ingester
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values: [$NODE]
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: loki-pv-ingester-wal
spec:
  capacity:
    storage: 10Gi
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  local:
    path: /var/loki/ingester-wal
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values: [$NODE]
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: loki-pv-index-gateway
spec:
  capacity:
    storage: 10Gi
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  local:
    path: /var/loki/index-gateway
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values: [$NODE]
EOF
echo "  Done."

# Step 6: Scale StatefulSets back up
echo ""
echo "Step 6: Scaling Loki StatefulSets back up..."
oc scale statefulset -n $LOKI_NS lokistack-network-ingester --replicas=1
oc scale statefulset -n $LOKI_NS lokistack-network-compactor --replicas=1
oc scale statefulset -n $LOKI_NS lokistack-network-index-gateway --replicas=1

echo ""
echo "Step 7: Waiting for pods to start..."
for i in $(seq 1 24); do
  READY=$(oc get statefulset -n $LOKI_NS --no-headers 2>/dev/null | awk '{print $2}' | grep -c "1/1" || echo 0)
  if [ "$READY" = "3" ]; then
    echo "  All 3 StatefulSets ready!"
    break
  fi
  echo -n "  ($READY/3 ready) "
  sleep 5
done

# Step 8: Also wipe MinIO data
echo ""
echo "Step 8: Wiping MinIO bucket data..."
oc exec -n $LOKI_NS deploy/minio -- sh -c "rm -rf /data/loki/* && mkdir -p /data/loki" 2>/dev/null
echo "  Done."

echo ""
echo "========================================================"
echo "  Loki storage reset complete."
echo "  Fresh 10Gi PVs ready. MinIO bucket wiped."
echo "  Wait 1-2 minutes, then check NOO dashboard."
echo "========================================================"
