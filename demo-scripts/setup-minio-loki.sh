#!/bin/bash
# ============================================================
# Setup MinIO + LokiStack for NOO Demo
# Deploys MinIO as in-cluster S3 replacement
# ============================================================

set -e

LOKI_NS="netobserv-loki"

echo ""
echo "========================================================"
echo "  Setting up MinIO + LokiStack for NOO Demo"
echo "========================================================"
echo ""

# Step 1: Deploy MinIO
echo "Step 1: Deploying MinIO in $LOKI_NS namespace..."

cat <<'EOF' | oc apply -f -
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

echo "  Waiting for MinIO pod to be ready..."
oc wait --for=condition=Ready pod -l app=minio -n $LOKI_NS --timeout=120s

echo ""
echo "Step 2: Creating bucket 'loki' in MinIO..."
oc exec -n $LOKI_NS deploy/minio -- mc alias set local http://localhost:9000 minio minio123 2>/dev/null || \
  oc exec -n $LOKI_NS deploy/minio -- mkdir -p /data/loki
echo "  Bucket created."

# Step 3: Create Loki secret pointing to MinIO
echo ""
echo "Step 3: Creating Loki S3 secret for MinIO..."

oc delete secret loki-s3-secret -n $LOKI_NS 2>/dev/null || true

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

echo "  Secret created."

# Step 4: Delete existing LokiStack and recreate
echo ""
echo "Step 4: Recreating LokiStack with MinIO backend..."

oc delete lokistack lokistack-network -n $LOKI_NS 2>/dev/null || true
sleep 5

# Delete old PVCs
oc delete pvc -n $LOKI_NS -l app.kubernetes.io/instance=lokistack-network --force 2>/dev/null || true
sleep 3

cat <<'EOF' | oc apply -f -
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
  storageClassName: lvms-vg1
  tenants:
    mode: openshift-network
EOF

echo "  LokiStack created. Waiting for pods to start..."
sleep 30

echo ""
echo "Step 5: Checking LokiStack pods..."
oc get pods -n $LOKI_NS -l app.kubernetes.io/instance=lokistack-network
echo ""
oc get statefulset -n $LOKI_NS

echo ""
echo "========================================================"
echo "  MinIO + LokiStack setup complete."
echo "  Wait 1-2 minutes for all pods to reach Running state."
echo "  Then check: OCP Console → Observe → Network Traffic"
echo "========================================================"
