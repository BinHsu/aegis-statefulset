# Future plan — TiKV as the distributed K-V upgrade path beyond LevelDB

> **Status:** Future plan. Out of POC scope. Requires explicit customer approval before any execution.
> **Why this doc exists:** ADR-04 names "distributed K-V replacement for LevelDB" as the upgrade trigger when SLA outgrows what LevelDB physics can deliver. This doc names *which* distributed K-V, *what* the migration costs, and *under what conditions* the customer should consider it. Reading this is not the same as committing to it — that's a separate conversation.
> **Reading order:** ADR-01 first (the constraints LevelDB physics impose), then ADR-04 (cold DR as the consequence), then this doc.

---

## 1. Why a distributed K-V is even on the table

The current architecture chose cold DR via Velero + EBS Snapshot precisely because **LevelDB has zero native sync APIs** — there's no leader election, no log shipping, no quorum primitive. A "warm" replica is, in practice, a snapshot copy with the replica running idle. That's why active-passive multi-region was rejected in ADR-04.

But the cost of *that* trade-off is bounded:

- **AZ failure RTO** is ~25 min (Velero restore in standby AZ).
- **Region failure RTO** is ~50 min (cross-region snapshot restore).
- **RPO** is ~30 sec at the 5-min cadence default.

RPO ~30 sec is well inside the spec's ≤ 6-hour RPO budget. Spec is silent on RTO; both AZ and region RTO are inside our chosen design target (~25 min AZ failure / ~50 min region). Cold DR is the *structurally honest* shape for LevelDB at that target.

The trigger to reconsider isn't "we want better numbers" — it's a hard constraint change. Three concrete triggers:

1. **Customer SLA tightens to sub-5-min RPO.** Cold DR cannot deliver this with LevelDB; WAL shipping or distributed consensus would be required.
2. **Customer SLA demands sub-15-min cross-region RTO.** Same — cold DR's restore time is dominated by snapshot import, which is bounded below by AWS's primitives.
3. **Multi-region active-active becomes a product requirement** — both regions must accept writes, not just serve reads from a hot replica.

Until one of those triggers fires, this doc is reading material, not a roadmap.

---

## 2. What TiKV delivers (multi-AZ HA)

TiKV is the canonical distributed K-V in the open-source space. Its design choices map directly onto the multi-AZ HA gap that LevelDB cannot fill.

### Three load-bearing facts

1. **Raft + 3-replica quorum.** TiKV writes 3 replicas across 3 AZs; writes ACK after 2/3 quorum. AZ failure → other 2 still serve; millisecond-level leader re-election; RTO ≈ 0, RPO = 0.

2. **Placement Driver (PD) topology awareness.** PD reads K8s node labels (`topology.kubernetes.io/zone=eu-central-1a`) and enforces replica spread across failure domains. Same-AZ duplicate replica → PD migrates it elsewhere automatically.

3. **Storage simplification at the platform layer.** Application-layer replication releases the *platform* from cross-AZ EBS pain. Single-AZ gp3 (or local NVMe) per pod is sufficient. Pod migration → new pod attaches empty disk, TiKV rebalances data from peers automatically. The "Velero restores PVC" mechanism the current architecture relies on becomes unnecessary at the application data layer.

### What this means for the current architecture

- ADR-01's single-master-AZ topology becomes unnecessary; TiKV would run multi-AZ with PD-managed replica placement.
- ADR-04's cold-DR posture becomes redundant for AZ failure; would still apply for region failure (see § 4).
- ADR-02's EBS gp3 + LVM + Retain stays, but the per-tenant pod model changes shape — TiKV's Region (96MB shard) is the unit, not the per-tenant pod.

---

## 3. What it COSTS to migrate

This is **architecture-level refactoring, not a "drop-in upgrade"**. LevelDB and TiKV are family-related (TiKV's storage engine is RocksDB, evolved from LevelDB), but their system design is on different dimensions.

### 3a. Why no "just mount the LevelDB files in TiKV"

| Dimension | LevelDB | TiKV |
|---|---|---|
| Sharding | Single SSTable set on local disk | Data sliced into ~96MB Regions managed by PD |
| Replication | None — single writer | Raft consensus across 3 replicas |
| Interface | Embedded library; in-process function calls | Standalone network service; gRPC over the wire |
| Latency | Microsecond local | Millisecond network async (Raft round-trip) |

TiKV at startup cannot read a LevelDB bundle as-is. There is no Raft log in LevelDB files. The application code has to change.

### 3b. Layer 1 — application code refactoring

Every LevelDB call site in the application must change to TiKV Client (officially supported: Go, Rust, Java; community: Python, others). Beyond the API change:

- **Latency profile flips** from microsecond local to millisecond network async. Error handling, retry, timeout logic need to be added or revisited at every call site.
- **Connection management** appears where it didn't exist before. TiKV Client maintains a pool of gRPC connections to the cluster; the application must reason about pool sizing, idle timeout, retry-on-leader-change.
- **Transaction boundaries** become explicit. LevelDB has WriteBatch; TiKV has both pessimistic and optimistic transactions with conflict detection. The application's existing concurrency assumptions may need to change.

Estimated effort: weeks-to-months of focused application work, depending on the call-site count and how transactional the existing code is.

### 3c. Layer 2 — data migration (two operational shapes)

**Cold migration** — for small data volumes + tolerable downtime:

1. Stop application writes (declared downtime window).
2. Run a one-shot migration script: open old LevelDB, iterate K-V pairs, batch them via TiKV Client `Put`.
3. Verify count match.
4. Start the new application against TiKV.

This is the simplest operationally but requires the customer to accept a downtime window proportional to the data volume.

**Dual-write + backfill** — for zero-downtime requirements:

1. Modify application to write to *both* LevelDB and TiKV (dual-write); reads continue against LevelDB as source of truth.
2. Run a background backfill process that copies pre-dual-write data from LevelDB → TiKV.
3. Verify both stores consistent (sample-based or full diff).
4. Switch reads to TiKV.
5. Disable dual-write; retire LevelDB.

This is the production-typical pattern for stateful migration at scale. Implementation effort: weeks for the application changes, weeks-to-months for the backfill at scale.

---

## 4. Multi-region active-active — TWO distinct paths

When the trigger that brought us here is *multi-region active-active* specifically (not just multi-AZ HA), TiKV alone is not the answer. **The CAP trade-off becomes the dominant decision.**

### Physics first

| Topology | Typical RTT | Raft round-trip impact |
|---|---|---|
| Multi-AZ within one region | 1–2 ms | Essentially free; latency floor unchanged |
| Multi-region within one continent (e.g., Frankfurt + Dublin) | 20–30 ms | Every write pays one round-trip |
| Cross-continent (e.g., Frankfurt + US East) | 100+ ms | Every write pays 100+ ms |

Raft is strong-consistency: a write must wait for cross-region quorum ACK. Naive multi-region Raft → write latency goes from microseconds to 100+ ms. Destructive for most SaaS write paths.

### Path A — Geo-close 5-node 3-region Raft (strong consistency)

Valid only when both regions are geographically close and the workload absolutely requires strong consistency:

- Pick 3 close regions (e.g., AWS Frankfurt `eu-central-1` + Paris `eu-west-3` + Milan `eu-south-1`).
- Deploy 5 replicas: 2 in Frankfurt, 2 in Paris, 1 in Milan.
- TiKV `Placement Rules` pin Leaders to the home region.
- A Frankfurt user write needs only Frankfurt's other replica + nearby Paris ACK → ~10–20 ms latency window.

Cost: very high (5 nodes vs 3), architecture very complex, only valid where the regions actually are geographically close. Cross-continent does not work this way.

### Path B — Async replication via TiCDC (eventual consistency)

The mainstream pattern for cross-continent active-active:

- Each region runs an independent multi-AZ-HA TiKV cluster (low local latency).
- **TiCDC** (TiDB Change Data Capture) streams the change log asynchronously across regions, replays at the other side. Bidirectional sync possible.

Trade: dropped from strong consistency to **eventual consistency**. Same-key write conflicts in tight time windows need timestamp-based resolution.

This is the production-typical pattern for multi-region active-active in the cross-continent case. The CAP cost is real and visible to the application — the application must tolerate eventual consistency at the inter-region boundary.

---

## 5. Three soul-search questions before committing

When product / CTO floats "multi-region active-active":

1. **Do we genuinely need cross-continent strong consistency?** Often the real requirement is regional DR, not bidirectional active-active — answered cheaper with active-standby or async replication via TiCDC.
2. **If write latency moves from 2 ms to 50 ms, can the application stack survive?** Many apps written for LevelDB latency profile will saturate connection pools at 50 ms and avalanche.
3. **What's the cross-region traffic budget?** AWS cross-region pricing is materially higher than cross-AZ. Bidirectional active-active log sync at scale produces significant bills.

The honest senior framing is: *name the trigger, name the CAP cost, and don't promise TiKV "automatically" solves multi-region active-active*. It solves it explicitly through TiCDC, with eventual-consistency cost.

---

## 6. Decision criteria — when to consider this seriously

| Trigger | Honest response |
|---|---|
| AZ failure RTO ~25 min is too long | TiKV multi-AZ HA. ~Months of refactoring + migration. RTO drops to ≈ 0. |
| RPO ~30 sec at 5-min cadence is too loose | TiKV (RPO = 0) — same scope as above. |
| Region failure RTO ~50 min is too long | Multi-region active-active via Path A or Path B above. Larger scope; CAP-side decision. |
| Multi-region read locality (latency for global users) | Read replicas — not necessarily TiKV. Consider regional caches first; TiKV only if writes also need to be regional. |

If none of these triggers is firing, this doc is reading material — there is no upside to migrating that justifies the cost.

---

## 7. Alternatives to TiKV

TiKV is the canonical reference but not the only option. Trade-off profiles:

- **CockroachDB** — SQL on top of similar Raft-based KV. Right answer if the application would prefer a SQL surface; same physics for cross-region.
- **ScyllaDB** — Cassandra-shape; eventually-consistent by default. Right answer for very high write throughput at the cost of giving up strong consistency by default.
- **FoundationDB** — Enterprise transactional KV. Right answer for very strict consistency + transaction requirements; smaller community.
- **AWS DynamoDB Global Tables** — Managed, no operational burden. Right answer if the customer is willing to accept vendor lock-in and the eventual-consistency model. Notably, this is what ADR-03 already uses for the placement table — extending it to the application data layer is the lowest-effort but highest-lock-in path.

The choice is "which CAP corner + which operational model + which ecosystem" — not "TiKV is the only answer."

---

## 8. What this doc is NOT

- **Not a commitment.** Reading this doesn't mean we'll execute it.
- **Not a near-term plan.** Estimated work is months, requires customer-side application refactoring as the dominant cost.
- **Not a recommendation against the current architecture.** Cold DR via Velero is correctly chosen for the current RPO/RTO budget. This doc exists to name what *would* change if the budget changes.
- **Not a migration runbook.** A real migration would require its own design doc, runbook, dry-run plan, and customer approval.

---

## 9. If the customer asks "should we plan this for next year"

The right answer is: **let's identify what we'd need to know first**.

- Current production RTO / RPO observed numbers vs the spec budget — are we under-utilising the budget, or pressing against it?
- Application call-site inventory — how many places talk to LevelDB directly? That's the refactoring surface.
- Latency budget at the application's hot path — what does the app do today that would change shape at 1–2 ms write latency?
- Cost model — what's the cross-AZ traffic baseline today, and what would 3-replica TiKV add to it?

Those four numbers, captured during normal operations of the current architecture, are the prerequisite for an honest TiKV decision conversation.

Until they exist, "we'll move to TiKV next year" is aspiration, not plan.
