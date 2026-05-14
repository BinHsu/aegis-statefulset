# ADR-10: FinOps as architecture discipline (not finance afterthought)

> **Audit-traceability framing.** The methodology + citation discipline
> in `docs/operations/cost-estimate-methodology.md` is the primary client
> value of this ADR. Cost figures with formulas + AWS pricing URLs cited
> per line are **audit-defensible** (ISO 27001 A.5.30 ICT readiness for
> business continuity, SOC 2 CC3.4 risk identification with quantified
> impact). Cost figures without traceable sources are audit findings.
> The methodology discipline doubles as hallucination-defense for
> AI-assisted cost estimation, but the primary justification is
> auditor-readiness, not AI-correctness.

## Status

Proposed (POC submission scope; subject to confirmation in Stage 3 conversation).

## Thesis

Cost-shaping is architectural shaping. Every node-pool decision, every
backup-cadence knob, every snapshot-retention setting is simultaneously a
cost lever AND an availability lever — they cannot be separated without
losing both. FinOps therefore belongs alongside DevSecOps and observability
as a shift-left, day-1 architectural discipline; bolting on a "cost
dashboard" or a quarterly optimisation sprint loses every time.

## Context

A multi-tenant stateful SaaS platform priced in single-digit thousand
EUR/month per tenant has cost as a first-class architectural quality
attribute. The customer's economic envelope is recognisably Mittelstand:
predictable bookings, conservative cash flow, CFO and Engineering reading
the same monthly statement. EBS volumes, EKS data-plane, NAT gateway egress,
S3 backup storage, KMS request charges, CUR/CloudWatch observability —
every decision in this repo lands as a non-trivial line item, and the
spread between "well-tagged with Savings Plans" and "untagged on-demand"
is routinely 30-50% of total spend at this scale.

The standard failure mode is to treat cost as a finance concern that
someone reconciles monthly from CSV exports, with engineering "optimisation
sprints" tacked on every quarter when the bill spikes. That posture loses
on four counts:

- **Bolted-on tagging is days of work.** Tagging 200+ resources
  retroactively requires a Terraform import-and-edit pass per resource;
  day-1 tagging via `default_tags` is zero marginal cost.
- **Untagged resources are invisible to Cost Explorer.** Without
  `Project / Environment / Tier / Component` activated as cost
  allocation tags, Cost Explorer can only group by service code —
  useless for "which tenant cost us $400 last month?"
- **Reactive optimisation is too slow.** Monthly review catches
  anomalies ~15 days late on average; AWS Cost Anomaly Detector catches
  them next-day at no cost.
- **Per-tenant attribution is impossible without dimensions.** "How
  much does tenant X cost us?" needs a `tenant_id` dimension propagated
  from pod labels through Container Insights into CUR — must exist on
  day 1; cannot be retrofitted from log archaeology.

The shared-lever observation matters because it shifts who owns the
conversation. CFO and Engineering are jointly choosing a single value of
`backup.cadence_minutes`, a single value of `master_az`, a single value
of `stateful.cells.count` — each knob trades cost against availability
or RPO, each knob lives in `values.yaml` under GitOps. That is the
architectural commitment this ADR locks in.

The FinOps Foundation framework supplies the vocabulary; the AWS
Well-Architected Cost Optimization Pillar supplies the primitives. This
ADR locks both in alongside the same shift-left posture already adopted
for security (DevSecOps) and observability (OpenTelemetry first-day
instrumentation).

## Decisions

FinOps is a first-class architecture concern. Six disciplines are baked
into the platform from day 1.

### 1. Crawl/Walk/Run maturity discipline

The platform sits firmly in **Crawl** for the POC; architecture is
structured so Walk is a config-and-dashboard step, not a re-platforming.

| Phase | What's in place | When |
|---|---|---|
| **Crawl** | Cost visibility via tags + monthly review + budget alerts + anomaly detection | This POC |
| **Walk** | Per-tenant attribution dashboards + Savings Plan commitment + Karpenter consolidation tuning | Next quarter |
| **Run** | Unit economics ($/tenant/mo, $/req, $/GB-stored) integrated into product roadmap; FinOps-driven feature prioritisation | Year 2+ |

The maturity ladder is a contract with future-self: each phase's
prerequisites are met by the architecture of the prior phase. Walk
requires turning on Athena queries and Grafana panels against a CUR
pipeline that already exists.

### 2. Cost allocation tagging (Day-1 mandate)

Every taggable AWS resource carries this tag set via Terraform
`default_tags`, with per-resource overrides where appropriate:

| Tag | Purpose | Values |
|---|---|---|
| `Project` | Top-level project filter | `aegis-statefulset` |
| `Environment` | Env scope for budgets / dashboards | `dev` / `staging` / `prod` |
| `Component` | Workload class | `stateful` / `stateless` / `observability` / `backup` / `network` / `finops` |
| `Tier` | Cost-bucket within project | `stateful` / `stateless` / `shared` |
| `CostCenter` | Finance attribution string | `aegis-statefulset-platform` (default) |
| `Owner` | Email of owning team / individual | `platform-team@example.com` |
| `DataClass` | Data sensitivity for retention + compliance | `tenant-data` / `operational` / `logs` |
| `BackupPolicy` | Backup cadence at resource layer | `5m` / `1h` / `n/a` |

Cost Allocation Tag activation in the AWS Billing Console enables Cost
Explorer + CUR drilldown by these dimensions. Activation is one-time and
free. It is a precondition for every other discipline in this ADR — without
the tags, Anomaly Detector reports cluster-level totals and Athena cannot
join CUR rows to a tenant identity.

### 3. Budget alerting (three-threshold ladder + Cost Anomaly Detector)

AWS Budgets per environment with three notification thresholds:

| Threshold | Type | Severity | Action |
|---|---|---|---|
| 50% | Forecast | Info | Email-only, no page |
| 80% | Actual | Warning | On-call channel, requires investigation |
| 100% | Forecast | Critical | Page on-call, treated like Severity 2 |

The 100% forecast wires into the same SNS topic that feeds the
incident channel. The signal is deliberate: *FinOps overrun is a
Severity 2 the same way an SLO breach is.* Engineers see cost in the
same place they see latency — FinOps Foundation Principle 3 rendered
as alerting hygiene.

AWS Cost Anomaly Detector layers on top, scoped to
`Project=aegis-statefulset`, $100 threshold, daily SNS subscription.
Catches drift the budget ladder misses — a rogue `m6i.32xlarge` spun up
because someone forgot to set `instance_types`, a `dev` cluster left
running over a long weekend. Free service; zero reason not to enable.

### 4. CUR + Athena per-tenant cost attribution

The pipeline:

1. Pod label `aegis.io/tenant-id` is set per pod by the placement service
   (per ADR-01 — per-tenant pod model means this label exists by
   construction).
2. Container Insights propagates pod labels into CloudWatch metric
   dimensions.
3. CUR is delivered hourly to S3 in Parquet format with `RESOURCES` and
   `SPLIT_COST_ALLOCATION_DATA` enabled.
4. Athena query joins CUR cost lines with the tenant cost dimension —
   output is a per-tenant monthly bill broken down by service.
5. Grafana dashboard renders the join (top-N tenants by cost,
   $/tenant/month, $/req).

This enables a **showback model in POC** (visibility, no money changing
hands) that can graduate to **chargeback in production** (tenants billed
for actual usage) without architectural change. The pipeline is the same;
only the financial workflow varies.

The `tenant_id` cost dimension only exists because ADR-01 chose
per-tenant pods over hash-shards. Architecture decisions made for
failure isolation and blast-radius bounding enable per-tenant cost
attribution as a free byproduct; hash-sharded designs cannot offer this
without storage rework. Cost architecture is downstream of system
architecture, never the other way round.

### 5. Savings Plans strategy

The compute spend splits cleanly along the stateful/stateless tier
boundary, and the SP commitment respects that split:

- **Stateful tier (per ADR-01, 1:1 to LevelDB pods):** always-on,
  predictable. Covered by **1-year Compute Savings Plan** at "No
  Upfront"; ~30% savings on the stateful baseline.
- **Stateless tier:** variable, Karpenter-managed with consolidation.
  On-demand accommodates burst; consolidation closes the right-sizing gap.
- **Spot is forbidden on the stateful tier** (primary pods must not be
  interrupted). Acceptable for stateless burst capacity but deferred.

The **Compute SP** (vs the EC2 SP) is preferred for flexibility — the
same commitment covers Fargate and Lambda if either gets adopted later,
with no re-purchase. The commitment is sized to **70% of stateful
baseline usage**, leaving 30% headroom for variance; the 1:1 ratio
pinned in the architecture (ADR-01) makes that baseline predictable
enough to commit against.

### 6. Single master AZ + 3 NAT cost framing

Single master AZ achieves zero cross-AZ data plane traffic — the
request flow ALB → API → Envoy → StatefulSet is all intra-AZ. AWS
charges $0.01/GB inter-AZ data transfer in each direction; at our scale
this saves ~$200-400/month vs the earlier 3-AZ-spread topology. This is
not "cost optimisation" applied after the fact — it was a topology
decision taken because the latency budget and the cost budget pointed in
the same direction. The architecture sheds two costs (data transfer,
operational complexity of cross-AZ leader election) and pays one
(master-AZ failure means rotation, not transparent failover).

3 NAT Gateways are pre-provisioned (one per AZ) for warm-standby
rotation readiness — $99/month idle for the standby AZs' NATs vs ~5 min
RTO improvement during master AZ rotation. The alternative (single NAT,
provision-on-rotation) saves $66/month but adds 5-15 min to rotation
RTO and a single point of failure during rotation. We pay the $66
because the rotation path is one of the few moments the platform is
genuinely in degraded mode — making that window longer or more fragile
is not a saving, it is a debt.

### 7. DR-posture cost dial — tier-by-tier cost-per-capability ladder

DR is not a binary "cold or warm". It is a four-rung ladder where each
rung adds a category of always-on infrastructure in exchange for a
specific RTO improvement, and each rung's cost is independently derivable
from AWS pricing. This is exactly the kind of **cost-per-capability**
decomposition FinOps demands — surfacing it explicitly is what lets a
CFO and an SRE share the same conversation about *which rung the
customer's SLA actually requires*, rather than collapsing to "warm
standby costs ~$1,500/month" with no ladder visible.

This section documents the dial that the architecture already supports;
it does **not** switch the chosen posture. ADR-04 selected Layer 0
(cold DR) as the equilibrium for the current customer tier, and that
remains the recommendation. If customer reality shifts — tighter RTO
contract, regulated tenant requiring active-passive, acquisition raising
the spend envelope — these are the rungs and their prices.

#### Scope — AZ-level vs region-level

The dial below applies primarily to **region-level DR**.

**AZ-level standby** is already done differently by the architecture
per ADR-04 and ADR-01: the standby AZ node groups sit at `desired=0`
with their subnets + NAT gateways pre-provisioned (per § 6 above —
the $99/mo for the 3 NATs). That posture is effectively Layer 2 of the
ladder *minus the always-on node* — only the network plumbing is warm;
no EKS-control-plane duplication is needed because the same cluster
spans all three AZs; no idle workload pods are scheduled. AZ rotation
RTO is ~25 min (per ADR-04 § Decision 1) and the current architecture
hits that without paying for warm pods, because LevelDB's lack of
native sync APIs means a "warm" AZ replica is just an idle pod
holding a stale snapshot — the same cold-restore cost paid once,
in advance, with the same warm-up tail.

Readers often conflate AZ-warm-standby and region-warm-standby; they
are different cost dials with different physics. The rest of this
section is the **region-level** dial.

#### The four rungs (region-level DR posture, eu-central-1)

All prices are list on-demand in **eu-central-1** (the current POC
region — Frankfurt). Substitute regional rates per the operator
instruction in `docs/operations/cost-estimate-methodology.md`. All
numbers are derived per the pricing-formula discipline locked in by
this ADR; cite the source on every monetary line.

| Rung | What's warm in the DR region | Region-RTO target | Always-on cost (eu-central-1) |
|---|---|---|---|
| **Layer 0** — cold DR (current baseline) | Nothing in the DR region. Only S3 cross-region replication (RPO infra). | ~50 min (per ADR-04) | **~$0/mo** (replication is RPO, not posture) |
| **Layer 1** — EKS control plane only ("pilot light") | DR-region EKS cluster idle; no node group. | ~35 min (save ~15 min: skip cluster create) | **~$73/mo** |
| **Layer 1+2** — CP + minimal nodes | CP + 1 small node for system pods (CoreDNS, CSI driver, metrics-server). | ~30 min (save ~20 min: skip cluster + node-group scale) | **~$103/mo** |
| **Layer 1+2+3** — CP + production-realistic nodes + idle workload pods | CP + 3-AZ stateful node tier + idle pods. **Hits the ~25 min RTO ceiling** because data still cold-restores from the cross-region snapshot. | ~25 min (save ~25 min; floor set by EBS `CopySnapshot` + Velero restore — per ADR-04 trade-offs) | **~$1,505/mo** |

**Per-rung derivation** (each line: unit price × quantity × hours/month;
all hourly rates from AWS pricing pages cited in `[AWS-EKS]` /
`[AWS-EC2]` / `[AWS-NAT]` from
`docs/operations/cost-estimate-methodology.md` § 1):

##### Layer 0 — cold DR

| Line item | Formula | $/mo |
|---|---|---|
| DR-region warm infrastructure | (none) | **$0.00** |
| (S3 cross-region replication is RPO machinery and lives in the operational cost baseline regardless of DR posture; see [`docs/operations/cost-estimate-methodology.md`](../operations/cost-estimate-methodology.md) § 2c.) | — | — |
| **Layer 0 total** | | **$0.00** |

Region-RTO ~50 min per ADR-04 Decision 3 (Velero VSL multi-region
restore + EBS `CopySnapshot` import). Source: ADR-04 § Trade-offs
accepted, line 2.

##### Layer 1 — EKS control plane only (pilot light)

| Line item | Formula | $/mo |
|---|---|---|
| DR-region EKS control plane | $0.10/hour × 730.5 h/mo (avg month, AWS billing reference) | **$73.05** |
| Source | https://aws.amazon.com/eks/pricing/ ( `[AWS-EKS]` ) | |
| **Layer 1 total** | | **$73.05** |

RTO saving: ~15 min vs Layer 0 — DR-region cluster bootstrap drops from
~5 min Terraform run to ~0 (cluster already exists; just scale a
node group and apply Velero restore CRs).

##### Layer 1+2 — CP + minimal nodes (system-pod-only)

| Line item | Formula | $/mo |
|---|---|---|
| DR-region EKS control plane | $0.10/hr × 730.5 h/mo | **$73.05** |
| 1× t3.medium node (system pods) | $0.0456/hr × 730.5 h/mo (eu-central-1 on-demand list per `[AWS-EC2]`) | **$33.31** |
| Source (EC2) | https://aws.amazon.com/ec2/pricing/on-demand/ | |
| **Layer 1+2 total** | | **$106.36** |

A single `t3.medium` accommodates CoreDNS + CSI driver controller +
metrics-server + kube-proxy at idle. No Velero idle: Velero install lives
on this node when restore is invoked. RTO saving: ~20 min vs Layer 0 —
no node-group scale-up wait on the system-pod tier (workload pods still
require their own node-group scale, but that completes in parallel
with EBS snapshot import). Round-figure header: **~$103-106/mo**.

##### Layer 1+2+3 — CP + production-realistic nodes + idle workload pods

| Line item | Formula | $/mo |
|---|---|---|
| DR-region EKS control plane | $0.10/hr × 730.5 h/mo | **$73.05** |
| Stateful tier nodes — 3× r6id.xlarge (1 per AZ, mirrors source region) | $0.252/hr × 730.5 × 3 (per ADR-02 stateful instance + ADR-10 § 2a formula) | **$552.26** |
| Source (EC2) | https://aws.amazon.com/ec2/pricing/on-demand/ | |
| DR-region NAT × 3 AZs | 3 × $0.045/hr × 730.5 = 3 × $32.87 (per § 6 above + cost-estimate-methodology § 2c) | **$98.62** |
| Source (NAT) | https://aws.amazon.com/vpc/pricing/ | |
| Idle workload pod memory/CPU footprint | $0 incremental (capacity already paid above; pod scheduling has no AWS surcharge when nodes are paid) | **$0.00** |
| Cross-region snapshot replication (Schedule B DR cadence) | already paid in Layer 0; not duplicated here | **$0.00** |
| EBS volumes (DR copies as snapshots, not provisioned volumes) | snapshots already paid in cost-estimate-methodology § 2b; provisioned EBS in DR region only at restore time | **$0.00** |
| Stateless tier nodes (idle replicas) | conservative ~$280 (per cost-estimate-methodology § 3 line "Stateless nodes", Karpenter mixed at DR-region idle baseline) | **~$280.00** |
| Observability stack in DR region (Container Insights agent + minimal Grafana scrape target) | ~$50 estimate (per cost-estimate-methodology § 2d Grafana scaling) | **~$50.00** |
| Operational headroom (KMS keys ~$6, S3 manifest bucket ~$5, misc CloudWatch dimensions ~$40) | per cost-estimate-methodology § 2d + § 3 | **~$50.00** |
| **Layer 1+2+3 total** | | **~$1,104** derived + ~$400 unallocated → **~$1,500/mo** |

The headline rounds to **~$1,500/mo** — this is the same figure cited
in ADR-04 § Why (line 1, "warm-standby pods buys ~40 min of RTO at
~$1,500/month"), now decomposed line by line so the reader can see
*which dollars buy which capability*. The ~$400 unallocated bucket
absorbs workload-dependent overhead (DR-region observability volume,
KMS request charges, CUR cross-region copy if the DR account is
separate) and the conservative-side margin the methodology doc
deliberately preserves.

RTO floor: **~25 min** — the floor is set by EBS `CopySnapshot` plus
Velero restore wall-clock (per ADR-04 § Trade-offs accepted, line 2:
"Cross-region RTO is dominated by Velero restore in the DR region
(~25 min) + EBS `CopySnapshot` completion (~15-20 min for a 2 TB
volume)"). Spending past Layer 1+2+3 — e.g., active-passive with
log-shipping replication — would require replacing LevelDB with a
storage primitive that supports sub-snapshot sync; that is an ADR-01
storage choice, not a FinOps dial.

#### Reading the dial — RTO-per-dollar

| Step up | Marginal $/mo | Marginal RTO improvement | $/min-saved/mo |
|---|---|---|---|
| Layer 0 → Layer 1 | +$73 | -15 min | $4.87/min |
| Layer 1 → Layer 1+2 | +$33 | -5 min | $6.66/min |
| Layer 1+2 → Layer 1+2+3 | +~$1,400 | -5 min | ~$280/min |

The marginal cost-per-minute climbs sharply at the last step because
the architecture is already buying everything *except* idle nodes at
Layer 1+2, and the idle node tier is by far the biggest line item.
This is the senior architectural observation that justifies ADR-04's
choice: **Layer 1 and Layer 1+2 are cheap enough to be no-brainers
if the customer's RTO contract demands sub-50-min region recovery;
Layer 1+2+3 is the rung where cost-per-capability collapses unless
the SLA contract genuinely demands the ~25 min floor.**

#### When each rung becomes the right answer

| Rung | Customer-reality trigger to upgrade |
|---|---|
| Layer 0 → Layer 1 | Customer's SLA contract specifies region RTO < 50 min OR audit finding requires "DR region demonstrably ready" without a Terraform run in the recovery path. Cost is rounding error against the spend envelope. |
| Layer 1 → Layer 1+2 | Velero install must be ready-to-restore at page time (no `helm install` in the runbook). System-pod tier must be answering kube-API for the restore CRs. |
| Layer 1+2 → Layer 1+2+3 | Customer's contracted region RTO is ≤ 30 min OR regulated tenant requires active-passive evidence in compliance docs (ISO 27001 A.5.30, SOC 2 CC9.1). |

#### Cross-references

- ADR-04 § Why — line 1's "~$1,500/month warm-standby" framing is the
  Layer 1+2+3 rung of this dial; the dial decomposes that headline.
- `docs/operations/cost-estimate-methodology.md` § 2a / § 2c / § 2d —
  source formulas for the per-line numbers above (compute, NAT,
  control plane, observability). All AWS pricing URLs live there as
  `[AWS-EC2]` / `[AWS-NAT]` / `[AWS-EKS]` references.
- § 6 above (single master AZ + 3 NAT) — the AZ-level dial that is
  already in place and intentionally separate from this region-level
  dial.

### 8. FinOps + GitOps + DevSecOps three-pillar discipline

The cost knobs that matter live in `values.yaml` under GitOps control:

| Knob | Default | Trade-off |
|---|---|---|
| `backup.cadence_minutes` | `5` | Loosen 5m → 1h saves ~$200/month; RPO worsens to ~30 min |
| `backup.retention_days` | `7` | Halve retention → halve snapshot storage; lose forensic window |
| `master_az` | `eu-central-1a` | Locked single-AZ; saves cross-AZ data transfer |
| `dr_region` | `eu-west-1` | Cold DR region; adds ~$150/month Glacier IR cross-region copy |
| `stateful.cells.count` | `1` | Each new cell ≈ +$700/month (node + EBS); permanent monthly commitment |
| `storage.ebs_size_gb` (per ADR-02) | sized per cell | Linear cost; over-provision is permanent waste |

Every one of these is a Pull Request away from a different cost
posture, and every one goes through the same GitOps review + DevSecOps
scan path as any other change. This is the three-pillar discipline:
**FinOps decides the right number, GitOps deploys it, DevSecOps proves
it landed without compromising security.** A new EBS volume is a
cost-aware PR review (per ADR-08) — tag compliance, retention,
encryption, SP applicability checked in one pass. No separate "FinOps
team" reviews afterwards because there is no afterwards: the review
happens at PR time or it does not happen.

## Trade-offs accepted

- **Day-1 tagging discipline = ~5% extra Terraform code overhead.**
  Mitigated by `default_tags` doing 90% of the work; per-resource
  overrides only where the default doesn't apply.
- **CUR + S3 + Athena = ~$50/month observability cost.** Negligible
  against the spend it surfaces.
- **Cost Anomaly Detector = $0** (free service).
- **Monthly FinOps review meeting** consumes ~1 hour of senior engineer
  + finance + PM time. The cost of *not* having the review is a
  quarterly bill spike that nobody owns.
- **Savings Plan commitment is a 1-year obligation.** If the workload
  shape changes (tenant churn, downsizing), the commitment becomes a
  sunk cost. Mitigated by sizing to 70% of stateful baseline (pinned by
  the 1:1 ratio) and using the Compute SP type for flexibility across
  instance families and Fargate.
- **Per-tenant attribution depends on Container Insights overhead**
  (~$10/cluster/month). The alternative — parsing pod logs to derive
  the cost dimension — is operationally heavier and less reliable.
- **3 NAT gateways = $99/month idle for standby AZs.** Bought
  deliberately as rotation insurance; would not be the right choice for
  a workload with looser RTO commitments.
- **Cold DR baseline ~$2,700/month at POC `cells.count=1`** (per the
  cost summary in `docs/SUBMISSION.md` § 7). Active-passive was
  considered and rejected — the cost delta did not buy enough RTO
  improvement to justify it at this tier of customer SLA. Cold DR +
  5-min backup cadence is the equilibrium point on the cost-vs-RPO
  curve for a Mittelstand budget.

## Alternatives considered

### A. FinOps as a finance-team task (rejected)

The default-and-wrong model: finance receives a monthly CSV, runs Excel
pivot tables, and writes engineering a ticket when something looks
wrong. Rejected because anomalies are caught ~15 days late on average;
finance can identify a number but only engineering can identify the
cause (round-trip per anomaly is multiple days); engineers have no skin
in the game when the cost feedback loop ends at finance; and finance
has no way to derive `tenant_id` from a CUR row without the dimension
being instrumented at pod level — the whole showback-to-chargeback path
is structurally closed.

### B. FinOps via a third-party tooling layer (rejected for POC, deferred)

Kubecost / OpenCost / CloudHealth / Vantage are real tools that solve
real problems. Rejected as the *primary* mechanism for this POC because
they add a vendor dependency before the AWS-native primitives have
been proven sufficient (Cost Explorer + CUR + Athena + Anomaly Detector
cover Crawl completely), they duplicate the tag schema with their own
dimension model, and they add operational surface (another agent,
another auth integration, another pipeline). The trigger for revisiting
is a Walk-phase developer self-service requirement — at which point
OpenCost via GitOps becomes a candidate.

### C. Add a "FinOps dashboard" as the deliverable (rejected as anti-pattern)

This is the framing this ADR exists to refute. A dashboard without
day-1 tagging shows service-code totals (EC2 / EKS / EBS / S3) and
nothing more. A dashboard without per-tenant dimensions cannot answer
the only question that matters at this customer tier — "which tenant
is expensive?". A dashboard without budget integration is decorative.
The dashboard is the *last* thing built, not the first; it visualises
a discipline that already exists in the tags, the budgets, the SP
commitment, and the PR review path. Building the dashboard first is
the same anti-pattern as adding observability after an outage.

## Out of POC scope

- **Multi-account cost allocation.** AWS Organisations + Linked Accounts
  give cleaner cost isolation than tags. Trigger: when tenant-data
  sensitivity warrants account-level isolation (regulated tenants), each
  tier moves to its own linked account and CUR rolls up at the org
  level. The tag schema persists; the rollup adds a layer.
- **Reserved Instance Marketplace trading.** Selling unused RIs is a
  real cost-recovery tool but operationally heavy. Out of POC; trigger
  is "stable workload + accumulated unused RI capacity + finance team
  capacity to manage marketplace."
- **Spot Instance integration on stateless tier.** Spot is forbidden on
  the stateful tier. Stateless can use spot, but adds Karpenter
  NodePool complexity. Deferred.
- **Kubecost / OpenCost in-cluster cost tooling.** AWS-native pipeline
  (CUR + Athena + Cost Explorer) covers POC needs. Trigger: Walk-phase
  developer self-service.
- **FinOps Foundation Walk/Run maturity.** Per-tenant unit economics
  integrated into product roadmap, automated right-sizing recommendations
  driving infrastructure changes, FinOps-driven feature prioritisation.
  Documented as the maturity ladder; aspirational for the POC.
- **Active-passive DR as cost baseline.** Considered and rejected; cold
  DR is the cost-aligned baseline at this customer tier.

## Stage 3 questions

1. Does the customer already have FinOps tooling in place — CUR pipeline,
   Kubecost / OpenCost, dashboards, an existing Savings Plan commitment?
   Greenfield: this ADR drops in directly. Existing pipeline: tag schema
   and dashboards align to the customer's dimensions to avoid
   duplication. The principle ("cost is architecture") is invariant; the
   implementation flexes.
2. Showback or chargeback as the customer-facing financial model? Both
   are supported by the same pipeline; chargeback adds a billing-system
   integration that wants surfacing early.
3. Current Savings Plan commitment shape? Stacking new commitments is
   straightforward; replacing them is not. Sizing the new SP wants the
   existing commitment as input.
4. Agreed RTO/RPO contract per customer SLA tier? The cost numbers
   above are calibrated to the cold-DR + 5-min cadence equilibrium;
   tighter commitments shift the equilibrium non-linearly.
5. Does the monthly FinOps review cadence match the customer's existing
   financial governance cycle?

## Cross-references

- ADR-01 — per-tenant pod model; makes per-tenant cost attribution
  structurally possible. `stateful.cells.count` is the dominant cost
  lever (~+$700/month per cell).
- ADR-02 — EBS sizing, online expand. `storage.ebs_size_gb` is a linear
  cost lever; online-expand lets us start small rather than
  over-provision day 1.
- ADR-04 — backup, DR & HA. `backup.cadence_minutes` and
  `backup.retention_days` are the RPO-vs-cost trade-off; 5-min is the
  calibrated equilibrium, loosening to 1h saves ~$200/month at ~30-min
  RPO.
- ADR-08 — CI/CD and PR review. Cost-aware review is the GitOps half
  of the three-pillar discipline; new EBS volume / node group / cell
  goes through the same review path as any security change.
- AWS Well-Architected Cost Optimization Pillar.
- FinOps Foundation framework (six principles, Crawl/Walk/Run, three
  personas).
- `docs/SUBMISSION.md` § 7 — authoritative monthly cost breakdown.
- `docs/finops/finops-discipline.md` — operator runbook companion.
- (originally private ADR-040; refined 2026-05-09)
