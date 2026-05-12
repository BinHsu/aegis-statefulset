# Future-plans — evolution paths, triggers, cost trajectories

> **Scope:** The architecture in `helm/` + `infrastructure/` is shipped at
> ONE operating point — POC scale, `cells.count=1`, single master AZ, cold
> DR via Velero. This directory documents how that operating point evolves
> as customer scale, SLA pressure, compliance demand, or industry shift
> moves the architecture's centre of gravity.
>
> **How to use this directory:** this README is the umbrella + the
> time-and-business axes. The individual docs below are single evolution
> paths with their own depth. Read the README for the *map*; drill into a
> spoke when a trigger fires.
>
> **The architecture stays invariant inside one horizon** — only `values.yaml`
> configuration moves. Crossing a horizon is structural, not parameter.

---

## 1. Architecture evolution map

Five horizons. Each row names the business shape, the architecture shape,
and the trigger that moves from the previous horizon. The pairs of
horizons are bracketed, not precise — "T+3y" means "the phase where the
T+3y trigger conditions typically appear for Mittelstand-scale B2B SaaS";
some customers reach it in 18 months, some never do.

| Horizon | Typical business shape | Architecture shape | Trigger to move from previous |
|---|---|---|---|
| **T0 (today)** | POC / early-stage; ~5–10 tenants total; 1 cell | Single master AZ, cold DR via Velero, dual-cadence backup (5-min operational + 4-h DR), `cells.count=1` | — |
| **T+1y** | Early customers; ~10–50 tenants spread over ~3 cells; cohort mix plus 1–2 enterprise-dedicated pods | Same shape; scale `cells.count` linearly via ADR-02 Mode 2 (empty-pod fill); Karpenter handles stateless tier elasticity | Aggregate cell utilisation > 70% sustained two weeks |
| **T+3y** | Growth; ~50–100 tenants over ~10–30 cells; some hot tenants need their own cell; mixed cohort + enterprise | EITHER same single-master-AZ shape scaled linearly OR **substrate upgrade** to TiKV multi-AZ HA (per `tikv-upgrade-path.md`) if SLA tightens | Customer SLA tightens RTO below ~25 min AZ failure OR cost-of-cold-DR exceeds cost of distributed-K-V running cost |
| **T+5y** | Mature SaaS; cross-region customer base; multi-region active-active may become product feature | Multi-region active-active — TiCDC async between regional TiKV clusters OR Path A geo-close 5-node Raft (see `tikv-upgrade-path.md` § 4) | Cross-continent customer base + sub-50 ms read latency demand OR multi-region write-everywhere becomes the product surface |
| **T+10y** | Market maturity; substrate-level questions emerge | LevelDB EOL question; serverless distributed K-V (DSQL / Spanner-equivalent SaaS) maturity question; AI-augmented placement / vector retrieval as adjacent systems | Industry inflection — when a serverless-DB offering's SLA + cost + portability collapse the current architecture's complexity, OR LevelDB itself gets deprecated by upstream maintainers |

**Two structural inflection points** are visible in this map:

- **T+1y → T+3y:** the *option* to upgrade the storage substrate (LevelDB → TiKV). The current architecture stays valid linearly through T+3y; the upgrade is a customer-SLA-driven choice, not a forced step.
- **T+5y → T+10y:** the *substrate question itself* — does in-cluster distributed K-V remain the right primitive, or does the market move to serverless databases that obviate the question?

Inside a horizon, configuration moves (`cells.count`, `backup.dr.cadence_hours`, `master_az`, etc.). Crossing a horizon, the architecture shape changes.

---

## 2. Trigger conditions — what moves us between horizons?

Five axes; ANY ONE tripping is enough to start the conversation. Documented per axis so "are we already at the trigger?" is answerable from operational telemetry, not subjective judgement.

### 2a. Tenant-count / capacity axis

| Phase boundary | Trigger metric | Threshold | Source of truth |
|---|---|---|---|
| T0 → T+1y | Aggregate cluster utilisation | > 70% sustained two weeks | `per-tenant-ops` Grafana dashboard |
| T+1y → T+3y | Per-cell utilisation | > 85% sustained four weeks (Mode 1 per ADR-02) | `capacity-headroom` dashboard |
| T+3y → T+5y | Single largest tenant size | > 50% of one pod, AND tenant-cell count > 50 | `per-tenant-ops` dashboard |
| T+5y → T+10y | Substrate operational burden | Operator-survey "we're managing the database, not the product" | qualitative; quarterly review |

### 2b. SLA / RTO / RPO axis

| Trigger | Architecture implication |
|---|---|
| Customer SLA tightens RTO below the ~25 min AZ-failure budget | TiKV multi-AZ HA (RTO ~0); see `tikv-upgrade-path.md` § 2 |
| Customer SLA demands sub-15-min cross-region RTO | Multi-region active-active; CAP conversation; `tikv-upgrade-path.md` § 4 |
| RPO target tightens below 5-min cadence floor | WAL shipping or distributed consensus required; substrate change |
| Granular per-tenant point-in-time restore becomes a product feature | Velero FSB path; see `restic-fsb-patch.md` |

### 2c. Compliance axis

| Trigger | Architecture implication |
|---|---|
| Regional data residency commitment (e.g., GDPR Schrems II sustained ruling) | Per-region cell pool + tenant-to-region pinning at the placement-table layer |
| SOC 2 Type II / ISO 27001 audit commitment | Backup-verification automation (currently in ADR-04 "out of POC"); EBS Fast Snapshot Restore (FSR) enabled for evidence-quality restore drills |
| HIPAA / financial-tier compliance | Tier 1 isolation per ADR-04 (dedicated AWS account per customer); separate KMS hierarchy |
| Air-gap requirement | Restic FSB path with offline-restore-from-USB (see `restic-fsb-patch.md` § "When Restic would be the right call") |

### 2d. Cost-ceiling axis

| Phase | Total monthly cost (illustrative; see § 3 line-by-line) | Lever revisited |
|---|---|---|
| T0 | ~$2,700 | none — within Mittelstand POC budget |
| T+1y | ~$5,000–8,000 | NAT Gateway consolidation; 1-year Savings Plans for stateful baseline |
| T+3y (same shape) | ~$15,000–25,000 | Karpenter spot diversification; multi-tenancy consolidation within cohort cells |
| T+3y (TiKV substrate) | ~$20,000–30,000 | Higher compute (3× Raft replicas) offset by lower backup pipeline cost; 3-year Savings Plans |
| T+5y (multi-region active-active) | ~$50,000–100,000 | Cross-region traffic is the dominant line item; depends on TiCDC sync volume |

### 2e. Industry-shift axis

| Trend | When relevant | Architecture implication |
|---|---|---|
| Serverless distributed K-V matures into production-grade SLA + cost | T+5y if Aurora DSQL / Spanner-equivalent become viable for B2B SaaS data | Substrate change; remove our own cluster ops |
| Edge-native databases for global latency (Planetscale, Neon, Turso class) | T+5y if customer demand for sub-100 ms global writes emerges | Application-level rewrite; different cost model |
| AI-augmented retrieval (vector DBs, feature stores) | T+3y if AI features become a product surface | Adjacent system (Pinecone / pg_vector / OpenSearch); not a LevelDB replacement |
| Kubernetes maturity + operator-pattern dominance | already true; reinforces T+3y TiKV path | The migration risk is bounded; operator-pattern tools are battle-tested |

---

## 3. Cost trajectory — broken down per horizon

All figures derive from formulas in [`docs/operations/cost-estimate-methodology.md`](../operations/cost-estimate-methodology.md) — operator substitutes actual customer scale variables to land the real number. The point of this section is the *shape* of cost evolution, not the precise number. AWS pricing as of 2026; operator verifies against current pricing before committing.

### 3a. T0 — POC scale (`cells.count=1`)

| Line item | Cost (USD/mo) | Formula |
|---|---|---|
| EKS control plane | $73 | flat, 1 cluster |
| Stateful nodes (master AZ only) | $500 | r6id.2xlarge × 1 pod × 730 h + on-demand overhead |
| Stateless nodes (api + envoy + system) | $800 | Karpenter mixed 70% spot / 30% on-demand, ~3 nodes equivalent |
| EBS gp3 storage (master AZ only) | $200 | 2 TB × $0.08/GB; standby AZ at $0 (no PVCs until rotation) |
| 3× NAT Gateways | $99 | 3 × $33 (per-AZ; preserves warm-standby rotation readiness per ADR-10 §6) |
| EBS Snapshot (5-min operational + 4-h DR cadence, 30-day retention) | $300 | depends on churn (10–20%/day) → 1.5–3 TB at retention |
| Cross-region snapshot copy (Glacier Instant Retrieval) | $150 | replicated changed-data × $0.004/GB + transfer |
| S3 (Velero metadata + replication) | $50 | small footprint (manifests + state) |
| Observability (Grafana Cloud Pro) | $500 | mid-tier subscription; AMP/AMG alternative ~$700 |
| **Subtotal** | **~$2,700** | Mittelstand POC budget |

### 3b. T+1y — Mid-stage (~10 customers, `cells.count=3`)

| Line item | Cost (USD/mo) | Δ vs T0 |
|---|---|---|
| EKS control plane | $73 | unchanged (one cluster covers all cells) |
| Stateful nodes | $1,500 | × 3 cells (linear) |
| Stateless nodes | $1,000 | scales with API rate (~1.25×) |
| EBS gp3 storage | $600 | × 3 cells (linear) |
| 3× NAT Gateways | $99 | unchanged (one VPC, three AZs) |
| EBS Snapshot | $900 | × 3 cells (linear) |
| Cross-region snapshot copy | $450 | × 3 cells (linear) |
| S3 metadata | $100 | more namespaces, more snapshot manifests |
| Observability | $500 | unchanged (custom-metric growth modest) |
| **Subtotal** | **~$5,200** | Linear scaling kicks in; near-linear in cells.count |

### 3c. T+3y, Path A — Same shape, scaled (`cells.count=20`)

| Line item | Cost (USD/mo) | Note |
|---|---|---|
| Stateful nodes | $10,000 | × 20 cells (linear) |
| EBS storage | $4,000 | × 20 cells (linear) |
| Snapshots + cross-region | $9,000 | × 20 cells (linear) |
| Stateless + NAT + obs + EKS | $2,500 | non-linear modest growth |
| **Subtotal** | **~$25,500** | Linear path; lowest-disruption choice |

### 3d. T+3y, Path B — TiKV multi-AZ HA substrate

| Line item | Cost (USD/mo) | Δ vs Path A |
|---|---|---|
| TiKV nodes (3-replica across 3 AZs) | $14,000 | ~3× compute vs single-master-AZ; node count grows |
| EBS storage | $4,000 | same per-replica; Raft amortises some compaction differently |
| Snapshot pipeline | $2,000 | smaller — TiKV's own snapshot/Raft log replaces high-cadence Velero pipeline |
| Cross-region copy | $4,000 | smaller — less data churn in dedicated DR snapshots |
| Other (PD, NAT, obs, EKS) | $4,000 | TiKV adds PD overhead; multi-AZ tripled NAT data-processed |
| **Subtotal** | **~$28,000** | ~10% premium over Path A; buys RTO ~0 + active-AZ across all 3 AZs |

The choice between Path A and Path B at T+3y is SLA-driven: if RTO ~25 min still fits the customer's tolerance, Path A is correct (cheaper, simpler). If RTO target tightens, Path B's ~10% cost premium buys structural correctness.

### 3e. T+5y — Multi-region active-active (if customer SLA forces it)

This is the inflection point where architecture cost stops being linear:

| Line item | Cost (USD/mo) | Driver |
|---|---|---|
| Two-region TiKV clusters | $50,000 | ~2× of Path B for compute + storage |
| Cross-region traffic (TiCDC bidirectional sync) | $5,000–20,000 | depends on write volume; dominant variable |
| Operational complexity premium | $5,000–10,000 | multi-region SRE expertise; deeper observability |
| **Subtotal** | **~$60,000–80,000** | Per ~500 customers; varies with write volume |

### 3f. T+10y — Substrate uncertain

Cost shape depends on which substrate dominates the market:

- **If serverless distributed K-V matures**: cost could *drop* dramatically (no cluster operations; pay-per-usage). Architecture becomes a thin layer above a managed primitive.
- **If edge-native databases win**: cost shape changes shape entirely (latency-billed per region, not capacity-billed per cluster).
- **If status quo persists** (TiKV / Cassandra / FoundationDB remain the answer): cost scales with the patterns above.

Hard to forecast precisely; depends on industry trajectory. Reserved for "we'll know when we get there" reasoning.

---

## 4. Future-plan documents — index

Each doc is one evolution path with its own depth + trade-off analysis + migration cost.

| Doc | Evolution type | Trigger that activates it |
|---|---|---|
| [`restic-fsb-patch.md`](restic-fsb-patch.md) | **Tactical** — same architecture, different backup transport (Velero CSI → FSB / Kopia / Restic) | Customer's RTO tolerance ≥ 12 h OR granular per-tenant file restore becomes product feature OR air-gap requirement |
| [`lvm-init-patch.md`](lvm-init-patch.md) | **Tactical** — same architecture, literal-LVM storage stack (Path γ multi-PVC → Path α LVM init container) | Existing legacy on-prem LevelDB host runs LVM and migration target should match mental model OR customer policy mandates literal Linux storage stack OR in-host thin snapshot independent of CSI is required |
| [`tikv-upgrade-path.md`](tikv-upgrade-path.md) | **Strategic** — substrate change (LevelDB → TiKV distributed K-V) | RTO ~25 min AZ failure not acceptable OR sub-5-min RPO required OR multi-region active-active becomes product requirement |

More docs land here as the architecture evolves. Each starts as a `[planning]` doc, gets reviewed, then either ships or stays as reading material until its trigger fires.

---

## 5. Industry trend context — where the space is heading

A brief survey of where K8s-stateful + distributed-K-V is in 2026 and where the current architecture sits relative to that trajectory.

**Distributed-K-V on K8s is maturing.** TiKV, Cassandra, FoundationDB, ScyllaDB all run on K8s in production at scale. Operator-pattern deployments (PD, etcd-operator, TiKV operator) are now the canonical shape. The current architecture's single-LevelDB-per-pod is the *not-yet-distributed* corner of this design space; the TiKV path documents the migration if the customer's SLA pressure outgrows what LevelDB physics can deliver.

**Serverless databases are emerging.** AWS Aurora DSQL (announced 2024), AlloyDB Omni (GCP), Cloudflare D1, Turso, Neon. If these mature with the operational characteristics customers expect (SLA + cost + portability + data-residency), they could collapse the current architecture's complexity into a managed primitive. The T+5y horizon question is whether this happens fast enough to matter.

**Edge-native databases for latency-sensitive workloads.** Planetscale, Neon, Turso class. Cost model is materially different (read-replica-per-region vs cluster-per-region). Right answer for global SaaS where read latency dominates; not yet a fit for write-heavy B2B SaaS with strong-consistency demand.

**AI-era retrieval primitives.** Vector retrieval (Pinecone, pg_vector, OpenSearch), feature stores (Feast, Tecton). These are adjacent systems, not LevelDB replacements; integration happens at the application layer. T+3y horizon if AI features become a product surface; doesn't affect the storage substrate decision.

**Kubernetes operator-pattern maturity.** Battle-tested operators (etcd, TiKV, Cassandra, PostgreSQL via Crunchy / CloudNativePG) reduce the operational risk of running a distributed database on K8s. This *de-risks* the T+3y TiKV path — the bet that the operator handles the hard parts is much safer in 2026 than it was in 2020.

**Where the current architecture sits.** Deliberately conservative — optimised for "Mittelstand SaaS where the storage primitive is the application's existing LevelDB". This is the right call at T0; the future-plan docs above name the conditions under which it should change.

---

## 6. Caveats

- **All cost numbers are illustrative.** Real costs depend on customer-specific traffic shape, retention policy, KMS request volume, observability custom-metric count, AWS pricing in effect at the time. Operator must substitute actuals via [`docs/operations/cost-estimate-methodology.md`](../operations/cost-estimate-methodology.md).
- **All triggers are minimums.** Hitting one trigger starts the architecture-conversation; it doesn't auto-mandate the change. Many triggers can fire harmlessly if the customer accepts the trade-off.
- **All timelines are bracketed, not precise.** "T+3y" doesn't mean "exactly 36 months from now"; it means "the phase where the T+3y trigger conditions typically appear for Mittelstand-scale B2B SaaS". Some customers reach T+3y in 18 months; some never do.
- **All alternatives are situational.** TiKV is the canonical reference but not the only answer (see `tikv-upgrade-path.md` § 7 for the four alternatives: CockroachDB, ScyllaDB, FoundationDB, DynamoDB Global Tables). The right substrate depends on which CAP corner + operational model + ecosystem fits the customer.
- **All horizons are reviewable.** The right cadence to re-read this README is quarterly — once a quarter, look at where the operational telemetry actually is against the trigger thresholds in § 2.
