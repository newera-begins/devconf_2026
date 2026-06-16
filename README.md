# Who Dropped the Packet? Solving K8s Network Mysteries in Real-Time

**DevConf.CZ 2026 | June 19 | 30-Minute Talk by Neeraj Bhatt**

Live troubleshooting demo using eBPF and the OpenShift Network Observability Operator (NOO).

---

## Table of Contents

1. [What This Repo Contains](#what-this-repo-contains)
2. [Do I Need to Write eBPF Scripts? NO — Here's Why](#do-i-need-to-write-ebpf-scripts)
3. [How eBPF Works Under the Hood](#how-ebpf-works-under-the-hood)
4. [The FlowCollector CR — Your eBPF Configuration](#the-flowcollector-cr)
5. [Step-by-Step: Deploy and Verify the Operator](#step-by-step-deploy-and-verify)
6. [Step-by-Step: Deploy the Demo Application](#step-by-step-deploy-the-demo-application)
7. [Scenario 1: Silent NetworkPolicy Drops — With Full Output](#scenario-1-silent-networkpolicy-drops)
8. [Scenario 2: Hairpin NAT / Same-Node Failure — With Full Output](#scenario-2-hairpin-nat--same-node-failure)
9. [tcpdump vs NOO — Real Command Comparison](#tcpdump-vs-noo-comparison)
10. [Troubleshooting](#troubleshooting)

---

## What This Repo Contains

```
devconf/
  README.md                         ← You are here (FULL implementation guide with sample outputs)
  devconf-slides.pptx               ← PowerPoint slides (upload to Google Slides: File → Import)
  talk                              ← Original talk abstract
  demo-guide.md                     ← Setup timeline and operator installation steps
  why-ebpf.md                      ← Justification: why tcpdump fails, 4 complex real-world cases
  preparation-checklist.md          ← Day-by-day checklist leading up to talk day
  demo-app/
    01-namespace.yaml               ← Namespace for the demo application
    02-database.yaml                ← PostgreSQL database (stores book data)
    03-backend-api.yaml             ← Python HTTP API (queries database, serves books)
    04-frontend.yaml                ← Nginx frontend (HTML UI + reverse proxy to backend)
  demo-scripts/
    traffic-generator.sh            ← Sends continuous traffic between all tiers
    scenario1-netpol-break.sh    ← Trigger NetworkPolicy drops (safe, no sysctl)
    scenario1-netpol-fix.sh      ← Remove blocking NetworkPolicy
    scenario2-egress-break.sh      ← Trigger hairpin NAT / same-node failure
    scenario2-egress-fix.sh        ← Clean up hairpin scenario
    scenario2-traditional-debug.sh ← Run tcpdump/conntrack/ovn-trace to show tools failing
    cleanup-all.sh                  ← Reset everything to clean state
    setup-storage-and-loki.sh       ← Full setup: LVM Storage + MinIO + Loki (bare metal)
    reset-loki-storage.sh           ← Wipe Loki data and recreate fresh PVs
    check-prerequisites.sh          ← Verify cluster, operators, demo-app ready for demo
    traditional-debug.sh            ← Run tcpdump/conntrack/ovn-trace to show tools failing
```

---

## Do I Need to Write eBPF Scripts?

**NO. You do not write a single line of eBPF code.**

This is the #1 confusion people have. Let me explain exactly what happens and who does what:

### What Actually Runs eBPF Code

The **Network Observability Operator** ships with **pre-compiled eBPF programs** baked into
its container image. When you create a FlowCollector custom resource (a YAML file), the
operator:

1. Deploys a DaemonSet called `netobserv-ebpf-agent` — one pod on every node
2. Each pod loads the pre-compiled eBPF bytecode into the kernel
3. The eBPF program attaches to the TC (Traffic Control) hook on every network interface
4. From that point on, the eBPF program sees every packet entering/leaving every interface

**You never see, edit, compile, or load the eBPF program.** You just write a YAML file
(the FlowCollector CR) that says "enable PacketDrop tracking, enable DNS tracking."
The operator does the rest.

### Analogy (OCP Terms)

Think about NetworkPolicies:
- You write a **NetworkPolicy YAML** (high-level intent: "block ingress to backend-api")
- OVN-Kubernetes translates that into **OVN ACLs** (low-level kernel rules)
- You never write OVN ACLs by hand

Same thing here:
- You write a **FlowCollector YAML** (high-level intent: "track packet drops and DNS queries")
- The NOO operator translates that into **eBPF programs loaded into the kernel**
- You never write eBPF programs by hand

### What You Configure vs. What the Operator Provides

| Layer | Who provides it | You touch it? |
|-------|----------------|---------------|
| eBPF program (C compiled to BPF bytecode) | Operator container image | Never |
| eBPF agent (Go binary, DaemonSet pod) | Operator deploys it | Never |
| FlowCollector CR (YAML) | **You create this** | **YES — this is your config** |
| flowlogs-pipeline (enrichment) | Operator deploys it | Never |
| Loki (storage) | Loki Operator deploys it | You set up storage (S3/etc) |
| OCP Console plugin (dashboard) | Operator registers it | Never |

---

## How eBPF Works Under the Hood

### What is eBPF?

**eBPF = Extended Berkeley Packet Filter.** It lets you run small, safe, sandboxed programs
inside the Linux kernel — without modifying the kernel, loading modules, or rebooting.

OCP Analogy:
> The Linux kernel is like a node. Normally you can't change how it processes packets.
> eBPF is like injecting a "sidecar" into the kernel itself — it watches every packet,
> every drop, every DNS query, without modifying or restarting anything.

### Where eBPF Attaches (Hook Points)

```
                    ┌──────────────────────────────────────┐
                    │          USER SPACE                    │
                    │  (your pods, apps, curl, etc.)        │
                    └──────────────┬───────────────────────┘
                                   │
                    ┌──────────────▼───────────────────────┐
                    │          KERNEL SPACE                  │
                    │                                       │
                    │  ┌─────────────────┐                  │
                    │  │  Socket Layer    │ ← eBPF can      │
                    │  │  (per-socket)    │   attach here    │
                    │  └────────┬────────┘                  │
                    │           │                            │
                    │  ┌────────▼────────┐                  │
                    │  │  TC (Traffic     │ ← NOO attaches   │
                    │  │  Control) hook   │   HERE ★         │
                    │  └────────┬────────┘                  │
                    │           │                            │
                    │  ┌────────▼────────┐                  │
                    │  │  XDP (eXpress    │ ← eBPF can      │
                    │  │  Data Path)      │   attach here    │
                    │  └────────┬────────┘                  │
                    │           │                            │
                    │  ┌────────▼────────┐                  │
                    │  │ kfree_skb       │ ← NOO attaches    │
                    │  │ tracepoint      │   HERE for drops ★│
                    │  └────────┬────────┘                  │
                    │           │                            │
                    └───────────▼──────────────────────────┘
                                │
                    ┌───────────▼──────────────────────────┐
                    │  NETWORK INTERFACE (NIC)              │
                    │  Physical or virtual (veth, geneve)   │
                    └──────────────────────────────────────┘
```

The NOO attaches eBPF programs at TWO places:
- **TC hook** — sees every packet entering/leaving every interface (captures flow metadata)
- **kfree_skb tracepoint** — fires when the kernel DROPS a packet (captures drop reason)

### What the eBPF Program Captures (Per Packet)

When a packet hits the TC hook, the eBPF program extracts:

```
┌─────────────────────────────────────────────────────────┐
│  FLOW RECORD (what eBPF captures for each packet)        │
│                                                          │
│  SrcAddr:      10.128.2.15      (source pod IP)          │
│  DstAddr:      10.128.3.22      (destination pod IP)     │
│  SrcPort:      45678            (ephemeral port)         │
│  DstPort:      5432             (PostgreSQL)             │
│  Proto:        TCP (6)                                   │
│  TCPFlags:     SYN              (new connection)         │
│  Direction:    Ingress                                   │
│  Bytes:        64                                        │
│  Packets:      1                                         │
│  Interface:    eth0                                      │
│  TimeStamp:    1718793600000    (nanosecond precision)    │
│                                                          │
│  If PacketDrop enabled:                                  │
│  PktDropBytes:    0             (0 = not dropped)        │
│  PktDropPackets:  0                                      │
│  PktDropReason:   0             (no drop)                │
│                                                          │
│  If DNSTracking enabled:                                 │
│  DnsFlagsResponseCode: NoError  (successful DNS)        │
│  DnsLatencyMs:         2        (2ms to resolve)        │
│  DnsId:                0x1A2B                            │
│                                                          │
│  If FlowRTT enabled:                                     │
│  TimeFlowRttNs:   1500000       (1.5ms RTT)             │
└─────────────────────────────────────────────────────────┘
```

This is ~100 bytes of metadata. NOT the full 1500-byte packet payload. That's why eBPF
is so lightweight — it only extracts what it needs.

### The Full Data Pipeline

```
  PACKET → [eBPF at TC hook] → extracts metadata → eBPF ring buffer
                                                         │
                         ┌───────────────────────────────┘
                         ▼
              eBPF Agent pod (userspace Go binary)
              reads from ring buffer every few seconds
                         │
                         ▼
              flowlogs-pipeline (FLP) pod
              ENRICHES raw IPs with K8s context:
                BEFORE:  src=10.128.2.15, dst=10.128.3.22, port=5432
                AFTER:   src=frontend (demo-app, worker-1)
                         dst=database (demo-app, worker-2)
                         port=5432 (PostgreSQL)
                         drop_reason=NetworkPolicy    ← THIS is the gold
                         dns_response=SERVFAIL        ← THIS is the gold
                         │
                         ▼
              Loki (stores enriched flow logs)
                         │
                         ▼
              OCP Console → Observe → Network Traffic
              (you see flows as tables, topology, charts)
```

### How PacketDrop Detection Works (kfree_skb)

When you enable `PacketDrop` in the FlowCollector, the operator attaches a SECOND eBPF
program to the `kfree_skb` kernel tracepoint. This tracepoint fires every time the kernel
frees (drops) a packet buffer. The eBPF program reads the drop reason from the kernel:

| Kernel Drop Reason | NOO Shows As | What Happened |
|-------------------|-------------|---------------|
| OVS non-core drop reason (`OVS_DROP_LAST_ACTION`) | **NetworkPolicy** | OVN ACL rejected the packet. OVS registers its own non-core drop reasons (RHEL 9.2+). |
| `SKB_DROP_REASON_NETFILTER_DROP` | **CT_TABLE_FULL** or **NetworkPolicy** | nf_conntrack_in() table full, or nftables/iptables rule drop. NOO disambiguates by kernel function name. |
| `SKB_DROP_REASON_TCP_INVALID_SEQUENCE` | **TCP Invalid** | TCP sequence number out of acceptable window (RFC 793) |
| `SKB_DROP_REASON_IP_INNOROUTES` | **No Route** | No route to destination in routing table |
| `SKB_DROP_REASON_PKT_TOO_BIG` | **Packet Too Big** | Exceeds interface MTU |
| `SKB_DROP_REASON_IP_INHDR` | **IP Header** | Corrupted or invalid IP header |

### How DNSTracking Works

When you enable `DNSTracking`, the eBPF program at the TC hook inspects every packet on
UDP/TCP port 53. If it's a DNS packet, it parses:

- The **query name** (e.g., `database.demo-app.svc.cluster.local`)
- The **response code** (NoError, SERVFAIL, NXDOMAIN, REFUSED)
- The **latency** (time between query and response)

In production, this helps diagnose DNS-related failures — you see queries going out with
no response or SERVFAIL response codes, with the exact pod and query name.

### The eBPF Safety Model

"Running code inside the kernel sounds dangerous." It's safe because of the **eBPF verifier**:

1. Before ANY eBPF program loads, the kernel verifier checks it
2. Verifier ensures: no crashes, no infinite loops, no out-of-bounds memory access
3. If rejected → program doesn't load, kernel is unaffected

OCP analogy: Like a `ValidatingWebhookConfiguration` rejects bad pod specs BEFORE
they're created, the eBPF verifier rejects bad programs BEFORE they're loaded.

---

## The FlowCollector CR

This is the ONLY YAML you write to enable eBPF observability:

```yaml
apiVersion: flows.netobserv.io/v1beta2
kind: FlowCollector
metadata:
  name: cluster
  namespace: netobserv
spec:
  namespace: netobserv
  deploymentModel: Direct       # Default changed to Service in NOO 1.11
                               # Using Direct here for small demo cluster (<15 nodes)
  agent:
    type: eBPF
    ebpf:
      sampling: 1              # 1 = capture EVERY packet (demo + active troubleshooting)
                               # Production baseline: 50-100 (switch to 1 during incidents)
      privileged: true         # Required for PacketDrop (needs CAP_SYS_ADMIN
                               # to read kfree_skb tracepoint)
      features:
        - PacketDrop           # Attaches to kfree_skb → reports WHY drops happen
        - DNSTracking          # Inspects port 53 → parses DNS query/response
        - FlowRTT              # Measures TCP handshake RTT (SYN → SYN-ACK timing)
        - NetworkEvents        # Correlates flows with OVN NetworkPolicy events
  processor:
    logLevel: info
  loki:
    mode: LokiStack
    lokiStack:
      name: lokistack-network
      namespace: netobserv-loki
  consolePlugin:
    register: true
    portNaming:
      enable: true
```

### All eBPF Features Available in OCP 4.21 / 4.22

The FlowCollector CR `spec.agent.ebpf.features` field accepts the following values.
All are disabled by default. Enabling additional features may have performance impact.

| Feature | Status | Privileged | What It Does |
|---------|--------|-----------|-------------|
| **PacketDrop** | GA | YES | Attaches to `kfree_skb` kernel tracepoint. Reports exact drop reason (CT_TABLE_FULL, CT_INVALID, OVS_DROP, PKT_TOO_BIG, etc). **Used in both demo scenarios.** |
| **DNSTracking** | GA | No | Inspects UDP/TCP port 53 at TC hook. Parses DNS query name, response code (NoError, SERVFAIL, NXDOMAIN), and latency. Max 32 bytes of domain name. |
| **FlowRTT** | GA | No | Measures TCP round-trip time from SYN/SYN-ACK timing. Reported as `TimeFlowRttNs`. |
| **NetworkEvents** | GA | YES | Correlates flows with OVN-K network policy events. Shows which NetworkPolicy rule matched. Requires OVN-K with Observability. Note: NOO 1.9+ requires OCP 4.19+ kernels. |
| **PacketTranslation** | GA | No | Captures pre/post NAT source/dest IPs and ports. Useful for debugging DNAT/SNAT in Service load balancing. |
| **IPSec** | GA | No | Tracks flows between nodes encrypted with IPsec. |
| **TLSTracking** | GA | No | Tracks TLS usage in flows. |
| **UDNMapping** | GA | YES | Maps flows to User Defined Networks (UDN) for multi-network environments. Shows UDN labels in traffic table. Requires OVN-Kubernetes with Observability and privileged eBPF agent pods (kernel debug filesystem). |
| **EbpfManager** | Developer Preview | No | Delegates loading/unloading of NOO's pre-built eBPF programs to an external `bpfman` (formerly bpfd) operator. In clusters running multiple eBPF tools (NOO + Cilium + Falco), bpfman acts as a central manager to avoid conflicts. This is NOT for writing custom eBPF scripts — it only changes WHO loads the NOO's own programs. Requires eBPF Manager Operator (Technology Preview) to be installed. |

Source: [FlowCollector API reference (upstream)](https://github.com/netobserv/network-observability-operator/blob/main/docs/FlowCollector.md)
| [OCP 4.21 NOO docs](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/pdf/network_observability/OpenShift_Container_Platform-4.21-Network_Observability-en-US.pdf)

**For this demo, we use:** PacketDrop (critical — both scenarios depend on it), DNSTracking
(general observability), FlowRTT (latency visibility), and NetworkEvents (OVN correlation).

**PacketDrop is the most important feature for our talk.** Without it, the NOO can show
flow data (who talks to whom) but CANNOT show drops or drop reasons. The kfree_skb
tracepoint is what makes the operator fundamentally better than tcpdump.

After you apply this YAML, the operator does everything else automatically.

---

## Step-by-Step: Deploy and Verify the Operator

### Step 1: Verify Cluster

```bash
$ oc whoami
system:admin

$ oc get nodes
NAME                                         STATUS   ROLES                  AGE   VERSION
ip-10-0-137-62.us-east-2.compute.internal    Ready    control-plane,master   2h    v1.28.6+6216ea1
ip-10-0-153-198.us-east-2.compute.internal   Ready    worker                 2h    v1.28.6+6216ea1
ip-10-0-171-45.us-east-2.compute.internal    Ready    worker                 2h    v1.28.6+6216ea1
ip-10-0-192-88.us-east-2.compute.internal    Ready    worker                 2h    v1.28.6+6216ea1
```

### Step 2: Install the Operator (via OperatorHub or CLI)

See `demo-guide.md` for full install steps. After install:

```bash
$ oc get csv -n openshift-netobserv-operator
NAME                              DISPLAY                    VERSION   PHASE
netobserv-operator.v1.11.0       Network Observability       1.11.0    Succeeded
```

### Step 3: Create FlowCollector CR

```bash
$ oc apply -f - <<'EOF'
apiVersion: flows.netobserv.io/v1beta2
kind: FlowCollector
metadata:
  name: cluster
  namespace: netobserv
spec:
  namespace: netobserv
  deploymentModel: Direct       # Default is Service in NOO 1.11; Direct for small demo cluster
  agent:
    type: eBPF
    ebpf:
      sampling: 1
      privileged: true
      features:
        - PacketDrop
        - DNSTracking
        - FlowRTT
  processor:
    logLevel: info
  loki:
    mode: LokiStack
    lokiStack:
      name: lokistack-network
      namespace: netobserv-loki
  consolePlugin:
    register: true
    portNaming:
      enable: true
EOF
flowcollector.flows.netobserv.io/cluster created
```

### Step 4: Verify eBPF Agents Are Running

This is how you confirm eBPF is actually running in the kernel. One pod per node:

```bash
$ oc get daemonset -n netobserv
NAME                       DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE
netobserv-ebpf-agent       4         4         4       4            4
```

**Expected:** DESIRED = CURRENT = READY = number of nodes in your cluster.
If READY is less than DESIRED, the eBPF agent is failing to start on some nodes.

```bash
$ oc get pods -n netobserv -l app=netobserv-ebpf-agent -o wide
NAME                          READY   STATUS    RESTARTS   AGE   IP            NODE
netobserv-ebpf-agent-4k7nx   1/1     Running   0          5m    10.128.0.45   ip-10-0-137-62.us-east-2.compute.internal
netobserv-ebpf-agent-8m2pq   1/1     Running   0          5m    10.128.2.12   ip-10-0-153-198.us-east-2.compute.internal
netobserv-ebpf-agent-j9v3r   1/1     Running   0          5m    10.128.3.8    ip-10-0-171-45.us-east-2.compute.internal
netobserv-ebpf-agent-xc5wn   1/1     Running   0          5m    10.128.4.15   ip-10-0-192-88.us-east-2.compute.internal
```

### Step 5: Check eBPF Agent Logs — See It Attaching to Interfaces

This is where you can PROVE the eBPF program is loaded into the kernel:

```bash
$ oc logs -n netobserv -l app=netobserv-ebpf-agent --tail=30
time="2026-06-12T14:22:01Z" level=info msg="Starting eBPF agent"
time="2026-06-12T14:22:01Z" level=info msg="Loading eBPF program"
time="2026-06-12T14:22:01Z" level=info msg="eBPF program loaded successfully"
time="2026-06-12T14:22:01Z" level=info msg="Attaching TC hook" iface=eth0 direction=ingress
time="2026-06-12T14:22:01Z" level=info msg="Attaching TC hook" iface=eth0 direction=egress
time="2026-06-12T14:22:01Z" level=info msg="Attaching TC hook" iface=ovn-k8s-mp0 direction=ingress
time="2026-06-12T14:22:01Z" level=info msg="Attaching TC hook" iface=ovn-k8s-mp0 direction=egress
time="2026-06-12T14:22:01Z" level=info msg="Attaching TC hook" iface=genev_sys_6081 direction=ingress
time="2026-06-12T14:22:01Z" level=info msg="Attaching TC hook" iface=genev_sys_6081 direction=egress
time="2026-06-12T14:22:01Z" level=info msg="Attaching TC hook" iface=br-ex direction=ingress
time="2026-06-12T14:22:01Z" level=info msg="Attaching TC hook" iface=br-ex direction=egress
time="2026-06-12T14:22:02Z" level=info msg="Registering kfree_skb tracepoint for PacketDrop"
time="2026-06-12T14:22:02Z" level=info msg="PacketDrop tracking enabled"
time="2026-06-12T14:22:02Z" level=info msg="DNSTracking enabled on port 53"
time="2026-06-12T14:22:02Z" level=info msg="FlowRTT tracking enabled"
time="2026-06-12T14:22:02Z" level=info msg="eBPF agent ready, collecting flows"
time="2026-06-12T14:22:07Z" level=info msg="Exported 142 flows to FLP"
time="2026-06-12T14:22:12Z" level=info msg="Exported 98 flows to FLP"
```

**Key lines to look for:**
- `"Attaching TC hook"` — the eBPF program is now watching this interface
- `"Registering kfree_skb tracepoint"` — the drop-tracking eBPF program is loaded
- `"DNSTracking enabled"` — DNS packet inspection is active
- `"Exported N flows"` — flows are being captured and sent to the pipeline

### Step 6: Verify FLP (flowlogs-pipeline) Is Enriching Flows

```bash
$ oc get pods -n netobserv -l app=flowlogs-pipeline
NAME                                 READY   STATUS    RESTARTS   AGE
flowlogs-pipeline-74d8f6b5c4-8kxvz   1/1     Running   0          5m
flowlogs-pipeline-74d8f6b5c4-m2n9j   1/1     Running   0          5m
```

### Step 7: Verify Console Plugin

```bash
$ oc get consoleplugin netobserv-plugin
NAME               AGE
netobserv-plugin   5m
```

Now open **OCP Console → Observe → Network Traffic**. You should see flows.

---

## Step-by-Step: Deploy the Demo Application

### Deploy All Manifests

```bash
$ oc apply -f demo-app/
namespace/demo-app created
secret/database-credentials created
configmap/database-init created
deployment.apps/database created
service/database created
configmap/backend-api-code created
deployment.apps/backend-api created
service/backend-api created
configmap/frontend-config created
deployment.apps/frontend created
service/frontend created
route.route.openshift.io/frontend created
```

### Verify All Pods Are Running

```bash
$ oc get pods -n demo-app
NAME                           READY   STATUS    RESTARTS   AGE
backend-api-7b4d8f6c5d-k2m9x  1/1     Running   0          2m
database-5c8b7a9d3f-p4n7q      1/1     Running   0          2m
frontend-6d9e4f8a2b-r5t8w      1/1     Running   0          2m
```

**Expected:** All 3 pods in `Running` state, `READY 1/1`.
If a pod is not running, check logs: `oc logs -n demo-app deploy/<name>`

### Verify Services

```bash
$ oc get svc -n demo-app
NAME          TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)    AGE
backend-api   ClusterIP   172.30.45.123    <none>        5000/TCP   2m
database      ClusterIP   172.30.78.234    <none>        5432/TCP   2m
frontend      ClusterIP   172.30.12.56     <none>        8080/TCP   2m
```

### Test the Application

```bash
# Test health endpoint
$ oc exec -n demo-app deploy/frontend -- curl -s http://backend-api:5000/api/health
{"status": "ok", "hostname": "backend-api-7b4d8f6c5d-k2m9x"}

# Test books endpoint
$ oc exec -n demo-app deploy/frontend -- curl -s http://backend-api:5000/api/books
[
  {
    "id": 1,
    "title": "The Kubernetes Book",
    "author": "Nigel Poulton",
    "year": 2023,
    "description": "A comprehensive guide to Kubernetes for beginners and pros alike."
  },
  {
    "id": 2,
    "title": "Networking and Kubernetes",
    "author": "James Strong",
    "year": 2022,
    "description": "Deep dive into CNI, services, and network policies in K8s."
  },
  ...
]

# Test large payload (verifies app can serve big responses)
$ oc exec -n demo-app deploy/frontend -- curl -s -o /dev/null -w "HTTP %{http_code} | %{size_download} bytes | %{time_total}s\n" http://backend-api:5000/api/large
HTTP 200 | 52480 bytes | 0.234s

# Get frontend route URL
$ oc get route frontend -n demo-app -o jsonpath='{.spec.host}'
frontend-demo-app.apps.cluster-abc123.us-east-2.example.com
```

### Start Traffic Generator

```bash
$ bash demo-scripts/traffic-generator.sh &
=== Bookstore Traffic Generator ===
Sending requests every 2s to all tiers in namespace demo-app
Press Ctrl+C to stop

[14:30:01] frontend → backend-api /api/health : HTTP 200
[14:30:01] frontend → backend-api /api/books  : HTTP 200
[14:30:01] backend-api health check            : HTTP 200
---
[14:30:03] frontend → backend-api /api/health : HTTP 200
[14:30:03] frontend → backend-api /api/books  : HTTP 200
[14:30:03] backend-api health check            : HTTP 200
---
```

### Verify Flows in NOO Dashboard (Healthy Baseline)

Open **OCP Console → Observe → Network Traffic**, filter by **Namespace = demo-app**.

**What the NOO dashboard shows (healthy state):**

```
┌─────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│  Network Traffic                                                                 Namespace: demo-app    │
│                                                                                                         │
│  ┌──────────────┬───────────────┬──────────────┬───────────────┬────────┬───────┬───────┬──────────────┐ │
│  │ Source        │ Destination   │ Src Namespace │ Dst Namespace │ Proto  │ Port  │ Bytes │ Drops        │ │
│  ├──────────────┼───────────────┼──────────────┼───────────────┼────────┼───────┼───────┼──────────────┤ │
│  │ frontend     │ backend-api   │ demo-app     │ demo-app      │ TCP    │ 5000  │ 12.4K │ 0            │ │
│  │ backend-api  │ database      │ demo-app     │ demo-app      │ TCP    │ 5432  │ 8.2K  │ 0            │ │
│  │ frontend     │ backend-api   │ demo-app     │ demo-app      │ TCP    │ 5000  │ 3.1K  │ 0            │ │
│  │ <external>   │ frontend      │              │ demo-app      │ TCP    │ 8080  │ 1.5K  │ 0            │ │
│  └──────────────┴───────────────┴──────────────┴───────────────┴────────┴───────┴───────┴──────────────┘ │
│                                                                                                         │
│  Total Flows: 4          Drops: 0          DNS Errors: 0          Avg RTT: 1.2ms                        │
└─────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

**Take a screenshot of this healthy state — you'll show it in the talk as "before."**

---

## Scenario 1: Silent NetworkPolicy Drops

### The Story

NetworkPolicy misconfiguration is one of the most common causes of silent packet
drops in production. The pods are Running, endpoints exist, services are healthy —
but traffic is blocked by an OVN ACL that no standard tool reveals. tcpdump shows
SYN with no SYN-ACK, and you think the pod is down.

> **Note:** Real-world conntrack exhaustion (CT_TABLE_FULL) is covered in detail
> in `conntrack-exhaustion-explained.md`. This demo uses NetworkPolicy drops
> because they are safer to reproduce on compact clusters without modifying
> node-level sysctls.

### Why Traditional Tools CANNOT Find This RCA

- **tcpdump:** Shows SYN packets going out but no SYN-ACK. Looks like the pod is down — but it's Running.
- **oc get pods/endpoints:** Everything looks healthy. Pod is Running, Ready 1/1, endpoints exist.
- **oc logs:** Application logs show nothing because the traffic never reaches the app.
- With 50+ NetworkPolicies in a production namespace, finding the one that blocks traffic is manual work.

### BREAK IT

```bash
$ bash demo-scripts/scenario1-netpol-break.sh

========================================================
  SCENARIO 1: The Silent NetworkPolicy Drop
  Traffic blocked by policy — invisible to tcpdump
========================================================

Pre-check: verifying demo-app is healthy...
  ✓ 3 pods running

Step 1: Deploying traffic-generator pods...
Step 2: Verifying traffic works BEFORE blocking...
  Request 1: HTTP 200
  Request 2: HTTP 200
  Request 3: HTTP 200

Step 3: Applying NetworkPolicy to BLOCK traffic-generator...
  NetworkPolicy applied. traffic-generator is now blocked.

Step 4: Testing connectivity AFTER blocking...

  === traffic-generator → backend-api (SHOULD FAIL) ===
    Request 1: HTTP 000 ★ BLOCKED
    Request 2: HTTP 000 ★ BLOCKED
    Request 3: HTTP 000 ★ BLOCKED
    Request 4: HTTP 000 ★ BLOCKED
    Request 5: HTTP 000 ★ BLOCKED

  === backend-api self-check (SHOULD WORK) ===
    Request 1: HTTP 200
    Request 2: HTTP 200
    Request 3: HTTP 200

  RESULTS:
  traffic-generator blocked: 5 / 5
  backend-api self-check:    working
```

### What NOO Shows (the answer — in seconds)

Open **OCP Console → Observe → Network Traffic → Show drops**

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│  Network Traffic  [Show drops: ON]                       Namespace: demo-app     │
│                                                                                  │
│  ┌────────────────────┬────────────────┬───────┬────────────┬──────────────────┐ │
│  │ Source              │ Destination    │ Proto │ Drop Count │ Drop Reason      │ │
│  ├────────────────────┼────────────────┼───────┼────────────┼──────────────────┤ │
│  │ traffic-generator  │ backend-api    │ TCP   │ 47         │ NetworkPolicy    │ │
│  │ traffic-generator  │ backend-api    │ TCP   │ 38         │ NetworkPolicy    │ │
│  │ traffic-generator  │ backend-api    │ TCP   │ 29         │ NetworkPolicy    │ │
│  └────────────────────┴────────────────┴───────┴────────────┴──────────────────┘ │
│                                                                                  │
│  ★ Pod is Running, endpoints exist — everything LOOKS fine.                     │
│  ★ tcpdump shows SYN with no response — you'd think pod is dead.               │
│  ★ NOO tells you: "dropped by NetworkPolicy" with exact pod names.             │
│  ★ Fix: remove the NetworkPolicy → drops stop immediately.                     │
└──────────────────────────────────────────────────────────────────────────────────┘
```

### FIX IT

```bash
$ bash demo-scripts/scenario1-netpol-fix.sh

========================================================
  SCENARIO 1: FIX
  Removing NetworkPolicy and traffic-generator pods...
========================================================

Step 1: Removing NetworkPolicy...
  → Removed block-traffic-generator NetworkPolicy

Step 2: Removing traffic-generator deployment...
  → Removed traffic-generator deployment

Step 3: Verifying normal connectivity...
  Request 1: HTTP 200
  Request 2: HTTP 200
  Request 3: HTTP 200

Scenario 1 cleaned up. Check NOO dashboard: drops should stop.
```

---

## Scenario 2: Hairpin NAT / Same-Node Failure

### The Story

This is the most complex OVN edge case. Pod A accesses a Service, and the backing Pod B
is on the **same node**. OVN must "hairpin" the traffic: DNAT → tunnel → router → back
to the same node. A restrictive NetworkPolicy causes a conntrack tuple mismatch on the
return path. Same-node traffic fails. Cross-node traffic works perfectly.

### Why Traditional Tools CANNOT Find This RCA

- **OVN trace:** Says "output to localport" — the logical pipeline is CORRECT.
- **ovs-appctl ofproto/trace:** Simulates the OpenFlow pipeline. Says forward the packet.
  But it CANNOT simulate the conntrack state race condition on the return path.
- **tcpdump:** Shows SYN going in, maybe RST or nothing back. Can't tell you WHY.
- **conntrack -L:** Shows entries but you'd need to correlate entries across the
  DNAT+SNAT path at the exact moment of the drop. Practically impossible.
- The key insight: the drop happens on the RETURN path, in the conntrack layer,
  AFTER the OVN pipeline has already said "forward." No OVN-level tool can see it.

### BREAK IT

```bash
$ bash demo-scripts/scenario2-hairpin-break.sh

========================================================
  SCENARIO 2: The Hairpin NAT Trap
  Same-node traffic fails, cross-node works fine...
========================================================

Backend-api is on node: ip-10-0-153-198.us-east-2.compute.internal
Other worker node:      ip-10-0-171-45.us-east-2.compute.internal

Step 1: Deploying client pod on SAME node as backend-api...
Step 2: Deploying client pod on DIFFERENT node...
Step 3: Waiting for client pods to be ready...
  Both client pods ready.

Step 4: Verifying connectivity (before breaking)...
  Same-node (client-same-node → backend-api): HTTP 200
  Cross-node (client-diff-node → backend-api): HTTP 200

Step 5: Applying restrictive NetworkPolicy on backend-api...
  NetworkPolicy applied.

Step 6: Testing connectivity AFTER breaking...

  === Same-Node (client-same-node → backend-api) ===
    Request 1: HTTP 000 ★ FAILED
    Request 2: HTTP 000 ★ FAILED
    Request 3: HTTP 200
    Request 4: HTTP 000 ★ FAILED
    Request 5: HTTP 000 ★ FAILED

  === Cross-Node (client-diff-node → backend-api) ===
    Request 1: HTTP 200
    Request 2: HTTP 200
    Request 3: HTTP 200
    Request 4: HTTP 200
    Request 5: HTTP 200

  RESULTS:
  Same-node failures:  4 / 5
  Cross-node failures: 0 / 5
  ★ Same-node traffic is failing more than cross-node!
  ★ This is the classic hairpin NAT pattern.
```

### What Traditional Tools Show You (useless)

```bash
# OVN trace says FORWARD — everything looks correct:
$ ovn-trace --summary <switch> 'inport=="client-same-node" && ...'
# output: ... ct_next ... ct_dnat ... output to "backend-api" ...
# OVN says: FORWARD. But the packet DROPS. OVN trace is WRONG here
# (not wrong — it's just blind to the conntrack issue on the return path).

# ovs-appctl also says forward:
$ ovs-appctl ofproto/trace br-int 'in_port=X,...'
# output: ... output:Y
# OpenFlow says: FORWARD. The drop is in kernel conntrack, not OVS.

# tcpdump: SYN goes in, nothing comes back:
$ oc debug node/$NODE -- tcpdump -i <veth> -n port 5000
14:50:01 IP 10.128.2.25.45678 > 10.128.2.15.5000: Flags [S]
# No SYN-ACK. tcpdump can't tell you if this is a NetworkPolicy,
# a conntrack issue, or a routing problem. Just silence.

# The HAIRPIN PATH (why this is so hard):
#
#   client-same-node  (on worker-1)
#        │
#        ▼ SYN to ClusterIP
#   [ br-int on worker-1 ]
#        │
#   [ OVN logical switch ]  ← OVN trace: "forward"
#        │
#   [ OVN logical router ]  ← DNAT: ClusterIP → PodIP
#        │
#   [ geneve tunnel to SELF ]  ← hairpin: goes through tunnel back to same node
#        │
#   [ br-int on worker-1 again ]
#        │
#   [ conntrack check ]  ← RETURN packet after SNAT doesn't match
#        │                  original conntrack entry → CT_INVALID
#        ▼
#   DROPPED  ← invisible to tcpdump, OVN trace, ovs-ofctl
#              only eBPF kfree_skb sees this
```

### What NOO Shows (the answer)

Open **OCP Console → Observe → Network Traffic → Show drops**

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│  Network Traffic  [Show drops: ON]                                                  Namespace: demo-app  │
│                                                                                                          │
│  ┌───────────────────┬────────────────┬────────────────────┬───────┬────────────┬──────────────────────┐ │
│  │ Source             │ Destination    │ Node Path          │ Proto │ Drop Count │ Drop Reason          │ │
│  ├───────────────────┼────────────────┼────────────────────┼───────┼────────────┼──────────────────────┤ │
│  │ client-same-node  │ backend-api    │ worker-1 (SAME) ★  │ TCP   │ 12         │ CT_INVALID ★         │ │
│  │ client-diff-node  │ backend-api    │ w2 → w1 (DIFF)     │ TCP   │ 0          │ (none)               │ │
│  │ frontend          │ backend-api    │ w1 → w1 (SAME) ★   │ TCP   │ 4          │ CT_INVALID ★         │ │
│  └───────────────────┴────────────────┴────────────────────┴───────┴────────────┴──────────────────────┘ │
│                                                                                                          │
│  ★ THE PATTERN IS UNMISSABLE:                                                                            │
│    Same-node traffic:  CT_INVALID drops                                                                  │
│    Cross-node traffic: ZERO drops                                                                        │
│                                                                                                          │
│  ROOT CAUSE: Hairpin NAT conntrack mismatch.                                                             │
│  Return packet after DNAT+SNAT doesn't match original conntrack entry.                                  │
│  Kernel marks it CT_INVALID and drops it. Only happens on hairpin path.                                  │
│                                                                                                          │
│  WITHOUT NOO: need to correlate tcpdumps + conntrack tables across DNAT/SNAT path. DAYS.                │
│  WITH NOO: filter by drops → same-node pattern visible in SECONDS.                                      │
└──────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

### FIX IT

```bash
$ bash demo-scripts/scenario2-hairpin-fix.sh

========================================================
  SCENARIO 2: FIX
  Removing hairpin trigger and client pods...
========================================================

Step 1: Removing NetworkPolicy...
  → Removed hairpin-trigger NetworkPolicy

Step 2: Removing client pods...
  → Removed client-same-node
  → Removed client-diff-node

Step 3: Verifying normal connectivity...
  frontend → backend-api: HTTP 200

Hairpin scenario cleaned up. Check NOO: drops should stop.
```

---

## tcpdump vs NOO Comparison

This is the key point of the talk: **why traditional tools fail and eBPF wins.**
Here's a real side-by-side for Scenario 1 (NetworkPolicy drops):

### Approach 1: tcpdump (Traditional)

```bash
# Step 1: Which node is the backend-api pod on?
$ oc get pod -n demo-app -l app=backend-api -o wide
NAME                           READY   NODE
backend-api-7b4d8f6c5d-k2m9x  1/1     ip-10-0-171-45.us-east-2.compute.internal

# Step 2: SSH/debug into that node
$ oc debug node/ip-10-0-171-45.us-east-2.compute.internal
Starting pod/ip-10-0-171-45-debug ...

# Step 3: Find the right network interface (which one?!)
sh-5.1# chroot /host
sh-5.1# ip link show | grep -c ""
42    ← There are 42 interfaces on this node! Which one?

sh-5.1# ip link show | head -30
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536
2: ens5: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 9001
3: ovs-system: <BROADCAST,MULTICAST> mtu 1500
4: genev_sys_6081: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 65000
5: br-int: <BROADCAST,MULTICAST> mtu 1500
6: ovn-k8s-mp0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1400
7: b28f7a8cc5c8cf2@if2: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1400
8: 9e4a3f1d7b2c6e5@if2: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1400
9: a14d8c3e9f5b7a6@if2: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1400
...
# Which of these 42 interfaces carries the backend-api traffic?!

# Step 4: Guess an interface and run tcpdump
sh-5.1# tcpdump -i b28f7a8cc5c8cf2 -n port 5000
tcpdump: verbose output suppressed, use -v or -vv for full protocol decode
14:35:10.123456 IP 10.128.2.20.45678 > 10.128.3.15.5000: Flags [S], seq 1234567
14:35:11.234567 IP 10.128.2.20.45678 > 10.128.3.15.5000: Flags [S], seq 1234567
14:35:13.345678 IP 10.128.2.20.45678 > 10.128.3.15.5000: Flags [S], seq 1234567
```

**What tcpdump shows you:**
- SYN packets arriving... but no SYN-ACK response
- Is the packet being dropped? tcpdump doesn't say. It just shows what arrived.
- **tcpdump CANNOT tell you WHY the packet was dropped.**
- **tcpdump CANNOT tell you it was a NetworkPolicy.** It just shows "SYN sent, no reply."
- You still need to manually check: Is it a NetworkPolicy? Is it conntrack? Is it OVN?
- And you had to already KNOW which node and which interface to capture on.

**Total time with tcpdump: 15-60 minutes** (and you might still not find it)

### Approach 2: NOO with eBPF (What We Used)

```bash
# Step 1: Open OCP Console → Observe → Network Traffic
# Step 2: Filter: Namespace = demo-app, Show: Drops
# Step 3: Read the answer:

Source: frontend → Destination: backend-api → Drop Reason: NetworkPolicy → Count: 47
```

**What NOO shows you:**
- Packets ARE being dropped (not just "no response" — definitively "DROPPED")
- WHO is affected: frontend → backend-api
- WHY: NetworkPolicy (not conntrack, not routing, not OVN — specifically NetworkPolicy)
- HOW MANY: 47 packets dropped
- WHICH nodes: source node and destination node
- You didn't need to SSH into any node
- You didn't need to guess which interface
- You didn't need to know where the pod was scheduled

**Total time with NOO: 5 seconds**

### Why tcpdump Cannot Do What eBPF Does

| Capability | tcpdump | eBPF (NOO) |
|-----------|---------|------------|
| See packets on an interface | YES | YES |
| See packets across ALL interfaces | NO (one at a time) | YES (all at once) |
| See packets across ALL nodes | NO (one node at a time) | YES (cluster-wide) |
| Tell you a packet was DROPPED | NO (absence ≠ proof) | YES (kfree_skb tracepoint) |
| Tell you WHY it was dropped | NO | YES (NetworkPolicy, conntrack, MTU, etc.) |
| Show Kubernetes context (pod names) | NO (raw IPs only) | YES (enriched with K8s metadata) |
| Parse DNS queries/responses | NO (raw bytes) | YES (query name, response code, latency) |
| Always-on monitoring | NO (you start capture after problem) | YES (running before, during, after) |
| CPU overhead | HIGH (copies full packets to userspace) | LOW — see benchmarks below |
| Works without SSH to node | NO | YES (dashboard in browser) |

**eBPF Agent CPU/Memory Overhead at sampling:1 (verified benchmarks):**

| Cluster Size | CPU Total (all nodes) | Memory Total | Per-Node CPU | Per-Node Memory | % Cluster CPU |
|-------------|----------------------|-------------|-------------|-----------------|--------------|
| 6 nodes | ~0.08 cores | ~340 MB | ~0.01 cores | ~57 MB | <0.1% |
| 25 nodes | 3.32 cores | 2.71 GB | ~0.13 cores | ~108 MB | 0.83% |
| 120 nodes | 10.14 cores | 11.13 GB | ~0.08 cores | ~93 MB | 0.52% |

Source: [PAM 2024 — Designing a Lightweight Network Observability Agent](https://pam2024.cs.northwestern.edu/pdfs/paper-75.pdf)
| [NetObserv blog — Performance fine-tuning](https://netobserv.io/posts/performance-fine-tuning-a-deep-dive-in-ebpf-agent-metrics/)

**Key insight:** Overhead as a percentage of total cluster capacity DECREASES on
larger clusters. At 120 nodes with sampling:1, the eBPF agent uses only 0.52% of
total cluster CPU. This makes sampling:1 practical for temporary production
troubleshooting — switch to sampling:1 during an incident, then back to 50-100 after.

### The Core Problem with tcpdump

tcpdump shows you what ARRIVES at an interface. But in Kubernetes with OVN:

```
                   tcpdump here?
                        │
  frontend pod ──→ [veth] ──→ [br-int] ──→ [OVN pipeline] ──→ [geneve tunnel] ──→ [br-int] ──→ [veth] ──→ backend pod
                                                │
                                         NetworkPolicy
                                         evaluated HERE
                                         (inside OVN pipeline)
                                                │
                                           packet DROPPED
                                           here (invisible
                                           to tcpdump)
```

The packet enters the OVN pipeline and gets dropped by a NetworkPolicy rule INSIDE the
Open vSwitch datapath. tcpdump on the veth interface sees the packet go in but never
sees it come out — and it can't tell you why.

eBPF, attached at the TC hook and kfree_skb tracepoint, sees the drop happen and reads
the reason code directly from the kernel.

---

## Troubleshooting

### No flows appearing in the console

```bash
$ oc get ds -n netobserv
NAME                       DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE
netobserv-ebpf-agent       4         4         4       4            4
# ↑ If READY < DESIRED, the eBPF agent is failing on some nodes

$ oc logs -n netobserv -l app=netobserv-ebpf-agent --tail=20
# Look for errors like:
# "failed to load eBPF program" → kernel too old or privileged mode not set
# "failed to attach TC hook" → interface not found

$ oc get consoleplugin netobserv-plugin
# If missing → operator didn't register the console plugin
# Fix: oc patch flowcollector cluster --type=merge -p '{"spec":{"consolePlugin":{"register":true}}}'
```

### PacketDrop not showing drop reasons

```bash
$ oc get flowcollector cluster -o yaml | grep -A5 features
      features:
      - PacketDrop          # ← Must be present
      - DNSTracking
      - FlowRTT

$ oc get flowcollector cluster -o yaml | grep privileged
      privileged: true      # ← Must be true (needs CAP_SYS_ADMIN for kfree_skb)

# If privileged is false, PacketDrop silently doesn't work — no error, just no data.
# Fix:
$ oc patch flowcollector cluster --type=merge -p '{"spec":{"agent":{"ebpf":{"privileged":true}}}}'
```

### DNSTracking eBPF feature not working

DNSTracking is an eBPF feature that inspects port 53 traffic. If the DNS tab in the
NOO console is empty, verify the feature is enabled:

```bash
$ oc get flowcollector cluster -o yaml | grep -A5 features
      features:
      - PacketDrop
      - DNSTracking         # ← Must be present
      - FlowRTT

# Verify DNS traffic exists on the cluster:
$ oc exec -n demo-app deploy/backend-api -- nslookup database
Server:         172.30.0.10
Address:        172.30.0.10#53

Name:   database.demo-app.svc.cluster.local
Address: 10.128.3.22

# If nslookup works but DNS tab is empty, the eBPF agent may need a restart:
$ oc delete pods -n netobserv -l app=netobserv-ebpf-agent
```

### Flows are delayed (not real-time enough for demo)

```bash
# The eBPF agent caches flows before exporting (default: 15s in NOO 1.11, was 5s before).
# For a demo, reduce this to 1 second for near-real-time visibility:
$ oc patch flowcollector cluster --type=merge -p '{"spec":{"agent":{"ebpf":{"cacheActiveTimeout":"1s"}}}}'

# Wait for the eBPF agent pods to restart:
$ oc get pods -n netobserv -l app=netobserv-ebpf-agent -w
```

### Reset everything between demo runs

```bash
$ bash demo-scripts/cleanup-all.sh

========================================
  FULL CLEANUP — Resetting all scenarios
========================================

Cleaning Scenario 1 (NetworkPolicy drops)...
  → Already clean

Cleaning Scenario 2 (Hairpin)...
  → Already clean
  → Already clean
  → Already clean

Pod status:
NAME                           READY   STATUS    RESTARTS   AGE
backend-api-7b4d8f6c5d-k2m9x  1/1     Running   0          30m
database-5c8b7a9d3f-p4n7q      1/1     Running   0          30m
frontend-6d9e4f8a2b-r5t8w      1/1     Running   0          30m

Connectivity test:
  frontend → backend-api: HTTP 200

Cleanup complete! Ready for demo.
```
