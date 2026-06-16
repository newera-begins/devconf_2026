# Q&A Preparation — Expected Audience Questions

Organized from simple → complex. Each question includes the likely context
(which slide/demo triggers it), a concise answer, and supporting details.

---

## BASIC QUESTIONS (from slides 1-7)

### Q1: What does NOO stand for?

**Answer:** Network Observability Operator. It's an optional operator for
OpenShift that provides network traffic visibility using eBPF. Available from
OperatorHub. Upstream project is at github.com/netobserv.

---

### Q2: Is NOO available on upstream Kubernetes or only OpenShift?

**Answer:** The upstream project (netobserv) works on vanilla Kubernetes. The
Red Hat-supported version is the Network Observability Operator available through
OperatorHub on OpenShift. The core components — eBPF agent, flowlogs-pipeline —
are open source and can run on any Kubernetes cluster with a Linux kernel that
supports eBPF (4.18+).

---

### Q3: Does eBPF require a specific kernel version?

**Answer:** The basic TC hook works on kernel 4.18+. The `kfree_skb_reason()`
function with drop reason codes was introduced in kernel 5.17 (commit `c504e5c2f964`).
Additional drop reasons were added throughout the 5.18 and 5.19 cycles, expanding
coverage from ~18 call sites to 70+ drop reason codes. OCP 4.14+ ships RHEL 9
kernels that include backported `kfree_skb_reason()` support. OVS non-core
drop reasons are available in RHEL 9.2+ (OCP 4.14+). Note: the NetworkEvents
feature in NOO 1.9+ requires OCP 4.19+ kernels — it breaks compatibility with
older kernels.

Source: [Red Hat Developer — How to retrieve packet drop reasons](https://developers.redhat.com/articles/2023/07/19/how-retrieve-packet-drop-reasons-linux-kernel)

---

### Q4: What's the performance overhead of running eBPF agents on every node?

**Answer:** Based on upstream benchmarks (NOO 1.6 on a 6-node AWS cluster with
`m6i.xlarge` nodes), all eBPF agent pods combined used ~0.08 CPU total and ~340MB
memory at a stable 3-3.5K flows/sec with `sampling: 1`. That's the total across
ALL agent pods, not per-pod. Version 1.8 improved user-space CPU by 40-57% per
node compared to 1.7 (tested on both 25-node and 250-node clusters). At
`sampling: 1` (every packet), CPU scales with traffic volume and connection
cardinality — a 250-node cluster with 14K pods will use significantly more than
0.08 CPU total. In production with `sampling: 50-100`, overhead drops because
fewer flow records are exported to FLP/Loki. The eBPF program runs in kernel
space and extracts ~100 bytes of metadata per packet — it does NOT copy the
full packet payload like tcpdump.

**Important:** The eBPF kernel-space program ALWAYS processes every packet
regardless of sampling. Sampling only controls what gets exported to userspace.
So kernel-space CPU is constant; only userspace CPU drops with higher sampling.

Source: [NetObserv blog — Performance fine-tuning](https://netobserv.io/posts/performance-fine-tuning-a-deep-dive-in-ebpf-agent-metrics/)
| [NetObserv 1.8 — Performance improvements](https://netobserv.io/posts/performance-improvements-in-1-8/)

---

### Q5: Does it work with all CNI plugins or only OVN-Kubernetes?

**Answer:** The core features (PacketDrop, DNSTracking, FlowRTT) work with any
CNI plugin because they attach to kernel-level hooks (TC, kfree_skb) that are
independent of the CNI. The `NetworkEvents` feature specifically requires
OVN-Kubernetes with the Observability feature enabled, because it correlates flows
with OVN ACL evaluations. PacketTranslation works with any CNI that uses kernel
conntrack for NAT.

---

### Q6: Is Loki required? Can I use a different storage backend?

**Answer:** Loki is the recommended and supported storage for flow logs. However,
NOO also supports:
- **Direct metrics mode** — flows exported as Prometheus metrics without Loki
  (less detail, but no Loki dependency)
- **Kafka mode** — flows sent to Kafka topic, then consumed by FLP
  (for high-scale environments)
- **OpenTelemetry export** — flows exported in OTLP format to any OpenTelemetry
  collector (Jaeger, Grafana Tempo, etc.)

For a demo or small cluster, Loki is simplest. For production at scale, Kafka mode
is recommended.

---

## INTERMEDIATE QUESTIONS (from slides 8-14, demos)

### Q7: What exactly is a "flow record"? How much data per packet?

**Answer:** A flow record is ~100 bytes of metadata extracted from each packet:
- Source/destination IP and port
- Protocol, TCP flags, direction, bytes, packets
- Interface name, timestamp (nanosecond precision)
- Drop reason (if PacketDrop enabled)
- DNS query name and response code (if DNSTracking enabled)
- RTT in nanoseconds (if FlowRTT enabled)

It does NOT include the packet payload. This is why eBPF is lightweight — tcpdump
copies the full ~1500-byte packet to userspace, eBPF extracts only the metadata
it needs directly in kernel space.

---

### Q8: What does "enrichment" mean in the FLP pipeline?

**Answer:** The raw eBPF data contains only IP addresses and port numbers. The
flowlogs-pipeline (FLP) queries the Kubernetes API to translate:
- `10.128.2.15` → `frontend` pod in namespace `demo-app` on node `worker-1`
- Port `5432` → `postgresql` (from IANA port names)

Without enrichment, you'd see the same raw IPs that tcpdump shows. Enrichment
is what makes NOO practical — you search by pod name, not by IP address.

---

### Q9: How real-time is the data? Can I see drops as they happen?

**Answer:** The eBPF agent batches flow records in a kernel hash map and exports
them every `cacheActiveTimeout` seconds. In NOO 1.11, the default was changed from
5s to 15s (to reduce CPU by ~40%). For demos, set this to `1s` for near-real-time
visibility. In production, 15s is fine — you don't need sub-second latency for
troubleshooting, you need the data to BE THERE when you look.

Source: [NOO 1.11 release notes](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/network_observability/network-observability-operator-release-notes)

---

### Q10: You showed CT_TABLE_FULL and CT_INVALID. What other drop reasons exist?

**Answer:** The kernel's `kfree_skb` tracepoint reports 70+ drop reason codes
(introduced in kernel 5.17, expanded since). Common ones in OCP:

| Drop Reason | What It Means |
|------------|---------------|
| `CT_TABLE_FULL` | Conntrack table exhaustion — no room for new connections |
| `CT_INVALID` | Packet doesn't match any conntrack entry (expired, NAT mismatch) |
| `NETFILTER_DROP` | Dropped by nftables/iptables rule |
| `OVS_DROP` | Dropped by Open vSwitch (OVN ACL = NetworkPolicy) |
| `NO_ROUTE` | No route to destination |
| `PKT_TOO_BIG` | Exceeds interface MTU |
| `TCP_INVALID_SEQUENCE` | TCP sequence number out of window |
| `IP_INHDR` | Corrupted IP header |

The NOO console translates the raw kernel codes into human-readable labels.

---

### Q11: In scenario 1, why doesn't conntrack -S tell you WHICH pods are affected?

**Answer:** `conntrack -S` is a per-CPU counter built into the kernel's netfilter
subsystem. It increments `insert_failed` every time a new entry can't be added.
But it's a cumulative counter — it doesn't store per-flow or per-pod information.
The kernel simply increments the number and drops the packet. There's no log,
no record, no per-connection attribution.

eBPF is different because the `kfree_skb` tracepoint fires PER PACKET that's
dropped. Each firing includes the packet headers (src/dst IP, port). FLP then
enriches those IPs to pod names. So you get per-pod, per-flow, per-second drop
data — not just a counter.

---

### Q12: In scenario 2 (hairpin), why does OVN trace say "forward" when the packet drops?

**Answer:** OVN trace simulates the **logical pipeline** — ACLs, routing decisions,
NAT targets. The logical pipeline IS correct: it says "DNAT this packet and send
it to the backend pod." And it does.

The drop happens on the **return path**, in the **kernel conntrack layer**, AFTER
the OVN pipeline has already processed the return packet. The reverse-NAT changes
the packet's tuple, and conntrack doesn't recognize the modified tuple → marks it
CT_INVALID → drops it.

OVN trace simulates the forward path. It cannot simulate:
- Kernel conntrack state tables
- The timing of reverse-NAT relative to conntrack evaluation
- The CT_INVALID marking on the return path

This is why eBPF is necessary — `kfree_skb` fires at the actual moment of the drop,
inside the kernel, and reports the real reason.

---

### Q13: In scenario 3 (idle timeout), why does tcpdump show a RST from the database?

**Answer:** It doesn't — the RST is generated by the **kernel**, not by PostgreSQL.
When the conntrack entry expires and the app sends data on the stale connection,
the kernel:
1. Receives the data packet (PSH,ACK)
2. Checks conntrack — no matching entry
3. Marks as CT_INVALID
4. Drops the data packet
5. Sends a RST back to the sender (as a courtesy, to reset the TCP state)

tcpdump on the wire sees the RST appearing to come FROM the database IP. But the
database never sent it — the kernel generated it because of the CT_INVALID state.
tcpdump can't distinguish "RST sent by the application" from "RST generated by
the kernel due to conntrack mismatch."

---

## ADVANCED QUESTIONS (from slides 18-21, architecture)

### Q14: Can I write custom eBPF scripts and load them into NOO?

**Answer:** No. The NOO eBPF agent has a fixed, pre-compiled eBPF program
embedded in the container image at build time. There is no plugin system, no
runtime loading, and no way to inject custom packet processing logic.

The `EbpfManager` feature only changes WHO loads the NOO's own programs (bpfman
vs the agent) — it does not enable custom code.

Two extension points exist:
1. **Custom GRPC collector** — build your own Go program that consumes the flow
   data the agent exports (upstream provides a library + example)
2. **Custom OpenTelemetry field mapping** — customize the export format

For actual custom eBPF programs, use bpftrace, bcc, or Cilium Hubble.

Source: [netobserv-ebpf-agent README](https://github.com/netobserv/netobserv-ebpf-agent)

---

### Q15: What's the difference between sampling:1 and sampling:50 in practice?

**Answer:**
- `sampling: 1` — the agent exports metadata for EVERY packet. Useful for
  demos AND active production troubleshooting. When investigating a live
  issue, switch to sampling:1 temporarily to capture every drop and DNS
  query. After the problem is resolved, increase back to 50-100 to reduce
  overhead. Don't think of sampling:1 as "demo only" — it's a real
  troubleshooting tool. CPU overhead scales with cluster size and traffic:

  **Verified benchmarks at sampling:1 (PAM 2024 paper + upstream blogs):**

  | Cluster | Instance Type | Flows/Min | CPU Total | Memory Total | Per-Node CPU | Per-Node Mem |
  |---------|--------------|-----------|-----------|-------------|-------------|-------------|
  | 6 nodes (fine-tuning blog) | m6i.xlarge | ~180K | ~0.08 cores | ~340 MB | ~0.01 cores | ~57 MB |
  | 25 nodes (node-density-heavy) | m6i.4xlarge | 520K | 3.32 cores | 2.71 GB | ~0.13 cores | ~108 MB |
  | 120 nodes (cluster-density) | m6i.4xlarge | 1.92M | 10.14 cores | 11.13 GB | ~0.08 cores | ~93 MB |
  | 250 nodes (NOO 1.8 blog) | not stated | not stated | 40-57% LESS than NOO 1.7 (same sampling:1) | +11% mem vs 1.7 | N/A | N/A |

  **Overhead as % of total cluster capacity (at sampling:1):**
  - 25-node cluster: 0.83% CPU, 0.16% memory
  - 120-node cluster: 0.52% CPU, 0.14% memory
  - Overhead DECREASES as a percentage on larger clusters

  Sources: [PAM 2024 paper](https://pam2024.cs.northwestern.edu/pdfs/paper-75.pdf)
  | [NetObserv fine-tuning blog](https://netobserv.io/posts/performance-fine-tuning-a-deep-dive-in-ebpf-agent-metrics/)
  | [NetObserv 1.8 improvements](https://netobserv.io/posts/performance-improvements-in-1-8/)
- `sampling: 50` — the agent exports 1 in 50 packets. Good baseline for
  always-on production monitoring. Patterns are still visible: if 1000
  packets are dropped with CT_TABLE_FULL, you see ~20 drops in the
  dashboard — enough to identify the pattern and affected pods. CPU
  overhead is significantly lower than sampling:1.

The eBPF kernel-space program ALWAYS sees every packet (it's in the
kernel path). Sampling only controls what gets exported to FLP/Loki.

**Critical nuance — PacketDrop vs DNSTracking at high sampling:**
- **PacketDrop events are NOT subject to sampling.** The `kfree_skb`
  tracepoint fires independently of the TC hook. Drop events are captured
  even at sampling:50.
- **DNSTracking IS subject to sampling.** DNS inspection happens at the TC
  hook. At sampling:50, ~98% of DNS packets (port 53) are skipped. Since
  DNS is typically 1-2 UDP packets per transaction, individual failed
  queries CAN be missed. To get full DNS visibility at higher sampling
  values, use an eBPF flow filter restricted to port 53 with sampling:1.

**Pipeline capacity at sampling:1 is NOT impossible in production.**
With the Kafka deployment model (recommended for production) and properly
sized Loki (tuned `perStreamRateLimit`, `perStreamRateLimitBurst`, and
stream limits), the pipeline CAN handle sampling:1 at scale. The Service
deployment model in NOO 1.11 also scales better than Direct. It's a
resource/cost tradeoff, not a technical impossibility.

Source: [NetObserv — Performance fine-tuning](https://netobserv.io/posts/performance-fine-tuning-a-deep-dive-in-ebpf-agent-metrics/)

---

### Q15a: At sampling:50, can DNS failures escape detection?

**Answer:** Yes. DNSTracking inspects packets at the TC hook, which IS
subject to sampling. DNS queries are typically 1-2 small UDP packets per
transaction — at sampling:50, approximately 98% of DNS packets are
skipped. A single SERVFAIL response on port 53 has only a 1-in-50 chance
of being captured.

This is different from PacketDrop, which uses the `kfree_skb` tracepoint
that fires independently of TC hook sampling. Drop events are captured
regardless of the sampling value.

**Solutions for full DNS visibility in production:**
1. **eBPF flow filter** — restrict sampling:1 to DNS ports only:
   ```yaml
   spec:
     agent:
       ebpf:
         sampling: 50
         flowFilter:
           enable: true
           ports: 53,5353
           sampling: 1
   ```
   This captures 100% of DNS traffic while sampling other traffic at 1:50.
2. **Temporarily set sampling:1** during active DNS troubleshooting.
3. **Use Prometheus DNS metrics** — NOO exports aggregated DNS metrics to
   Prometheus that are computed before sampling, giving full visibility
   even at high sampling values.

Source: [How DNS name tracking enhances network observability](https://developers.redhat.com/articles/2026/04/09/how-dns-name-tracking-enhances-network-observability)

---

### Q16: How does NOO handle multi-tenant clusters? Can team A see team B's traffic?

**Answer:** NOO 1.11 introduced `FlowCollectorSlice` — a new API that supports
hierarchical governance. Project administrators can independently manage sampling
and subnet labeling for their specific namespaces. This provides tenant isolation:
team A's flows are only visible to team A.

Additionally, the OCP console's Network Traffic view respects RBAC. Users can only
see flows for namespaces they have access to. Cluster admins see all flows.

---

### Q17: What happens to flow data when Loki is down?

**Answer:** The eBPF agents and FLP continue running. Flow records are buffered
temporarily. If Loki is down for an extended period, old buffered records are
dropped (FLP has finite memory). When Loki comes back, new flows start storing
again but the gap period is lost.

For production, consider:
- Running Loki in HA mode (3+ replicas)
- Using Kafka as an intermediate buffer (`deploymentModel: Kafka`)
- Setting up Prometheus metrics as a fallback (always-on, no Loki dependency)

---

### Q18: Can NOO detect encrypted traffic (TLS/mTLS)?

**Answer:** NOO cannot inspect encrypted payload content — eBPF sees packet
headers, not decrypted data. However:
- `TLSTracking` detects TLS handshakes and identifies which flows use TLS
- `IPSec` tracks IPsec-encrypted node-to-node traffic
- Flow metadata (src/dst IP, port, bytes, timing) is still visible even for
  encrypted traffic — you can see WHO is talking to WHOM and HOW MUCH
- DNS queries (DNSTracking) happen before TLS, so domain names are captured

For mTLS inspection, you'd need a service mesh sidecar that terminates TLS
and re-encrypts — NOO sees the traffic between the sidecar and the pod.

---

### Q19: How does PacketDrop work at the kernel level?

**Answer:** When the kernel decides to drop a packet, it calls `kfree_skb()`
to free the socket buffer. Starting from kernel 5.17, this function writes a
`reason` enum to the skb before freeing it. The NOO eBPF agent attaches a
program to the `kfree_skb` tracepoint. When the tracepoint fires, the eBPF
program reads:
- The packet headers from the skb (src/dst IP, port, protocol)
- The drop reason enum from the skb
- The kernel function name where the drop occurred
- A nanosecond timestamp

This is the ONLY place in the kernel that records WHY a packet was dropped.
Neither tcpdump, conntrack, OVN trace, nor any OpenFlow tool has access to
this information. It's exclusively available through the eBPF kfree_skb
tracepoint.

---

### Q20: What's the difference between NOO and Cilium Hubble?

**Answer:** Both use eBPF for network observability, but they differ:

| Aspect | NOO | Cilium Hubble |
|--------|-----|---------------|
| CNI dependency | Works with any CNI | Requires Cilium CNI |
| OCP support | Red Hat supported, OperatorHub | Community, no Red Hat support |
| Drop reasons | kfree_skb tracepoint (kernel-level) | Cilium datapath-level |
| DNS tracking | Yes (port 53 inspection) | Yes |
| NetworkPolicy correlation | Yes (NetworkEvents + OVN) | Yes (Cilium policies) |
| Integration | OCP Console native plugin | Hubble UI (separate) |
| Storage | Loki + Prometheus | Hubble Relay + Grafana |

If you're running OCP with OVN-Kubernetes, NOO is the supported choice.
If you're running Cilium as your CNI, Hubble is the natural choice.
They solve similar problems with different approaches.

---

### Q21: Can NOO help with network performance tuning, not just troubleshooting?

**Answer:** Yes:
- **FlowRTT** shows TCP latency per connection — identify slow paths
- **Topology view** reveals communication patterns — find unexpected traffic
- **Bytes/packets per flow** — identify bandwidth hogs
- **DNS latency tracking** — find slow DNS resolution
- **Prometheus metrics** — set up alerts for latency thresholds

NOO isn't just for "something is broken" — it's also for "something is slow"
and "I want to understand my cluster's traffic patterns."

---

### Q22: What's the maximum cluster size NOO supports?

**Answer:** NOO 1.11 changed the default deployment model from `Direct` to
`Service`. The three options:
- **Service model** (NEW DEFAULT in NOO 1.11) — FLP runs as a scalable
  Kubernetes Service with TLS enabled by default. Default is 3 FLP pods.
  Recommended for most clusters. Scales better than Direct because FLP
  instances don't duplicate cached cluster metadata.
- **Direct model** — FLP runs as a DaemonSet (one per node). Only
  recommended for small clusters below ~15 nodes. Less memory efficient
  on larger clusters. Uses localhost (unencrypted but host-local only).
- **Kafka model** — FLP reads from Kafka. Best for 100+ nodes or
  high-throughput/bursty environments. Most resilient option.

The eBPF agent always runs as a DaemonSet (one per node) regardless of
deployment model. Scaling concerns are primarily about FLP processing
and Loki storage, not the eBPF agent itself.

---

## CURVEBALL QUESTIONS (hard to predict)

### Q23: Is there a CLI tool to query NOO data without the web console?

**Answer:** You can query Loki directly using LogQL via the Loki API or `logcli`.
NOO stores flows as Loki log entries with labels like `SrcK8S_Name`,
`DstK8S_Namespace`, `PktDropReason`. You can query these programmatically.

Prometheus metrics are also available — you can use `oc` or `curl` to query
the Prometheus API for flow-based metrics.

There's no dedicated NOO CLI tool, but the data is accessible through standard
Loki/Prometheus APIs.

---

### Q24: Can I use NOO to detect network-based attacks (DDoS, port scanning)?

**Answer:** NOO provides the data that could detect anomalies:
- Sudden spike in connection count from a single source
- Flows to unusual ports (port scanning pattern)
- Massive byte counts from unexpected sources (DDoS)
- DNS queries to suspicious domains

However, NOO is an observability tool, not a security tool. It doesn't have
built-in attack detection rules. You could build detection on top of the
Prometheus metrics (alert on unusual patterns) or export flows to a SIEM.

For dedicated network security, look at Kubernetes NetworkPolicies (prevention)
or tools like Falco (runtime detection).

---

### Q25: Does eBPF add latency to packet processing?

**Answer:** The eBPF program runs synchronously in the packet processing path
at the TC hook — so technically, yes, it adds processing time per packet.
Upstream benchmarks on 40Gbps links show the overhead is minimal and does not
measurably impact application throughput at production sampling rates. The eBPF
verifier ensures the program has bounded execution time (no loops, no unbounded
memory access). The kernel rejects any program that could slow down the packet
path.

Source: [PAM 2024 paper — Designing a Lightweight Network Observability Agent](https://pam2024.cs.northwestern.edu/pdfs/paper-75.pdf)
