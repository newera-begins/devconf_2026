#!/bin/bash
# ============================================================
# SCENARIO 1: FIX — Remove blocking NetworkPolicy
# ============================================================
# SAFE: Only deletes resources in demo-app namespace.
# ============================================================

NAMESPACE="demo-app"

echo ""
echo "========================================================"
echo "  SCENARIO 1: FIX"
echo "  Removing NetworkPolicy and traffic-generator pods..."
echo "========================================================"
echo ""

# Step 1: Remove the blocking NetworkPolicy
echo "Step 1: Removing NetworkPolicy..."
oc delete networkpolicy block-traffic-generator -n "$NAMESPACE" 2>/dev/null && \
    echo "  → Removed block-traffic-generator NetworkPolicy" || \
    echo "  → Already removed"

# Step 2: Remove traffic-generator pods
echo ""
echo "Step 2: Removing traffic-generator deployment..."
oc delete deployment traffic-generator -n "$NAMESPACE" 2>/dev/null && \
    echo "  → Removed traffic-generator deployment" || \
    echo "  → Already removed"

# Step 3: Verify
echo ""
echo "Step 3: Verifying normal connectivity..."
sleep 5

for i in 1 2 3; do
    HTTP=$(oc exec -n "$NAMESPACE" deploy/backend-api -- \
        curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 3 --max-time 5 \
        http://backend-api:5000/api/books 2>/dev/null || echo "000")
    echo "  Request $i: HTTP $HTTP"
    sleep 1
done

echo ""
echo "Step 4: Pods status..."
oc get pods -n "$NAMESPACE" --no-headers

echo ""
echo "Scenario 1 cleaned up. Check NOO dashboard: drops should stop."
