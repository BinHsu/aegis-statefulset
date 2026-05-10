# ADR-03: Routing and ingress — three-tier flow with placement-table contract

## Status

Decided 2026-05-09 (POC submission scope; subject to confirmation in Stage 3 conversation). The placement-table-as-contract decision supersedes an earlier hash-plus-override-delta proposal, which is retained here only for the trade-off discussion.

## Thesis

The per-tenant pod model commits the architecture to one routing rule: every request must reach the specific pod that owns the requesting tenant's LevelDB. The ingress design therefore optimises for the integrity of that lookup — refusing to serve when the binding is unknown, never falling back to "any pod" — and minimises everything else: one ALB at the edge, three replicas of an Envoy router behind it, and a placement table whose backend is interchangeable as long as it satisfies six well-defined properties. The same shape covers TLS termination, AZ-aware target health, and the relocation flip described in ADR-05.

## Context (why these decisions belong together)

Routing in this architecture is not a load-balancing problem. It is a directory-lookup problem with a load balancer attached. Three decisions that were originally written separately have to be considered together because they share the same constraint and are wrong if any one of them is wrong:

1. **What primitive holds the tenant-to-pod binding?** A placement table satisfying a six-property contract — the customer can swap backends. The customer's existing system likely already has a tenant-to-cluster mapping; the architecture's value-add is the contract, not the implementation.
2. **What carries the request from the public internet to the right pod?** A single ALB at the edge feeding three Envoy replicas, each running a Lua filter that reads the placement table on every request. The decisions about TLS, AZ-aware target health, and direct-pod-IP target groups all live at this layer.
3. **What happens when the lookup misses?** Three legitimate paths can produce a lookup miss (relocation flip in flight, signup race, system bug). Two of them resolve in seconds; the third is a real bug. The correct response in all three cases is `503 Service Unavailable` with `Retry-After: 30`. Falling back to "any pod" would silently corrupt LevelDB state — a P1 violation that would not be noticed until a relocation completed and the data was on the wrong pod.

These three are entangled: the contract for the placement table is what allows Envoy to be read-only against it; Envoy being read-only is what makes the recovery story sound; the recovery story depends on cold-DR rehydration in warm-standby AZs (ADR-04) rather than on cross-AZ live writes. Treating them as one topic surfaces the shared logic that holds across relocation, capacity-driven moves, and DR recovery.

The current architecture also adds one constraint that simplifies the routing story: stateful workloads run in a single master AZ; AZ-B and AZ-C are warm-standby with desired=0 node groups. The ALB still spans three AZs because the warm-standby AZs receive traffic during cold-DR rehydration, but the steady-state routing target is always a pod in the master AZ. There is no live cross-AZ stateful failover for Envoy to reason about.

## Decisions

### The three-tier ingress flow

The path from client to pod has four hops (one more than the minimum, one fewer than what most service-mesh shops end up with):

```
Client
  → Route 53 (single A record, no failover policy in POC — single region)
  → ALB (regional, multi-AZ subnets, ACM-managed TLS, native target health)
  → API tier: nginx forwarder (3 replicas behind ALB target group)
  → Envoy router (3 replicas, Lua filter reads placement table per request)
  → StatefulSet pod (primary in master AZ; standby slot reserved for cold DR)
```

The ALB is the regional edge layer, multi-AZ by default. AWS Load Balancer Controller binds it to K8s `Ingress` resources, and target groups bind directly to pod IPs (instance-mode is not used). TLS terminates at the ALB via ACM with automatic renewal — no key material in the cluster, no cert distribution to Envoy pods. Cluster-internal traffic from ALB to nginx to Envoy is plaintext in the baseline; mTLS within the cluster is documented as a future hardening upgrade rather than POC scope.

The API tier (nginx forwarder) sits between the ALB and the Envoy router. It is a thin tier — its job is to do edge work (rate limiting, header normalisation, routing-by-host-header for the few non-tenant routes such as health and signup) before traffic reaches the routing-aware tier. Splitting it from Envoy keeps the Envoy filter focused on tenant lookup and pod selection, and lets edge concerns (DDoS shaping, header rewriting) be tuned independently.

The Envoy router is where the per-tenant logic lives. Three replicas behind their own target group. Each replica runs the Lua filter that extracts `tenant_id` from the request, looks it up in the in-memory placement cache, and forwards to the pod identified in the cache row. On cache miss, Envoy reads the placement table backend with strongly-consistent semantics, populates the cache, and forwards. The three reset modes — TTL, per-entry sync invalidation, bulk flush — and the four-layer protection that makes them safe are described below.

The StatefulSet pod is the terminal hop. Its identity (`app-statefulset-primary-N`) resolves through the headless Service to a stable pod DNS name (`app-statefulset-primary-N.app-headless-svc.ns.svc.cluster.local`), which in turn resolves to the AZ-pinned pod IP. Without the headless Service, the placement table would have to carry pod IPs directly, and pod IPs change on restart, which would invalidate every placement row every time a pod cycled. The headless Service stabilises the addressing primitive against pod-IP churn; the placement table records identity (pod ordinal in cell), and DNS resolves identity to current IP at request time.

### Why ALB and only ALB at the edge

The temptation in K8s shops is to chain layers — NLB feeding Envoy directly, with Envoy handling TLS — but each additional layer adds latency, cost, and a place for misconfiguration. The architectural question is what ALB gives natively, and whether that is enough.

ALB is multi-AZ-native: subnets in three AZs produce an ALB instance in each AZ, and unhealthy AZ targets are removed automatically without DNS TTL waiting. TLS termination is solved via ACM with automatic renewal. AWS Load Balancer Controller integrates with K8s natively, and target groups can bind to pod IPs directly so traffic does not double-hop through node ports. The use case for an additional NLB layer — non-HTTP protocols or extreme client-IP-fidelity needs that ALB's `X-Forwarded-For` cannot satisfy — does not apply here. Layering an NLB in front of Envoy or behind ALB is pure overhead with no benefit.

The accepted costs are minor. ALB has per-LCU pricing (roughly $20/month per ALB plus per-LCU at low traffic), trivial against the simplicity gained. TLS terminates at ALB rather than end-to-end into the cluster, which is acceptable and standard for SaaS at this scope; mTLS within the cluster is a hardening upgrade, not a POC blocker. There is no cross-region failover at the edge — the single Route 53 A record points to one regional ALB — and cross-region DR requires manual DNS update or upgrade to Route 53 health-check failover, documented as out-of-POC.

### Routing primitive: a placement table satisfying a six-property contract

The earlier framing — `consistent_hash(tenant_id) → pod` as default, with an override-delta table holding only divergent tenants — was an over-engineered intermediate model. It looked attractive at first glance: graceful degradation if the override store was lost, small override size in normal operation, simple recovery story. The design discussion of 2026-05-08 stress-tested it against three workloads and the model broke:

1. **Every tenant ends up in the override table eventually.** Capacity-driven relocations, dedicated cells for large tenants, hot-tenant rebalances, AZ-failure standby promotion — these are not edge cases, they are the steady-state operating regime once the cluster passes ramp. After a few quarters the "delta" approaches a full table.
2. **The hash function loses its purpose.** When the override covers nearly all tenants, the hash is dead code: computed and immediately overridden. The "graceful degradation if override is lost" property is also dead — the override is the routing truth, and reconstructing it from `pod-on-disk + hash` no longer produces a useful starting point because the hash result almost never matches reality.
3. **The customer's existing system already has a tenant-to-cluster mapping.** The architecture's value-add is not "decide where the truth lives." That decision was made before this project. The value-add is to define the contract the routing primitive must satisfy, point at a POC reference backend that demonstrably satisfies it, and respect that the production system may use a different backend (Postgres, Aurora, etcd, Cassandra) that already meets the contract.

The hybrid model conflated implementation and contract. The clean model separates them.

The decision has three layers.

#### Layer 1 — The contract (six properties)

Any backend that satisfies all six is acceptable. The contract, not the backend, is what this ADR commits to:

| # | Property | Why required |
|---|---|---|
| 1 | Atomic write with CAS (compare-and-swap) | Five distinct writers (signup, failover, relocation, churn, DR) must coordinate without a lock service. CAS makes "flip target_pod from A to B only if current state is still A" expressible without a coordinator. |
| 2 | Strongly consistent reads | After a successful CAS write, the next read must see the new value. Eventual consistency would let stale reads route a flipped tenant back to the source pod. |
| 3 | Multi-AZ durable | Single-region in POC, but must survive AZ failure. RPO 0 for placement state — losing a row means losing a tenant's address. |
| 4 | Low read latency on hot path (cached or <10 ms p99) | Envoy reads on every request. Direct backend hit per request would add 5-10 ms; in-memory cache plus invalidation is mandatory. The contract permits cached architectures. |
| 5 | CDC / change-stream capability | Required for fail-safe async cache invalidation. Without CDC, cache TTL is the only invalidation path, and the stale window is bounded only by TTL. |
| 6 | Audit log | Every placement change must be reconstructable: who wrote, what changed, when. Tenant-routing is operationally sensitive; an unauthored row is a 5xx without forensics. |

The contract is opinionated about CAS and audit. A backend that prefers CAP-availability over consistency (Cassandra without LWT, for instance) does not qualify. This is intentional: routing must be linearisable from the writer's view.

#### Layer 2 — The POC reference backend (DynamoDB)

For the take-home POC, DynamoDB is the reference backend. Schema:

```
PlacementTable
  PK: tenant_id (string)
  Attributes:
    primary_pod          string  e.g. "app-cell-3-pod-2"
    standby_pod          string  e.g. "app-cell-7-pod-2"
    state                enum    IDLE | PRE_FLIP_SYNCING | ATOMIC_FLIP |
                                 SOAK_PENDING_BACKUP | SOAK_PENDING_STANDBY |
                                 SOAK_COMPLETE | CLEANUP_DONE | ROLLBACK
    pending_source_pod   string  used during relocation soak
    flip_at              ISO8601 timestamp of atomic flip
    cleanup_eligible_at  ISO8601 timestamp = flip_at + 24h floor
    last_writer          string  IRSA principal that wrote
    version              number  monotonic, used for CAS

  Streams: NEW_AND_OLD_IMAGES enabled (for cache invalidation fan-out)
  Encryption: dedicated KMS key (per-tier, see ADR-07)
  Backup: PITR enabled
```

Backend matrix — what qualifies under the contract:

| Backend | CAS | SC reads | Multi-AZ | Low latency | CDC | Audit | Verdict |
|---|---|---|---|---|---|---|---|
| **DynamoDB** | ConditionExpression | ConsistentRead=true | regional, 3-AZ | 5-10 ms (cached <1 ms) | DynamoDB Streams | CloudTrail data events | **POC choice** |
| Aurora (Postgres) | SERIALIZABLE | yes | regional, 3-AZ | 5-15 ms (cached) | logical replication | RDS audit + CT | qualifies |
| Postgres self-hosted | SERIALIZABLE | yes | depends on deploy | depends | logical decoding | pg_audit | qualifies if HA-deployed |
| etcd | mvcc + revision | yes | quorum across AZs | <10 ms | watch API | requires custom audit | qualifies |
| Cassandra (LWT) | lightweight transactions | quorum reads | yes | 10-20 ms | CDC framework | requires custom audit | qualifies but LWT is expensive |
| Redis | WATCH/MULTI/EXEC | single primary | with Sentinel/Cluster | <1 ms | keyspace notifications (best-effort) | none built-in | **partial** — no audit, weak CDC |
| ConfigMap (etcd via API) | resourceVersion CAS | yes | quorum across AZs | etcd-tier | watch | API audit | qualifies for tiny tables only (<1 MB) |

Redis is rejected as a sole backend because it fails property 6 and weakly satisfies property 5. Redis as a cache layer in front of DynamoDB is fine and is documented as an upgrade trigger.

The POC chooses DynamoDB because the cost is negligible at the relevant scale (~$5-50/month with cache hit rate above 99%), backup and encryption and audit are all native (PITR, KMS, CloudTrail data events), and Streams give a clean fan-out path for async cache invalidation. Self-hosted alternatives would cost more in operator time than the savings on the line item.

#### Layer 3 — Envoy cache, three reset modes, four-layer protection

Envoy reads placement on every request. A direct DynamoDB hit per request would add 5-10 ms p99 — unacceptable for a hot path. The architecture inserts an in-memory cache per Envoy replica via the Lua filter:

```
Envoy request flow:
  1. Extract tenant_id from request (URL / subdomain / JWT)
  2. Cache lookup → tenant_id
     2a. Hit → forward to cached pod_dns
     2b. Miss → DynamoDB ConsistentRead → cache → forward
  3. Cache write-through with TTL
```

Three reset modes — all three are mandatory:

| Mode | Mechanism | Latency | Use case |
|---|---|---|---|
| TTL passive expiry | per-entry TTL=300s default | up to 5 min | background freshness; safety net |
| Per-entry sync invalidation | Envoy admin: `POST /placement_cache/invalidate {tenant_id}` | sub-second across all 3 replicas | mandatory atomic step in relocation flip |
| Bulk flush | Envoy admin: `POST /placement_cache/flush` | sub-second | operator nuclear option |

Four-layer protection (defence in depth for cache freshness):

```
Layer 1 — Per-entry sync invalidation     (primary, sub-second)
Layer 2 — TTL passive expiry              (secondary, 5 min bound)
Layer 3 — Stream async invalidation       (tertiary, ~1-5 s)
Layer 4 — Bulk flush                      (nuclear, manual)
```

Layer 3 is the fail-safe: DynamoDB Streams → Lambda → fan-out to all Envoy admin endpoints. If Layer 1 sync invalidation fails for any replica (network partition, Envoy restart in progress), Layer 3 catches it within seconds. If Layer 3 is also broken (Lambda error, Stream lag), Layer 2 TTL is the bound. Layer 4 is the human escape hatch — partial-invalidation failure, suspected cache corruption, post-incident reset.

### The five writers, and why Envoy is read-only

The placement table is read by Envoy on every request, written only at lifecycle events:

| Writer | Trigger | What it writes |
|---|---|---|
| Signup | new tenant onboarded | new row: primary + standby + state=IDLE |
| Failover | AZ failure cold-DR rehydration | update: primary ← rehydrated pod |
| Relocation (ADR-05) | tenant size / rate trigger | multi-step state machine through PRE_FLIP_SYNCING → ATOMIC_FLIP → SOAK_* → CLEANUP_DONE |
| Churn | tenant offboarded | DELETE row |
| DR recovery | cluster recovery from backup | reconstruct from pod-on-disk truth |

Envoy is read-only against the placement table. This is non-negotiable.

Two clocks run at very different speeds. **Session ID** is identity proof — short-lived, typically about 24 hours, validated per request, re-issuing constantly. **Tenant-to-pod binding** is data ownership — long-lived, years. The binding outlives session identity by four to six orders of magnitude. If Envoy wrote on session creation, the placement decision would be made by request traffic instead of by the placement model: capacity decisions, relocation policy, and DR would all race against session establishment. That is the anti-pattern this architecture rejects.

The five writers each correspond to a deliberate, infrequent, audited operation. None of them happens in the request path. None of them is Envoy.

The separation is non-negotiable for four reasons:

- **Stateless proxy principle.** Envoy runs three replicas. Concurrent writes from different replicas would race; CAS conflicts would appear under load with no semantic meaning. Stateless proxy means no state to race over.
- **Separation of concerns.** Routing is identity-derived (where does this tenant live), not capacity-derived at request time (which pod has headroom right now). Capacity belongs in placement decisions made out-of-band, then expressed as placement rows.
- **Audit and rollback.** Every placement change carries a `last_writer` IRSA principal and a CloudTrail entry. If Envoy could write, rows would accumulate without provenance.
- **Recovery determinism.** DR recovery reconstructs the table from pod-on-disk truth precisely because pod-on-disk is the ground truth. If Envoy were a writer, the placement store would diverge from pod-on-disk over time, and the reconstruction would no longer be sound.

The mental model: **Envoy is a routing decision engine. It looks up where to send a request. It never decides where a tenant lives.**

### Lookup miss handling — 503 semantics as architectural integrity check

When Envoy receives a request for a `tenant_id` not found in either local cache or the placement backend, the only correct response is `503 Service Unavailable` with `Retry-After: 30`. Never fallback to "any pod" or "default pod."

Three legitimate paths into this branch exist:

| Trigger | Window | Resolution |
|---|---|---|
| Relocation atomic flip in flight | ~500 ms during the flip step | client retry after 30s succeeds |
| Tenant signup race | a few seconds — auth issued token before placement service wrote entry | client retry after 30s succeeds |
| System bug (auth issued token, placement entry never written) | indefinite | client retry stays 503; alert fires; operator investigates |

The reason 503 is correct rather than fallback is architectural integrity. Auth passing means identity is verified. It does not mean the system knows where this tenant lives. Three states are distinct: authenticated and placed (serve 200), authenticated and not placed (503, system is mid-flight or broken), not authenticated (401, separate concern).

If Envoy fell back to "pick any pod" on lookup miss:

- The wrong pod would accept writes for an unknown tenant.
- LevelDB on that pod would gain data with a foreign tenant_id.
- When relocation eventually completed (or signup race resolved), routing would flip to the *intended* pod, which would not have those writes.
- Silent data loss plus split-brain — the P1 violation that the entire architecture is designed to prevent.

503 is the correct architectural integrity check: refuse to serve until system state is consistent. Cost is brief client retry latency; alternative is silent corruption.

The Lua filter on lookup miss returns HTTP 503 with `Retry-After: 30` and a JSON body `{"error": "tenant placement in flight or not registered"}`, and emits the metric `routing_lookup_miss_total{tenant_id, reason="not_placed"}`. If the rate sustains above 10/sec for any tenant for more than one minute, the operator is paged — the relocation race window is sub-second and will not sustain that rate, so a sustained signal means the third path (real bug) is in play.

## Trade-offs accepted

- **5-10 ms DynamoDB read on cache miss.** Mitigated by cache hit rate above 99% in steady state, lower on cold start and post-flush. Measured at admission; degraded modes documented.
- **Cost ~$5-50/month depending on traffic and TTL.** Knob: increase TTL → fewer backend reads → lower cost, longer stale window. Default TTL 300s.
- **Stream-based async invalidation has 1-5 s lag.** This is the Layer 3 fallback, not the primary path. Layer 1 (sync invalidation in flip step) targets sub-second.
- **Cross-region replication not in POC baseline.** DynamoDB Global Tables is the upgrade trigger. Single-region for POC.
- **Schema evolution requires coordinated deploy.** DynamoDB is schemaless for new attributes, but state-machine value changes (new states) require writers updating first and readers tolerating unknown values during the deploy window.
- **The contract is opinionated about CAS and audit.** A backend that prefers availability over consistency does not qualify.
- **TLS terminates at ALB.** Cluster-internal traffic from ALB to nginx to Envoy is plaintext in the baseline. Acceptable and standard at this scope; mTLS within the cluster is a hardening upgrade.
- **No cross-region failover at the edge.** Single Route 53 A record points to one regional ALB. Cross-region DR requires manual DNS update or Route 53 health-check failover, documented as out-of-POC.
- **Three-tier flow has one extra hop versus minimum.** ALB → nginx → Envoy → pod has four hops where ALB → Envoy → pod would have three. The extra hop is paid to keep edge concerns out of the routing-aware tier; the latency cost is small (≈1 ms) and the operational separation is worth more.

## Alternatives considered

- **Pure consistent hash, no placement table at all.** Every routing decision is `hash(tenant_id) mod N`. Rejected because adding or removing pods rebalances 1/N of tenants per change, which is unacceptable for a per-tenant-pod model where each tenant has 100-1000 GB of LevelDB on a specific EBS volume. Rebalance equals data migration of TB scale.
- **Hash plus override-delta (the superseded model).** Default to hash, exceptions in a small override table. Rejected because the override grows to nearly 100% of tenants in steady state; the hash becomes dead code; recovery from pod-on-disk loses its hash starting point.
- **Per-pod hash ring (rendezvous / HRW).** Each pod has a weight; tenant routes to highest-scoring pod. Rejected because it is still tenant-rebalancing on weight changes and does not compose with cell-aware placement, where capacity and tenant locality decisions are not weight-expressible.
- **Pure Redis lookup as primary writer.** Every tenant-to-pod mapping in Redis. Rejected because it fails property 6 (audit) and CAS in Redis (`WATCH/MULTI/EXEC`) is awkward as a primary writer pattern. Acceptable as a cache layer in front of a contract-compliant backend.
- **ConfigMap-only (no external store).** Single source of truth in a git-tracked ConfigMap. Rejected at production scale because ConfigMap's 1 MB limit caps at ~10-20K tenants depending on row size; updates require ConfigMap edit and Envoy reload; CAS expressed via resourceVersion is workable but no CDC for cache invalidation. Acceptable as the absolute-minimum POC fallback if the team rejects DynamoDB and has no other backend.
- **Standalone placement service (microservice with its own DB).** Custom service with REST/gRPC API; encapsulates the contract. Rejected for POC because the contract is what matters, not whether a service wraps it. If the team prefers a service abstraction later (multi-region, custom routing logic, complex tenant policies), this is the upgrade path.
- **NLB → Envoy at the edge.** NLB as the public layer, route directly to Envoy. Rejected because NLB is L4, doesn't terminate TLS (would have to terminate at Envoy with cert distribution headache), and is not HTTP-aware for health-check. The NLB use case is non-HTTP or extreme client-IP-fidelity needs; neither applies here.
- **ALB → NLB → Envoy.** Both layers. Rejected as pure overhead with no benefit.
- **Envoy directly on public ENI, no ALB.** Envoy pods get public IPs, Route 53 round-robin DNS. Rejected because Envoy pod failure equals bad client experience due to DNS TTL caching prolonging the outage. ALB removes unhealthy targets in seconds; DNS would take minutes.
- **Route 53 health-check + failover policy as multi-AZ mechanism.** Use DNS-level failover instead of ALB's per-target health. Rejected because Route 53 is per-DNS-query and cached resolvers extend the failure window. ALB's per-request target health is much faster.

## Out of POC scope (upgrade triggers)

- **Cross-region sharding via DynamoDB Global Tables.** Trigger: multi-region active-active. Implementation: Global Tables (~1 s replication lag) plus region-pinned routing prefix in tenant_id.
- **Secondary indexes on the placement table for tenant lookup by pod.** Trigger: operational queries like "list all tenants on pod-3." Today: DynamoDB Scan with FilterExpression — slow but acceptable for off-hours operator queries.
- **GraphQL/gRPC service abstraction.** Trigger: routing logic needs to encapsulate complex policies (tenant tiering, cost-class routing).
- **Hot-path Redis cache layer in front of DynamoDB.** Trigger: cache miss rate above 1% sustained (very long tail of low-traffic tenants evicted from per-Envoy cache).
- **Cross-region failover via Route 53.** Trigger: customer SLA demands sub-2h cross-region RTO. Add a second regional ALB plus Route 53 failover policy.
- **WAF in front of ALB.** Trigger: regulatory or threat-model requirement. Adds AWS WAF as ALB integration; cost scales with rule count.
- **mTLS cluster-internal.** Trigger: zero-trust requirement at internal hops. Consider Istio / Linkerd at that point.

## Stage 3 questions

| # | Question | Why it matters |
|---|---|---|
| 1 | Where does the existing system store tenant-to-cluster mapping today (Postgres? Internal service? Redis?) | Determines whether we adopt the existing backend or run DynamoDB in parallel. |
| 2 | Does the existing backend satisfy the six-property contract — specifically, CAS support and CDC capability? | If yes, adopt. If partial, the gap is a concrete conversation, not an architecture rewrite. |
| 3 | Where is the tenant identifier carried in the request — URL path, subdomain, JWT? | Determines the Envoy extraction expression. |
| 4 | Cache invalidation TTL preference. | Default 300 s. Tighter (60 s) costs more in backend reads; looser (600 s+) tolerates longer stale windows. |
| 5 | Writer concurrency expectation. | Five writer classes assumed; if more (multiple tenant-management UIs writing concurrently), CAS retry semantics need explicit policy. |
| 6 | Existing tenant_id format — UUID, slug, integer? | Affects partition key cardinality and DynamoDB hot-partition risk. |
| 7 | TLS certificate strategy: ACM-managed (recommended) or external CA with manual rotation? | Confirms ALB integration approach. |

## Cross-references

- ADR-01 (architecture and topology) — establishes the per-tenant pod model and the single-master-AZ topology that this ingress design routes into.
- ADR-02 (storage and PV mapping) — pod identity (`app-statefulset-primary-N`) is the value the placement table records and the headless Service resolves.
- ADR-04 (backup, DR and HA) — owns the cold-DR rehydration that the failover writer triggers; the warm-standby AZ is the recovery destination, not a live routing target.
- ADR-05 (migration / Strangler Fig) — primary writer of the placement state machine during relocation; the CAS, sync invalidation, and soak gate semantics live there.
- ADR-06 (observability) — the routing-lookup-miss alert and the cache hit-rate dashboards.
- ADR-07 (security and runtime) — IRSA principals for the five writers; the dedicated KMS key for the placement table at rest; network policies governing Envoy admin endpoint access.
- ADR-08 (CI/CD and GitOps) — Envoy Lua filter and admin endpoint config flow through the GitOps pipeline.
- ADR-10 (FinOps) — DynamoDB on-demand cost tracked in cost dashboard; ALB per-LCU pricing.

(Originally split across private ADR-009-routing-placement-table / ADR-009-consistent-hash-override-delta / ADR-010; consolidated 2026-05-09. The earlier hash-plus-override-delta ADR is retained in the private archive only for the trade-off discussion.)
