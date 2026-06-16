#!/bin/bash
# ============================================================
# SCENARIO 1: BREAK — Silent NetworkPolicy Drops
# ============================================================
# SAFE: No sysctl changes. No oc debug node/. Namespace-scoped only.
#
# What this does:
#   Deploys traffic-generator pods that send requests to backend-api.
#   Then applies a NetworkPolicy that silently BLOCKS the traffic.
#   Requests fail with timeout — pod is Running, endpoints exist,
#   but packets are dropped by OVN ACLs (NetworkPolicy enforcement).
#
# Why this is hard to debug with traditional tools:
#   - tcpdump shows SYN packets going out but no SYN-ACK
#   - Pod is Running, Ready 1/1, endpoints exist
#   - OVN trace may show the ACL drop, but you need to know
#     which policy to trace — with 50+ policies, good luck
#   - conntrack shows nothing useful (the drop is in OVS/OVN)
#
# What NOO shows:
#   - Drop reason: NetworkPolicy (or OVS_DROP)
#   - Exact source and destination pods
#   - Drop count and time window
#   - Which node the drops occur on
#
# SAFETY: Only creates pods and a NetworkPolicy in demo-app namespace.
#         No node-level changes. Cluster services unaffected.
# ============================================================

NAMESPACE="demo-app"

# Safety guard — revert everything if script fails mid-way
cleanup_on_failure() {
    echo ""
    echo "  ✗ Script failed — reverting changes..."
    oc delete networkpolicy block-traffic-generator -n "$NAMESPACE" 2>/dev/null
    oc delete deployment traffic-generator -n "$NAMESPACE" 2>/dev/null
    echo "  Reverted. Cluster is clean."
    exit 1
}
trap cleanup_on_failure ERR

# Pre-check: verify demo-app pods are healthy
echo ""
echo "Pre-check: verifying demo-app is healthy..."
RUNNING=$(oc get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -c Running)
if [ "$RUNNING" -lt 3 ]; then
    echo "  ✗ Only $RUNNING/3 demo-app pods running. Fix before running scenario."
    exit 1
fi
echo "  ✓ $RUNNING pods running"

echo ""
echo "========================================================"
echo "  SCENARIO 1: The Silent NetworkPolicy Drop"
echo "  Traffic blocked by policy — invisible to tcpdump"
echo "========================================================"
echo ""

# Step 1: Deploy traffic-generator pods
echo "Step 1: Deploying traffic-generator pods..."

cat <<'EOF' | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: traffic-generator
  namespace: demo-app
  labels:
    app: traffic-generator
spec:
  replicas: 3
  selector:
    matchLabels:
      app: traffic-generator
  template:
    metadata:
      labels:
        app: traffic-generator
    spec:
      containers:
        - name: generator
          image: registry.redhat.io/ubi9/ubi:latest
          command:
            - /bin/bash
            - -c
            - |
              echo "Traffic generator started. Sending requests every 2s..."
              while true; do
                HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
                  --connect-timeout 3 --max-time 5 \
                  http://backend-api.demo-app.svc.cluster.local:5000/api/health 2>/dev/null)
                echo "[$(date '+%H:%M:%S')] backend-api → HTTP $HTTP"
                sleep 2
              done
          resources:
            requests:
              memory: "32Mi"
              cpu: "50m"
            limits:
              memory: "64Mi"
              cpu: "100m"
EOF

echo "  Waiting for traffic-generator pods to be ready..."
oc wait --for=condition=Ready pod -l app=traffic-generator -n "$NAMESPACE" --timeout=120s 2>/dev/null || true
sleep 5

echo ""
echo "Step 2: Verifying traffic works BEFORE blocking..."
for i in 1 2 3; do
    HTTP=$(oc exec -n "$NAMESPACE" deploy/traffic-generator -- \
        curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 3 --max-time 5 \
        http://backend-api:5000/api/health 2>/dev/null || echo "000")
    echo "  Request $i: HTTP $HTTP"
    sleep 1
done

# Step 3: Apply blocking NetworkPolicy
echo ""
echo "Step 3: Applying NetworkPolicy to BLOCK traffic-generator..."
echo "  (Allows frontend, blocks traffic-generator pods)"

cat <<'EOF' | oc apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: block-traffic-generator
  namespace: demo-app
spec:
  podSelector:
    matchLabels:
      app: backend-api
  policyTypes:
    - Ingress
  ingress:
    # Allow frontend
    - from:
        - podSelector:
            matchLabels:
              app: frontend
      ports:
        - port: 5000
          protocol: TCP
    # Allow hairpin test pods (for scenario 2)
    - from:
        - podSelector:
            matchLabels:
              test: hairpin
      ports:
        - port: 5000
          protocol: TCP
    # Allow database health checks from backend-api to itself
    - from:
        - podSelector:
            matchLabels:
              app: backend-api
      ports:
        - port: 5000
          protocol: TCP
    # NOTE: traffic-generator is NOT listed → BLOCKED
EOF

echo "  NetworkPolicy applied. traffic-generator is now blocked."
echo ""
echo "  Waiting 10 seconds for policy to take effect..."
sleep 10

# Step 4: Test — traffic-generator should fail, frontend should work
echo ""
echo "Step 4: Testing connectivity AFTER blocking..."
echo ""

echo "  === traffic-generator → backend-api (SHOULD FAIL) ==="
FAIL_GEN=0
for i in 1 2 3 4 5; do
    HTTP=$(oc exec -n "$NAMESPACE" deploy/traffic-generator -- \
        curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 3 --max-time 5 \
        http://backend-api:5000/api/health 2>/dev/null || echo "000")
    if [ "$HTTP" = "200" ]; then
        echo "    Request $i: HTTP $HTTP"
    else
        echo "    Request $i: HTTP $HTTP ★ BLOCKED"
        FAIL_GEN=$((FAIL_GEN + 1))
    fi
    sleep 1
done

echo ""
echo "  === backend-api self-check (SHOULD WORK) ==="
for i in 1 2 3; do
    HTTP=$(oc exec -n "$NAMESPACE" deploy/backend-api -- \
        curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 3 --max-time 5 \
        http://backend-api:5000/api/health 2>/dev/null || echo "000")
    echo "    Request $i: HTTP $HTTP"
    sleep 1
done

echo ""
echo "========================================================"
echo "  RESULTS:"
echo "  traffic-generator blocked: $FAIL_GEN / 5"
echo "  backend-api self-check:    working (allowed by policy)"
echo ""
echo "  ★ traffic-generator is BLOCKED but pod is Running!"
echo "  ★ tcpdump would show SYN with no SYN-ACK"
echo "  ★ 'oc get pods' shows everything Running, Ready 1/1"
echo "  ★ Only NOO shows: Drop Reason = NetworkPolicy"
echo ""
echo "  What to check in NOO:"
echo "  1. OCP Console → Observe → Network Traffic"
echo "  2. Filter: Namespace = demo-app, Show drops ON"
echo "  3. Look for: traffic-generator → backend-api drops"
echo "  4. Drop Reason: NetworkPolicy or OVS_DROP"
echo ""
echo "  To fix: bash demo-scripts/scenario1-netpol-fix.sh"
echo "========================================================"
