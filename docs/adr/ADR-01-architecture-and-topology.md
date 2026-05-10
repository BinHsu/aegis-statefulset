# ADR-01: Architecture & topology

## Status
Accepted (POC submission scope; subject to confirmation in Stage 3 conversation)

## Context

LevelDB is a single-writer, file-based, embedded key-value store with no native replication. That one fact constrains every architectural decision in this repo: a tenant's database lives in exactly one set of files on exactly one disk on exactly one pod at any moment. There is no distributed-storage primitive to lean on, no leader election to coordinate, no consensus protocol to fall back on. The architecture's job is to make this constraint operate cleanly at multi-tenant SaaS scale.

The customer ships a low-code platform: each customer holds isolated business data in one or more LevelDB instances. Pod density varies enormously — from a 100 MB hobbyist tenant to a 500 GB enterprise tenant on the same fleet. The architecture must accommodate that range without a separate code path per tier. The cost envelope is recognisably Mittelstand: every node, every NAT, every gigabyte of S3 lands on a monthly invoice that engineering and finance read together. The submission's job is to give the customer a small set of well-named knobs that trade cost against availability — not a pre-decided answer.

This ADR fixes the topology that makes those constraints workable. It is the foundation every other ADR builds on.

## Decision

1. **Per-tenant pod identity.** Each tenant resolves to one specific pod via the placement table (ADR-03). Cohort packing for small tenants (one pod hosts many tenants); dedicated pod for the enterprise tier (one pod hosts one tenant). Per-tenant identity is the *routing* identity — the inside-the-pod data layout (Pattern 1 shared LDB with key prefix vs Pattern 2 per-tenant folder) is application architecture, with cascading consequences documented in ADR-04.
2. **Single master AZ at any moment.** All workloads — stateful and stateless — pinned to one master AZ via `nodeAffinity`. AZ-B and AZ-C are warm-standby AZs: subnet provisioned, NAT Gateway running, EKS managed node group at `desiredSize=0`. A rotation event (planned or AZ failure) scales the standby AZ's node group up via `aws eks update-nodegroup-config`; no `terraform apply` is required. The cost of "ready to rotate" is one NAT per standby AZ, not one node pool per standby AZ.
3. **Cell-based capacity unit.** A cell = one stateful pod + its retained EBS Snapshots + its placement-table rows. POC default `cells.count=1`. Production scale matches the customer's existing partitioning. Cells are added one at a time via Strangler Fig migration (ADR-05); the migration runbook is the same shape as the legacy-to-K8s cutover, only the source changes.
4. **3-tier request flow.** ALB (regional, TLS termination, host-routing) → API tier (stateless nginx forwarder, autoscaled, auth + business logic) → Envoy router (Lua filter, placement-table lookup, 3-mode cache invalidation) → StatefulSet pod (state). Each tier in its own namespace with NetworkPolicy boundary (ADR-07). The decoupled router tier is the industry-standard pattern for stateful sharded systems — Lyft, Stripe, Reddit's shard router, Vitess `vtgate`, the DynamoDB request router all run the same shape.
5. **Microservices, not multi-container pods.** Each component (api / envoy / stateful / Velero / observability) is its own Deployment or StatefulSet — independently scalable, individually observable, separately rollback-able. No multi-container "kitchen sink" pods that conflate failure domains.
6. **Internal LDB layout is application architecture, not platform.** The platform supports both Pattern 1 (shared LDB, key prefix) and Pattern 2 (per-tenant folder). Pod identity is the routing primitive; internal layout is a downstream choice the application team owns. Capability matrix in ADR-04 § "LDB layout — what each pattern enables".

## Why

- **LevelDB physics make per-tenant pod identity the only consistent shape.** Hash-sharding a single tenant's database across pods would require a distributed K-V layer above LevelDB — effectively reimplementing Cassandra or FoundationDB for one customer's POC. Out of scope for a stateful POC and arguably an anti-feature for a low-code platform that values data isolation per customer. Per-tenant identity is what the storage primitive is asking for.
- **Single master AZ matches the cost model.** Cross-AZ chatter on a stateful tier with no cluster-aware replication is wasted latency *and* double cost. Inter-AZ traffic is metered; running stateful pods in three AZs simultaneously triples the egress without buying any availability that cold DR (ADR-04) doesn't already deliver. Warm-standby AZs are pre-provisioned topology, not running compute — they cost the price of one NAT each (~€33/month) plus subnet IP space, and they buy the ability to rotate at runtime without touching Terraform.
- **Cells make capacity expansion linear and migration-symmetric.** Each cell has its own EBS Snapshot lineage, its own placement-table rows, its own backup schedule key. Adding capacity = adding a cell. Migrating from legacy = filling cells one at a time via Strangler Fig (ADR-05). Re-balancing = moving tenants between cells via the placement table (ADR-03). Three operations, one primitive, one runbook shape.
- **3-tier flow decouples concerns that scale at different rates.** ALB is regional and stateless; auth/business logic in the API tier scales on CPU and request rate; Envoy scales with route table size and request rate (cache hit ratio matters here); the stateful tier scales 1:1 with EBS volumes. Collapsing routing into the API tier mixes cache invalidation logic with business logic; service-mesh sidecar handles east-west well but not "consult an external DB to determine destination pod." A dedicated router tier is what these requirements actually need.
- **Microservices keep blast radius bounded.** A multi-container "kitchen sink" pod conflates failure domains and obscures observability. Five small Deployments are easier to reason about than one wide pod, and the K8s primitives (HPA, PDB, NetworkPolicy, PSS labels) are designed to operate at the workload level, not the container level.

## Trade-offs accepted

- **Master AZ failure = full RTO event** (~25 min via Velero restore in standby AZ). Multi-AZ active-active stateful would shave this to ~5 min but requires a distributed K-V replacement for LevelDB — an upgrade trigger documented below, not a POC choice. The spec is silent on RTO; ~25 min is our chosen architecture target (Mittelstand-grade design judgment for a SaaS where downstream customers run their own businesses on top); Stage 3 conversation should validate against the customer's actual operational tolerance.
- **Cohort packing creates noisy-neighbour boundaries at the pod level.** Multiple tenants sharing a pod share LevelDB compaction, OS page cache, EBS IOPS budget. Requires per-cohort sizing and per-tenant size telemetry; the customer pays in tuning effort, not customer-facing latency, *if* the sizing is honest. The capability matrix in ADR-04 spells out which observability layers Pattern 1 vs Pattern 2 affords.
- **Cell expansion is operator-driven, not auto-rebalancing.** Auto-rebalancing for a stateful per-tenant tier is materially more complex than the value it delivers at the customer's likely scale (a few cell expansions per quarter at most). Upgrade trigger documented if the rate exceeds that.
- **3-tier flow adds one network hop per request** vs collapsing routing into the API tier. Worth it for cleaner observability + cache invalidation + tenant traffic shaping concentrated in one tier — and the hop is intra-AZ, sub-millisecond.
- **Master AZ asymmetry over cluster lifetime.** After several rotations, the operations team must keep all three AZ node groups patched and ready even when the cluster has only ever served from one of them. A discipline cost, not a runtime cost.

## Alternatives considered

- **Hash-sharded LevelDB across pods.** Rejected — would require building a distributed K-V layer above LevelDB, effectively reimplementing Cassandra. Out of scope; arguably an anti-feature for a per-tenant SaaS.
- **Multi-AZ active-active stateful pods.** Rejected — LevelDB has zero native sync APIs; "active-active" is impossible without a different storage layer. Rejecting at this level avoids the same rejection echoing through ADR-03 (routing) and ADR-04 (DR).
- **Multi-container pod with sidecars for routing + business logic.** Rejected — conflates failure domains, obscures observability. K8s primitives operate at the workload level; multi-container pods break that abstraction without buying anything.
- **Service mesh (Istio / Cilium SM) handling tenant routing via sidecar.** Rejected for POC scope — service mesh handles east-west traffic well but not "consult an external DB to determine destination." Implementing tenant routing as a Wasm extension or EnvoyFilter inside a mesh sidecar is operationally heavier than a dedicated Envoy router tier.

## Out of POC scope (upgrade triggers)

- **Distributed K-V replacement for LevelDB.** Trigger: customer SLA demands sub-5-min RPO or multi-region active-active. Reach for FoundationDB / Cassandra / Scylla; this whole architecture changes shape.
- **Auto-rebalancing operator across cells.** Trigger: more than 2 manual cell expansions per quarter. Build operator with explicit gates (Slack approval / two-person rule / scheduled maintenance window).
- **Multi-master (multiple active master AZs simultaneously).** Trigger: throughput or geographic latency demands a single AZ cannot satisfy.
- **Per-tenant pod isolation at the kernel level (one tenant = one pod, never cohort).** Trigger: regulatory requirement that tenant workloads cannot share OS page cache or kernel resources.

## Stage 3 questions

- Confirm legacy is per-tenant rather than hash-sharded. Most likely per-tenant given LevelDB physics, but the spec doesn't pin it; if sharded, the migration spec changes substantially.
- Pod density distribution — many small tenants (cohort default) or enterprise dedicated profile dominant? Determines whether `values.yaml` sizing defaults reflect cohort or dedicated topology.
- LDB layout (Pattern 1 vs Pattern 2). Cascades to relocation tooling cost (ADR-04 capability matrix); spec doesn't pin it.
- Master AZ choice — operator pin via `master_az` value, or pick whichever AZ has cheapest spot capacity at provisioning time?
- Multi-container vs microservice preference — confirm the customer's existing fleet is microservice-shaped; if monolithic, the 3-tier flow assumption needs re-examination.

## Cross-references

- *(originally split across private ADR-001 / ADR-002 / ADR-003 / ADR-004 / ADR-005 / ADR-006 / ADR-045 / ADR-046; consolidated 2026-05-09)*
- ADR-02 — storage primitives (EBS + LVM + retain) underpinning per-pod state
- ADR-03 — routing primitive (placement table is the per-tenant identity resolver)
- ADR-04 — backup, DR & HA (cold DR is the consequence of single-writer LevelDB physics; LDB layout matrix lives there)
- ADR-05 — migration (Strangler Fig, cell-based)
- ADR-07 — security & runtime (NetworkPolicy boundaries reflect the 3-tier flow; PSS restricted at namespace level)
