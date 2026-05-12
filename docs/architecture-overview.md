# Architecture overview — one page

> For reviewers without time to read all 10 ADRs.
> Read this; then dive into whichever ADR a question lands on.

## The architecture in one sentence

Per-tenant LevelDB pods on a single master AZ in EKS, fronted by a 3-tier
request flow (ALB → API tier → Envoy router → StatefulSet), with cold DR
via Velero + EBS Snapshot, configurable RPO via a Helm values knob, and
Strangler-Fig migration at the infrastructure layer.

## Grounding — calibration against public reality

| | Current public commitment | Spec target | Delivered |
|---|---|---|---|
| Uptime SLA | 99.50% (Team / Business) | (implicit "auto recover") | ~25 min AZ-failure RTO supports 99.5%+ |
| RPO | ~24 h (daily backup) | ≤ 6 h | ~30 sec @ 5-min cadence default |
| RTO | not published | not specified | ~25 min AZ / ~50 min region (our chosen target; Stage 3 validates) |

Sources: customer's public pricing page + information-security page (URLs in
the customer-specific grounding annex; verified 2026-05-10). Spec target =
~4× improvement vs current public commitment. Architecture delivers ~480× —
over-delivery to expose the curve, not hit the floor.

## Three organising principles

| | Principle | Practical consequence |
|---|---|---|
| P1 | EBS is treasure; everything else is cattle | Stateful tier gets `Retain` + 1:1 pod-to-node + conservative cadence; stateless tier gets autoscaling + spot mix |
| P2 | RPO is a configurable trade-off, not a fixed floor | Spec says ≤ 6 h; default 5 min; lever in `values.yaml` (`backup.cadence_minutes`); cost-RPO curve documented |
| P3 | Detection automatic; execution manual | Prometheus + ALB health + Blackbox probe fire within ~30 sec; operator decides "transient or sustained" inside a 5–10 min window; no auto-failback |

## The diagram

<img src="diagrams/d1-high-level.svg" alt="High-level architecture — eu-central-1 source region with master AZ + warm-standby AZs, eu-west-1 cold DR" width="100%" />

### Multi-tenancy isolation tiers (per ADR-04)

<img src="diagrams/d5-cell-isolation.svg" alt="Three-tier multi-tenancy isolation — dedicated AWS account / dedicated VPC / shared cluster + namespace" width="100%" />

The three isolation tiers map directly to compliance posture: Tier 1
(dedicated account) for top-tier regulated workloads, Tier 2 (dedicated
VPC) for the medium-regulation default, Tier 3 (shared cluster +
namespace) for sandbox / low-trust. The tier choice is a deployment
decision; runtime enforcement is the consequence.

### Strangler-Fig migration sequence (per ADR-05)

<img src="diagrams/d6-strangler-fig.svg" alt="Strangler Fig migration via Target Group Binding — 4 phases from parallel infra to legacy decommission" width="100%" />

The migration substrate change happens at the infrastructure layer.
Phase 1 provisions parallel EKS infra alongside the legacy EC2 service.
Phase 2 verifies the shadow with read-only probes. Phase 3 flips traffic
gradually via TargetGroupBinding weights — 90/10, 50/50, 0/100 — with
soak-window monitoring at each step. Phase 4 decommissions legacy. The
anchor — *"the application should not need to know it's being migrated"*
— captures the design lever: cutover lives at the routing layer.

## Why each piece earns its place

- **Per-tenant pod identity (ADR-01).** LevelDB is single-writer, file-based, no native replication. Sharding a single tenant's database across pods would require a distributed K-V layer above LevelDB. Per-tenant identity is the only consistent shape for this storage primitive.
- **Single master AZ + warm-standby AZs (ADR-01, ADR-04).** Cross-AZ chatter on a stateful tier with no cluster-aware replication is wasted latency and double cost. Warm-standby AZs are pre-provisioned topology, not running compute. Rotation is a runtime scaling decision (`aws eks update-nodegroup-config`), not a `terraform apply`.
- **3-tier request flow (ADR-01, ADR-03).** Edge / business logic / routing / state separation maps cleanly to scaling shape. Decoupled Envoy router is the industry-standard pattern for stateful sharded systems (Lyft, Stripe, Reddit, Vitess `vtgate`, DynamoDB request router) — not invention, recognition.
- **DynamoDB Global Tables placement table (ADR-03).** Six-property contract: atomic compare-and-swap (CAS) / strong reads / multi-AZ durable / low latency / change-data-capture (CDC) / audit log. Customer can substitute any backend that satisfies the contract; DynamoDB is the POC reference.
- **Cold DR via Velero + EBS Snapshot (ADR-04).** LevelDB has zero native sync APIs. Any "warm" replica is a snapshot copy with the replica running idle. Paying for idle warm-standby pods buys ~40 min of RTO at ~€1,500/month — a poor trade against our chosen ~25 min AZ-failure target (spec is silent on RTO; ~25 min is our design judgment). Cold DR is the structurally correct shape at that target.
- **Three-Layer DR (ADR-04).** Layer 1 = Terraform (infra). Layer 2 = Helm via terraform `helm_release` (cluster controllers including Velero itself). Layer 3 = Velero (application + data). Each layer the right tool; no double management; each layer's restore time bounded by what it owns.
- **5-min cadence default (ADR-04).** Well inside the 6-h spec ceiling. Cost-RPO curve is linear; the operator picks the operating point. POC default tight; relaxing to 1 h saves ~€200/mo, RPO degrades to ~30 min.
- **Strangler Fig migration (ADR-05).** Application doesn't know it's being migrated. Cell-by-cell cutover via placement-table flip. Same pattern Bin used at E2 Nova for EC2-to-EKS via Target Group Binding.
- **OpenTelemetry (OTel)-only instrumentation (ADR-06).** Vendor-neutral at the instrumentation layer; backend (Grafana Cloud / Amazon Managed Prometheus + Grafana) reversible.
- **Defense in depth (ADR-07).** Edge TLS → NetworkPolicy → Pod Security Standards (PSS) restricted → Cosign admission → External Secrets Operator (ESO) + IAM Roles for Service Accounts (IRSA) → per-tier KMS → eBPF runtime → tamper-protected audit. Each layer names the threat the layer above can't see.
- **Manual prod sync GitOps (ADR-08).** Terraform applies and ArgoCD prod sync are explicit operator actions, not auto-merge. CI does plan + lint, never apply.
- **SHA pin + Supply-chain Levels for Software Artifacts (SLSA) L3 + Software Bill of Materials (SBOM) (ADR-09).** Five lines of YAML buy "the image you reviewed is the image that runs." Audit-grade chain of custody from source to running container.
- **FinOps as architecture, not afterthought (ADR-10).** Tagging discipline + AWS Budgets + Cost Anomaly Detector + per-tenant Cost and Usage Report (CUR) + Athena attribution + Savings Plans strategy — all day-1, not bolted on.

## Cost (Mittelstand POC scale)

> **All figures derive from formulas in `docs/operations/cost-estimate-methodology.md`**
> with AWS pricing pages cited per line. Numbers shown as `~€X/mo` are
> approximations from those formulas applied at POC scale (`cells.count=1`,
> assumed Mittelstand-typical workload churn). Operator should substitute
> the customer's actual scale variables (cell count, churn rate, traffic
> profile) into the formulas to derive their own number, and verify
> against AWS Cost Explorer with a representative test workload before
> committing.

```
Stateful nodes (master AZ only)            ~€500/mo  (cells.count=1 default, r6id.xlarge on-demand)
Stateless nodes (api + envoy + system)     ~€800/mo  (Karpenter mixed spot 70% / on-demand 30%)
EBS gp3 (2 TB total split data+WAL multi-PVC) ~€200/mo  (90%/10% data/WAL ratio per ADR-02)
3× NAT Gateways                             ~€99/mo  (~€33/mo each, AWS list)
EBS Snapshot (5-min cadence, 30-day)       ~€300/mo  (depends on block-change rate; estimate)
Cross-region copy (Glacier IR)             ~€150/mo  (depends on snapshot delta volume)
S3 (Velero metadata + replication)          ~€50/mo
Observability (Grafana Cloud Pro)          ~€500/mo
EKS control plane                           ~€73/mo  (AWS published)
                                           ─────────
                                           ~€2,700/mo

Linear scale: each additional cell ≈ +€700/mo (node + EBS, no other shared costs).
```

For comparison: the active-passive multi-region path was estimated at
~€8,500/mo for ~5–10 min RTO improvement against our chosen 25-min
AZ-failure target. Rejected against that target; would be a different
conversation if the customer's actual operational tolerance demands
sub-15-min recovery. Reasoning chain in `docs/operations/why-cold-dr.md`
(spec is silent on RTO; we set our own target).

## Knobs (operator levers)

| Knob | Default | Range | Effect |
|---|---|---|---|
| `backup.cadence_minutes` | 5 | 1–360 | Lower → tighter RPO + higher EBS Snapshot cost |
| `master_az` | `eu-central-1a` | any AZ in region | Pinned at provisioning; rotation via `aws eks update-nodegroup-config` |
| `dr_region` | `eu-west-1` | any AWS region | Cross-region snapshot target |
| `stateful.cells.count` | 1 | 1–N | Production scale matches customer's existing partitioning |
| `routing.backend` | `dynamodb` | `dynamodb`, `customer_supplied` | Customer can substitute any 6-property-contract backend |
| `observability.backend` | `grafana_cloud` | `grafana_cloud`, `amp_amg` | Vendor-reversible per ADR-06 |
| `stateful.cells.storage.data` / `.wal` | 18Gi / 2Gi (POC); 1843Gi / 205Gi (prod) | per-PVC | Multi-PVC layout per ADR-02; literal LVM available as opt-in patch |

Full inventory in `helm/aegis-statefulset/values.yaml` with inline trade-off comments.

## Where to read next

| Question | ADR / doc |
|---|---|
| **Cost methodology — formulas + AWS pricing URLs for every quantitative claim** | `docs/operations/cost-estimate-methodology.md` |
| Why per-tenant pods, why single master AZ, why cells? | ADR-01 |
| EBS sizing, multi-PVC layout (Path γ), Retain reclaim, 1:1 pod-to-node? | ADR-02 |
| Literal LVM init container (the spec-literal opt-in)? | `docs/future/lvm-init-patch.md` |
| Why DynamoDB placement table, why dedicated Envoy? | ADR-03 |
| Why cold DR over active-passive? Three-Layer DR? | ADR-04 + `docs/operations/why-cold-dr.md` |
| How does migration actually work? | ADR-05 |
| Observability stack? Dashboards? | ADR-06 |
| Security architecture? Threat model? | ADR-07 |
| GitHub Actions, ArgoCD, manual prod sync? | ADR-08 |
| Supply chain hygiene? | ADR-09 |
| FinOps discipline? | ADR-10 |
| Region failure recovery runbook? | `docs/operations/region-failure-recovery.md` |
| Per-tenant relocation tiers? | `docs/operations/per-tenant-relocation.md` |
| What I'd execute on submission day? | `docs/operations/runbooks/` |
| Why Velero + EBS Snapshot rather than Restic + LVM as the spec named? | `docs/operations/why-velero-not-restic.md` |
| Future plan — TiKV upgrade path beyond LevelDB | `docs/future/tikv-upgrade-path.md` |
| Future plan — Restic / Kopia FSB path diff patch | `docs/future/restic-fsb-patch.md` |
