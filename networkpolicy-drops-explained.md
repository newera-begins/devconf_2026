# NetworkPolicy Drops — Deep Concept Explanation

## What This Document Covers

This explains exactly what happens in Demo Scenario 1 (The Silent NetworkPolicy Drop) —
how OVN-Kubernetes enforces NetworkPolicies, why dropped packets are invisible to
traditional tools, and how eBPF is the only way to identify the exact policy and
affected pods.

---

## What is a NetworkPolicy?

### The Kubernetes Concept

A **NetworkPolicy** is a Kubernetes resource that controls which pods can talk to
which other pods. By default, all pods in a namespace can communicate with each
other freely. When you create a NetworkPolicy, it acts as a firewall rule:

```
OCP Analogy:
  If pods are like VMs on a network, a NetworkPolicy is like a firewall rule
  that says "only allow traffic from VM-A to VM-B on port 5000."
  
  Without NetworkPolicy: all pods can talk to all pods (like a flat network)
  With NetworkPolicy: only explicitly allowed traffic gets through
```

### How OVN-Kubernetes Implements NetworkPolicies

When you create a NetworkPolicy, OVN-Kubernetes translates it into **OVN ACLs**
(Access Control Lists) in the OVN Northbound Database. These ACLs are then
compiled into **OpenFlow rules** on each node's `br-int` bridge.

```
NetworkPolicy YAML
       │
       ▼
OVN-Kubernetes controller
  reads the NetworkPolicy
  creates OVN ACLs in NBDB
       │
       ▼
OVN Southbound Database
  distributes ACLs to all nodes
       │
       ▼
ovn-controller on each node
  compiles ACLs into OpenFlow rules
  installs them in br-int
       │
       ▼
Every packet entering br-int is evaluated
  against these OpenFlow rules
  BEFORE reaching the destination pod
```

### The Silent Drop Problem

When a NetworkPolicy blocks traffic, the packet is **silently dropped** inside
the OVS datapath (br-int). There is no ICMP "destination unreachable" sent back.
There is no RST. There is no log entry. The source pod simply sees:

```
$ curl http://backend-api:5000/api/health
curl: (28) Connection timed out after 5001 milliseconds
```

The curl times out because the SYN packet was dropped inside br-int by an OVN ACL.
The source pod's TCP stack retransmits the SYN (1s, 2s, 4s, 8s exponential backoff)
and eventually gives up.

---

## Why Traditional Tools Fail

### Tool 1: tcpdump

```bash
$ oc exec -n demo-app deploy/traffic-generator -- \
    tcpdump -i eth0 -n port 5000
14:30:01 IP 10.128.2.20.45678 > 10.128.3.15.5000: Flags [S]
14:30:02 IP 10.128.2.20.45678 > 10.128.3.15.5000: Flags [S]    ← retransmit
14:30:04 IP 10.128.2.20.45678 > 10.128.3.15.5000: Flags [S]    ← retransmit
```

**What you see:** SYN packets going out, no SYN-ACK.
**What you think:** "backend-api is down or not listening on port 5000."
**Reality:** The SYN enters br-int, hits the OVN ACL, and is dropped. It NEVER
reaches backend-api's veth interface. tcpdump on the source side sees the SYN
leaving, but can't see where it was dropped.

If you run tcpdump on the DESTINATION side (backend-api), you see NOTHING —
the packet never arrives. But this looks identical to "pod not listening" or
"wrong Service selector" — tcpdump can't tell you it was a NetworkPolicy.

### Tool 2: oc get pods / oc get endpoints

```bash
$ oc get pods -n demo-app -l app=backend-api
NAME                           READY   STATUS    RESTARTS
backend-api-7b4d8f6c5d-k2m9x  1/1     Running   0

$ oc get endpoints backend-api -n demo-app
NAME          ENDPOINTS           AGE
backend-api   10.128.3.15:5000    30m
```

Everything looks healthy. Pod is Running. Endpoints exist. Service is configured.
Nothing in this output tells you traffic is being blocked.

### Tool 3: oc get networkpolicy

```bash
$ oc get networkpolicy -n demo-app
NAME                        POD-SELECTOR       AGE
block-traffic-generator     app=backend-api    5m
```

You CAN see the NetworkPolicy exists. But with 20-50 policies in a production
namespace, you'd need to:
1. Read each policy's YAML
2. Understand the podSelector, ingress rules, and label matching
3. Figure out which SOURCE pod's labels don't match any ingress rule
4. Realize THAT is why traffic is blocked

This takes 15-30 minutes of manual YAML reading. And you need to already
SUSPECT it's a NetworkPolicy — which you might not, because the symptoms
look like "pod is down."

### Tool 4: OVN Trace

```bash
$ ovn-trace --summary <datapath> \
    'inport=="traffic-generator" && ip4.src==10.128.2.20 && \
     ip4.dst==10.128.3.15 && tcp.dst==5000'
```

OVN trace CAN show you the ACL drop — IF you know exactly which source port,
destination, and datapath to trace. But:
- You need to know the exact OVN port names (not pod names)
- You need to construct the correct microflow expression
- On a 100-node cluster with 1000 pods, finding the right trace is non-trivial
- OVN trace shows what WOULD happen to a synthetic packet — not what DID happen
  to real traffic in the past

---

## What the NOO Dashboard Shows

When you filter by **Namespace = demo-app** and toggle **Show drops**:

```
┌──────────────────────────────────────────────────────────────────────┐
│  Network Traffic  [Show drops: ON]            Namespace: demo-app    │
│                                                                      │
│  ┌────────────────────┬────────────────┬────────┬──────────────────┐ │
│  │ Source              │ Destination    │ Drops  │ Drop Reason      │ │
│  ├────────────────────┼────────────────┼────────┼──────────────────┤ │
│  │ traffic-generator  │ backend-api    │ 47     │ NetworkPolicy    │ │
│  │ traffic-generator  │ backend-api    │ 38     │ NetworkPolicy    │ │
│  │ traffic-generator  │ backend-api    │ 29     │ NetworkPolicy    │ │
│  └────────────────────┴────────────────┴────────┴──────────────────┘ │
│                                                                      │
│  ★ Source = traffic-generator pods (3 replicas, each dropping)       │
│  ★ Destination = backend-api                                        │
│  ★ Drop Reason = NetworkPolicy (OVN ACL blocked the traffic)       │
│  ★ frontend → backend-api: ZERO drops (allowed by policy)          │
└──────────────────────────────────────────────────────────────────────┘
```

**In ONE view, you get:**
- WHICH pods are affected (traffic-generator → backend-api)
- The exact DROP REASON (NetworkPolicy — not conntrack, not routing, specifically a policy)
- HOW MANY packets dropped (47, 38, 29 per generator pod)
- That OTHER traffic works (frontend → backend-api has 0 drops)
- No SSH, no tcpdump, no manual YAML reading

---

## How eBPF Captures NetworkPolicy Drops

### The OVS Drop Path

When a packet is dropped by an OVN ACL in the OVS datapath:

```
Packet arrives at br-int
         │
         ▼
  ┌──────────────────────────┐
  │  OpenFlow table lookup    │
  │  (compiled from OVN ACLs) │
  │                           │
  │  Rule matches:            │
  │  "drop packets from       │
  │   traffic-generator to    │
  │   backend-api on port     │
  │   5000"                   │
  │                           │
  │  Action: DROP             │
  └──────────┬───────────────┘
             │
             ▼
  ┌──────────────────────────┐
  │  kfree_skb() called       │
  │  Reason: NETFILTER_DROP   │
  │  or OVS non-core reason   │
  │                           │
  │  eBPF tracepoint FIRES    │
  │  Captures: src/dst IP,    │
  │  port, protocol, reason   │
  └──────────────────────────┘
```

The eBPF agent attached to the `kfree_skb` tracepoint captures every drop with:
- The packet headers (source/destination IP and port)
- The drop reason (OVS_DROP for OVN ACL drops, NETFILTER_DROP for nftables)
- The kernel function where the drop occurred
- A nanosecond timestamp

FLP enriches the raw IPs to pod names, and the NOO dashboard displays it as
"traffic-generator → backend-api, Drop Reason: NetworkPolicy."

### OVS Non-Core Drop Reasons

Open vSwitch registers its own **non-core drop reasons** in the kernel (available
in RHEL 9.2+). These are separate from the core `SKB_DROP_REASON_*` enum:

| Drop Origin | Kernel Reason | NOO Label |
|------------|---------------|-----------|
| OVN ACL (NetworkPolicy) | OVS non-core (`OVS_DROP_LAST_ACTION`) | NetworkPolicy |
| nftables/iptables rule | `SKB_DROP_REASON_NETFILTER_DROP` | NetworkPolicy or Firewall |
| Conntrack table full | `SKB_DROP_REASON_NETFILTER_DROP` (in `nf_conntrack_in`) | CT_TABLE_FULL |
| Conntrack invalid | `SKB_DROP_REASON_NETFILTER_DROP` or similar | CT_INVALID |

NOO disambiguates between these by combining the drop reason code with the
kernel function name where the drop occurred.

---

## How the Demo Script Works

### Break Script (`scenario1-netpol-break.sh`)

```
1. Pre-check: verify 3 demo-app pods are Running
   (if not, script exits — won't run on a broken cluster)

2. Deploy 3x traffic-generator pods
   (UBI9 image, sends curl every 2s to backend-api:5000)

3. Verify traffic works BEFORE blocking
   (3 requests, all HTTP 200)

4. Apply NetworkPolicy "block-traffic-generator":
   - podSelector: app=backend-api (applies TO backend-api)
   - Ingress rules ALLOW:
     * app=frontend (frontend can still reach backend-api)
     * test=hairpin (hairpin test pods for scenario 2)
     * app=backend-api (self-access for health checks)
   - traffic-generator is NOT in any allow rule → BLOCKED

5. Test connectivity:
   - traffic-generator → backend-api: HTTP 000 (BLOCKED)
   - backend-api self-check: HTTP 200 (ALLOWED)

Safety: trap cleanup_on_failure ERR
   If ANY step fails, the script automatically:
   - Deletes the NetworkPolicy
   - Deletes the traffic-generator deployment
   - Prints "Reverted. Cluster is clean."
```

### Fix Script (`scenario1-netpol-fix.sh`)

```
1. Delete NetworkPolicy "block-traffic-generator"
2. Delete deployment "traffic-generator"
3. Verify backend-api is accessible (3 requests, HTTP 200)
```

### What Makes This Safe

| Risk | Mitigation |
|------|-----------|
| Could it crash a node? | No — only creates pods and a NetworkPolicy |
| Could it break cluster services? | No — everything is in demo-app namespace only |
| Could it affect other namespaces? | No — NetworkPolicy only targets pods with `app=backend-api` in `demo-app` |
| What if the script crashes mid-way? | `trap cleanup_on_failure ERR` auto-reverts everything |
| What if I forget to run the fix? | `cleanup-all.sh` deletes all scenario resources |

---

## Real-World Context

NetworkPolicy misconfiguration is extremely common in production:

1. **New service deployed without updating policies** — a new microservice is
   added but the existing NetworkPolicy's ingress rules don't include it.
   Traffic from the new service is silently dropped.

2. **Label mismatch after refactoring** — pod labels change during a refactor,
   but the NetworkPolicy's podSelector still references the old labels.
   Traffic that used to work suddenly stops.

3. **Egress policy blocks DNS** — an egress NetworkPolicy forgets to allow
   port 53 (DNS). Pods can't resolve service names. Looks like "DNS is broken"
   but it's actually a NetworkPolicy blocking DNS queries.

4. **Default deny in a new namespace** — a security team applies a default-deny
   NetworkPolicy to all namespaces. Existing services break because no explicit
   allow rules were created.

In all these cases, the symptoms are identical: "connection timed out." Traditional
tools show the pod is running, endpoints exist, service is configured — but
traffic is silently dropped. Only NOO with eBPF reveals the drop reason.

---

## Summary

| Aspect | Traditional Tools | NOO + eBPF |
|--------|------------------|------------|
| Symptom seen | "connection timed out" | Drop reason: NetworkPolicy |
| What you suspect | Pod is down, wrong port, DNS issue | Exact policy blocking exact pod |
| Time to find | 15-30 min (manual YAML reading) | 5 seconds (filter by drops) |
| Risk of misdiagnosis | High — looks like many other issues | Zero — drop reason is definitive |
| Requires | Know it's a NetworkPolicy, read all policies | Just filter by drops in dashboard |
