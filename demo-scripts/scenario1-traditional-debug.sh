#!/bin/bash
# ============================================================
# SCENARIO 1: TRADITIONAL DEBUGGING — NetworkPolicy Drops
# ============================================================
# Run this AFTER scenario1-netpol-break.sh to show the audience
# what standard K8s tools tell you (spoiler: nothing useful).
#
# SAFE: No oc debug node. No sysctl. Only oc exec and oc get.
# ============================================================

NAMESPACE="demo-app"
BACKEND_POD=$(oc get pod -n "$NAMESPACE" -l app=backend-api -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
BACKEND_IP=$(oc get pod -n "$NAMESPACE" "$BACKEND_POD" -o jsonpath='{.status.podIP}' 2>/dev/null)
GEN_POD=$(oc get pod -n "$NAMESPACE" -l app=traffic-generator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

echo ""
echo "══════════════════════════════════════════════════════════"
echo "  SCENARIO 1: Traditional Debugging — NetworkPolicy Drops"
echo "  Showing what each tool tells you (spoiler: not the RCA)"
echo "══════════════════════════════════════════════════════════"
echo ""
echo "  Backend pod: $BACKEND_POD (IP: $BACKEND_IP)"
echo "  Traffic-gen pod: $GEN_POD"

# -------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  STEP 1: Check pod status"
echo "  \$ oc get pods -n demo-app"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
oc get pods -n "$NAMESPACE"
echo ""
echo "  ► ALL pods Running, Ready 1/1. Nothing crashed."
echo "  ► Traditional conclusion: 'Pods look fine.'"
echo "  ► MISLEADING: the drop happens in OVS, not the pod."

# -------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  STEP 2: Check endpoints"
echo "  \$ oc get endpoints -n demo-app backend-api"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
oc get endpoints -n "$NAMESPACE" backend-api
echo ""
echo "  ► Endpoint exists: $BACKEND_IP:5000"
echo "  ► Traditional conclusion: 'Service is configured correctly.'"
echo "  ► MISLEADING: endpoint exists but traffic is blocked before"
echo "    it reaches the pod."

# -------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  STEP 3: Test from traffic-generator (FAILS)"
echo "  \$ oc exec $GEN_POD -- curl http://backend-api:5000/api/health"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
HTTP=$(oc exec -n "$NAMESPACE" "$GEN_POD" -- \
    curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 5 \
    http://backend-api:5000/api/health 2>/dev/null || echo "000")
echo "  Result: HTTP $HTTP"
echo ""
if [ "$HTTP" != "200" ]; then
    echo "  ► FAILED! Connection timed out."
    echo "  ► Traditional conclusion: 'backend-api must be down!'"
    echo "  ► WRONG: backend-api IS running. The NetworkPolicy blocked it."
fi

# -------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  STEP 4: Test from backend-api itself (WORKS)"
echo "  \$ oc exec deploy/backend-api -- curl http://backend-api:5000/api/health"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
HTTP2=$(oc exec -n "$NAMESPACE" deploy/backend-api -- \
    curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 5 \
    http://backend-api:5000/api/health 2>/dev/null || echo "000")
echo "  Result: HTTP $HTTP2"
echo ""
echo "  ► WORKS! backend-api can reach itself."
echo "  ► So the pod is healthy. The app is listening."
echo "  ► CONFUSION: 'Why can't traffic-generator reach it"
echo "    when backend-api can reach itself?'"

# -------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  STEP 5: Check application logs"
echo "  \$ oc logs deploy/backend-api --tail=5"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
oc logs -n "$NAMESPACE" deploy/backend-api --tail=5 2>/dev/null
echo ""
echo "  ► Logs show health checks WORKING (self-access)."
echo "  ► No errors, no connection attempts from traffic-generator."
echo "  ► MISLEADING: 'App looks healthy' — because it IS healthy."
echo "  ► The traffic never reaches the app. Can't log what you"
echo "    never received. The drop is in the OVS datapath."

# -------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  STEP 6: List NetworkPolicies"
echo "  \$ oc get networkpolicy -n demo-app"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
oc get networkpolicy -n "$NAMESPACE"
echo ""
echo "  ► NetworkPolicy 'block-traffic-generator' exists."
echo "  ► But with 20-50 policies in production, would you"
echo "    spot THIS one? You'd need to read each YAML, check"
echo "    label selectors, and realize traffic-generator's"
echo "    labels don't match any ingress rule."
echo "  ► Takes 15-30 minutes of manual YAML reading."

# -------------------------------------------------------
echo ""
echo "══════════════════════════════════════════════════════════"
echo "  SUMMARY: 6 checks. Zero clear root cause."
echo ""
echo "  ✗ Pod status:   Running, Ready 1/1"
echo "  ✗ Endpoints:    Exist, IP assigned"
echo "  ✗ traffic-gen:  HTTP $HTTP (timeout — looks like pod is down)"
echo "  ✓ backend-api:  HTTP $HTTP2 (self-check works — pod IS healthy)"
echo "  ✗ App logs:     No errors, no connection attempts"
echo "  ? NetworkPolicy: Exists — but which one is the culprit?"
echo ""
echo "  NOW: OCP Console → Observe → Network Traffic"
echo "       → Filter namespace=demo-app → Show drops"
echo "       → See 'NetworkPolicy' drop with exact pod names"
echo "       → 5 SECONDS vs 15-30 minutes of YAML reading"
echo "══════════════════════════════════════════════════════════"
