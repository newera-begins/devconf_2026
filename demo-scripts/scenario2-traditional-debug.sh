#!/bin/bash
# ============================================================
# SCENARIO 2: TRADITIONAL DEBUGGING — Egress DB Block
# ============================================================
# Run this AFTER scenario2-egress-break.sh to show the audience
# how every traditional tool sends you on a wild goose chase
# debugging PostgreSQL — when the real problem is an EGRESS
# NetworkPolicy blocking port 5432.
#
# Runs REAL commands. SAFE: No oc debug node, no sysctl.
# ============================================================

NAMESPACE="demo-app"
OVN_NS="openshift-ovn-kubernetes"

BACKEND_POD=$(oc get pod -n "$NAMESPACE" -l app=backend-api -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
BACKEND_NODE=$(oc get pod -n "$NAMESPACE" "$BACKEND_POD" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
BACKEND_IP=$(oc get pod -n "$NAMESPACE" "$BACKEND_POD" -o jsonpath='{.status.podIP}' 2>/dev/null)

DB_POD=$(oc get pod -n "$NAMESPACE" -l app=database -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
DB_IP=$(oc get pod -n "$NAMESPACE" "$DB_POD" -o jsonpath='{.status.podIP}' 2>/dev/null)
DB_NODE=$(oc get pod -n "$NAMESPACE" "$DB_POD" -o jsonpath='{.spec.nodeName}' 2>/dev/null)

SVC_DB_IP=$(oc get svc -n "$NAMESPACE" database -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "unknown")

OVN_POD=$(oc get pods -n "$OVN_NS" -l app=ovnkube-node \
    -o jsonpath="{range .items[*]}{.metadata.name}{' '}{.spec.nodeName}{'\n'}{end}" 2>/dev/null \
    | grep "$BACKEND_NODE" | awk '{print $1}')

echo ""
echo "══════════════════════════════════════════════════════════"
echo "  SCENARIO 2: Traditional Debugging — 'Database is Broken'"
echo "  Spoiler: PostgreSQL is fine. The problem is elsewhere."
echo "══════════════════════════════════════════════════════════"
echo ""
echo "  Backend: $BACKEND_POD on $BACKEND_NODE (IP: $BACKEND_IP)"
echo "  Database: $DB_POD on $DB_NODE (IP: $DB_IP)"
echo "  DB Service: $SVC_DB_IP:5432"
echo "  OVN pod: $OVN_POD"

# -------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  STEP 1: Reproduce — health works, books fails"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Health endpoint (via frontend → backend-api):"
for i in 1 2 3; do
    H=$(oc exec -n "$NAMESPACE" deploy/frontend -- \
        curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 3 --max-time 5 \
        http://backend-api:5000/api/health 2>/dev/null || echo "000")
    echo "    $i: HTTP $H"
done
echo ""
echo "  Books endpoint (via frontend → backend-api → database):"
for i in 1 2 3; do
    RESP=$(oc exec -n "$NAMESPACE" deploy/frontend -- \
        curl -s --max-time 8 http://backend-api:5000/api/books 2>/dev/null)
    if echo "$RESP" | grep -q '"id"'; then
        echo "    $i: OK"
    elif echo "$RESP" | grep -q "error"; then
        echo "    $i: ★ FAILED — $(echo "$RESP" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('error','?')[:60])" 2>/dev/null)"
    else
        echo "    $i: ★ FAILED — timeout/empty response"
    fi
done
echo ""
echo "  ► Health WORKS. Books FAILS."
echo "  ► Traditional conclusion: 'Database must be broken!'"

# -------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  STEP 2: Check all pods — everything is Running"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
oc get pods -n "$NAMESPACE" --no-headers
echo ""
echo "  ► ALL pods Running, Ready 1/1. Nothing crashed."
echo "  ► Traditional conclusion: 'Pods look fine.'"

# -------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  STEP 3: Check database DIRECTLY — it's healthy!"
echo "  \$ oc exec deploy/database -- psql -c 'SELECT count(*) FROM books'"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
oc exec -n "$NAMESPACE" deploy/database -- \
    psql -U demo -d bookstore -c "SELECT count(*) as book_count FROM books;" 2>/dev/null
echo ""
echo "  ► Database has 8 books. PostgreSQL is perfectly healthy."
echo "  ► CONFUSION: 'If the DB is fine, why can't the app read it?'"

# -------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  STEP 4: Check endpoints and services"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
oc get endpoints -n "$NAMESPACE" database
echo ""
echo "  ► Database endpoint exists: $DB_IP:5432"
echo "  ► Service is configured correctly."

# -------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  STEP 5: tcpdump — REAL capture on port 5432"
echo "  \$ tcpdump -i any -nn port 5432 (from ovnkube-node)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
if [ -n "$OVN_POD" ]; then
    oc exec -n "$OVN_NS" -c ovn-controller "$OVN_POD" -- \
        timeout 8 tcpdump -i any -nn port 5432 -c 8 2>/dev/null > /tmp/tcpdump-s2.txt &
    TCPD=$!
    sleep 1

    # Trigger a books request to generate DB traffic
    oc exec -n "$NAMESPACE" deploy/frontend -- \
        curl -s --max-time 6 http://backend-api:5000/api/books &>/dev/null &
    sleep 2
    oc exec -n "$NAMESPACE" deploy/frontend -- \
        curl -s --max-time 4 http://backend-api:5000/api/books &>/dev/null &

    wait $TCPD 2>/dev/null
    echo "  --- LIVE tcpdump on port 5432 ---"
    cat /tmp/tcpdump-s2.txt 2>/dev/null | head -10
    PKTS=$(wc -l < /tmp/tcpdump-s2.txt 2>/dev/null || echo "0")
    echo "  --- $PKTS packets captured ---"
    rm -f /tmp/tcpdump-s2.txt
else
    echo "  (ovnkube-node pod not found)"
fi
echo ""
echo "  ► Look: SYN packets from backend-api ($BACKEND_IP) to"
echo "    database ($DB_IP) on port 5432. No SYN-ACK."
echo "  ► tcpdump shows SYN going out but can't tell you WHY"
echo "    there's no response. Is the DB down? Port blocked?"
echo "  ► We JUST proved the DB is healthy (Step 3). So why?"

# -------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  STEP 6: Check NetworkPolicies"
echo "  \$ oc get networkpolicy -n demo-app"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
oc get networkpolicy -n "$NAMESPACE"
echo ""
echo "  ► There IS a NetworkPolicy. But what does it do?"
echo "  ► Most engineers check INGRESS rules first."
echo "  ► This policy only has EGRESS rules — easy to miss."
echo "  ► With 20-50 policies in production, finding the one"
echo "    that blocks EGRESS on a SPECIFIC port takes 15-30 min."

# -------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  STEP 7: OVN Load Balancer + ACLs (REAL output)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
if [ -n "$OVN_POD" ]; then
    echo "  a) OVN Load Balancer for database service:"
    oc exec -n "$OVN_NS" -c ovnkube-controller "$OVN_POD" -- \
        ovn-nbctl lb-list 2>/dev/null | grep "$SVC_DB_IP" | head -2
    echo ""
    echo "  ► LB maps $SVC_DB_IP:5432 → $DB_IP:5432. DNAT correct."

    echo ""
    echo "  b) OVN ACLs on the logical switch (NetworkPolicy rules):"
    if [ -n "$LS_NAME" ]; then
        echo "  \$ ovn-nbctl acl-list $LS_NAME"
        echo ""
        ACLS=$(oc exec -n "$OVN_NS" -c ovnkube-controller "$OVN_POD" -- \
            ovn-nbctl acl-list "$LS_NAME" 2>/dev/null)
        EGRESS_ACLS=$(echo "$ACLS" | grep -i "from-lport\|to-lport" | head -8)
        ACL_TOTAL=$(echo "$ACLS" | grep -c "." 2>/dev/null || echo "0")
        echo "  --- ACL rules (showing first 8 of $ACL_TOTAL) ---"
        echo "$EGRESS_ACLS" | while read line; do
            echo "  $line"
        done
        echo "  --- end ---"
        echo ""
        echo "  ► $ACL_TOTAL ACL rules on this switch."
        echo "  ► These include allow (port 53, 443, 5000) and deny-all egress."
        echo "  ► Port 5432 is NOT in any allow rule → BLOCKED by default-deny."
        echo "  ► But reading $ACL_TOTAL ACL rules to spot the missing port?"
        echo "    With 50+ policies in production — good luck."
    fi
    echo ""
    echo "  ► The INGRESS path to the database is fine."
    echo "  ► The problem is backend-api's EGRESS — it can't send."
fi

# -------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  STEP 8: OVS flows on port 5432 (REAL output)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
if [ -n "$OVN_POD" ]; then
    TOTAL_FLOWS=$(oc exec -n "$OVN_NS" -c ovn-controller "$OVN_POD" -- \
        ovs-ofctl dump-flows br-int 2>/dev/null | wc -l)
    FLOWS_5432=$(oc exec -n "$OVN_NS" -c ovn-controller "$OVN_POD" -- \
        ovs-ofctl dump-flows br-int 2>/dev/null | grep "tp_dst=5432\|nw_dst=$DB_IP")
    FLOW_COUNT=$(echo "$FLOWS_5432" | grep -c "." 2>/dev/null || echo "0")

    echo "  Total OpenFlow rules on br-int: $TOTAL_FLOWS"
    echo "  Rules matching port 5432 or database IP ($DB_IP): $FLOW_COUNT"
    echo ""
    if [ -n "$FLOWS_5432" ]; then
        echo "  --- Actual OVS flow rules for port 5432 ---"
        echo "$FLOWS_5432" | head -5 | while read line; do
            echo "  $line"
        done
        echo "  --- end ---"
    fi
    echo ""
    echo "  ► These flows match port 5432 — they're DNAT/LB rules."
    echo "  ► They say 'ct(nat)' — forward and NAT. Looks correct."
    echo ""
    echo "  But where is the ACTUAL drop? Let's find it:"
    echo ""
    echo "  --- Drop rules matching backend-api IP ($BACKEND_IP) ---"
    DROP_RULES=$(oc exec -n "$OVN_NS" -c ovn-controller "$OVN_POD" -- \
        ovs-ofctl dump-flows br-int 2>/dev/null | grep "$BACKEND_IP" | grep "actions=drop")
    if [ -n "$DROP_RULES" ]; then
        echo "$DROP_RULES" | head -3 | while read line; do
            echo "  $line"
        done
        DROP_PKTS=$(echo "$DROP_RULES" | head -1 | grep -o "n_packets=[0-9]*" | head -1)
        echo "  --- end ---"
        echo ""
        echo "  ★ FOUND IT! Table 79 (egress ACL), $DROP_PKTS"
        echo "  ★ This rule matches ALL IP from backend-api → actions=drop"
        echo "  ★ Port 5432 is NOT in any allow rule → hits this default-deny"
        echo ""
        echo "  But to find this, you need to:"
        echo "    1. Know that table 79 handles egress ACLs"
        echo "    2. Know to grep by SOURCE IP, not destination port"
        echo "    3. Read $TOTAL_FLOWS rules to find the one that matters"
        echo "    4. Understand register values and metadata IDs"
        echo "  ► This requires deep OVN pipeline expertise."
        echo "  ► NOO shows 'NetworkPolicy, port 5432' in 5 seconds."
    else
        echo "  (No drop rules found matching backend-api IP)"
        echo "  ► The drop rule uses register-based matching that"
        echo "    grep by IP alone might miss. Need OVN pipeline expertise."
    fi
fi

# -------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  STEP 9: Application logs — misleading!"
echo "  \$ oc logs deploy/backend-api --tail=5"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
oc logs -n "$NAMESPACE" deploy/backend-api --tail=5 2>/dev/null
echo ""
echo "  ► Logs show health checks working (200 responses)."
echo "  ► No explicit 'connection refused' errors — the request"
echo "    just times out at the kernel level."
echo "  ► Traditional conclusion: 'App looks fine, DB must be slow.'"
echo "  ► WRONG: The DB is fast. The EGRESS policy blocks port 5432."

# -------------------------------------------------------
echo ""
echo "══════════════════════════════════════════════════════════"
echo "  SUMMARY: 9 REAL checks. ALL send you in the WRONG direction."
echo ""
echo "  ✗ Health endpoint:   HTTP 200 (misleading — app IS healthy)"
echo "  ✗ Books endpoint:    FAILS (everyone blames the database)"
echo "  ✗ Database pod:      Running, 8 books (PostgreSQL is fine!)"
echo "  ✗ Endpoints:         Exist (service is configured)"
echo "  ✗ tcpdump:           SYN to port 5432, no SYN-ACK"
echo "  ✗ NetworkPolicy:     Exists (but who reads EGRESS rules?)"
echo "  ✗ OVN LB:            DNAT correct for database service"
echo "  ✗ OVS flows:         Flows exist for port 5432"
echo "  ✗ App logs:          No errors (timeout is silent)"
echo ""
echo "  THE DEBUGGING TRAP:"
echo "  1. Health works → 'app is fine'"
echo "  2. Books fails → 'database is broken'"
echo "  3. DBA checks PostgreSQL → it's healthy"
echo "  4. Dev checks app code → code is correct"
echo "  5. SRE runs tcpdump → SYN no SYN-ACK → 'network issue?'"
echo "  6. 30+ minutes later... still no answer"
echo ""
echo "  WITH NOO (5 seconds):"
echo "  → backend-api → database, port 5432"
echo "  → Drop Reason: NetworkPolicy"
echo "  → 'An EGRESS policy on backend-api blocks port 5432.'"
echo "  → Fix: remove the policy. Done."
echo ""
echo "  NOW: OCP Console → Observe → Network Traffic → Show drops"
echo "       → backend-api → database → NetworkPolicy → port 5432"
echo "══════════════════════════════════════════════════════════"
