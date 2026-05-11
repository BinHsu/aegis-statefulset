# FinOps Discipline — Senior Architect Runbook

**Scope:** the FinOps practice for `aegis-statefulset`. Companion to ADR-10.
**Audience:** platform engineers, SRE on-call, finance partner, product manager.
**Status:** Crawl phase (per FinOps Foundation Crawl/Walk/Run maturity model).

---

## 1. Why FinOps is architecture (not finance afterthought)

The standard failure mode is to treat cost as a finance concern that someone reconciles from CSV exports, with engineering "optimisation sprints" tacked on every quarter when the bill spikes. That posture loses every time:

- **Bolted-on tagging is days of work.** Tagging 200+ resources retroactively requires a Terraform import-and-edit pass per resource. Day-1 tagging via `default_tags` is zero marginal cost.
- **Untagged resources are invisible to Cost Explorer.** Without `Project / Environment / Tier / Component` activated as cost allocation tags, Cost Explorer can only group by service code (EC2 / EKS / EBS / S3) — useless for "which tenant cost us $400 last month?"
- **Reactive optimisation is too slow.** A monthly review catches anomalies on average ~15 days late. AWS Cost Anomaly Detector catches them next-day at no cost.
- **Per-tenant attribution is impossible without dimensions.** "How much does tenant X cost us?" needs a `tenant_id` dimension propagated from pod labels through Container Insights into CUR. That dimension has to exist on day 1.

The same shift-left posture this platform already adopts for security (DevSecOps — pre-commit hooks, image signing, NetworkPolicy) and observability (OpenTelemetry first-day instrumentation) applies to cost. **Cost is architecture, not a finance afterthought.**

For the full decision rationale, see [`docs/adr/ADR-10-finops.md`](../adr/ADR-10-finops.md).

---

## 2. The five disciplines

### 2.1 Cost allocation tagging (Day-1 mandate)

Every taggable AWS resource carries this tag set via Terraform `default_tags`:

| Tag | Purpose | Example values |
|---|---|---|
| `Project` | Top-level project filter | `aegis-statefulset` |
| `Environment` | Env scope for budgets / dashboards | `dev` / `staging` / `prod` |
| `Component` | Workload class | `stateful` / `stateless` / `observability` / `backup` / `network` / `finops` |
| `Tier` | Cost-bucket within project | `stateful` / `stateless` / `shared` |
| `CostCenter` | Finance attribution string | `aegis-statefulset-platform` |
| `Owner` | Email of owning team / individual | `platform-team@example.com` |
| `DataClass` | Data sensitivity for retention + compliance | `tenant-data` / `operational` / `logs` |
| `BackupPolicy` | Backup cadence at resource layer | `1h` / `6h` / `n/a` |

**Activation:** these tags must be activated as Cost Allocation Tags in the AWS Billing Console. Until activated, Cost Explorer cannot filter by them. One-time, free, mandatory before the first monthly review.

**Override pattern:** `default_tags` covers 90% of cases. Stateful EBS overrides `Component=stateful, Tier=stateful, DataClass=tenant-data, BackupPolicy=1h`; backup S3 overrides `Component=backup, BackupPolicy=n/a`. See `infrastructure/terraform/main.tf` for the defaults and per-resource files for overrides.

### 2.2 Budget alerting (three-threshold ladder)

AWS Budgets per environment with three notification thresholds:

| Threshold | Type | Severity | Action |
|---|---|---|---|
| 50% | Forecast | Info | Email-only, no page |
| 80% | Actual | Warning | On-call channel, requires investigation |
| 100% | Forecast | Critical | Page on-call, treated like Severity 2 |

The 100% forecast wires into the same SNS topic as availability alerts. The signal: *FinOps overrun is a Severity 2 the same way an SLO breach is.* Engineers see cost in the same alerting flow as latency. (FinOps Foundation Principle 3 — "Everyone takes ownership of cloud usage.")

Per-tier budget on the stateful tier catches drift specific to that tier (rogue m6i.32xlarge, accidental cluster left running) without waiting for the project-wide ceiling to trip.

### 2.3 Cost anomaly detection

AWS Cost Anomaly Detector with monitor scoped to `Project=aegis-statefulset`, threshold $100 absolute impact, daily SNS subscription. Catches drift the budget ladder misses — short-lived spikes that don't reach the monthly threshold but signal a misconfiguration.

**Cost:** $0 (free service).
**Cadence:** daily.
**Tuning:** raise threshold to $250 if alert fatigue sets in during the first month of operation. Lower never (false-negative cost > false-positive noise).

### 2.4 Per-tenant cost attribution

Pipeline:

1. Pod label `aegis.io/tenant-id` is set per pod by the placement service (per ADR-01 — per-tenant pod model means this label exists by construction).
2. Container Insights propagates pod labels into CloudWatch metric dimensions.
3. CUR is delivered hourly to S3 in Parquet format with `RESOURCES` and `SPLIT_COST_ALLOCATION_DATA` enabled.
4. Athena query joins CUR cost lines with the tenant cost dimension — output is a per-tenant monthly bill broken down by service.
5. Grafana dashboard renders the join.

**Showback in POC** (visibility, no money changing hands) → **chargeback in production** (tenants billed for actual usage) without architectural change. The pipeline is the same; only the financial workflow varies.

Query examples: `scripts/finops/per-tenant-cost-attribution.sql`.

### 2.5 Savings Plan / Reserved Instance strategy

| Tier | Workload shape | Strategy | Discount |
|---|---|---|---|
| Stateful (per ADR-04, ADR-02) | Always-on, 1:1 to LevelDB pods, predictable | 1-year Compute SP, No Upfront, sized to 70% of baseline | ~30% off committed slice |
| Stateless (per ADR-02) | Variable, Karpenter-managed with consolidation | On-demand + consolidation | Right-sizing automation |
| Spot | — | Stateful: forbidden (per ADR-04). Stateless: deferred to Wave 2B | n/a |

**Why Compute SP, not EC2 SP:** Compute SP applies across instance families AND covers Fargate / Lambda. EC2 SP is cheaper but locks to one family in one region. Stateful is pinned to r6id today, but the flexibility outweighs the incremental discount as Fargate / family-expansion options stay open.

**Sizing logic:** 70% of baseline is committed; 30% headroom stays on-demand. Pinning ADR-02's 1:1 ratio gives a clean baseline number; SP commitment doesn't outpace it.

---

## 3. FinOps Foundation Crawl/Walk/Run maturity

| Phase | What's in place | When |
|---|---|---|
| **Crawl** | Cost visibility via tags + monthly review + budget alerts + anomaly detection | This POC ← we are here |
| **Walk** | Per-tenant attribution dashboards + Savings Plan commitment + Karpenter consolidation tuning | Next quarter |
| **Run** | Unit economics ($/tenant/mo, $/req, $/GB-stored) integrated into product roadmap; FinOps-driven feature prioritisation | Year 2+ |

The architecture is structured so that **Walk is a configuration-and-dashboard step rather than a re-platforming.** Tags exist; CUR exists; the join key (`tenant_id`) exists; only the dashboard wiring and SP purchase are pending.

---

## 4. Operational rituals

### Monthly FinOps review (recurring meeting)

- **Cadence:** monthly, first Thursday, 60 minutes.
- **Attendees:** platform team lead + finance partner + product manager (FinOps Foundation three personas).
- **Agenda:**
  1. Bill review — actuals vs forecast, top deltas (Athena query Q1 + Q2).
  2. Anomaly review — what fired this month, what was action vs noise.
  3. Per-tenant unit economics — top 10 tenants by cost, $/tenant/month trend.
  4. Tagging hygiene — % resources with full tag set; investigate untagged.
  5. Action items — capacity planning, SP commitment review, dashboard updates.

### Quarterly Savings Plan commitment review

- **Cadence:** quarterly.
- **Decision:** purchase / increase / hold / let lapse.
- **Inputs:** trailing 90-day SP utilisation (target ≥ 95%), forecast for next quarter, workload-shape changes.
- **Approvers:** finance partner + on-call engineering lead.
- **Output:** documented commitment via AWS console; Terraform output in `finops-savings-plans.tf` records the recommendation.

### Weekly anomaly triage

- **Cadence:** Monday morning, 15 minutes.
- **Attendees:** platform on-call.
- **Agenda:** review anomalies from the past 7 days; classify as action / noise / waiting; raise ticket if action.

---

## 5. Tag governance

### Adding a new tag

1. Propose the new tag via PR to `infrastructure/terraform/main.tf` `default_tags`.
2. Reviewer checks: is the dimension already covered by an existing tag? is the value space bounded? is the tag aligned with FinOps Foundation guidance?
3. On merge: activate the tag in AWS Billing Console as a Cost Allocation Tag.
4. Update this runbook section 2.1 with the new dimension.

### Enforcement (AWS Config rules)

- `required-tags` rule scoped to `aws:Project = aegis-statefulset` checking presence of `Component`, `Tier`, `Owner`, `DataClass`. Out of POC scope; deploy in Walk phase.
- Pre-commit / CI gate (per ADR-08 Terraform CI) catches tag misses before merge. Lighter than Config rules; sufficient for POC.

### Removing or renaming a tag

- Tag activation is one-way in AWS — once activated, deactivating loses historical data on cost allocation reports.
- Migration path: introduce new tag, run dual-tagging for one billing cycle, then deactivate old tag.
- Document the migration in this runbook + an ADR amendment.

---

## 6. Per-tenant cost attribution workflow

### Athena query patterns

See `scripts/finops/per-tenant-cost-attribution.sql` for the full set:

- **Q1** — Top 10 tenants by monthly compute + storage cost.
- **Q2** — Component breakdown.
- **Q3** — Anomaly check (daily cost vs 30-day average per tier).
- **Q4** — Savings Plan utilisation (daily).
- **Q5** — EBS waste detection.

### Dashboard refresh cadence

- **CUR delivery:** hourly to S3 (Parquet + Athena artifact).
- **Grafana refresh:** 1 hour (set on the dashboard).
- **Consequence:** dashboards lag actuals by ~1 hour. Acceptable for monthly review; for real-time investigation, query Athena directly via the workgroup.

### When a tenant disputes their bill

- Athena query joining CUR with `aegis.io/tenant-id` dimension produces line-item breakdown.
- Hand-off to finance with a per-resource manifest (from `RESOURCES` schema element in CUR).
- Most disputes resolve at the dashboard layer; deep dispute → Athena → CUR raw lines.

---

## 7. Cost-aware design patterns

### When to choose Reserved Instances vs Savings Plans

- **Savings Plans (preferred):** flexible across instance family / region / Fargate / Lambda. Commitment is a $-amount/hour, not a SKU.
- **Reserved Instances:** locked to specific instance type/region. Cheaper per unit but rigid.
- **Default:** Compute SP unless workload is truly unchangeable (e.g., regulatory-pinned region + family).

### When to use Spot

- **Stateful:** never (per ADR-04 — primary pods must not be interrupted).
- **Stateless burst:** acceptable, deferred to Wave 2B. Karpenter NodePool with mixed spot+on-demand, fallback policy on interrupt.
- **Batch / CI workloads:** strong fit; stateless by design.

### When consolidation pays off

- **Always for stateless tier** (Karpenter consolidation per ADR-02). Right-sizing automation closes the gap between provisioned and used capacity.
- **Never for stateful tier** (per ADR-02 1:1 ratio). Consolidation would re-pack pods onto fewer nodes; loses the noisy-neighbour isolation that 1:1 buys.
- **Cost / availability trade-off:** consolidation saves money but increases blast radius on node failure. Acceptable for stateless replicas; not acceptable for stateful primaries.

### When to choose gp3 over io2

- **gp3 (default):** stateful EBS volumes. Tunable IOPS independent of size; better $/IOPS at this workload's IO profile.
- **io2:** trigger is "consistent >16k IOPS sustained per volume + workload values latency stability over $." Out of POC.

---

## 8. Anti-patterns to avoid

- **Bolted-on cost optimisation.** Treating cost as a quarterly cleanup project. Loses to architectural decisions made for other reasons.
- **Untagged resources.** Every untagged resource is a hole in Cost Explorer. CI/PR review must catch tag drift.
- **Ignored anomaly alerts.** First missed anomaly trains the team to ignore the next one. Triage every alert; classify as action or noise; tune the threshold if noise.
- **Expired SP commitments.** A 1-year SP that lapses into on-demand at full price is a 30% bill spike. Quarterly review is non-negotiable.
- **Per-tenant attribution by log scraping.** Parsing pod logs to derive cost dimension is fragile and operationally heavy. Use Container Insights + CUR; the pipeline is supported and structured.
- **Cost dashboards isolated from engineering.** Finance has the cost dashboard; engineering has the latency dashboard. Both populations make decisions in isolation. Fix: cost dimension shows up in the engineering dashboard alongside SLI.
- **Single-budget alerting.** A single 100% threshold means no early warning. Three-threshold ladder (50/80/100) gives time to react.

---

## 9. References

### FinOps Foundation framework

- **Six Principles** — https://www.finops.org/framework/principles/
- **Crawl/Walk/Run maturity model** — https://www.finops.org/framework/maturity-model/
- **Three personas (Engineering / Finance / Product)** — https://www.finops.org/framework/personas/

### AWS

- **AWS Well-Architected Cost Optimization Pillar** — https://docs.aws.amazon.com/wellarchitected/latest/cost-optimization-pillar/welcome.html
- **AWS Budgets** — https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html
- **AWS Cost Anomaly Detection** — https://docs.aws.amazon.com/cost-management/latest/userguide/manage-ad.html
- **CUR (Cost and Usage Report)** — https://docs.aws.amazon.com/cur/latest/userguide/what-is-cur.html
- **Container Insights** — https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/ContainerInsights.html

### Internal

- [`docs/adr/ADR-10-finops.md`](../adr/ADR-10-finops.md) — FinOps as architecture discipline.
- [`docs/adr/ADR-04-backup-dr-and-ha.md`](../adr/ADR-04-backup-dr-and-ha.md) / [`docs/adr/ADR-02-storage-and-pv-mapping.md`](../adr/ADR-02-storage-and-pv-mapping.md) — pin the stateful baseline that drives Savings Plans sizing.
- [`docs/adr/ADR-02-storage-and-pv-mapping.md`](../adr/ADR-02-storage-and-pv-mapping.md) — Karpenter mode-aware scaling for stateless cost optimisation.
- [`docs/adr/ADR-07-security-and-runtime.md`](../adr/ADR-07-security-and-runtime.md) — NetworkPolicy reduces NAT egress cost as a security byproduct.
- [`docs/operations/cost-estimate-methodology.md`](../operations/cost-estimate-methodology.md) — cost-per-config trade-off table and the per-knob formula.
- `infrastructure/terraform/finops-*.tf` — implementation files.
- `scripts/finops/per-tenant-cost-attribution.sql` — Athena query patterns.
- `gitops/grafana/dashboards/finops-overview.json` — dashboard skeleton.
