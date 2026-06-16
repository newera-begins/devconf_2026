#!/bin/bash
# ============================================================
# CLEANUP — Remove all demo scenarios and reset to clean state
# ============================================================
# SAFE: Only deletes resources in demo-app namespace.
# No sysctl changes, no oc debug node/.
# Run between rehearsals or before the actual talk.
# ============================================================

echo ""
echo "========================================"
echo "  FULL CLEANUP — Resetting all scenarios"
echo "========================================"

# Scenario 1: Remove NetworkPolicy and traffic-generator
echo ""
echo "Cleaning Scenario 1 (NetworkPolicy drops)..."
oc delete networkpolicy block-traffic-generator -n demo-app 2>/dev/null && \
    echo "  → Removed block-traffic-generator NetworkPolicy" || \
    echo "  → Already clean"
oc delete deployment traffic-generator -n demo-app 2>/dev/null && \
    echo "  → Removed traffic-generator deployment" || \
    echo "  → Already clean"
oc delete deployment traffic-flood -n demo-app 2>/dev/null && \
    echo "  → Removed traffic-flood deployment (legacy)" || \
    echo "  → Already clean"

# Scenario 2: Remove egress block + legacy hairpin resources
echo ""
echo "Cleaning Scenario 2 (Egress DB Block)..."
oc delete networkpolicy egress-db-block -n demo-app 2>/dev/null && \
    echo "  → Removed egress-db-block NetworkPolicy" || \
    echo "  → Already clean"
oc delete networkpolicy hairpin-trigger -n demo-app 2>/dev/null && \
    echo "  → Removed hairpin-trigger NetworkPolicy (legacy)" || \
    echo "  → Already clean"
oc delete pod client-same-node -n demo-app 2>/dev/null && \
    echo "  → Removed client-same-node" || \
    echo "  → Already clean"
oc delete pod client-diff-node -n demo-app 2>/dev/null && \
    echo "  → Removed client-diff-node" || \
    echo "  → Already clean"

# Clean up state files
rm -f /tmp/devconf-scenario1-state /tmp/devconf-scenario2-state /tmp/devconf-scenario3-state

echo ""
echo "Verifying application health..."
sleep 3

echo ""
echo "Pod status:"
oc get pods -n demo-app --no-headers

echo ""
echo "Connectivity test:"
HTTP=$(oc exec -n demo-app deploy/backend-api -- \
    curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 5 --max-time 8 \
    http://backend-api:5000/api/books 2>/dev/null || echo "000")
echo "  backend-api /api/books: HTTP $HTTP"

echo ""
echo "Cleanup complete! Ready for demo."
