#!/bin/bash
# ============================================================
# NOO Demo Pre-Requisite Check
# Run this BEFORE the demo to verify everything is ready
# ============================================================

echo ""
echo "============================================"
echo "  NOO DEMO PRE-REQUISITE CHECK"
echo "  $(date)"
echo "============================================"
echo ""

PASS=0
FAIL=0
WARN=0

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }
warn() { echo "  ~ $1"; WARN=$((WARN+1)); }

# --- 1. CLUSTER ---
echo "=== 1. CLUSTER HEALTH ==="
VER=$(oc get clusterversion -o jsonpath='{.items[0].status.desired.version}' 2>/dev/null)
[ -n "$VER" ] && ok "Version: $VER" || fail "Cannot reach cluster API"
AVAIL=$(oc get clusterversion -o jsonpath='{.items[0].status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
[ "$AVAIL" = "True" ] && ok "Cluster available" || fail "Cluster not available"
DEGRADED=$(oc get co --no-headers 2>/dev/null | awk '$5=="True"' | wc -l | tr -d ' ')
[ "$DEGRADED" = "0" ] && ok "No degraded operators" || fail "$DEGRADED degraded operators"
NODES=$(oc get nodes --no-headers 2>/dev/null | grep -c Ready)
[ "$NODES" -ge 2 ] && ok "$NODES nodes Ready" || fail "Need at least 2 Ready nodes for hairpin demo"

# --- 2. OVN-K ---
echo ""
echo "=== 2. OVN-KUBERNETES ==="
CNI=$(oc get network.config cluster -o jsonpath='{.spec.networkType}' 2>/dev/null)
[ "$CNI" = "OVNKubernetes" ] && ok "CNI: OVNKubernetes" || warn "CNI: $CNI (NetworkEvents feature requires OVN-K)"

# --- 3. LOKI OPERATOR ---
echo ""
echo "=== 3. LOKI OPERATOR ==="
LOKI_CSV=$(oc get csv -n openshift-operators-redhat --no-headers 2>/dev/null | grep loki | awk '{print $1}')
[ -n "$LOKI_CSV" ] && ok "Loki Operator: $LOKI_CSV" || fail "Loki Operator NOT installed"

# --- 4. LOKISTACK ---
echo ""
echo "=== 4. LOKISTACK ==="
LOKI_READY=$(oc get lokistack lokistack-network -n netobserv-loki -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
[ "$LOKI_READY" = "True" ] && ok "LokiStack: Ready" || fail "LokiStack: NOT ready ($LOKI_READY)"
LOKI_PODS=$(oc get pods -n netobserv-loki --no-headers 2>/dev/null | grep -c Running)
[ "$LOKI_PODS" -ge 8 ] && ok "Loki pods: $LOKI_PODS running" || fail "Loki pods: only $LOKI_PODS running (need 8+)"

# --- 5. NOO ---
echo ""
echo "=== 5. NETWORK OBSERVABILITY OPERATOR ==="
NOO_CSV=$(oc get csv -n openshift-netobserv-operator --no-headers 2>/dev/null | grep network-observability | awk '{print $1}')
if [ -n "$NOO_CSV" ]; then
    ok "NOO: $NOO_CSV"
else
    fail "NOO NOT installed — install from OperatorHub"
fi

# --- 6. FLOWCOLLECTOR ---
echo ""
echo "=== 6. FLOWCOLLECTOR ==="
FC=$(oc get flowcollector cluster -o jsonpath='{.metadata.name}' 2>/dev/null)
if [ -n "$FC" ]; then
    ok "FlowCollector exists"
    FEATURES=$(oc get flowcollector cluster -o jsonpath='{.spec.agent.ebpf.features}' 2>/dev/null)
    echo "$FEATURES" | grep -q "PacketDrop" && ok "Feature: PacketDrop enabled" || fail "PacketDrop NOT enabled"
    echo "$FEATURES" | grep -q "DNSTracking" && ok "Feature: DNSTracking enabled" || warn "DNSTracking not enabled"
    echo "$FEATURES" | grep -q "NetworkEvents" && ok "Feature: NetworkEvents enabled" || warn "NetworkEvents not enabled"
    PRIV=$(oc get flowcollector cluster -o jsonpath='{.spec.agent.ebpf.privileged}' 2>/dev/null)
    [ "$PRIV" = "true" ] && ok "Privileged: true" || fail "Privileged: false (PacketDrop won't work)"
    SAMP=$(oc get flowcollector cluster -o jsonpath='{.spec.agent.ebpf.sampling}' 2>/dev/null)
    [ "$SAMP" = "1" ] && ok "Sampling: 1 (every packet)" || warn "Sampling: $SAMP (set to 1 for demo)"
else
    fail "FlowCollector NOT created"
fi

# --- 7. eBPF AGENTS ---
echo ""
echo "=== 7. eBPF AGENTS ==="
AGENT_READY=$(oc get ds -n netobserv-privileged --no-headers 2>/dev/null | awk '{print $4}')
AGENT_DESIRED=$(oc get ds -n netobserv-privileged --no-headers 2>/dev/null | awk '{print $2}')
if [ -n "$AGENT_READY" ]; then
    [ "$AGENT_READY" = "$AGENT_DESIRED" ] && ok "eBPF agents: $AGENT_READY/$AGENT_DESIRED ready" || fail "eBPF agents: $AGENT_READY/$AGENT_DESIRED ready"
else
    fail "No eBPF agent DaemonSet"
fi

# --- 8. FLP ---
echo ""
echo "=== 8. FLOWLOGS-PIPELINE ==="
FLP_COUNT=$(oc get pods -n netobserv --no-headers 2>/dev/null | grep -c flowlogs)
[ "$FLP_COUNT" -ge 1 ] && ok "FLP pods: $FLP_COUNT running" || fail "No FLP pods"

# --- 9. CONSOLE PLUGIN ---
echo ""
echo "=== 9. CONSOLE PLUGIN ==="
PLUGIN=$(oc get consoleplugin 2>/dev/null | grep -c netobserv)
[ "$PLUGIN" -ge 1 ] && ok "Console plugin registered" || fail "Console plugin NOT registered"

# --- 10. DEMO APP ---
echo ""
echo "=== 10. DEMO APPLICATION ==="
APP_PODS=$(oc get pods -n demo-app --no-headers 2>/dev/null | grep -c Running)
if [ "$APP_PODS" -eq 3 ]; then
    ok "All 3 demo-app pods running"
    # Test connectivity
    HEALTH=$(oc exec -n demo-app deploy/backend-api -- curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 http://backend-api:5000/api/health 2>/dev/null)
    [ "$HEALTH" = "200" ] && ok "backend-api /api/health: HTTP 200" || fail "backend-api health: HTTP $HEALTH"
    BOOKS=$(oc exec -n demo-app deploy/backend-api -- curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 http://backend-api:5000/api/books 2>/dev/null)
    [ "$BOOKS" = "200" ] && ok "backend-api /api/books: HTTP 200" || fail "backend-api books: HTTP $BOOKS (DB init may have failed)"
else
    fail "Demo app: $APP_PODS/3 pods running — deploy with: oc apply -f /root/devconf/demo-app/"
fi

# --- 11. NOO DASHBOARD ---
echo ""
echo "=== 11. VERIFY IN BROWSER ==="
CONSOLE_URL=$(oc whoami --show-console 2>/dev/null)
if [ -n "$CONSOLE_URL" ]; then
    echo "  Open: $CONSOLE_URL"
    echo "  Navigate: Observe → Network Traffic"
    echo "  Filter: Namespace = demo-app"
    echo "  Verify: flows appear with 0 drops (healthy baseline)"
else
    warn "Cannot determine console URL"
fi

# --- SUMMARY ---
echo ""
echo "============================================"
echo "  RESULTS: $PASS passed, $FAIL failed, $WARN warnings"
echo "============================================"
if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "  FIX REQUIRED before demo:"
    [ -z "$NOO_CSV" ] && echo "    1. Install NOO from OperatorHub"
    [ -z "$FC" ] && echo "    2. Create FlowCollector CR"
    [ "$APP_PODS" -ne 3 ] 2>/dev/null && echo "    3. Deploy demo app: oc apply -f /root/devconf/demo-app/"
fi
echo ""
