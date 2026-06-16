#!/bin/bash
# ============================================================
# TRADITIONAL DEBUGGING — Show the audience what tcpdump,
# ovn-trace, ovs-ofctl, and conntrack give you (spoiler: not much)
#
# Run this AFTER breaking a scenario to demonstrate why
# traditional tools fail. Then switch to NOO dashboard.
# ============================================================

set -e

NAMESPACE="demo-app"
BACKEND_POD=$(oc get pod -n "$NAMESPACE" -l app=backend-api -o jsonpath='{.items[0].metadata.name}')
BACKEND_NODE=$(oc get pod -n "$NAMESPACE" "$BACKEND_POD" -o jsonpath='{.spec.nodeName}')
BACKEND_IP=$(oc get pod -n "$NAMESPACE" "$BACKEND_POD" -o jsonpath='{.status.podIP}')

echo ""
echo "========================================================"
echo "  TRADITIONAL DEBUGGING COMMANDS"
echo "  These are the tools a support engineer would use."
echo "  Watch how NONE of them tell you the root cause."
echo "========================================================"
echo ""
echo "Backend pod: $BACKEND_POD"
echo "Backend node: $BACKEND_NODE"
echo "Backend IP: $BACKEND_IP"

# -------------------------------------------------------
echo ""
echo "════════════════════════════════════════════════════"
echo "  1. tcpdump — capture packets on the node"
echo "════════════════════════════════════════════════════"
echo ""
echo "$ oc debug node/$BACKEND_NODE -- chroot /host tcpdump -i any -n port 5000 -c 10"
echo ""
echo "Running tcpdump for 10 packets (timeout 15s)..."
timeout 15 oc debug node/"$BACKEND_NODE" -- chroot /host \
    timeout 10 tcpdump -i any -n port 5000 -c 10 2>&1 | head -15 || echo "(tcpdump timed out or captured less than 10 packets)"
echo ""
echo "OBSERVATION: You see SYN packets going out. No SYN-ACK."
echo "CONCLUSION:  tcpdump says 'packets sent, no reply' — but WHY?"
echo "             Is the pod down? Is it a NetworkPolicy? Conntrack? No idea."

# -------------------------------------------------------
echo ""
echo "════════════════════════════════════════════════════"
echo "  2. conntrack -S — check conntrack statistics"
echo "════════════════════════════════════════════════════"
echo ""
echo "$ oc debug node/$BACKEND_NODE -- chroot /host conntrack -S"
echo ""
oc debug node/"$BACKEND_NODE" -- chroot /host \
    conntrack -S 2>/dev/null | head -4 || echo "(conntrack command not available)"
echo ""
echo "OBSERVATION: You might see 'insert_failed' or 'drop' counters."
echo "CONCLUSION:  Just a COUNTER. Which pods? When? Which connections? No idea."

# -------------------------------------------------------
echo ""
echo "════════════════════════════════════════════════════"
echo "  3. conntrack -L — list conntrack entries"
echo "════════════════════════════════════════════════════"
echo ""
echo "$ oc debug node/$BACKEND_NODE -- chroot /host conntrack -L -d $BACKEND_IP | head -5"
echo ""
oc debug node/"$BACKEND_NODE" -- chroot /host \
    bash -c "conntrack -L -d $BACKEND_IP 2>/dev/null | head -5" 2>/dev/null || echo "(no entries or command failed)"
echo ""
echo "OBSERVATION: Raw conntrack entries — thousands of them on a busy node."
echo "CONCLUSION:  Can you find the DROPPED connection in this list? Good luck."

# -------------------------------------------------------
echo ""
echo "════════════════════════════════════════════════════"
echo "  4. ovs-ofctl dump-flows — check OpenFlow rules"
echo "════════════════════════════════════════════════════"
echo ""
echo "$ oc debug node/$BACKEND_NODE -- chroot /host ovs-ofctl dump-flows br-int | wc -l"
echo ""
FLOW_COUNT=$(oc debug node/"$BACKEND_NODE" -- chroot /host \
    bash -c "ovs-ofctl dump-flows br-int 2>/dev/null | wc -l" 2>/dev/null || echo "?")
echo "  Total OpenFlow rules on br-int: $FLOW_COUNT"
echo ""
echo "OBSERVATION: Hundreds of OpenFlow rules. Which one is dropping your traffic?"
echo "CONCLUSION:  Reading $FLOW_COUNT OpenFlow rules manually — not practical."

# -------------------------------------------------------
echo ""
echo "════════════════════════════════════════════════════"
echo "  5. ovs-appctl ofproto/trace — simulate a packet"
echo "════════════════════════════════════════════════════"
echo ""
echo "$ ovs-appctl ofproto/trace br-int 'in_port=X,...'"
echo ""
echo "(This simulates the OpenFlow pipeline — it will say 'output:Y')"
echo "(But it CANNOT simulate conntrack state — it doesn't know about"
echo " CT_TABLE_FULL or CT_INVALID because those are kernel states,"
echo " not OpenFlow states.)"
echo ""
echo "CONCLUSION: ofproto/trace says 'forward the packet' — but the"
echo "            kernel drops it anyway."

# -------------------------------------------------------
echo ""
echo "════════════════════════════════════════════════════"
echo "  6. Pod status — is the pod even running?"
echo "════════════════════════════════════════════════════"
echo ""
oc get pods -n "$NAMESPACE" -l app=backend-api
echo ""
echo "OBSERVATION: Pod is RUNNING, READY 1/1. Not crashed."
echo ""

oc get endpoints -n "$NAMESPACE" backend-api
echo ""
echo "OBSERVATION: Endpoints look FINE. Backend has an IP."
echo ""
echo "════════════════════════════════════════════════════"
echo "  SUMMARY: ALL traditional tools say 'looks fine'"
echo "  or give you raw data with no actionable insight."
echo ""
echo "  NOW switch to OCP Console → Observe → Network Traffic"
echo "  → Filter namespace=demo-app → Show drops"
echo "  → See the EXACT answer in 5 seconds."
echo "════════════════════════════════════════════════════"
