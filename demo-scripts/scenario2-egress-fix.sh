#!/bin/bash
# ============================================================
# SCENARIO 2: FIX — Remove egress block on backend-api
# ============================================================
# SAFE: Only deletes the NetworkPolicy in demo-app namespace.
# ============================================================

NAMESPACE="demo-app"

echo ""
echo "========================================================"
echo "  SCENARIO 2: FIX"
echo "  Removing egress NetworkPolicy..."
echo "========================================================"
echo ""

echo "Step 1: Removing egress NetworkPolicy..."
oc delete networkpolicy egress-db-block -n "$NAMESPACE" 2>/dev/null && \
    echo "  → Removed egress-db-block NetworkPolicy" || \
    echo "  → Already removed"

echo ""
echo "Step 2: Waiting for connections to recover..."
sleep 5

echo ""
echo "Step 3: Verifying recovery..."
echo ""
echo "  Health:"
H=$(oc exec -n "$NAMESPACE" deploy/frontend -- \
    curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 3 --max-time 5 \
    http://backend-api:5000/api/health 2>/dev/null || echo "000")
echo "    HTTP $H"

echo ""
echo "  Books (should work now):"
for i in 1 2 3; do
    B=$(oc exec -n "$NAMESPACE" deploy/frontend -- \
        curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 3 --max-time 8 \
        http://backend-api:5000/api/books 2>/dev/null || echo "000")
    echo "    Request $i: HTTP $B"
    sleep 1
done

echo ""
echo "Step 4: Pods status..."
oc get pods -n "$NAMESPACE" --no-headers

echo ""
echo "Scenario 2 cleaned up. Check NOO: drops should stop."
