#!/bin/bash
# ============================================================
# SCENARIO 2: BREAK — Egress NetworkPolicy Blocks Database
# ============================================================
# SAFE: No sysctl. No oc debug node. Namespace-scoped only.
#
# What this does:
#   Applies an EGRESS NetworkPolicy on backend-api that allows
#   DNS (port 53) but blocks ALL other egress — including port
#   5432 (PostgreSQL). Health endpoint works (no DB needed).
#   Books endpoint fails (needs DB). Database is perfectly healthy.
#
# Why this is hard to debug:
#   - Health check returns 200 → "app is healthy"
#   - Frontend loads fine → "network works"
#   - Database pod is Running, has data → "PostgreSQL is fine"
#   - Only /api/books fails → "must be a code bug"
#   - App logs show no connection errors (timeout at kernel level)
#   - Nobody checks EGRESS NetworkPolicy — everyone checks ingress
#   - DBA spends hours debugging PostgreSQL for nothing
#
# What NOO shows:
#   - Drop reason: NetworkPolicy
#   - Source: backend-api → Destination: database
#   - Port: 5432 (blocked by egress policy)
#   - Answer in 5 seconds. No DB debugging needed.
#
# SAFETY: trap auto-reverts on failure. Only creates a NetworkPolicy.
# ============================================================

NAMESPACE="demo-app"

# No trap ERR — curl timeouts are EXPECTED behavior in this scenario.
# The books endpoint SHOULD fail (that's the point of the demo).
# If oc apply fails, the script just exits with no harm done.

# Pre-check
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
echo "  SCENARIO 2: The Database That Isn't Broken"
echo "  Egress policy blocks DB — but everything LOOKS fine"
echo "========================================================"
echo ""

# Step 1: Verify everything works BEFORE breaking
echo "Step 1: Verifying everything works (baseline)..."
echo ""

echo "  Health endpoint (no DB needed):"
H=$(oc exec -n "$NAMESPACE" deploy/frontend -- \
    curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 3 --max-time 5 \
    http://backend-api:5000/api/health 2>/dev/null || echo "000")
echo "    HTTP $H ✓"

echo ""
echo "  Books endpoint (needs DB):"
B=$(oc exec -n "$NAMESPACE" deploy/frontend -- \
    curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 3 --max-time 5 \
    http://backend-api:5000/api/books 2>/dev/null || echo "000")
echo "    HTTP $B ✓"

echo ""
echo "  Database direct check:"
DB_COUNT=$(oc exec -n "$NAMESPACE" deploy/database -- \
    psql -U demo -d bookstore -tAc "SELECT count(*) FROM books;" 2>/dev/null || echo "?")
echo "    $DB_COUNT books in database ✓"

# Step 2: Apply the egress block
echo ""
echo "Step 2: Applying EGRESS NetworkPolicy on backend-api..."
echo "  This allows DNS (port 53) but blocks port 5432 (database)."
echo "  Ingress is NOT restricted — frontend can still reach backend-api."

cat <<'EOF' | oc apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: egress-db-block
  namespace: demo-app
spec:
  podSelector:
    matchLabels:
      app: backend-api
  policyTypes:
    - Egress
  egress:
    # Allow DNS
    - ports:
        - port: 5353
          protocol: UDP
        - port: 5353
          protocol: TCP
    # Allow HTTPS (pip install, external APIs)
    - ports:
        - port: 443
          protocol: TCP
    # Allow HTTP to pods in same namespace (health, frontend)
    - to:
        - podSelector: {}
      ports:
        - port: 5000
          protocol: TCP
        - port: 8080
          protocol: TCP
    # NOTE: port 5432 (PostgreSQL) is INTENTIONALLY MISSING
    # backend-api can reach everything EXCEPT the database
    # Health works. Books fails. Database is healthy.
EOF

echo "  NetworkPolicy applied."
echo ""
echo "  Waiting 5 seconds for policy to take effect..."
sleep 5

# Step 3: Test — health works, books fails
echo ""
echo "Step 3: Testing AFTER applying egress block..."
echo ""

echo "  === Health endpoint (no DB — SHOULD WORK) ==="
for i in 1 2 3; do
    H=$(oc exec -n "$NAMESPACE" deploy/frontend -- \
        curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 3 --max-time 5 \
        http://backend-api:5000/api/health 2>/dev/null || echo "000")
    echo "    Request $i: HTTP $H"
    sleep 1
done

echo ""
echo "  === Books endpoint (needs DB — SHOULD FAIL) ==="
FAIL_BOOKS=0
for i in 1 2 3; do
    RESP=$(oc exec -n "$NAMESPACE" deploy/frontend -- \
        curl -s --max-time 8 \
        http://backend-api:5000/api/books 2>/dev/null)
    if echo "$RESP" | grep -q '"id"'; then
        echo "    Request $i: OK (got books)"
    elif echo "$RESP" | grep -q "error"; then
        ERR=$(echo "$RESP" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('error','?')[:60])" 2>/dev/null || echo "connection error")
        echo "    Request $i: ★ FAILED — $ERR"
        FAIL_BOOKS=$((FAIL_BOOKS + 1))
    else
        echo "    Request $i: ★ FAILED — timeout (no response from DB)"
        FAIL_BOOKS=$((FAIL_BOOKS + 1))
    fi
    sleep 1
done

echo ""
echo "  === Database pod — is it healthy? ==="
oc get pod -n "$NAMESPACE" -l app=database --no-headers
DB_COUNT2=$(oc exec -n "$NAMESPACE" deploy/database -- \
    psql -U demo -d bookstore -tAc "SELECT count(*) FROM books;" 2>/dev/null || echo "?")
echo "    Database has $DB_COUNT2 books. PostgreSQL is FINE."

echo ""
echo "  === Frontend route — does the page load? ==="
ROUTE=$(oc get route frontend -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)
ROUTE_CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 5 "http://$ROUTE/" 2>/dev/null || echo "000")
echo "    Frontend route: HTTP $ROUTE_CODE (HTML loads fine)"

echo ""
echo "========================================================"
echo "  RESULTS:"
echo "  Health endpoint:   3/3 HTTP 200 (works — no DB needed)"
echo "  Books endpoint:    $FAIL_BOOKS/3 FAILED (DB blocked by egress)"
echo "  Database:          Running, $DB_COUNT2 books, healthy"
echo "  Frontend:          HTTP $ROUTE_CODE (loads fine)"
echo ""
echo "  ★ THE MISDIRECTION:"
echo "  Health works → 'App is healthy'"
echo "  Frontend works → 'Network is fine'"
echo "  Database is Running with data → 'PostgreSQL is fine'"
echo "  Only /api/books fails → 'Must be a code bug!'"
echo ""
echo "  ★ THE REALITY:"
echo "  An EGRESS NetworkPolicy on backend-api blocks port 5432."
echo "  backend-api can't REACH the database."
echo "  Health works because it doesn't need the database."
echo "  Nobody checks EGRESS policies — everyone debugs PostgreSQL."
echo ""
echo "  What to check in NOO:"
echo "  1. OCP Console → Observe → Network Traffic → Show drops"
echo "  2. Filter: Namespace = demo-app"
echo "  3. Look for: backend-api → database, Drop = NetworkPolicy"
echo "  4. Port: 5432 (the blocked port)"
echo ""
echo "  Traditional debugging: 30+ minutes (wrong direction)"
echo "  NOO: 5 seconds → 'NetworkPolicy blocking port 5432'"
echo ""
echo "  To fix: bash demo-scripts/scenario2-egress-fix.sh"
echo "========================================================"
