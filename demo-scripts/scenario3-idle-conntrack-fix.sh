#!/bin/bash
# ============================================================
# SCENARIO 3: FIX — Restore conntrack ESTABLISHED timeout
# ============================================================

set -e

echo ""
echo "══════════════════════════════════════════════════════════"
echo "  SCENARIO 3: FIX — Restoring conntrack timeout..."
echo "══════════════════════════════════════════════════════════"
echo ""

if [ -f /tmp/devconf-scenario3-state ]; then
    read -r NODE ORIG_TIMEOUT < /tmp/devconf-scenario3-state
    echo "Node: $NODE"
    echo "Restoring timeout to: ${ORIG_TIMEOUT}s ($(( ORIG_TIMEOUT / 86400 )) days)"
    oc debug node/"$NODE" -- chroot /host \
        sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established="$ORIG_TIMEOUT" 2>/dev/null
    rm -f /tmp/devconf-scenario3-state
else
    NODE=$(oc get pod -n demo-app -l app=backend-api -o jsonpath='{.items[0].spec.nodeName}')
    echo "No saved state. Restoring default (432000s = 5 days) on $NODE..."
    oc debug node/"$NODE" -- chroot /host \
        sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=432000 2>/dev/null
fi

echo ""
echo "Testing connectivity..."
sleep 3
for i in 1 2 3; do
    HTTP=$(oc exec -n demo-app deploy/backend-api -- \
        curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 3 --max-time 5 \
        http://backend-api:5000/api/books 2>/dev/null || echo "000")
    echo "  Request $i: HTTP $HTTP"
    sleep 1
done
echo ""
echo "Timeout restored. Check NOO: drops should stop."
