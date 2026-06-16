#!/bin/bash
# ============================================================
# SCENARIO 3: TRADITIONAL DEBUGGING — Idle Conntrack Timeout
# ============================================================

set -e

NAMESPACE="demo-app"
BACKEND_POD=$(oc get pod -n "$NAMESPACE" -l app=backend-api -o jsonpath='{.items[0].metadata.name}')
BACKEND_NODE=$(oc get pod -n "$NAMESPACE" "$BACKEND_POD" -o jsonpath='{.spec.nodeName}')
BACKEND_IP=$(oc get pod -n "$NAMESPACE" "$BACKEND_POD" -o jsonpath='{.status.podIP}')
DB_POD=$(oc get pod -n "$NAMESPACE" -l app=database -o jsonpath='{.items[0].metadata.name}')
DB_IP=$(oc get pod -n "$NAMESPACE" "$DB_POD" -o jsonpath='{.status.podIP}')

echo ""
echo "══════════════════════════════════════════════════════════"
echo "  SCENARIO 3: Traditional Debugging — Idle Conntrack"
echo "══════════════════════════════════════════════════════════"
echo ""
echo "  Backend: $BACKEND_POD on $BACKEND_NODE (IP: $BACKEND_IP)"
echo "  Database: $DB_POD (IP: $DB_IP)"

# -------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  STEP 1: Check pod status"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
oc get pods -n "$NAMESPACE"
echo ""
echo "  ► ALL pods Running, Ready. Database is NOT crashed."

# -------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  STEP 2: Test database directly"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  $ oc exec backend-api -- curl http://backend-api:5000/api/health"
oc exec -n "$NAMESPACE" "$BACKEND_POD" -- \
    curl -s --max-time 3 http://localhost:5000/api/health 2>/dev/null || echo "(failed)"
echo ""
echo "  ► Backend responds to localhost. Pod itself is healthy."

# -------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  STEP 3: tcpdump — capture traffic to database"
echo "  $ oc debug node/$BACKEND_NODE -- tcpdump -i any -n port 5432 -c 8"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
# Trigger a request
oc exec -n "$NAMESPACE" deploy/backend-api -- \
    curl -s --max-time 3 http://backend-api:5000/api/books &>/dev/null &
timeout 20 oc debug node/"$BACKEND_NODE" -- chroot /host \
    timeout 10 tcpdump -i any -n port 5432 -c 8 2>&1 | grep -v "^Starting\|^Removing\|^$" | head -12 \
    || echo "  (tcpdump timed out)"
echo ""
echo "  ► You see data packets going to database. Maybe RST coming back."
echo "  ► Looks like the DATABASE is resetting the connection."
echo "  ► But the database is FINE — it's the conntrack entry that expired."
echo "  ► tcpdump can't tell the difference."

# -------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  STEP 4: conntrack -L — look for the connection"
echo "  $ oc debug node/$BACKEND_NODE -- conntrack -L -s $BACKEND_IP -d $DB_IP"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
oc debug node/"$BACKEND_NODE" -- chroot /host \
    bash -c "conntrack -L -s $BACKEND_IP -d $DB_IP 2>/dev/null | head -3" 2>/dev/null \
    || echo "  (no entries found)"
echo ""
echo "  ► Few or NO entries. Because the conntrack entry EXPIRED."
echo "  ► You can't find evidence of something that was deleted."
echo "  ► conntrack -L shows current state, not historical."
echo "  ► The timeout happened 35 seconds ago — the entry is GONE."

# -------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  STEP 5: Check conntrack timeout setting"
echo "  $ sysctl net.netfilter.nf_conntrack_tcp_timeout_established"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
TIMEOUT=$(oc debug node/"$BACKEND_NODE" -- chroot /host \
    sysctl -n net.netfilter.nf_conntrack_tcp_timeout_established 2>/dev/null || echo "?")
echo "  nf_conntrack_tcp_timeout_established: ${TIMEOUT}s"
echo ""
echo "  ► If this is low (30s), idle connections lose their conntrack entry."
echo "  ► But you'd have to KNOW to check this specific sysctl."
echo "  ► And even if you find it, you don't know which pods are affected."

# -------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  STEP 6: Application logs — what they say"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Backend-api logs would show:"
echo '    psycopg2.OperationalError: server closed the connection unexpectedly'
echo '    or: connection reset by peer'
echo ""
echo "  ► Looks like the DATABASE closed the connection."
echo "  ► Team spends 2 days debugging PostgreSQL settings."
echo "  ► But the database never closed it — conntrack did."

# -------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  STEP 7: ovn-trace — OVN pipeline check"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  $ ovn-trace 'inport==\"backend-api\" && ip4.src==$BACKEND_IP && ip4.dst==$DB_IP && tcp.dst==5432'"
echo "    → ct_next → output to \"database\""
echo ""
echo "  ► OVN says: ALLOW, forward to database. Correct!"
echo "  ► The ACLs allow backend→database traffic."
echo "  ► But the drop is in kernel conntrack (entry expired)."
echo "  ► OVN trace cannot see conntrack timeout state."

# -------------------------------------------------------
echo ""
echo "══════════════════════════════════════════════════════════"
echo "  SUMMARY:"
echo ""
echo "  ✗ Pod status:    All Running, database healthy"
echo "  ✗ tcpdump:       Data sent, RST back → 'database reset it'"
echo "  ✗ conntrack -L:  No entry (it expired!) → nothing to find"
echo "  ✗ conntrack timeout: 30s (but you'd have to know to check)"
echo "  ✗ App logs:      'connection reset by peer' → blame database"
echo "  ✗ ovn-trace:     Says ALLOW → pipeline is correct"
echo ""
echo "  Every tool points at the DATABASE. But the database is fine."
echo "  The conntrack entry expired after 30s of idle time."
echo "  When the app reused the connection, kernel said CT_INVALID."
echo ""
echo "  NOO shows: CT_INVALID drops on backend→database flows,"
echo "  ONLY on connections idle >30s. New connections: 0 drops."
echo "══════════════════════════════════════════════════════════"
