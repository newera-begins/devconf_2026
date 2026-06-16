#!/bin/bash
# ============================================================
# SAFE SETUP: LVM Storage + MinIO + Loki Operator + LokiStack
# For bare metal OCP 4.21 cluster WITHOUT existing StorageClass
#
# SAFETY: This script only CREATES resources in dedicated
# namespaces. It does NOT modify or delete anything existing.
# Every step checks if the resource exists before creating.
#
# Run on: Dell R640 bare metal cluster (3-node compact)
# ============================================================

set -euo pipefail

echo ""
echo "========================================================"
echo "  SAFE SETUP: LVM Storage + MinIO + Loki for NOO Demo"
echo "========================================================"
echo ""

# Pre-flight checks
echo "=== Pre-flight Checks ==="
echo -n "  Cluster access: "
oc whoami || { echo "FAILED — not logged in"; exit 1; }
echo -n "  Cluster version: "
oc get clusterversion -o jsonpath='{.items[0].status.desired.version}'
echo ""
echo -n "  Nodes: "
oc get nodes --no-headers | wc -l | tr -d ' '
echo " nodes"
echo -n "  Existing StorageClasses: "
SC_COUNT=$(oc get sc --no-headers 2>/dev/null | wc -l | tr -d ' ')
echo "$SC_COUNT"
if [ "$SC_COUNT" -gt 0 ]; then
    echo "  WARNING: StorageClasses already exist:"
    oc get sc
    echo ""
    read -p "  Continue anyway? (y/n) " -n 1 -r
    echo ""
    [[ $REPLY =~ ^[Yy]$ ]] || exit 0
fi
echo ""

# ============================================================
# STEP 1: Install LVM Storage Operator
# ============================================================
echo "=== Step 1: LVM Storage Operator ==="

if oc get subscription lvms-operator -n openshift-storage 2>/dev/null | grep -q lvms; then
    echo "  Already installed. Skipping."
else
    echo "  Creating namespace and subscription..."

    oc create namespace openshift-storage 2>/dev/null || echo "  Namespace already exists"

    cat <<'EOF' | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-storage-og
  namespace: openshift-storage
spec:
  targetNamespaces:
    - openshift-storage
EOF

    cat <<'EOF' | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: lvms-operator
  namespace: openshift-storage
spec:
  channel: stable-4.21
  installPlanApproval: Automatic
  name: lvms-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

    echo "  Waiting for operator pod to start (up to 3 minutes)..."
    for i in $(seq 1 36); do
        if oc get pods -n openshift-storage -l app.kubernetes.io/name=lvms-operator 2>/dev/null | grep -q Running; then
            echo "  LVM Storage Operator is Running."
            break
        fi
        echo -n "."
        sleep 5
    done
    echo ""
fi

# ============================================================
# STEP 2: Create LVMCluster
# ============================================================
echo ""
echo "=== Step 2: LVMCluster ==="

if oc get lvmcluster -n openshift-storage 2>/dev/null | grep -q lvmcluster; then
    echo "  LVMCluster already exists. Skipping."
else
    echo "  Creating LVMCluster (uses available VG space on nodes)..."

    cat <<'EOF' | oc apply -f -
apiVersion: lvm.topolvm.io/v1alpha1
kind: LVMCluster
metadata:
  name: lvmcluster
  namespace: openshift-storage
spec:
  storage:
    deviceClasses:
      - name: vg1
        default: true
        thinPoolConfig:
          name: thin-pool-1
          sizePercent: 90
          overprovisionRatio: 10
EOF

    echo "  Waiting for StorageClass to appear (up to 2 minutes)..."
    for i in $(seq 1 24); do
        if oc get sc 2>/dev/null | grep -q lvms; then
            echo "  StorageClass created:"
            oc get sc
            break
        fi
        echo -n "."
        sleep 5
    done
    echo ""
fi

# Verify StorageClass exists before proceeding
SC_NAME=$(oc get sc -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$SC_NAME" ]; then
    echo "  ERROR: No StorageClass found. LVM setup may have failed."
    echo "  Check: oc get pods -n openshift-storage"
    echo "  Check: oc get lvmcluster -n openshift-storage -o yaml"
    exit 1
fi
echo "  Using StorageClass: $SC_NAME"

# ============================================================
# STEP 3: Install Loki Operator
# ============================================================
echo ""
echo "=== Step 3: Loki Operator ==="

if oc get csv -n openshift-operators-redhat 2>/dev/null | grep -q loki-operator; then
    echo "  Loki Operator already installed. Skipping."
else
    echo "  Creating namespace and subscription..."

    oc create namespace openshift-operators-redhat 2>/dev/null || echo "  Namespace already exists"

    cat <<'EOF' | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-operators-redhat-og
  namespace: openshift-operators-redhat
spec: {}
EOF

    cat <<'EOF' | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: loki-operator
  namespace: openshift-operators-redhat
spec:
  channel: stable-6.5
  installPlanApproval: Automatic
  name: loki-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

    echo "  Waiting for Loki Operator to install (up to 3 minutes)..."
    for i in $(seq 1 36); do
        if oc get csv -n openshift-operators-redhat 2>/dev/null | grep -q Succeeded; then
            echo "  Loki Operator installed successfully."
            break
        fi
        echo -n "."
        sleep 5
    done
    echo ""
fi

# ============================================================
# STEP 4: Deploy MinIO (in-cluster S3)
# ============================================================
echo ""
echo "=== Step 4: MinIO (in-cluster S3 storage) ==="

oc create namespace netobserv-loki 2>/dev/null || echo "  Namespace already exists"

if oc get deployment minio -n netobserv-loki 2>/dev/null | grep -q minio; then
    echo "  MinIO already deployed. Skipping."
else
    echo "  Deploying MinIO..."

    cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: netobserv-loki
  labels:
    app: minio
spec:
  replicas: 1
  selector:
    matchLabels:
      app: minio
  template:
    metadata:
      labels:
        app: minio
    spec:
      containers:
        - name: minio
          image: quay.io/minio/minio:latest
          command:
            - minio
            - server
            - /data
            - --console-address
            - ":9001"
          env:
            - name: MINIO_ROOT_USER
              value: "minio"
            - name: MINIO_ROOT_PASSWORD
              value: "minio123"
          ports:
            - containerPort: 9000
              name: s3
            - containerPort: 9001
              name: console
          volumeMounts:
            - name: data
              mountPath: /data
          resources:
            requests:
              memory: "256Mi"
              cpu: "100m"
            limits:
              memory: "512Mi"
              cpu: "500m"
      volumes:
        - name: data
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: netobserv-loki
spec:
  selector:
    app: minio
  ports:
    - port: 9000
      targetPort: 9000
      name: s3
    - port: 9001
      targetPort: 9001
      name: console
  type: ClusterIP
EOF

    echo "  Waiting for MinIO pod..."
    oc wait --for=condition=Ready pod -l app=minio -n netobserv-loki --timeout=120s

    echo "  Creating 'loki' bucket..."
    oc exec -n netobserv-loki deploy/minio -- mkdir -p /data/loki
    echo "  MinIO ready."
fi

# ============================================================
# STEP 5: Create Loki S3 Secret + LokiStack
# ============================================================
echo ""
echo "=== Step 5: LokiStack with MinIO backend ==="

# Create secret
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: loki-s3-secret
  namespace: netobserv-loki
stringData:
  access_key_id: "minio"
  access_key_secret: "minio123"
  bucketnames: "loki"
  endpoint: "http://minio.netobserv-loki.svc.cluster.local:9000"
  region: "us-east-1"
EOF
echo "  S3 secret created."

# Create LokiStack
if oc get lokistack lokistack-network -n netobserv-loki 2>/dev/null | grep -q lokistack; then
    echo "  LokiStack already exists. Skipping."
else
    echo "  Creating LokiStack (1x.demo size — minimal resources)..."

    cat <<EOF | oc apply -f -
apiVersion: loki.grafana.com/v1
kind: LokiStack
metadata:
  name: lokistack-network
  namespace: netobserv-loki
spec:
  size: 1x.demo
  storage:
    schemas:
      - effectiveDate: "2024-10-01"
        version: v13
    secret:
      name: loki-s3-secret
      type: s3
    tls:
      caName: ""
  storageClassName: $SC_NAME
  tenants:
    mode: openshift-network
EOF

    echo "  LokiStack created. Waiting for pods (up to 3 minutes)..."
    for i in $(seq 1 36); do
        READY=$(oc get statefulset -n netobserv-loki 2>/dev/null | grep -c "1/1" || echo "0")
        TOTAL=$(oc get statefulset -n netobserv-loki --no-headers 2>/dev/null | wc -l | tr -d ' ')
        echo -n "  ($READY/$TOTAL StatefulSets ready) "
        if [ "$READY" = "$TOTAL" ] && [ "$TOTAL" -gt 0 ]; then
            echo ""
            echo "  All LokiStack StatefulSets ready!"
            break
        fi
        sleep 5
    done
fi

# ============================================================
# Final Status
# ============================================================
echo ""
echo "========================================================"
echo "  FINAL STATUS"
echo "========================================================"
echo ""
echo "=== StorageClass ==="
oc get sc
echo ""
echo "=== Loki Operator ==="
oc get csv -n openshift-operators-redhat 2>/dev/null | grep loki || echo "  Not found"
echo ""
echo "=== MinIO ==="
oc get pods -n netobserv-loki -l app=minio
echo ""
echo "=== LokiStack Pods ==="
oc get pods -n netobserv-loki -l app.kubernetes.io/instance=lokistack-network
echo ""
echo "=== LokiStack StatefulSets ==="
oc get statefulset -n netobserv-loki
echo ""
echo "========================================================"
echo "  NEXT STEPS:"
echo "  1. Install Network Observability Operator from OperatorHub"
echo "  2. Create FlowCollector CR: oc apply -f demo-app/flowcollector.yaml"
echo "  3. Deploy demo app: oc apply -f demo-app/"
echo "  4. Verify: OCP Console → Observe → Network Traffic"
echo "========================================================"
