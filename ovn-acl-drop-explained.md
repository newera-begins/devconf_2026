# How OVN ACL Drops Work in OVS — Deep Explanation

## The Question

When a NetworkPolicy blocks traffic, where does the drop happen in the OVS
OpenFlow pipeline? Since everything OVN does goes through OVS, the drop
MUST be visible in `ovs-ofctl dump-flows br-int`. But `grep tp_dst=5432`
finds nothing. Why?

---

## The Answer: Default-Deny, Not Explicit Port Block

OVN compiles NetworkPolicies into OpenFlow rules using a **default-deny
with explicit allows** pattern, NOT a per-port deny pattern.

```
How you'd EXPECT it to work (WRONG):
  "Drop packets to port 5432" → flow rule with tp_dst=5432, actions=drop

How it ACTUALLY works (CORRECT):
  "Allow port 53" → high-priority rule, actions=resubmit (pass)
  "Allow port 443" → high-priority rule, actions=resubmit (pass)
  "Allow port 5000" → high-priority rule, actions=resubmit (pass)
  "Drop EVERYTHING ELSE" → low-priority rule, actions=drop ← catches 5432
```

There is NO flow rule that mentions port 5432. The drop is the
**ABSENCE** of an allow rule, not the **PRESENCE** of a deny rule.

---

## The Real OVS Pipeline (from live cluster)

When backend-api (10.128.0.119) sends a packet to database (10.128.0.73)
on port 5432, the packet traverses these OpenFlow tables on br-int:

```
Packet: src=10.128.0.119 dst=10.128.0.73 dport=5432 TCP SYN

Table 0  (ingress):        classify packet → resubmit to table 8
Table 8  (pre-ACL):        conntrack lookup → resubmit
Table 28 (ingress ACL):    ingress policy check → PASS (no ingress block)
Table 44 (egress hairpin):  check for hairpin → resubmit
Table 48 (pre-egress ACL):  prepare for egress ACL → resubmit

Table 79 (egress ACL):     ← DROP HAPPENS HERE

  Priority 2001: match=tcp,nw_src=10.128.0.119,tp_dst=53
                 actions=resubmit(,80)   ← DNS allowed, skip to next table

  Priority 2001: match=tcp,nw_src=10.128.0.119,tp_dst=443
                 actions=resubmit(,80)   ← HTTPS allowed, skip to next table

  Priority 2001: match=tcp,nw_src=10.128.0.119,tp_dst=5000
                 actions=resubmit(,80)   ← Health allowed, skip to next table

  Priority 100:  match=ip,nw_src=10.128.0.119
                 actions=drop            ← DEFAULT DENY — catches port 5432
                 n_packets=2010          ← 2010 packets dropped here!

Packet to port 5432 → no allow rule matches → falls to priority 100 → DROP
```

### The actual flow rule from `ovs-ofctl dump-flows`:

```
table=79, priority=100, ip, reg14=0x2, metadata=0x1,
  dl_src=0a:58:0a:80:00:77, nw_src=10.128.0.119
  actions=drop
  n_packets=2010, n_bytes=302858
```

This single rule drops ALL egress traffic from backend-api that wasn't
explicitly allowed by higher-priority rules. Port 5432 traffic hits
this rule because there's no allow for port 5432.

---

## Why `grep tp_dst=5432` Finds Nothing

```bash
$ ovs-ofctl dump-flows br-int | grep "tp_dst=5432"
```

This returns the DNAT/load-balancer rules, NOT the drop rule. Because:

1. The DNAT rules (table 15) match `tp_dst=5432` and do NAT — these
   are for INCOMING traffic to the database Service.

2. The DROP rule (table 79) matches `nw_src=10.128.0.119` — the
   source IP of backend-api, NOT the destination port. It drops ALL
   egress from this pod regardless of port.

3. Port 5432 is not mentioned anywhere in the drop path because the
   drop is implicit — it's the default action for unmatched egress.

---

## Why Traditional Debugging Misses This

### Problem 1: Too many rules

```bash
$ ovs-ofctl dump-flows br-int | wc -l
5319
```

5319 OpenFlow rules. Finding the ONE rule in table 79 that drops
backend-api's traffic requires knowing:
- Which table handles egress ACLs (table 79)
- What the backend-api port register value is (reg14=0x2)
- What metadata value represents the logical switch (metadata=0x1)
- That you need to look for `nw_src` not `tp_dst`

This requires deep OVN pipeline knowledge that most engineers don't have.

### Problem 2: The drop rule looks generic

```
priority=100, ip, reg14=0x2, metadata=0x1, nw_src=10.128.0.119 actions=drop
```

This doesn't say "NetworkPolicy" or "port 5432 blocked." It's a raw
OpenFlow rule with register values and metadata. Without OVN pipeline
knowledge, you can't tell this is a NetworkPolicy default-deny.

### Problem 3: The allowed ports are in separate rules

The allow rules use `conjunction` actions (grouped matches) that are
even harder to read:

```
priority=2001, tcp, reg0=0x80/0x80, reg14=0xd2, metadata=0x3,
  nw_dst=10.128.0.119 actions=conjunction(3479905692,1/2)
```

This doesn't even mention port numbers in a human-readable way —
they're encoded in conjunction IDs.

---

## What eBPF / NOO Shows Instead

```
Source:      backend-api
Destination: database
Port:        5432
Drop Cause:  OVS_DROP_EXPLICIT
```

NOO translates the raw `OVS_DROP_EXPLICIT` kernel reason into:
"NetworkPolicy blocked this traffic." It tells you:
- WHO is affected (backend-api → database)
- WHICH port (5432)
- WHY (NetworkPolicy / OVS_DROP_EXPLICIT)
- WHEN (timestamps)

Without reading 5319 OpenFlow rules. Without knowing table 79.
Without understanding conjunction IDs or register values.

---

## Summary

| Question | OVS flows | NOO |
|----------|----------|-----|
| Is there a drop? | Hidden in 5319 rules at table 79 | "OVS_DROP_EXPLICIT" — visible immediately |
| Which port? | Not in the drop rule (drop matches src IP) | "port 5432" — shown in flow record |
| Why dropped? | "actions=drop" with register values | "NetworkPolicy" — human-readable |
| Which pod? | "nw_src=10.128.0.119" (raw IP) | "backend-api → database" (pod names) |
| Time to find | 30+ min (need OVN pipeline expertise) | 5 seconds (filter by drops) |
