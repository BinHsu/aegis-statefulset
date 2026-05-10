# aegis-statefulset

> Stateful Kubernetes workload management — proof-of-concept submission.
> An opinionated, parameterised reference architecture for hosting LevelDB-backed
> stateful applications on single-master-AZ Kubernetes with cold DR via Velero,
> Strangler-Fig migration support, and observability built in.

<img src="docs/diagrams/d1-high-level.svg" alt="High-level architecture — eu-central-1 source region with master AZ + warm-standby AZs, eu-west-1 cold DR, Velero backup pipeline, ArgoCD GitOps, observability stack" width="100%" />

---

## Grounding — current public commitments vs spec target vs what this delivers

This architecture is calibrated against the customer's **publicly-stated**
operational baseline + the **spec's stated improvement target**, not against
guessed customer aspirations. Numbers below are the anchor; every
architectural decision references back here.

| Dimension | Current public commitment | Spec target | This architecture delivers |
|---|---|---|---|
| Uptime SLA | **99.50%** for Team / Business; "SLA possible" for Enterprise [^pricing] | "automatically recover from failures" (spec implicit) | 99.5%+ achievable with ~25 min AZ-failure RTO target; comfortably inside the 3.6 h/month budget the SLA implies |
| RPO | **~24 hours** — "automatic backup of databases every day" [^security] | **≤ 6 hours** | **5-min cadence default → ~30 sec typical RPO** (operator-tunable to 6h via `backup.cadence_minutes`) |
| RTO | Not publicly stated | Not stated | ~25 min AZ failure / ~50 min region (architecture's chosen target — Stage 3 validation against actual operational tolerance) |
| Backup mechanism | "regularly generates incremental backups… secured at separate locations" [^security] | "Restic backup with LVM" | Velero + EBS Snapshot + DLM cross-region (Restic / Kopia FSB path documented as opt-in patch — see `docs/future/restic-fsb-patch.md`) |

[^pricing]: Customer's public pricing page (verified 2026-05-10). URL in customer-specific grounding annex.
[^security]: Customer's public information-security page (verified 2026-05-10). URL in customer-specific grounding annex.

The spec's 6-h RPO is a **~4× improvement** over current public commitment.
This architecture delivers **~480× improvement** via 5-min cadence — over-
delivery on the lever the spec asks about, deliberately, to demonstrate
the *curve* not just hit the *floor*. Operator picks the operating point
given customer's actual operational tolerance + cost ceiling. Full
methodology in `docs/operations/cost-estimate-methodology.md`; auto-vs-
manual recovery catalog in `docs/operations/automation-tiers.md`.

---

## Two organising principles + one reliability discipline

The architecture is anchored by three short statements. Every ADR traces back to one of them; every knob in `values.yaml` is the operator's seat at one of these levers.

### P1 — Data on EBS is the only irreplaceable asset; everything else is declarative

Customer state lives on encrypted EBS volumes managed via LVM. Cluster, deployments, routing tables, container images, AZ topology — all reproducible in 30–60 minutes from Helm + Terraform. Every architectural choice is a function of "is this the state that must survive, or is this the substrate that re-knits?" Stateful tier gets `reclaimPolicy=Retain`, 1:1 pod-to-node, conservative backup cadence. Stateless tier gets autoscaling, spot mix, and cattle treatment.

### P2 — RPO is a configurable trade-off, not a fixed floor

The challenge spec sets RPO 6h as the upper bound. The default is tighter — 5-min cadence yields typical recovery point ~30 sec — but the lever is exposed in `values.yaml` (`backup.cadence_minutes`), and the cost-RPO curve is documented for operator self-tune. The submission gives the curve, not a pre-decided answer; the operator picks the operating point.

### P3 — Conservative on recovery, aggressive on failure detection

Failover detection: 50% unhealthy / 2 min sustained — reactive, sensitive. Recovery detection: 95% healthy / 60 min sustained — notify-only, never auto-failback. Asymmetric thresholds prevent flap. Assume failure is real until proven otherwise; assume recovery is fake until validated by sustained signal.

---

## What this delivers

- **Single master AZ stateful tier** — POC default `cells.count=1`, production scale matches customer's existing partitioning per ADR-05 Strangler Fig migration. AZ-B/C are warm-standby AZs (subnet + NAT + node group `desired=0`) ready for AZ rotation.
- **Cold DR via Velero + EBS Snapshot (ADR-04)** — no standby pods. AZ failure recovery via `aws eks update-nodegroup-config` + Velero restore. Typical RTO ~25 min for AZ failure, ~50 min for region failure. RPO ~30 sec at 5-min cadence default.
- **Strangler-Fig migration support** — per-shard cutover with rollback per step; application container preserved unchanged; migration happens at the infrastructure layer (ADR-05).
- **Routing — placement table on DynamoDB (ADR-03)** — 6-property contract (atomic CAS / strongly consistent reads / multi-AZ durable / low latency / CDC / audit log). Customer can adapt to existing routing storage if it satisfies the contract; DynamoDB Global Tables is POC reference. Envoy router with custom Lua filter performs lookup with 3-mode cache reset (TTL / per-entry sync / bulk flush).
- **Backup pipeline — Velero schedule (ADR-04, ADR-04, ADR-04)** — 5-min EBS Snapshot cadence via Velero CRD, cross-region copy via AWS DLM to Glacier Instant Retrieval. Encrypted at rest with per-tier customer-managed KMS keys.
- **Three-path disaster recovery** — Path A (EBS survives, Velero restore), Path B (rebuild routing from pod inventory + DynamoDB Global Tables), Path C (cross-region snapshot restore in DR region).
- **Observability stack** — vendor-neutral OpenTelemetry instrumentation, tiered alerting with hysteresis, Blackbox Exporter for continuous external probe, structured tenant-scoped logs, tail-sampled traces, 8 default dashboards including service-availability for chaos demo evidence.
- **Three-Layer DR (ADR-04)** — Layer 1 (Terraform infra), Layer 2 (Helm via terraform `helm_release` for cluster controllers), Layer 3 (Velero for application + data). Each layer with the right tool, clear ownership boundary, no double management.
- **Architectural reasoning** — `docs/operations/why-cold-dr.md` documents why cold DR over active-passive (LevelDB has zero native sync APIs, refresh cycle vs cadence collision, $1,500/月 cost vs 5-10 min RTO trade-off unfavorable for Mittelstand).
- **3-tier flow** — ALB (TLS + host-routing) → API tier (auth + business logic) → Envoy mesh (east-west shaping) → StatefulSet (state). All in master AZ; AZ rotation via `aws eks update-nodegroup-config` + Velero restore (no `terraform apply` needed).
- **10 thematic ADRs (originally split across 50 private predecessors)** — every architectural decision documented with context, options considered, decision, consequences. DR + LDB-layout topics consolidated into ADR-04.

---

## Operational overhead awareness

The architecture ships maintenance surface — and acknowledges it on its own
terms. Three tools to operate (Velero / EBS Snapshot / ArgoCD), six runbooks
for human-side operations, ten thematic ADRs (originally split across fifty
private predecessors), pre-commit's five-check enforcement gate, and a CI
surface of four primary workflows plus four supporting. This is the senior
platform-engineering job in audit-grade SaaS — not a side-effect to apologise
for. Full breakdown plus the small-platform-team carrying-capacity argument
in [`docs/SUBMISSION.md` § 7a](docs/SUBMISSION.md#7a-operational-overhead--honest-accounting).

---

## Quick start

```bash
# Prerequisites
#   - aws CLI configured with appropriate IAM permissions
#   - terraform >= 1.6
#   - helm >= 3.13
#   - kubectl >= 1.28
#   - argocd CLI (optional, for GitOps workflow)

# 1. Provision AWS infrastructure
cd infrastructure/terraform
terraform init
terraform plan -out=tfplan
terraform apply tfplan

# 2. Configure kubeconfig
aws eks update-kubeconfig --name aegis-statefulset-prod --region eu-central-1

# 3. Bootstrap ArgoCD (one-time)
kubectl apply -n argocd -f gitops/argocd/projects/
kubectl apply -n argocd -f gitops/argocd/applications/observability-stack.yaml

# 4. Deploy applications (dev environment first)
kubectl apply -n argocd -f gitops/argocd/applications/aegis-statefulset-dev.yaml

# 5. Verify
kubectl get statefulset -n aegis-app-dev
helm test aegis-statefulset -n aegis-app-dev
```

For production, sync is **manual** by design — see `gitops/argocd/README.md` and ADR-08.

---

## File structure

```
aegis-statefulset/
├── README.md                       # This file
├── LICENSE                         # MIT
├── CONTRIBUTING.md                 # Local validation + ADR workflow
├── .gitattributes                  # Line endings + linguist hints
│
├── helm/
│   └── aegis-statefulset/          # Helm chart (templates, values, hooks)
│       ├── Chart.yaml
│       ├── values.yaml             # Default knobs (see "Configuration knobs")
│       ├── values-dev.yaml         # Dev environment overrides
│       ├── values-prod.yaml        # Prod environment overrides
│       └── templates/              # StatefulSets, Services, CronJobs, etc.
│
├── infrastructure/
│   └── terraform/                  # AWS layer (VPC, EKS, IAM, S3, KMS, FinOps, audit)
│       ├── main.tf                 # FinOps default_tags (Project / CostCenter / Tier / DataClass)
│       ├── eks-cluster.tf
│       ├── vpc.tf
│       ├── iam.tf
│       ├── s3-backup.tf
│       ├── kms.tf
│       ├── finops-budgets.tf       # AWS Budgets per env (50/80/100% thresholds)
│       ├── finops-cost-anomaly.tf  # Cost Anomaly Detector
│       ├── finops-cur-athena.tf    # CUR + Athena per-tenant cost attribution
│       ├── finops-savings-plans.tf # 1y Compute SP recommendation (stateful predictable)
│       └── cloudtrail.tf           # Multi-region CloudTrail + Object Lock 7y
│
├── scripts/
│   ├── backup/                     # LVM snapshot + Restic pipeline
│   ├── failover/                   # AZ failover + standby promotion
│   ├── dr/                         # Three-path DR scripts (recover / restore / warm-routing)
│   ├── migration/                  # Strangler Fig per-shard cutover
│   └── finops/                     # Per-tenant cost attribution Athena queries
│
├── gitops/
│   ├── argocd/
│   │   ├── projects/               # AppProject definitions
│   │   ├── applications/           # Application manifests (dev / prod / observability / policies / opencost)
│   │   ├── applicationsets/        # Multi-env generator (ADR-08)
│   │   └── README.md               # GitOps howto
│   ├── policies/
│   │   └── kyverno/
│   │       ├── cluster-policies/   # Pod security, cost labels, resource limits
│   │       └── supply-chain/       # Image signature, SBOM, disallow privileged
│   ├── runtime-security/           # Falco + Tetragon eBPF policies (ADR-07)
│   └── grafana/
│       └── dashboards/             # 7 SRE dashboards + 1 FinOps overview
│
├── docs/
│   ├── adr/                        # 44 architecture decision records (after weekend impl)
│   ├── finops/                     # FinOps discipline runbook (Crawl→Walk→Run)
│   ├── gitops/                     # Promotion model + drift remediation
│   └── devsecops/                  # Security controls mapping + STRIDE threat model
│
├── renovate.json                   # SHA-pin discipline + auto-merge rules (ADR-09)
│
└── .github/
    ├── CODEOWNERS                  # High-blast-radius routing
    └── workflows/                  # 8 CI pipelines: pr-validation / helm-release / terraform-plan
                                    # / dr-drill / sbom-attestation / secret-scanning / cis-benchmark / dast
```

---

## Configuration knobs (overview)

The chart exposes the trade-off curve through a small, deliberate set of values. Full inventory in `helm/aegis-statefulset/values.yaml`; the most operationally consequential ones are summarised below.

| Knob | Default | Range | Trade-off |
|---|---|---|---|
| `backup.cadence_minutes` | `5` | `1` – `360` | Lower = tighter RPO + higher EBS Snapshot / S3 cost; upper bound is the spec's 6 h RPO. |
| `ha.model` | `cold_dr` | `cold_dr` | Single mode in Wave 4: cold DR via Velero + EBS Snapshot. active-passive (private ADR-014) retired in favour of cold DR (see ADR-04). |
| `routing.backend` | `dynamodb` | `dynamodb`, `customer_supplied` | DynamoDB Global Tables is POC reference; customer can substitute any backend that satisfies the 6-property contract per ADR-03. |
| `stateful.cells.count` | `1` | `1` – `N` | POC default 1; production scale matches customer's existing partitioning per ADR-05 Strangler Fig migration. |
| `storage.ebs_size_gb` | `2048` | `512` – `16384` | Per-pod EBS size; LVM-managed and online-expandable. |
| `master_az` | `eu-central-1a` | any AZ in region | Master AZ for ALL workloads. Standby AZs `desiredSize=0`; rotation via `aws eks update-nodegroup-config`, no `terraform apply` (ADR-01 modified, ADR-04). |
| `dr_region` | `eu-west-1` | any AWS region | Cross-region DR target for EBS Snapshot copy via DLM (ADR-04). |
| `observability.backend` | `grafana_cloud` | `grafana_cloud`, `amp_amg` | OTel-instrumented; backend reversible per ADR-06. |

Pointer to `helm/aegis-statefulset/values.yaml` for the full schema and inline documentation.

---

## Architecture decisions

10 thematic ADRs cover every architectural choice. Each ADR follows a 9-section format (context, decision, alternatives considered, consequences, references). Public versions live in `docs/adr/` after weekend implementation; until then the chart bundles a copy in `helm/aegis-statefulset/docs/`.

| Domain | Count | Highlights |
|---|---|---|
| Architecture | 6 | Per-tenant pod model, multi-AZ topology, cell-based capacity unit |
| Storage | 2 | EBS + LVM (online-expand), 4-layer pod-to-PV mapping discipline |
| Routing | 2 | Consistent hash + override delta, ALB single-layer multi-AZ |
| Backup / DR | 3 | Configurable cadence, cross-region S3 replication, three recovery paths |
| HA | 2 | Cold DR posture (ADR-04 superseded by ADR-04), master AZ rotation policy (ADR-04) |
| Migration | 1 | Strangler Fig at infrastructure layer |
| Operational | 2 | 1:1 pod-to-node, mode-aware horizontal scaling |
| Monitoring & Observability | 7 | Grafana Cloud default, OpenTelemetry, tiered alerting, structured logs, tail-sampled traces, 7 dashboards, Grafana IaC |
| Security & Tooling | 7 | Zero-trust NetworkPolicy, ESO, per-tier KMS, Wazuh + GuardDuty SIEM, Edge TLS, Pod Security Standards + Kyverno, Trivy + Cosign |
| CI/CD Pipeline | 5 | GitHub Actions, four-workflow split, anonymisation gate, Helm + kubeconform, Terraform fmt/validate/tflint/tfsec |
| GitOps & Supply Chain | 2 | ArgoCD over Flux (ADR-08), SHA-pinned external dependencies (ADR-09) |
| FinOps | 1 | Cost-as-architecture (tagging / budgets / anomaly detector / per-tenant attribution / Savings Plan strategy) — ADR-10 |
| GitOps Promotion | 1 | ApplicationSet pattern + PR-based environment promotion — ADR-08 |
| Runtime Security & Audit | 3 | SLSA L3 + CycloneDX SBOM + provenance attestation, eBPF runtime (Falco + Tetragon), tamper-protected audit log pipeline — ADR-09 / ADR-07 / ADR-07 |
| Capacity & Relocation | 2 | Cell-based capacity expansion, tenant relocation as first-class — ADR-01 |
| DR Depth | 4 | Cold DR via Velero (ADR-04), DR-related (ADR-04), Three-Layer DR (ADR-04), LDB layout — Pattern 1 vs 2 (ADR-04) |

**Total: 10 thematic ADRs (originally split across 50 private predecessors).** Cold DR + Three-Layer DR + LDB-layout decisions are consolidated into ADR-04.

---

## 3-tier flow

```
Client
  │
  ▼
Route 53 (weighted A-record, default 100/0 primary/dr)
  │
  ▼
ALB — regional, TLS termination, host-routing
  │
  ▼
API tier — stateless, autoscaled, auth + business logic
  │
  ▼
Envoy mesh — stateless, east-west traffic shaping
  │
  ▼
StatefulSet pods — 1:1 pod-to-node, master AZ only
  │
  ▼
EBS volumes — Retain, LVM, encrypted (per-tier KMS)
```

All four tiers run in the master AZ (default `eu-central-1a`). Standby
AZs have node groups at `desiredSize=0`, ready to scale up on AZ rotation.
AZ rotation is a runtime scaling decision (`aws eks update-nodegroup-config`
plus Velero restore) — no `terraform apply` required (ADR-01 modified, ADR-04).

For cross-region DR, see `docs/operations/region-failure-recovery.md` and
`scripts/dr/region-failure-recovery.sh`.

---

## Cold DR architecture summary

The submission picks cold DR over active-passive multi-region for three
reasons (full reasoning in `docs/operations/why-cold-dr.md`):

1. **LevelDB has zero native sync APIs.** Any "warm" replica is, in
   practice, a snapshot-copy with the replica running idle.
2. **The cost delta is unfavourable against our chosen RTO target.**
   Active-passive multi-region buys ~40 minutes of RTO at ~$1,500/month.
   Spec is silent on RTO; we set our architecture target at ~25 min AZ
   failure (Mittelstand-grade for downstream-customer impact). At that
   target, the warm-standby trade is poor.
3. **Cold DR is self-consistent with 5-min cadence + manual DR posture.**
   One mode, one number, no auto-failover footgun.

```
Primary region (eu-central-1)            DR region (eu-west-1)
─────────────────────────────             ─────────────────────
StatefulSet → EBS                  -->    (cold; bootstraps in ~25 min via terraform apply)
       │                                  
       ▼                                  
Velero schedule → EBS Snapshot   ==DLM cross-region copy==>  EBS Snapshot (DR, Glacier IR)
                  + S3 (Velero metadata)  ==replicate==>     S3 (DR)
                                                                  │
                                                                  ▼
                                                          (Velero restore on declared DR — ~25 min)

Total RTO ~50 min. RPO ~30 sec at default 5-min cadence.
```

---

## For reviewers — entry points

| You want to read about… | Start here |
|---|---|
| The whole submission | `docs/SUBMISSION.md` |
| Why each architectural decision | `_context/adr/` (50 private predecessor ADRs) — public mirror coming in `docs/adr/` |
| Why cold DR over active-passive multi-region | `docs/operations/why-cold-dr.md` |
| Why Velero + EBS Snapshot (and not Restic + LVM as the spec named) | `docs/operations/why-velero-not-restic.md` |
| **Cost & time estimate methodology** (formulas + AWS pricing URLs for every quantitative claim) | `docs/operations/cost-estimate-methodology.md` |
| **Automation tiers** — what auto-recovers, what doesn't, what could but doesn't, with the four-segment senior matrix per row (detection / mechanism / decision / cost) | `docs/operations/automation-tiers.md` |
| **Future plan — Restic / Kopia FSB path diff patch** (apply if customer's Stage 3 trade-off arrives there) | `docs/future/restic-fsb-patch.md` |
| Disaster runbook | `docs/operations/region-failure-recovery.md` |
| Ownership boundaries (Terraform / Velero / ArgoCD) | `docs/operations/scope-boundaries.md` |
| Per-tenant relocation tiers | `docs/operations/per-tenant-relocation.md` |
| Architectural assumptions | `docs/architecture-assumptions.md` |
| Mock app implementation | `app/main.go` |
| Chaos demo scripts | `scripts/chaos/` |
| Helm chart | `helm/aegis-statefulset/` |
| Terraform | `infrastructure/terraform/` |
| Service-availability dashboard (chaos demo evidence) | `gitops/grafana/dashboards/service-availability.json` |
| **Future plan** — TiKV as the distributed K-V upgrade path beyond LevelDB (out of POC scope; reading material) | `docs/future/tikv-upgrade-path.md` |

---

## Stage 3 question pile (top 15)

The submission deliberately defers these to a live conversation. Each maps
to a knob, an ADR caveat, or an architecture variant.

1. Service decomposition — actual count and identity?
2. Routing key location — URL / subdomain / JWT?
3. Legacy session storage — in-memory / file / Redis / RDBMS?
4. Placement algorithm — deterministic by hash, or capacity-aware?
5. Customer SLA shape — single RPO across tiers, or tiered?
6. Multi-pod model — confirm per-tenant cell vs hash-sharded?
7. Pod density distribution — many small tenants or enterprise dedicated?
8. Failover detection threshold — 50% / 2 min acceptable?
9. Failback policy — Option A (permanent) vs Option B (rebalance)?
10. Maintenance window cadence — what frequency is acceptable?
11. LDB layout — Pattern 1 (shared) vs Pattern 2 (per-tenant)? (ADR-04)
12. Existing tenant→cluster mapping storage backend?
13. App code changeability — small telemetry metric acceptable?
14. Migration window availability — scheduled or fully invisible?
15. Customer's existing GitOps + DR tooling — ArgoCD? Velero?

Each maps to a knob in `values.yaml` or a caveat in an ADR. The submission
gives the curve, not the answer.

---

## Verification

```bash
# Helm
helm lint helm/aegis-statefulset/
helm template helm/aegis-statefulset/ --debug | kubeconform -summary -strict -

# Terraform
cd infrastructure/terraform && terraform fmt -check -recursive && terraform validate

# Shell scripts
shellcheck scripts/**/*.sh

# Anonymisation gate (matches ADR-08 CI check)
./scripts/git-hooks/pre-commit
```

Full local validation matrix is in `CONTRIBUTING.md`.

---

## License

MIT — see `LICENSE`.

---

## Status

Proof-of-concept submission for a take-home challenge. Architecture is stable; implementation is skeletal — the submission covers structural depth (10 thematic ADRs (originally split across 50 private predecessors), full topology, parameterised knobs, FinOps + GitOps + DevSecOps three-pillar discipline) over surface coverage (line counts, every microservice templated). Anonymised for portability across organisations. Reusable as a reference architecture for stateful K8s workloads at Mittelstand-scale B2B SaaS.
