# Conntrack Table Exhaustion — Deep Concept Explanation

## What This Document Covers

This explains exactly what happens in Demo Scenario 1 (The Invisible Conntrack Storm) —
how the Linux kernel's connection tracking table works, what happens when it fills up,
why every traditional tool gives you zero answers, and how eBPF is the only way to
identify the affected pods and time window.

---

## What is Conntrack?

### Connection Tracking in the Linux Kernel

Every Linux node running OVN-Kubernetes has a kernel subsystem called **conntrack**
(connection tracking). It's part of the **netfilter** framework — the same framework
that powers iptables/nftables.

Conntrack's job is to **remember every network connection** passing through the node.
For every TCP connection, UDP flow, or ICMP exchange, conntrack creates an entry that
tracks:

```
Entry format:
  protocol  src_ip  src_port  dst_ip  dst_port  state  timeout

Example:
  tcp  src=10.128.2.15  sport=45678  dst=10.128.3.22  dport=5000  ESTABLISHED  timeout=120s
```

### Why Conntrack Exists

Conntrack is required for:

1. **Stateful firewalling (NetworkPolicies):**
   When you create a NetworkPolicy that allows ingress on port 5000, OVN-K translates
   it to an OVN ACL. The ACL uses conntrack to track the connection state. The first
   packet (SYN) is evaluated against the ACL rules. If allowed, conntrack creates an
   entry with state NEW → ESTABLISHED. Subsequent packets in the same connection match
   the conntrack entry and are fast-tracked through without re-evaluating every ACL rule.

2. **NAT (DNAT/SNAT for Services):**
   When a pod accesses a ClusterIP Service, the kernel DNATs the packet to the backing
   pod's IP. Conntrack remembers this NAT mapping so that return traffic can be
   reverse-NAT'd correctly.

3. **Connection-level accounting:**
   Conntrack entries are used by OVN to track which connections are active, which are
   timing out, and which are invalid.

### The Conntrack Table

All conntrack entries are stored in a hash table in kernel memory. The table has a
**maximum size** controlled by the sysctl:

```bash
$ sysctl net.netfilter.nf_conntrack_max
net.netfilter.nf_conntrack_max = 1048576    # default: ~1 million entries
```

And you can see the current usage:

```bash
$ sysctl net.netfilter.nf_conntrack_count
net.netfilter.nf_conntrack_count = 23456    # currently tracking 23K connections
```

---

## What Happens When the Table Fills Up

### The Normal Case

Under normal conditions, the table has plenty of room:

```
Conntrack table: 23,456 / 1,048,576 entries used (2.2%)

New connection arrives:
  SYN from 10.128.2.15:45678 → 10.128.3.22:5000
  → conntrack creates new entry
  → entry added to hash table (now 23,457 entries)
  → packet forwarded to destination
  → SYN-ACK comes back
  → connection ESTABLISHED
```

### The Exhaustion Case

When the table is full (all slots used), new connections are **silently dropped**:

```
Conntrack table: 512 / 512 entries used (100%)   ← FULL

New connection arrives:
  SYN from 10.128.2.15:45678 → 10.128.3.22:5000
  → conntrack tries to create new entry
  → hash table is FULL → insert FAILS
  → kernel increments insert_failed counter
  → kernel DROPS the SYN packet ← SILENT DROP
  → no SYN-ACK is ever sent
  → source pod sees: "connection timed out"
```

The critical detail: **the kernel does not send any error back to the source pod.**
It simply drops the SYN packet silently. The source pod's TCP stack retransmits
the SYN (1s, 2s, 4s, 8s... exponential backoff) and eventually gives up with
"connection timed out."

### Why It's Intermittent

The table isn't permanently full. Conntrack entries have timeouts:
- ESTABLISHED TCP: 432000 seconds (5 days) by default — lowered in constrained environments
- SYN_SENT: 120 seconds
- TIME_WAIT: 120 seconds
- UDP: 30-180 seconds

As old connections time out, slots free up. New connections can briefly succeed.
Then the freed slots fill up again. This creates the **intermittent pattern**:

```
14:47:00 - Table 510/512 → 2 free slots → some connections work
14:47:05 - Table 512/512 → FULL → new connections drop
14:47:10 - 3 old entries expire → 509/512 → some connections work
14:47:12 - 3 new connections fill the slots → 512/512 → drops again
```

This is why the failure looks random — "it works sometimes, fails sometimes,
no pattern." But there IS a pattern: it correlates with the conntrack table
occupancy on a specific node.

---

## Why Traditional Tools Fail

### Tool 1: tcpdump

```bash
$ tcpdump -i any -n port 5000
14:47:01 IP 10.128.2.15.45678 > 10.128.3.22.5000: Flags [S]
14:47:02 IP 10.128.2.15.45678 > 10.128.3.22.5000: Flags [S]   ← retransmit
14:47:04 IP 10.128.2.15.45678 > 10.128.3.22.5000: Flags [S]   ← retransmit
```

**What you see:** SYN packets going out. No SYN-ACK.
**What you think:** "The destination pod is not responding. Is it crashed? Overloaded?"
**What actually happened:** The SYN was DROPPED by the kernel's conntrack before
it ever reached the destination pod. tcpdump sees the SYN because it captures at
the interface level — the packet arrives at the interface, then enters the kernel
networking stack, hits conntrack, and gets dropped. tcpdump sees the arrival but
not the internal drop.

**Why tcpdump fails here:**
- tcpdump captures packets at the interface boundary (AF_PACKET socket)
- The conntrack drop happens INSIDE the kernel, after the packet leaves the
  tcpdump capture point
- tcpdump sees "packet sent, no reply" — which looks like the DESTINATION is broken
- It can't distinguish between "destination didn't respond" and "kernel dropped
  the packet before it reached the destination"

### Tool 2: conntrack -S

```bash
$ conntrack -S
cpu=0  found=14523  invalid=847  insert=0  insert_failed=3214  drop=3214
```

**What you see:** `insert_failed=3214, drop=3214` — there ARE drops happening.
**What you DON'T see:**
- WHICH pods are affected? (could be any of the 200+ pods on this node)
- WHEN exactly did the drops happen? (the counter is cumulative since boot)
- WHICH connections were dropped? (no per-connection attribution)
- Is it still happening NOW or was it a one-time burst 3 hours ago?

`conntrack -S` is a **cumulative counter**. It tells you drops happened at
some point. It doesn't tell you who, when, or what was affected. In a cluster
with 200 pods on a node, you can't map "3214 drops" to specific service pairs.

### Tool 3: conntrack -L

```bash
$ conntrack -L | wc -l
512

$ conntrack -L | head -5
tcp  6  117  ESTABLISHED  src=10.128.2.15  dst=10.128.3.22  sport=45678  dport=5000  ...
tcp  6  23   SYN_SENT     src=10.128.4.33  dst=10.128.2.15  sport=33210  dport=8080  ...
tcp  6  86   TIME_WAIT    src=10.128.1.44  dst=172.30.0.10  sport=52111  dport=443   ...
...
```

**What you see:** 512 entries. The table IS full. But:
- These are the SURVIVING connections — the successful ones.
- The DROPPED connections are NOT in this table (they were never inserted).
- You can see the table is full, but you can't see WHICH new connections failed.

### Tool 4: OVN Trace

```bash
$ ovn-trace --summary <switch> 'inport=="pod-a" && ...'
output: ... ct_next ... output to "pod-b" ...
```

**What you see:** OVN says "forward this packet to pod-b."
**Why this is misleading:** The OVN logical pipeline IS correct. The ACLs allow
the traffic. The routing decision is right. The DNAT target is correct.

The drop happens AFTER the OVN pipeline, in the kernel's netfilter conntrack
layer. OVN trace only simulates the logical pipeline — it doesn't know about
the kernel conntrack table size or state. It says "forward" because, logically,
the packet SHOULD be forwarded. The kernel disagrees because its table is full.

### Tool 5: ovs-ofctl dump-flows / ovs-appctl ofproto/trace

Same problem as OVN trace. The OpenFlow rules say "output to port X." The
OpenFlow pipeline is correct. The drop is in the kernel conntrack subsystem,
which is downstream of the OpenFlow pipeline.

---

## What eBPF / NOO Shows — And Why Only It Can

### The kfree_skb Tracepoint

When a packet is dropped by the kernel, the kernel calls `kfree_skb()` to free
the packet buffer. The eBPF agent attaches a program to the `kfree_skb` tracepoint.

This tracepoint provides:
- **The packet headers** (src/dst IP, port, protocol)
- **The drop reason** (an enum from the kernel):
  - When the conntrack table is full, `nf_conntrack_in()` returns `NF_DROP`,
    which translates to `SKB_DROP_REASON_NETFILTER_DROP` in the kernel
  - NOO maps this to the human-readable label `CT_TABLE_FULL` in the dashboard
    by correlating the drop location (function `nf_conntrack_in`) with the reason
- **The kernel function** where the drop occurred (e.g., `nf_conntrack_in`)
- **Nanosecond timestamp**

### The FLP Enrichment

The raw eBPF data says: `src=10.128.2.15, dst=10.128.3.22, reason=NETFILTER_DROP`

FLP enriches this to:
```
Source:     traffic-flood-5c8b7a-k2m9x (namespace: demo-app, node: worker-3)
Dest:       backend-api-7b4d8f6c5d-k2m9x (namespace: demo-app, node: worker-3)
Drop:       CT_TABLE_FULL
Packets:    142
Time:       14:47:12 - 14:47:28
```

### The Dashboard View

```
┌───────────────┬────────────────┬──────────┬────────┬────────────┬────────────────┐
│ Source         │ Destination    │ Node     │ Proto  │ Drop Count │ Drop Reason    │
├───────────────┼────────────────┼──────────┼────────┼────────────┼────────────────┤
│ traffic-flood │ backend-api    │ worker-3 │ TCP    │ 142        │ CT_TABLE_FULL  │
│ frontend      │ backend-api    │ worker-3 │ TCP    │ 34         │ CT_TABLE_FULL  │
│ traffic-flood │ backend-api    │ worker-3 │ TCP    │ 98         │ CT_TABLE_FULL  │
└───────────────┴────────────────┴──────────┴────────┴────────────┴────────────────┘
```

**In ONE view, you get:**
- Which PODS are affected (traffic-flood, frontend → backend-api)
- Which NODE has the problem (worker-3)
- The exact DROP REASON (CT_TABLE_FULL)
- How many packets (142, 98, 34)
- The time window (from the flow timestamps)

**No other tool can give you this combination.** tcpdump shows packets, conntrack -S
shows a counter, OVN trace shows the logical pipeline. Only eBPF kfree_skb gives you
per-pod, per-flow, per-reason drop data with Kubernetes context.

---

## How the Demo Script Triggers This

### Step 1: Lower conntrack_max

```bash
$ oc debug node/$NODE -- chroot /host sysctl -w net.netfilter.nf_conntrack_max=512
```

This shrinks the table from ~1 million to 512 entries. On a busy node, 512 entries
fill up within seconds from normal cluster traffic (kube-proxy, DNS, node-to-node
communication).

### Step 2: Deploy flood pods

5 pods, each making 20 concurrent HTTP requests per cycle:

```yaml
replicas: 5
command: |
  while true; do
    for i in $(seq 1 20); do
      curl -s http://backend-api:5000/api/health &
    done
    wait
    sleep 0.5
  done
```

5 pods × 20 requests = 100 new connections every 0.5 seconds. Each connection
creates a conntrack entry. At 100 new entries per 0.5s, the 512-entry table
fills up almost immediately.

### Step 3: Observe

The traffic-generator script (already running) sends requests every 2 seconds.
When the table is full, these requests fail intermittently:

```
Request 1: HTTP 200 (lucky — conntrack had a free slot)
Request 2: HTTP 000 ★ FAILED (table full)
Request 3: HTTP 000 ★ FAILED (table full)
Request 4: HTTP 200 (an old entry expired, slot freed briefly)
Request 5: HTTP 000 ★ FAILED (table full again)
```

### Step 4: Run traditional-debug.sh

Show the audience: tcpdump → SYN no reply. conntrack -S → counter. OVN trace → ALLOW.
None of them identify the root cause.

### Step 5: Switch to NOO dashboard

Filter by namespace, show drops → CT_TABLE_FULL on worker-3. Answer in 5 seconds.

### Step 6: Fix

```bash
$ oc debug node/$NODE -- chroot /host sysctl -w net.netfilter.nf_conntrack_max=1048576
$ oc delete deployment traffic-flood -n demo-app
```

Drops stop immediately. Dashboard shows healthy flows again.

---

## Summary

| Aspect | What Happens |
|--------|-------------|
| Root cause | Conntrack table on a node is full — no room for new connections |
| Symptom | Intermittent "connection timed out" from random pods on that node |
| tcpdump | Shows SYN, no SYN-ACK — looks like destination is down |
| conntrack -S | Shows insert_failed counter — but which pods? when? |
| conntrack -L | Shows 512 entries (all successful) — dropped ones not in table |
| OVN trace | Says "forward" — pipeline is correct, drop is AFTER OVN |
| NOO/eBPF | Per-pod drops with reason CT_TABLE_FULL on exact node + time window |
| Fix | Increase nf_conntrack_max, reduce connection churn, tune timeouts |
