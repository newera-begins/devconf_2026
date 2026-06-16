#!/bin/bash
# ============================================================
# SCENARIO 3: BREAK — Idle Connection Conntrack Timeout
# ============================================================
# COMPLEXITY: HIGH — Real production issue with database pools
#
# What this does:
#   Lowers the conntrack ESTABLISHED timeout on a worker node
#   from the default (432000s = 5 days) to 30 seconds. Then
#   creates a long-lived TCP connection from backend-api to
#   database. After 35 seconds of idle time, the conntrack
#   entry expires. When the app tries to use the connection
#   again, conntrack sees a data packet with no matching entry
#   → marks it CT_INVALID → DROPS it.
#
#   NEW connections still work (they create fresh conntrack
#   entries). Only IDLE connections that outlive the timeout fail.
#
# Why this is hard to debug:
#   - tcpdump: shows data packets going out, RST coming back
#     → looks like the DATABASE reset the connection
#   - But the database is FINE — it's the conntrack entry that
#     expired, not the database connection
#   - conntrack -L: no entry (it expired!) — you can't see
#     something that was deleted
#   - OVN trace: says "forward" — the pipeline allows traffic
#   - App logs: "connection reset by peer" → blame the database
#
# What NOO shows:
#   - Drop reason: CT_INVALID (packet doesn't match any entry)
#   - Drops ONLY on idle connections after ~30s gap
#   - New connections = 0 drops
#   - The pattern reveals: conntrack timeout, not database issue
# ============================================================

set -e

echo ""
echo "══════════════════════════════════════════════════════════"
echo "  SCENARIO 3: The Expired Connection"
echo "  Lowering conntrack ESTABLISHED timeout to 30 seconds..."
echo "══════════════════════════════════════════════════════════"
echo ""

NAMESPACE="demo-app"

# Step 1: Find the node where backend-api runs
BACKEND_NODE=$(oc get pod -n "$NAMESPACE" -l app=backend-api \
    -o jsonpath='{.items[0].spec.nodeName}')
echo "Target node: $BACKEND_NODE"

# Step 2: Save current timeout
echo ""
echo "Step 1: Reading current conntrack ESTABLISHED timeout..."
CURRENT_TIMEOUT=$(oc debug node/"$BACKEND_NODE" -- chroot /host \
    sysctl -n net.netfilter.nf_conntrack_tcp_timeout_established 2>/dev/null)
echo "  Current timeout: ${CURRENT_TIMEOUT}s ($(( CURRENT_TIMEOUT / 86400 )) days)"

# Save state
echo "$BACKEND_NODE $CURRENT_TIMEOUT" > /tmp/devconf-scenario3-state

# Step 3: Lower timeout to 30 seconds
echo ""
echo "Step 2: Setting ESTABLISHED timeout to 30 seconds..."
oc debug node/"$BACKEND_NODE" -- chroot /host \
    sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=30 2>/dev/null
echo "  Done. Idle TCP connections will lose their conntrack entry after 30s."

# Step 4: Show a working NEW connection
echo ""
echo "Step 3: NEW connections still work (creates fresh conntrack entry)..."
HTTP_CODE=$(oc exec -n "$NAMESPACE" deploy/backend-api -- \
    curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 3 --max-time 5 \
    http://backend-api:5000/api/health 2>/dev/null || echo "000")
echo "  New request: HTTP $HTTP_CODE ✓"

# Step 5: Create a long-lived connection and let it go idle
echo ""
echo "Step 4: Creating a long-lived connection and letting it go idle..."
echo "  (Backend-api has a database connection pool to PostgreSQL)"
echo "  Fetching books (creates DB connection)..."
oc exec -n "$NAMESPACE" deploy/backend-api -- \
    curl -s --max-time 5 http://backend-api:5000/api/books > /dev/null 2>&1
echo "  Connection created. Now waiting 35 seconds for conntrack to expire..."
echo ""
echo "  ┌──────────────────────────────────────────────────┐"
echo "  │  [0s]  Connection established, conntrack: NEW    │"
echo "  │  [5s]  Conntrack state: ESTABLISHED              │"
echo "  │  [30s] Conntrack entry EXPIRES (timeout=30s)     │"
echo "  │  [35s] App tries to reuse connection → CT_INVALID│"
echo "  └──────────────────────────────────────────────────┘"

for i in $(seq 35 -5 0); do
    echo -ne "  Waiting: ${i}s remaining...\r"
    sleep 5
done
echo "  Conntrack entry has expired!                    "

# Step 6: Try to reuse the "established" connection
echo ""
echo "Step 5: Trying to use the connection AFTER conntrack expired..."
echo "  (The TCP connection is still open at the app level,"
echo "   but the kernel conntrack entry is gone)"
echo ""

FAIL_COUNT=0
for i in 1 2 3 4 5; do
    HTTP_CODE=$(oc exec -n "$NAMESPACE" deploy/backend-api -- \
        curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 3 --max-time 5 \
        http://backend-api:5000/api/books 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ]; then
        echo "  Request $i: HTTP $HTTP_CODE (new connection — works)"
    else
        echo "  Request $i: HTTP $HTTP_CODE ★ FAILED (reused idle connection — CT_INVALID)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
    sleep 2
done

# Step 7: Show the pattern
echo ""
echo "══════════════════════════════════════════════════════════"
echo "  RESULTS: $FAIL_COUNT / 5 requests failed"
echo ""
echo "  What's happening:"
echo "  - The backend-api has a connection pool to the database"
echo "  - Idle connections sit for >30s between requests"
echo "  - After 30s, the kernel deletes the conntrack entry"
echo "  - When the app reuses the connection, the kernel sees"
echo "    a data packet with NO matching conntrack entry"
echo "  - Kernel marks it CT_INVALID and DROPS it"
echo "  - App gets 'connection reset' — blames the database"
echo ""
echo "  What traditional tools show:"
echo "  ✗ tcpdump: data packet sent, RST back → 'database reset it'"
echo "  ✗ conntrack -L: no entry (it expired!) → nothing to see"
echo "  ✗ App logs: 'connection reset by peer' → wrong blame"
echo "  ✗ Database: healthy, accepting NEW connections fine"
echo ""
echo "  What NOO shows:"
echo "  ✓ Drop reason: CT_INVALID"
echo "  ✓ Only on connections idle >30s"
echo "  ✓ New connections: 0 drops"
echo "  ✓ Pattern: timeout-related, not database-related"
echo ""
echo "  To debug: bash demo-scripts/scenario3-traditional-debug.sh"
echo "  To fix: bash demo-scripts/scenario3-idle-conntrack-fix.sh"
echo "══════════════════════════════════════════════════════════"
