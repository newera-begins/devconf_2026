# Egress NetworkPolicy Blocks Database — Deep Concept Explanation

## What This Document Covers

This explains Demo Scenario 2 (The Database That Isn't Broken) — how an EGRESS
NetworkPolicy silently blocks backend-api from reaching the database, why every
traditional tool sends you debugging PostgreSQL instead of the real problem, and
how NOO identifies it in 5 seconds.

---

## The Scenario

A 3-tier application: Frontend → Backend-API → Database (PostgreSQL).

An EGRESS NetworkPolicy is applied to backend-api that allows DNS (port 53)
but blocks ALL other outbound traffic — including port 5432 (PostgreSQL).

```
                    INGRESS                        EGRESS
                    (not restricted)               (restricted!)
                         │                              │
Frontend ──────────► Backend-API ──────X──────► Database
   HTTP 200              │                         port 5432
   (works)               │                         BLOCKED
                    /api/health                          │
                    returns 200                    PostgreSQL
                    (no DB needed)                 is HEALTHY
                         │                         (8 books)
                    /api/books
                    FAILS (needs DB)
```

## Why This Is Hard to Debug

### The Multi-Layered Misdirection

1. **Health check returns 200** → "The app is healthy"
   - The `/api/health` endpoint returns `{"status": "ok"}` without touching
     the database. It's a simple ping. So the app IS responding.

2. **Frontend loads fine** → "The network is working"
   - The frontend HTML page loads. The route works. HTTP 200.
   - INGRESS to backend-api is not restricted — only EGRESS.

3. **Database pod is Running, Ready 1/1** → "PostgreSQL is fine"
   - `oc get pods` shows database Running.
   - Direct `psql` query returns 8 books.
   - PostgreSQL is perfectly healthy.

4. **Only `/api/books` fails** → "Must be a code bug in the books endpoint"
   - Developers review the Python code for bugs.
   - They add logging, check SQL queries, verify schema.
   - Nothing wrong with the code.

5. **App logs show no connection errors** → "The app looks fine"
   - The connection timeout happens at the kernel level (the SYN packet
     is dropped by the OVN ACL before leaving the pod's network namespace).
   - psycopg2's default connect_timeout is 0 (infinite), so it waits
     silently until curl's --max-time kills the request.
   - Backend-api's logs show health checks succeeding but nothing about
     failed database connections.

6. **Nobody checks EGRESS NetworkPolicy**
   - When troubleshooting "app can't reach database," engineers check:
     - Is the DB pod running? (yes)
     - Is the DB service configured? (yes)
     - Are the endpoints correct? (yes)
     - Is there an INGRESS policy blocking? (no — or they check ingress on DB)
   - EGRESS policies on the CLIENT pod (backend-api) are rarely checked first.
   - With 20-50 policies in a production namespace, finding the one EGRESS
     rule that blocks a specific port is a needle-in-a-haystack problem.

### What Traditional Tools Show

```
Tool               What it shows              Misleading conclusion
─────────────────  ─────────────────────────  ────────────────────────────
oc get pods        All Running, Ready 1/1     "Nothing crashed"
oc get endpoints   database: 10.x.x.x:5432   "Service is configured"
psql (direct)      8 books returned           "Database is healthy"
tcpdump            SYN to port 5432, no ACK   "DB isn't responding" ← WRONG
oc logs            Health checks OK, no err   "App looks fine"
NetworkPolicy      Policy exists              "Probably not relevant" ← WRONG
OVN LB             DNAT correct               "Load balancer is fine"
OVS flows          Flows for port 5432 exist  "Pipeline is correct"
```

**Every tool points AWAY from the real problem.** The DBA debugs PostgreSQL.
The developer debugs the Python code. The SRE debugs the network. Nobody
finds the answer because nobody checks EGRESS policies on the client pod.

---

## What NOO Shows

```
┌──────────────────────────────────────────────────────────────────┐
│  Network Traffic  [Show drops]            Namespace: demo-app    │
│                                                                  │
│  ┌──────────────┬────────────┬──────┬───────┬──────────────────┐│
│  │ Source         │ Dest       │ Port │ Drops │ Drop Reason      ││
│  ├──────────────┼────────────┼──────┼───────┼──────────────────┤│
│  │ backend-api  │ database   │ 5432 │ 23    │ NetworkPolicy    ││
│  │ backend-api  │ database   │ 5432 │ 18    │ NetworkPolicy    ││
│  └──────────────┴────────────┴──────┴───────┴──────────────────┘│
│                                                                  │
│  ★ Source = backend-api (NOT database — the CLIENT is blocked)  │
│  ★ Destination = database, port 5432                            │
│  ★ Drop Reason = NetworkPolicy                                  │
│  ★ Direction = EGRESS from backend-api                          │
│                                                                  │
│  Answer: EGRESS policy on backend-api blocks port 5432.         │
│  Fix: remove the policy or add port 5432 to the egress rules.  │
└──────────────────────────────────────────────────────────────────┘
```

**5 seconds.** Not 30 minutes debugging PostgreSQL.

---

## How the eBPF Agent Captures This

When backend-api sends a SYN packet to database:5432:

```
1. backend-api sends: SYN to 10.x.x.x:5432
2. Packet enters br-int on the node
3. OVN evaluates EGRESS ACLs for backend-api:
   - Is port 5432 in the egress allow list? NO.
   - Only port 53 (DNS) is allowed.
   - Action: DROP
4. kfree_skb() called with reason: OVS_DROP_EXPLICIT
5. eBPF tracepoint fires:
   - src: backend-api IP
   - dst: database IP
   - dport: 5432
   - reason: OVS_DROP_EXPLICIT
6. FLP enriches: "backend-api → database, port 5432, NetworkPolicy"
7. NOO dashboard displays it
```

The packet never reaches the database. The database never knows someone
tried to connect. PostgreSQL's logs show nothing. tcpdump on the database
side shows nothing. Only eBPF on the SOURCE node sees the drop.

---

## Real-World Context

This scenario is extremely common in production:

1. **Security team applies default-deny EGRESS** — a new security policy
   requires all namespaces to have egress restrictions. The policy allows
   DNS and a few known ports, but misses port 5432 for the database.
   The app worked before the policy was applied.

2. **New database migration changes ports** — the team migrates from
   MySQL (3306) to PostgreSQL (5432). The egress policy was updated to
   allow 5432 but a typo or missing YAML line leaves it blocked.

3. **Egress policy copied from another namespace** — a working egress
   policy from namespace A is copied to namespace B, but namespace B
   uses different database ports. Nobody notices until the app breaks.

4. **CI/CD pipeline adds policy without testing** — an automated pipeline
   applies NetworkPolicies but doesn't test database connectivity.
   The health check passes (no DB needed), so CI says "deploy succeeded."

In ALL these cases, the symptoms are identical: "the database stopped
working." Traditional debugging follows the wrong path for 30+ minutes.
NOO shows "NetworkPolicy blocking port 5432" in 5 seconds.

---

## Demo Script Safety

| Risk | Mitigation |
|------|-----------|
| Could it crash a node? | No — only creates a NetworkPolicy in demo-app |
| Could it break cluster services? | No — namespace-scoped, only targets app=backend-api |
| Could it affect other namespaces? | No — policy only applies to pods in demo-app |
| What if the script crashes? | `trap cleanup_on_failure ERR` auto-deletes the policy |
| What if I forget to fix? | `cleanup-all.sh` removes all scenario resources |
| Does it modify any node settings? | No — zero sysctl, zero oc debug, zero SSH |

---

## Summary

| Aspect | Traditional Tools | NOO + eBPF |
|--------|------------------|------------|
| Symptom | "/api/books fails, /api/health works" | backend-api → database drops |
| What gets blamed | PostgreSQL, app code, "network issue" | EGRESS NetworkPolicy on backend-api |
| Time to find | 30+ minutes (wrong direction) | 5 seconds (correct direction) |
| Key insight | EGRESS policies are rarely checked first | NOO shows drop direction + reason |
| Risk of misdiagnosis | High — health works, DB is healthy | Zero — drop reason is definitive |
