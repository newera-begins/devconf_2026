# DevConf.CZ 2026 — Complete Demo Implementation Guide
## "Who Dropped the Packet?" — Step-by-Step Setup

---

## Timeline

| When | What |
|------|------|
| June 10-12 | Phase 1: Cluster setup & operator install |
| June 13-15 | Phase 2: Deploy demo app, test scenarios |
| June 16-17 | Phase 3: Full rehearsal (3 run-throughs) |
| June 18 | Phase 4: Record backup video, final prep |
| June 19 | Talk day |

---

## Phase 1: Cluster & Operator Setup

### Step 1.1: Provision the OCP Cluster

**Option A — Bare metal cluster (current demo setup):**
Using the 3-node compact bare metal cluster at `dell-r640-31.gsslab.pnq2.redhat.com`.
OCP 4.21.12 with 3 control-plane/worker nodes (`m0/m1/m2.c1.ocplabs.bm`).
For hairpin scenario: all 3 nodes serve as both control-plane and worker.

**Option B — demo.redhat.com (alternative):**
Order an "OpenShift 4.21 Workshop" cluster with 3+ workers.

```bash
# Verify access:
oc whoami
oc get nodes
oc get clusterversion
```

Expected output:
```
NAME               STATUS   ROLES                         AGE   VERSION
m0.c1.ocplabs.bm   Ready    control-plane,master,worker   49d   v1.34.6
m1.c1.ocplabs.bm   Ready    control-plane,master,worker   49d   v1.34.6
m2.c1.ocplabs.bm   Ready    control-plane,master,worker   49d   v1.34.6
```

> **Note:** Sample outputs in this guide use AWS node names (ip-10-0-xxx). Your
> actual node names will differ. The scripts use dynamic discovery (`oc get pod
> -o jsonpath`) so they work on any cluster.

### Step 1.2: Install the Network Observability Operator

**Option A — Via OCP Console (recommended for demo setup):**

1. Go to **Operators → OperatorHub**
2. Search for **"Network Observability"**
3. Click **Install**
4. Accept defaults (All namespaces, Automatic approval)
5. Wait for operator to reach `Succeeded` state

**Option B — Via CLI:**

```bash
# Create the namespace
oc create namespace netobserv

# Install Loki Operator first (required for flow storage)
cat <<'EOF' | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: loki-operator
  namespace: openshift-operators-redhat
spec:
  channel: stable-6.5
  installPlanApproval: Automatic
  name: loki-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Wait for Loki Operator to be ready
oc wait --for=condition=CatalogSourcesUnhealthy=false \
  subscription/loki-operator -n openshift-operators-redhat --timeout=120s

# Install Network Observability Operator
cat <<'EOF' | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: netobserv-operator
  namespace: openshift-netobserv-operator
spec:
  channel: stable
  installPlanApproval: Automatic
  name: netobserv-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Wait for the operator pod to be running
oc get pods -n openshift-netobserv-operator -w
```

### Step 1.3: Set Up Loki Storage (for flow logs)

**For bare metal clusters without cloud storage**, use the automated setup script
that deploys MinIO as in-cluster S3 + local PVs:

```bash
bash demo-scripts/setup-storage-and-loki.sh
```

This script:
1. Installs LVM Storage Operator (if no StorageClass exists — may not work on
   all bare metal setups; see fallback below)
2. Installs Loki Operator (channel `stable-6.5`)
3. Deploys MinIO pod as S3-compatible storage (emptyDir — no external deps)
4. Creates S3 secret pointing to MinIO
5. Creates LokiStack `1x.demo` size

**If LVM Storage fails** (no available disks), create local PVs manually:

```bash
# Create directories on a worker node
oc debug node/<NODE> -- chroot /host bash -c \
  "mkdir -p /var/loki/{compactor,ingester,ingester-wal,index-gateway} && chmod 777 /var/loki/*"

# Create StorageClass + 4 PVs (see setup-storage-and-loki.sh for full YAML)
```

**For AWS/cloud clusters**, use S3 directly:

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: loki-s3-secret
  namespace: netobserv-loki
stringData:
  access_key_id: "<YOUR_AWS_ACCESS_KEY>"
  access_key_secret: "<YOUR_AWS_SECRET_KEY>"
  bucketnames: "netobserv-loki"
  endpoint: "https://s3.<REGION>.amazonaws.com"
  region: "<REGION>"
EOF
```

**To reset Loki storage** when PVs fill up during testing:

```bash
bash demo-scripts/reset-loki-storage.sh
```

This wipes all flow data, recreates fresh PVs, and restarts Loki pods.

**Loki-free alternative:** Set `spec.loki.mode: Disabled` in FlowCollector
for Prometheus metrics-only mode (no Traffic Flow table, but Overview/Topology work).

### Step 1.4: Create the FlowCollector

This is the main custom resource that enables flow collection:

```bash
cat <<'EOF' | oc apply -f -
apiVersion: flows.netobserv.io/v1beta2
kind: FlowCollector
metadata:
  name: cluster
  namespace: netobserv
spec:
  namespace: netobserv
  deploymentModel: Direct       # Default changed to Service in NOO 1.11
                               # Using Direct for small demo cluster (<15 nodes)
  agent:
    type: eBPF
    ebpf:
      sampling: 1              # Capture every packet (demo + active troubleshooting; baseline 50-100 in prod)
      privileged: true
      features:
        - PacketDrop            # CRITICAL: enables drop reason tracking (kfree_skb)
        - DNSTracking           # Enables DNS query/response tracking on port 53
        - FlowRTT              # Round-trip time measurement (TCP handshake)
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
EOF
```

**Key config explained:**
- `sampling: 1` — Captures every packet. Useful for demos and active production troubleshooting. For always-on monitoring, use 50 or 100 to reduce overhead. Note: DNSTracking is subject to sampling — at sampling:50, DNS queries on port 53 can be missed. Use eBPF flow filter on port 53 with sampling:1 for full DNS visibility.
- `features: [PacketDrop, DNSTracking, FlowRTT]` — These three features are what make the demo scenarios work. Without `PacketDrop`, you won't see drop reasons. Without `DNSTracking`, you won't see DNS queries.
- `privileged: true` — Required for eBPF packet drop tracking.

### Step 1.5: Verify Everything is Working

Run the full pre-requisite check:

```bash
bash demo-scripts/check-prerequisites.sh
```

This checks cluster health, operators, LokiStack, FlowCollector, eBPF agents,
FLP, console plugin, and demo-app in one pass. All items must show ✓.

Manual checks if needed:

```bash
# Check eBPF agent DaemonSet is running on all nodes
oc get daemonset -n netobserv-privileged
# Should show DESIRED = CURRENT = READY (one pod per node)

# Check FLP (flowlogs-pipeline) pods
oc get pods -n netobserv -l app=flowlogs-pipeline

# Check console plugin is registered
oc get consoleplugin netobserv-plugin

# Open OCP Console → Observe → Network Traffic
# You should see flows appearing within 1-2 minutes
```

---

## Phase 2: Deploy the Demo Application

### Step 2.1: Create the Namespace

```bash
oc new-project demo-app
```

### Step 2.2: Deploy the 3-Tier Application

Apply all manifests from the `demo-app/` directory:

```bash
oc apply -f demo-app/
```

This deploys:
1. **PostgreSQL database** — Stores book data
2. **Backend API** — Python Flask app that queries the database
3. **Frontend** — Nginx serving a static page that calls the backend API

### Step 2.3: Verify the Application

```bash
# Check all pods are running
oc get pods -n demo-app
# Expected: frontend-xxx Running, backend-api-xxx Running, database-xxx Running

# Check services
oc get svc -n demo-app
# Expected: frontend (8080), backend-api (5000), database (5432)

# Test the frontend
oc expose svc/frontend -n demo-app
FRONTEND_URL=$(oc get route frontend -n demo-app -o jsonpath='{.spec.host}')
curl -s http://$FRONTEND_URL | head -5

# Test backend directly
oc exec -n demo-app deploy/frontend -- curl -s http://backend-api:5000/api/books
# Should return JSON list of books

# Test database connectivity
oc exec -n demo-app deploy/backend-api -- python -c "
import psycopg2
conn = psycopg2.connect(host='database', dbname='bookstore', user='demo', password='demo123')
print('DB connected!')
conn.close()
"
```

### Step 2.4: Start the Traffic Generator

This script sends continuous traffic between all tiers so the NOO dashboard shows active flows:

```bash
bash demo-scripts/traffic-generator.sh &
```

### Step 2.5: Verify Flows in NOO Dashboard

1. Open OCP Console → **Observe → Network Traffic**
2. Filter: **Namespace = demo-app**
3. You should see flows between:
   - frontend → backend-api (port 5000)
   - backend-api → database (port 5432)
   - External → frontend (port 8080)
4. All flows should show **0 drops** — this is your "healthy" baseline
5. **Take a screenshot of this healthy state** — you'll show it in the talk

---

## Phase 3: Demo Scenarios

Both scenarios are complex, real-world cases that CANNOT be solved with tcpdump,
conntrack -S, OVN trace, or any traditional tool alone. They require eBPF kernel-level
visibility to identify the root cause.

---

### Scenario 1: Silent NetworkPolicy Drops

**Why this matters:** NetworkPolicy misconfiguration is one of the most common
causes of silent packet drops in production. The pods are Running, endpoints exist,
services are healthy — but traffic is blocked by an OVN ACL that no standard tool
reveals. tcpdump shows SYN with no SYN-ACK, and you think the pod is down.

**What happens:** Traffic-generator pods send requests to backend-api. A NetworkPolicy
is applied that allows frontend but blocks the traffic-generator pods. Requests from
traffic-generator silently fail — dropped by OVN ACLs before reaching the destination.

**SAFE:** No sysctl changes. No node-level modifications. Only namespace-scoped
pods and NetworkPolicy. Automatic revert on script failure.

**Break it:**
```bash
bash demo-scripts/scenario1-netpol-break.sh
```

**Sample output when broken:**
```
Pre-check: verifying demo-app is healthy...
  ✓ 3 pods running

Step 1: Deploying traffic-generator pods...
  Waiting for traffic-generator pods to be ready...

Step 2: Verifying traffic works BEFORE blocking...
  Request 1: HTTP 200
  Request 2: HTTP 200
  Request 3: HTTP 200

Step 3: Applying NetworkPolicy to BLOCK traffic-generator...
  NetworkPolicy applied.

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
  backend-api self-check:    working (allowed by policy)
```

**What to show the audience — Traditional tools fail (run LIVE):**

**1. Pod status — looks perfectly healthy:**
```bash
$ oc get pods -n demo-app -l app=backend-api
NAME                           READY   STATUS    RESTARTS
backend-api-7b4d8f6c5d-k2m9x  1/1     Running   0

WHY IT FAILS: Pod IS running. Nothing wrong with the pod itself.
The drop happens in the OVS datapath BEFORE traffic reaches the pod.
```

**2. Endpoints — look correct:**
```bash
$ oc get endpoints backend-api -n demo-app
NAME          ENDPOINTS           AGE
backend-api   10.128.2.15:5000    30m

WHY IT FAILS: Endpoint exists. Service is configured. But the OVN ACL
silently drops the SYN packet inside br-int. Endpoints don't show you
which traffic is BLOCKED — only which pods back the Service.
```

**3. tcpdump from traffic-generator — SYN, no SYN-ACK:**
```bash
$ oc exec deploy/traffic-generator -- tcpdump -i eth0 -n port 5000 -c 5
14:30:01 IP 10.128.2.20.45678 > 10.128.3.15.5000: Flags [S]
14:30:02 IP 10.128.2.20.45678 > 10.128.3.15.5000: Flags [S]   ← retransmit
14:30:04 IP 10.128.2.20.45678 > 10.128.3.15.5000: Flags [S]   ← retransmit

WHY IT FAILS: tcpdump sees the SYN leaving the pod. But it can't follow
the packet into br-int where the OVN ACL drops it. From tcpdump's view,
it looks IDENTICAL to "backend-api is not listening" — but it IS listening.
tcpdump CANNOT tell you the difference between:
  - "destination pod is down" (no process listening)
  - "NetworkPolicy is blocking" (ACL drop in OVS)
  - "conntrack is full" (kernel drop)
All three look like "SYN sent, no SYN-ACK."
```

**4. oc logs — shows nothing:**
```bash
$ oc logs deploy/backend-api --tail=5
[14:30:01] "GET /api/health" 200     ← self-check works
[14:30:03] "GET /api/health" 200     ← self-check works
No errors, no timeouts, no connection attempts from traffic-generator.

WHY IT FAILS: backend-api never SEES the traffic-generator requests because
they're dropped by the OVN ACL before reaching the pod. The app logs show
nothing — you can't log what you never received.
```

**5. Now switch to NOO → Answer in 5 seconds:**

Open **OCP Console → Observe → Network Traffic → Show drops → Namespace = demo-app**

```
┌────────────────────┬────────────┬───────┬────────────────┐
│ Source              │ Dest       │ Drops │ Reason         │
├────────────────────┼────────────┼───────┼────────────────┤
│ traffic-generator  │ backend-api│ 47    │ NetworkPolicy  │
│ traffic-generator  │ backend-api│ 38    │ NetworkPolicy  │
│ traffic-generator  │ backend-api│ 29    │ NetworkPolicy  │
└────────────────────┴────────────┴───────┴────────────────┘
```

**Key points for the audience:**
- "Pod is Running, endpoints exist — everything LOOKS fine"
- "tcpdump shows SYN with no response — looks like pod is dead. It's NOT."
- "oc logs shows nothing — backend-api never saw the traffic"
- "NOO tells you EXACTLY: 'dropped by NetworkPolicy' with pod names and count"
- "Traditional tools: 15-30 minutes of guessing. NOO: 5 seconds."
- "Fix: remove the NetworkPolicy → drops stop immediately"

**Fix it:**
```bash
bash demo-scripts/scenario1-netpol-fix.sh
```

---

### Scenario 2: Egress NetworkPolicy Blocks Database

**Why this matters:** EGRESS NetworkPolicy misconfiguration is one of the hardest
issues to debug because every tool sends you in the wrong direction. The health
endpoint works (no DB needed), the database is perfectly healthy, and traditional
tools all say "everything should work." But backend-api can't REACH the database
because an EGRESS policy blocks port 5432.

**The multi-layered misdirection:**
- Health returns 200 → "app is healthy"
- Frontend loads → "network is fine"
- Database is Running with 8 books → "PostgreSQL is fine"
- Only `/api/books` fails → "must be a code bug"
- Nobody checks EGRESS policies — everyone debugs PostgreSQL

**SAFE:** Only creates one NetworkPolicy in demo-app namespace. No sysctl, no
node modifications. Auto-reverts via fix script or cleanup-all.sh.

**Break it:**
```bash
bash demo-scripts/scenario2-egress-break.sh
```

**Sample output when broken:**
```
Step 1: Verifying everything works (baseline)...
  Health: HTTP 200 ✓
  Books: HTTP 200 ✓
  Database: 8 books ✓

Step 2: Applying EGRESS NetworkPolicy...
  NetworkPolicy applied.

Step 3: Testing AFTER applying egress block...
  === Health endpoint (SHOULD WORK) ===
    Request 1: HTTP 200
    Request 2: HTTP 200
    Request 3: HTTP 200

  === Books endpoint (SHOULD FAIL) ===
    Request 1: ★ FAILED — timeout (no response from DB)
    Request 2: ★ FAILED — timeout (no response from DB)
    Request 3: ★ FAILED — timeout (no response from DB)

  Database pod: Running, 8 books. PostgreSQL is FINE.
  Frontend route: HTTP 200 (HTML loads fine)
```

**What to show the audience — Traditional tools fail (run LIVE):**

```bash
bash demo-scripts/scenario2-traditional-debug.sh
```

This script runs 9 REAL commands. Key results:

1. **Health check:** HTTP 200 — "App is healthy" (MISLEADING)
2. **Books endpoint:** FAILS — "Database must be broken!" (WRONG)
3. **Database direct query:** 8 books, PostgreSQL healthy — "If DB is fine, why?"
4. **Endpoints:** Exist — "Service is configured"
5. **tcpdump on port 5432:** SYN sent, no SYN-ACK — "DB isn't responding" (WRONG — DB is fine)
6. **NetworkPolicy:** Exists — but who reads EGRESS rules?
7. **OVN LB:** DNAT correct — "Load balancer is fine"
8. **OVS flows:** Flows for port 5432 exist — "Pipeline is correct"
9. **App logs:** Health checks working, no errors — "App looks fine"

**THE DEBUGGING TRAP:**
- Health works → "app is fine"
- Books fails → "database is broken"
- DBA checks PostgreSQL → it's healthy
- Developer checks code → code is correct
- SRE runs tcpdump → SYN no SYN-ACK on port 5432
- 30+ minutes later... still no answer

**Then switch to NOO:**
```
NOO Dashboard → Show drops:
  backend-api → database, port 5432, Drop Reason: NetworkPolicy
  
  Answer: EGRESS policy on backend-api blocks port 5432.
  5 seconds. Not 30 minutes.
```

**Fix it:**
```bash
bash demo-scripts/scenario2-egress-fix.sh
```

---

### Scenario 3: Idle Connection Conntrack Timeout

**Why this matters:** This is a REAL production issue with database connection pools.
The conntrack ESTABLISHED timeout expires on idle connections. When the app reuses the
connection, the kernel marks the packet CT_INVALID and drops it. Every tool blames the
database — but the database is fine. The kernel did it.

**What happens:** We lower `nf_conntrack_tcp_timeout_established` to 30 seconds. Backend-api's
database connection pool has idle connections. After 30s idle, conntrack entry expires. Next
query on that connection → CT_INVALID → dropped. App sees "connection reset by peer."

**Break it:**
```bash
bash demo-scripts/scenario3-idle-conntrack-break.sh
```

**Sample output when broken:**
```
Step 2: Setting ESTABLISHED timeout to 30 seconds...
Step 4: Creating a long-lived connection and letting it go idle...
  Connection created. Now waiting 35 seconds for conntrack to expire...

Step 5: Trying to use the connection AFTER conntrack expired...
  Request 1: HTTP 000 ★ FAILED (reused idle connection — CT_INVALID)
  Request 2: HTTP 200 (new connection — works)
  Request 3: HTTP 000 ★ FAILED (reused idle connection — CT_INVALID)
  Request 4: HTTP 200 (new connection — works)
  Request 5: HTTP 000 ★ FAILED (reused idle connection — CT_INVALID)
```

**Traditional debugging (run LIVE):**
```bash
bash demo-scripts/scenario3-traditional-debug.sh
```

**1. tcpdump (blames the database):**
```
$ oc debug node/$NODE -- tcpdump -i any -n port 5432 -c 8
14:50:35 IP 10.128.2.15.45678 > 10.128.3.22.5432: Flags [P.], seq 1:48
    ↑ data packet sent on reused connection
(silence — packet was dropped by conntrack before reaching database)
14:50:36 IP 10.128.2.15.45678 > 10.128.3.22.5432: Flags [P.], seq 1:48
    ↑ TCP retransmit — still dropped
14:50:38 IP 10.128.3.22.5432 > 10.128.2.15.45678: Flags [R.]
    ↑ RST — looks like database reset the connection. But it DIDN'T.
      The kernel generated this RST because of CT_INVALID.

RESULT: "Database is resetting connections" → WRONG. Kernel did it.
```

**2. conntrack -L (evidence is gone):**
```
$ oc debug node/$NODE -- conntrack -L -s $BACKEND_IP -d $DB_IP
(no entries)

RESULT: The entry EXPIRED. There's nothing to find. You're looking
for evidence that has been destroyed. Only eBPF captured the drop
at the moment it happened.
```

**3. Application logs (mislead you):**
```
psycopg2.OperationalError: server closed the connection unexpectedly

RESULT: "PostgreSQL crashed!" → WRONG. PostgreSQL is fine. The kernel's
conntrack entry expired, and the next packet was dropped as CT_INVALID.
Teams spend 1-3 days debugging PostgreSQL for nothing.
```

**4. ovn-trace (says ALLOW):**
```
$ ovn-trace 'inport=="backend-api" && ip4.dst==$DB_IP && tcp.dst==5432'
  ct_next → output to "database"

RESULT: OVN pipeline ALLOWS the traffic. The drop is in kernel conntrack.
OVN trace cannot see conntrack timeout state.
```

**NOO shows:**
```
┌───────────────┬────────────────┬──────────┬───────┬──────────────┐
│ Source         │ Destination    │ Node     │ Drops │ Reason       │
├───────────────┼────────────────┼──────────┼───────┼──────────────┤
│ backend-api   │ database       │ worker-1 │ 8     │ CT_INVALID   │
└───────────────┴────────────────┴──────────┴───────┴──────────────┘

Pattern: drops ONLY on backend→database, ONLY after idle periods.
New connections: 0 drops. The timing reveals it's a timeout issue.
```

**Fix it:**
```bash
bash demo-scripts/scenario3-idle-conntrack-fix.sh
```

---

## Phase 4: Backup Plan

### Record a Backup Video

In case the cluster has issues during the talk:

```bash
# Use OBS Studio or QuickTime to record your screen
# Walk through all 3 scenarios with narration
# Save as devconf-demo-backup.mp4 (keep under 8 minutes)
```

### Take Screenshots

For each scenario, capture:
1. The "healthy" NOO dashboard (before breaking)
2. The "broken" NOO dashboard showing drops/errors
3. The "fixed" NOO dashboard showing recovery

Save these in `devconf/screenshots/` — use them in slides if the live demo fails.

### Pre-load Everything

Before the talk:
1. Have terminal open with `demo-scripts/` directory
2. Have OCP Console open in browser, logged in, on Network Traffic page
3. Have traffic generator running
4. Test one scenario to make sure flows are appearing
5. Clear the scenario so you start clean

---

## Troubleshooting Common Issues

| Issue | Fix |
|-------|-----|
| No flows appearing in console | Check eBPF agent DaemonSet: `oc get ds -n netobserv` |
| Console plugin not showing | `oc get consoleplugin` — may need to refresh browser |
| Loki not storing flows | Check Loki pods: `oc get pods -n netobserv -l app=loki` |
| PacketDrop not showing reasons | Ensure `features: [PacketDrop]` in FlowCollector AND `privileged: true` |
| DNS tracking not working | Ensure `features: [DNSTracking]` in FlowCollector |
| Flows are delayed | Reduce `agent.ebpf.cacheActiveTimeout` to 1s for demo responsiveness |
