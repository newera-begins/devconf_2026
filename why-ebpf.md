# Why eBPF? Why Not Just tcpdump?

## A Justification for Experienced Network Engineers

If you've been troubleshooting OCP networking for 10 years, you know tcpdump, ovs-ofctl,
conntrack, ip route, OVN traces, and sosreports inside out. You might be thinking:
"I can find most of these issues with the tools I already have."

**You're right — for simple cases.** A missing NetworkPolicy, a crashed pod, a wrong
service selector — any experienced engineer finds those in minutes.

**But here are the cases where you CAN'T.** The cases where you've spent hours or days,
where tcpdump shows you packets going in but never tells you why they don't come out,
where the RCA requires correlating data across multiple nodes, multiple layers, and
multiple time windows — simultaneously.

This document proves, with real-world scenarios, exactly where traditional tools hit
their limits and why kernel-level eBPF observability is not just nice-to-have — it's
the only way to get the answer.

---

## The Core Problem: tcpdump Shows PRESENCE, Not ABSENCE

This is the fundamental limitation. Let's be precise:

**tcpdump tells you:** "A packet with these headers arrived at this interface at this time."

**tcpdump CANNOT tell you:**
- "A packet was dropped" (absence on one interface ≠ proof of drop — maybe it went
  to a different interface, or was NATted, or was tunneled)
- "A packet was dropped because of [specific reason]"
- "This packet was dropped by OVN ACL rule #47 in the router pipeline at table 8"
- "DNS resolution for this specific FQDN failed with SERVFAIL at this time"

When you run tcpdump on interface A and see a SYN but no SYN-ACK, you know the
connection didn't complete. But you don't know:
- Was the SYN dropped before reaching the destination?
- Was the SYN delivered but the SYN-ACK dropped on the return path?
- Was the SYN delivered to the wrong destination (DNAT/load balancing)?
- Was the SYN-ACK sent but dropped by conntrack as INVALID?

**eBPF (kfree_skb tracepoint) tells you:** "This specific packet was dropped at
function X in the kernel, reason code Y, at timestamp Z." That's definitive.

---

## Complex Use Case 1: Intermittent Drops Under Load (Conntrack Table Exhaustion)

### The Scenario

A production cluster runs 200+ microservices. During peak traffic (10am-2pm daily),
random services experience intermittent connection timeouts. Not the same services
every time. Not the same nodes. Failures last 5-30 seconds, then self-heal.

### Why a 10-Year Engineer Can't Solve This with Traditional Tools

**Attempt 1: tcpdump**
```bash
# You SSH into a node where a failure was reported
$ oc debug node/worker-3 -- tcpdump -i any -n port 8080
```
Problem: The failure is intermittent and affects random services on random nodes.
By the time you SSH in and start tcpdump, the 5-30 second failure window has passed.
You'd need to run tcpdump on ALL nodes simultaneously, 24/7, which:
- Generates terabytes of pcap data per day
- Causes significant CPU overhead per node (copies every packet to userspace)
- Is simply not practical in production

**Attempt 2: conntrack -L**
```bash
# Check conntrack table
$ oc debug node/worker-3 -- conntrack -L | wc -l
262144

$ oc debug node/worker-3 -- conntrack -S
cpu=0    found=14523  invalid=847  insert=0  insert_failed=3214  drop=3214  early_drop=0
                                                                  ^^^^^^^^
                                                                  DROPS!
```
You found it! `insert_failed=3214` means the conntrack table is full and new
connections are being dropped. But:
- You had to already SUSPECT conntrack exhaustion (takes experience + intuition)
- You had to check EVERY node manually (the drops happen on different nodes)
- By the time you check, the counter has been incrementing for hours — you can't
  tell WHICH connections were dropped, WHEN they were dropped, or WHO was affected
- `conntrack -S` gives you a counter. It doesn't tell you: "At 10:47:23, the
  connection from pod orders-api in namespace prod to pod inventory-db was dropped
  because the conntrack table was full."

**Attempt 3: OVN traces**
```bash
$ ovn-trace --summary ...
```
OVN trace simulates a packet through the logical pipeline. It tells you "if this
packet were sent, here's what would happen." But:
- It doesn't tell you what DID happen in the past
- Conntrack drops happen OUTSIDE the OVN pipeline (in the kernel's netfilter layer)
- OVN trace would show the packet passing all ACLs successfully — because the
  conntrack drop happens after the OVN pipeline, at the kernel conntrack layer

### What eBPF/NOO Shows

```
┌──────────────────────────────────────────────────────────────────────────────────────────────┐
│  Network Traffic  [Show drops: ON]  [Time: 10:47:00 - 10:47:30]                              │
│                                                                                              │
│  ┌──────────────┬───────────────┬──────────────────┬────────┬───────┬───────────────────────┐│
│  │ Source        │ Destination   │ Node             │ Proto  │ Drops │ Drop Reason           ││
│  ├──────────────┼───────────────┼──────────────────┼────────┼───────┼───────────────────────┤│
│  │ orders-api   │ inventory-db  │ worker-3 ★       │ TCP    │ 142   │ CT_TABLE_FULL ★       ││
│  │ cart-svc     │ redis-cache   │ worker-3 ★       │ TCP    │ 98    │ CT_TABLE_FULL ★       ││
│  │ auth-svc     │ user-db       │ worker-3 ★       │ TCP    │ 67    │ CT_TABLE_FULL ★       ││
│  │ payment-api  │ stripe-gw     │ worker-3 ★       │ TCP    │ 34    │ CT_TABLE_FULL ★       ││
│  │ search-svc   │ elastic       │ worker-5 ★       │ TCP    │ 23    │ CT_TABLE_FULL ★       ││
│  └──────────────┴───────────────┴──────────────────┴────────┴───────┴───────────────────────┘│
│                                                                                              │
│  Pattern: worker-3 has 341 drops, worker-5 has 23 drops. All CT_TABLE_FULL.                  │
│  Peak time: 10:47:12 - 10:47:28 (16 seconds)                                                │
│  Affected: 5 different service pairs, all on worker-3                                        │
│                                                                                              │
│  ROOT CAUSE: Conntrack table exhaustion on worker-3 during peak load.                        │
│  FIX: Increase nf_conntrack_max on the affected nodes.                                       │
└──────────────────────────────────────────────────────────────────────────────────────────────┘
```

**What NOO gave you that tcpdump/conntrack couldn't:**
- Exact time window of drops (10:47:12 - 10:47:28)
- Exact pods affected (orders-api, cart-svc, auth-svc, payment-api, search-svc)
- Exact nodes with the problem (worker-3 primarily, worker-5 starting)
- Exact reason (CT_TABLE_FULL, not a guess)
- Historical data (you can look at this AFTER the incident, not just during)
- No SSH required, no pcap files, no manual correlation

---

## Complex Use Case 2: Asymmetric Routing Causes Spurious TCP Resets

### The Scenario

A pod running on node A sends traffic to a Service. The Service's backing pods are on
nodes B and C. Traffic going OUT from node A takes path X, but the return traffic takes
path Y (asymmetric routing due to ECMP or OVN gateway misconfiguration). The return
packet arrives at node A's conntrack table, but conntrack doesn't have a matching entry
(because it was tracking via path X), so it sends a TCP RST.

Result: Random "connection reset by peer" errors that affect ~5% of requests.

### Why Traditional Tools Fail

**tcpdump on node A:**
```bash
14:22:01 IP 10.128.2.15.45678 > 10.96.100.50.8080: Flags [S]
14:22:01 IP 10.96.100.50.8080 > 10.128.2.15.45678: Flags [S.ACK]     ← SYN-ACK arrives
14:22:01 IP 10.128.2.15.45678 > 10.96.100.50.8080: Flags [.]          ← ACK
14:22:01 IP 10.128.2.15.45678 > 10.96.100.50.8080: Flags [P.]         ← Data sent
14:22:01 IP 10.96.100.50.8080 > 10.128.2.15.45678: Flags [R.]         ← RST!!! WHY???
```

tcpdump shows you the RST arrived. But WHY? The connection looked fine!
- Was the RST sent by the application?
- Was the RST injected by a middlebox?
- Was the RST generated by conntrack because the return path was different?

You'd need to:
1. tcpdump on ALL nodes in the path simultaneously
2. Correlate timestamps across captures (nanosecond precision needed)
3. Compare the conntrack state on each node at the exact moment of the RST
4. Check if the return packet arrived on a different interface than expected
5. Verify the conntrack zone configuration on each OVN gateway

This takes **hours** even for an experienced engineer, and requires reproducing
the issue while captures are running.

**conntrack on node A:**
```bash
$ conntrack -E
# Event monitor shows entries appearing and being destroyed
# But it doesn't show WHY an entry was marked INVALID
# And it doesn't correlate with the specific pod/service
```

### What eBPF/NOO Shows

```
┌──────────────────────────────────────────────────────────────────────────────────────────────┐
│  Network Traffic  [Show drops: ON]  [Filter: DstPort=8080]                                   │
│                                                                                              │
│  ┌──────────────┬───────────────┬──────────────────┬────────┬───────┬───────────────────────┐│
│  │ Source        │ Destination   │ Node Path        │ Proto  │ Drops │ Drop Reason           ││
│  ├──────────────┼───────────────┼──────────────────┼────────┼───────┼───────────────────────┤│
│  │ my-app       │ backend-svc   │ A → B (forward)  │ TCP    │ 0     │ (none)                ││
│  │ backend-svc  │ my-app        │ B → A (return) ★ │ TCP    │ 47    │ CT_INVALID ★          ││
│  │ my-app       │ backend-svc   │ A → C (forward)  │ TCP    │ 0     │ (none)                ││
│  │ backend-svc  │ my-app        │ C → A (return)   │ TCP    │ 0     │ (none)                ││
│  └──────────────┴───────────────┴──────────────────┴────────┴───────┴───────────────────────┘│
│                                                                                              │
│  Pattern: Forward path A→B works. Return path B→A drops with CT_INVALID.                    │
│  Forward path A→C works AND return path C→A works.                                          │
│  ONLY the return from node B has drops.                                                      │
│                                                                                              │
│  ROOT CAUSE: Asymmetric routing for return traffic from node B.                              │
│  Return packets arrive at node A via a different path than the forward path,                │
│  causing conntrack to not find a matching entry → marks as INVALID → drops.                  │
│  FIX: Check OVN gateway configuration on node B or ECMP routing tables.                     │
└──────────────────────────────────────────────────────────────────────────────────────────────┘
```

Without eBPF, finding "only the return path from node B has conntrack drops" would take
correlating tcpdumps across 3 nodes with nanosecond-precision timestamps. With NOO, it's
one dashboard filter.

---

## Complex Use Case 3: Hairpin NAT Failure with Geneve Encapsulation

### The Scenario

Pod A on node 1 accesses a Service (ClusterIP). The Service's only backing pod (Pod B)
happens to be on the same node (node 1). OVN needs to "hairpin" the traffic — DNAT the
packet, send it through the Geneve tunnel to the router, then back to the same node.

Under certain conditions (kernel version + OVN version + specific conntrack state),
the hairpin path fails: the return packet is dropped because the conntrack entry
was created with the original source IP, but after DNAT+SNAT, the return packet has
a different tuple. Conntrack marks it INVALID.

This affects ~1% of connections and only when source and destination are on the same node.

### Why Traditional Tools Fail

**tcpdump on the veth interface:**
```bash
$ tcpdump -i <pod-veth> -n
14:30:01 IP 10.128.2.15.45678 > 172.30.100.50.8080: Flags [S]
# ... nothing else. The SYN goes into the OVN pipeline and never comes back.
```
Where did it go? tcpdump on the veth sees the packet enter but can't follow it through:
veth → br-int → OVN logical switch → OVN logical router → DNAT → SNAT → back to br-int

**tcpdump on br-int:**
```bash
$ tcpdump -i br-int -n
# Shows HUNDREDS of packets per second from ALL pods on this node
# You can't isolate the specific flow you care about
# And even if you filter by port, you see:
14:30:01 IP 10.128.2.15.45678 > 172.30.100.50.8080: Flags [S]
14:30:01 IP 10.128.2.15.45678 > 10.128.2.22.8080: Flags [S]    ← After DNAT
# The DNAT happened! But where did the SYN-ACK go?
```

**ovs-appctl ofproto/trace:**
```bash
$ ovs-appctl ofproto/trace br-int in_port=X,...
# Traces the packet through OpenFlow tables
# Shows DNAT happening, packet being sent to local port
# But this is a SIMULATION — it tells you what SHOULD happen
# Not what DID happen
# And it can't simulate conntrack state race conditions
```

**ovn-trace:**
```bash
$ ovn-trace --summary switch1 'inport=="pod-a" && ...'
# Same problem: simulates the logical pipeline
# Shows the packet SHOULD be forwarded
# But the actual drop happens in the kernel conntrack layer
# AFTER the OVN pipeline has made its forwarding decision
```

### What eBPF/NOO Shows

```
┌──────────────────────────────────────────────────────────────────────────────────────────────┐
│  Network Traffic  [Show drops: ON]  [Filter: same-node traffic]                              │
│                                                                                              │
│  ┌──────────────┬───────────────┬──────────────────┬────────┬───────┬───────────────────────┐│
│  │ Source        │ Destination   │ Node             │ Proto  │ Drops │ Drop Reason           ││
│  ├──────────────┼───────────────┼──────────────────┼────────┼───────┼───────────────────────┤│
│  │ pod-a        │ pod-b         │ worker-1 (SAME)  │ TCP    │ 12    │ CT_INVALID ★          ││
│  │ pod-a        │ pod-c         │ w1→w2 (DIFF)     │ TCP    │ 0     │ (none)                ││
│  │ pod-d        │ pod-b         │ w2→w1 (DIFF)     │ TCP    │ 0     │ (none)                ││
│  │ pod-e        │ pod-f         │ worker-2 (SAME)  │ TCP    │ 8     │ CT_INVALID ★          ││
│  └──────────────┴───────────────┴──────────────────┴────────┴───────┴───────────────────────┘│
│                                                                                              │
│  Pattern:                                                                                    │
│  ★ Drops ONLY when source and destination are on the SAME node                              │
│  ★ Cross-node traffic has ZERO drops                                                        │
│  ★ Drop reason: CT_INVALID (conntrack tuple mismatch after NAT)                             │
│                                                                                              │
│  ROOT CAUSE: Hairpin NAT conntrack race condition.                                           │
│  When a pod accesses a Service whose backing pod is on the same node,                       │
│  the DNAT+SNAT path creates a conntrack entry mismatch on the return path.                  │
│  FIX: Apply the OVN hairpin fix, or update to OCP version with the fix.                     │
└──────────────────────────────────────────────────────────────────────────────────────────────┘
```

The pattern "drops only on same-node traffic, always CT_INVALID" is IMPOSSIBLE to find
with tcpdump. You'd need to:
1. Know that source and destination are on the same node (requires checking pod placement)
2. Capture on br-int and follow the packet through DNAT/SNAT
3. Inspect conntrack entries at the exact moment of the drop
4. Correlate across multiple pod pairs to see the same-node pattern
5. Realize this is a known OVN hairpin bug

With NOO, the pattern jumps off the screen: filter by drops, sort by node — all
CT_INVALID drops are same-node. Done.

---

## Complex Use Case 4: DNS Cache Poisoning Causes Cascading Failures

### The Scenario

One CoreDNS pod (out of 2) has a corrupted cache entry. It returns the wrong IP for
`payment-gateway.prod.svc.cluster.local`. Half of all DNS queries hit this pod (round-robin
load balancing on the kube-dns Service), so ~50% of connections to the payment gateway
go to the wrong IP and fail.

But here's the twist: the wrong IP IS a valid pod IP — it belongs to a completely
different service. So the TCP connection succeeds! But the application gets unexpected
responses (wrong service) and throws application-level errors that look like bugs in
the payment gateway code.

### Why Traditional Tools Fail

**Application logs:**
```
ERROR: Unexpected response from payment-gateway: {"error": "unknown endpoint /api/charge"}
ERROR: PaymentGateway returned 404 for POST /api/charge
```
Looks like a payment gateway bug! Developers spend 2 days debugging the payment service.

**tcpdump:**
```bash
$ tcpdump -i any -n host 10.128.3.45 port 8080
# Shows traffic going to 10.128.3.45:8080 — but IS that the payment gateway?
# You'd need to check: oc get pod -o wide | grep 10.128.3.45
# And discover it's actually a completely different service
# But you'd have to already SUSPECT DNS is the problem
```

**nslookup:**
```bash
$ nslookup payment-gateway.prod.svc.cluster.local
# Returns the correct IP 50% of the time (when query hits the good CoreDNS pod)
# Returns the wrong IP 50% of the time (when query hits the bad CoreDNS pod)
# But nslookup doesn't show you WHICH CoreDNS pod answered!
```

### What eBPF/NOO DNS Tracking Shows

```
┌──────────────────────────────────────────────────────────────────────────────────────────────┐
│  Network Traffic — DNS                                            Namespace: prod            │
│                                                                                              │
│  ┌───────────────┬─────────────────────────────────────────┬──────────┬──────────┬──────────┐│
│  │ Source Pod     │ DNS Query                               │ Response │ DNS Resp │ Answered ││
│  │               │                                         │ IP       │ Code     │ By       ││
│  ├───────────────┼─────────────────────────────────────────┼──────────┼──────────┼──────────┤│
│  │ orders-api    │ payment-gateway.prod.svc.cluster.local  │ 10.128.4 │ NoError  │ dns-abc  ││
│  │ orders-api    │ payment-gateway.prod.svc.cluster.local  │ 10.128.3 │ NoError  │ dns-xyz★ ││
│  │ cart-svc      │ payment-gateway.prod.svc.cluster.local  │ 10.128.4 │ NoError  │ dns-abc  ││
│  │ checkout-svc  │ payment-gateway.prod.svc.cluster.local  │ 10.128.3 │ NoError  │ dns-xyz★ ││
│  │ cart-svc      │ payment-gateway.prod.svc.cluster.local  │ 10.128.3 │ NoError  │ dns-xyz★ ││
│  └───────────────┴─────────────────────────────────────────┴──────────┴──────────┴──────────┘│
│                                                                                              │
│  Pattern:                                                                                    │
│  ★ dns-abc always returns 10.128.4.x (CORRECT payment gateway IP)                          │
│  ★ dns-xyz always returns 10.128.3.x (WRONG IP — belongs to user-profile-svc!)             │
│  ★ 50% of queries hit dns-xyz → 50% of payment traffic goes to wrong service               │
│                                                                                              │
│  ROOT CAUSE: CoreDNS pod dns-xyz has a corrupted cache entry.                                │
│  FIX: Restart dns-xyz pod, or flush its cache.                                               │
└──────────────────────────────────────────────────────────────────────────────────────────────┘
```

Without eBPF DNS tracking, you'd need to:
1. Suspect DNS is the problem (not obvious — the connection SUCCEEDS, just to the wrong IP)
2. Run nslookup dozens of times and track which CoreDNS pod answered each query
3. Compare the response IPs to actual pod IPs to find the mismatch
4. Identify which CoreDNS pod is returning wrong answers

With NOO DNS tracking, you filter by DNS query name and immediately see two different
response IPs. The wrong one points to the corrupted CoreDNS pod.

---

## Summary: When tcpdump Fails and eBPF Succeeds

| Scenario | tcpdump's Limitation | eBPF's Advantage |
|----------|---------------------|-------------------|
| Conntrack exhaustion | Counter only (conntrack -S). No per-flow data. Need to check every node manually. | Per-flow drop data with exact pod names, timestamps, and affected node. Cluster-wide view. |
| Asymmetric routing RSTs | Shows RST arrived but can't explain why. Need synchronized captures on 3+ nodes. | Shows return path drops with CT_INVALID reason on specific node-to-node path. |
| Hairpin NAT failure | Can't follow packet through OVN pipeline. OVN trace shows it SHOULD work. | Shows drops only on same-node traffic with CT_INVALID. Pattern is immediately visible. |
| DNS cache corruption | nslookup returns correct IP 50% of the time. No visibility into which DNS pod answered. | DNS tracking shows different response IPs per CoreDNS pod. Wrong answers are immediately visible. |
| ANY intermittent issue | Must be capturing at the right time, on the right node, on the right interface. | Always-on. Historical data available. Filter and search AFTER the incident. |

### The Fundamental Difference

**tcpdump:** You must already know WHERE the problem is to capture the right traffic.
You're looking for evidence at a crime scene you haven't identified yet.

**eBPF/NOO:** Every packet, every drop, every DNS query is recorded cluster-wide, always.
You search the evidence AFTER you know something went wrong.

**tcpdump tells you WHAT happened at one point.**
**eBPF tells you WHY it happened across the entire cluster.**

That's why eBPF isn't optional for modern Kubernetes troubleshooting. It's not about
replacing tcpdump — it's about having visibility that tcpdump architecturally cannot provide.
