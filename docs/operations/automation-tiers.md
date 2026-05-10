# Automation tiers — what auto-recovers, what doesn't, and why

> Companion to ADR-04 (backup, DR & HA). Catalogues every failure mode
> in the current architecture, what level of automation it has today,
> what level it *could* have if we ignored jitter, and what dilemmas
> moving to full-auto would introduce. Each "could be auto but we
> default manual" row points to a diff patch the operator can apply
> to flip — same pattern as `docs/future/restic-fsb-patch.md`.
>
> The architecture is calibrated against the customer's published 99.5%
> uptime SLA + 24h-implicit-RPO baseline (per `docs/SUBMISSION.md` § 0).
> Whether to flip any of the patches is a Stage 3 conversation —
> the right answer depends on the customer's *aspirational* SLA, not
> the current public floor.

---

## Tier 1 — Fully auto-recovered today (no operator action)

These work without human intervention. They're the baseline that K8s
gives us; the architecture builds on top.

| Failure mode | Recovery mechanism | Typical recovery time | Operator notification |
|---|---|---|---|
| Single pod crash | kubelet `livenessProbe` restart | seconds | metric only (CrashLoopBackOff alert if rate > threshold) |
| Pod OOM | kubelet restart + `RestartPolicy: Always` | seconds | metric only |
| Container image pull failure | kubelet retry with exponential backoff | seconds-minutes | metric only |
| Single node hardware failure | EKS managed node group ASG replaces; StatefulSet rebinds PVC | ~5-10 min | Slack notification (informational) |
| Single AZ subnet flap (transient) | AZ-rotation logic doesn't fire below threshold | n/a (no action taken) | metric only |
| Stateless tier load spike | HPA + Karpenter | seconds-minutes | metric only |
| Cluster controller drift (dev only) | ArgoCD `selfHeal: true` | minutes | Slack notification |
| Helm release version drift (dev only) | ArgoCD auto-sync | minutes | Slack notification |

These cover ~80–90 % of incidents in normal operation. The remaining
~10–20 % are the AZ-and-above events the next tier addresses.

---

## Tier 2 — Auto-detect, manual-execute (architecture default)

These the architecture detects automatically (within ~30 sec via
Prometheus + ALB health + Blackbox probe) but **executes manually** via
a runbook. The operator has a 5–10 min decision window between page and
action — intentional, see § "Why we chose semi-auto" per row below.

Each row links to the diff patch that flips it to full-auto if the
customer's Stage 3 conversation arrives there.

### 2a. AZ failure rotation

| | Current default | Could be full-auto |
|---|---|---|
| Detection | ALB health degraded + Blackbox probe failing + Prometheus pod-failure alerts (~30 sec) | Same — already automatic |
| Decision | Operator decides "transient or sustained" within 5–10 min window | EventBridge rule + Lambda evaluator + cooldown timer (~2 min) |
| Execution | Runbook: `scripts/dr/az-rotation.sh` (manual invocation) | Same script triggered via Lambda + EventBridge → SNS topic |
| Recovery time | ~25 min (5-10 min decision + 5 min node-group scale-up + 10-15 min Velero restore) | ~15-20 min (no decision delay) |

**Why we chose semi-auto:**

1. **Auto-failback is unsafe with single-writer LevelDB.** Once the
   new master AZ has accepted writes, those writes don't exist in the
   original master. If the original AZ recovers and an automated rule
   fails back, those writes are lost (or require reverse-sync, which
   ADR-04 explicitly retired). Manual control gives the operator the
   chance to make the "no, AZ-B stays as the new master forever" call.
2. **False-positive AZ-failure jitter has real customer cost.** A
   spurious "AZ-A is down" event triggers a 25-min rotation; if
   AZ-A wasn't actually down, that 25 min is customer-visible
   degradation × every active tenant. At a 99.5% SLA's 3.6h/month
   budget, one false positive eats ~12% of the month.
3. **Cascading failure judgment.** "Is this AZ-A failing, or is
   AWS regional networking having a bad day, or is our own
   observability stack lying to us, or is this an attacker draining
   us deliberately?" These are pattern-matching calls humans are
   currently better at than rule-based automation.

**Patch to flip to full-auto:** `docs/future/auto-az-rotation.patch`
(outline below in § "Patch outlines"). Apply if customer's Stage 3
conversation establishes that operator-paging cost > false-positive
cost — typically only true for fully-automated operations teams with
chaos-engineering maturity.

### 2b. Region failure cutover

| | Current default | Could be full-auto |
|---|---|---|
| Detection | Cross-region observability + AWS Health API + Route 53 health checks (~1 min) | Same |
| Decision | Operator decides cross-region cutover (5–15 min window) | Route 53 weighted-record-with-health-check policy auto-flips |
| Execution | Runbook: `scripts/dr/region-failure-recovery.sh` | Velero restore in DR region triggered via Lambda |
| Recovery time | ~50 min (10 min decision + 25 min Velero restore + 15 min DNS / TTL propagation) | ~35-45 min |

**Why we chose semi-auto:**

1. **Same write-loss issue as AZ rotation, amplified at region scope.**
2. **Cross-region cluster bootstrap costs real money.** A spurious
   region-cutover event provisions a full DR-region cluster, runs
   Velero restore (~25 min), and may rack up several hundred dollars
   before being un-cutover.
3. **DNS TTL means customer-visible cutover takes minutes regardless.**
   Auto-cutover doesn't actually save time at the customer-experience
   level if the TTL is set conservatively (which it should be for a
   stateful tier where cutover is destructive).

**Patch to flip:** `docs/future/auto-region-cutover.patch` (outline below).

### 2c. Cell capacity exhaustion

| | Current default | Could be full-auto |
|---|---|---|
| Detection | Prometheus alert on `tenant_storage_bytes` per cell crossing threshold | Same |
| Decision | Operator decides "expand cell" or "relocate hot tenants out" | Operator-policy controller |
| Execution | Runbook: `scripts/capacity/expand-cell.sh` or `scripts/relocation/per-tenant-relocate.sh` | Same scripts triggered via controller |
| Recovery time | Hours-to-days (planned operation, not incident response) | Minutes-to-hours |

**Why we chose semi-auto:**

1. **Cell expansion involves cost commitment.** Each new cell adds
   ~€700/month per `docs/operations/cost-estimate-methodology.md`.
   Auto-expansion can blow the cost budget without operator approval.
2. **Hot-tenant identification is a judgment call.** Telemetry shows
   *which* tenants are hot; deciding whether to move them, expand the
   cell, or accept the contention requires understanding customer
   impact + capacity-plan trajectory.
3. **Expansion is rarely incident-driven.** It's a planned operation
   measured in days; auto-firing on a Friday afternoon is the wrong
   tempo.

**Patch to flip:** `docs/future/auto-cell-expansion.patch` (outline below).

### 2d. Per-tenant hot-spot relocation

| | Current default | Could be full-auto |
|---|---|---|
| Detection | Prometheus alert on per-tenant request rate / IOPS share | Same |
| Decision | Operator decides which tenant to move | Bin-packing optimiser controller |
| Execution | Runbook: `scripts/relocation/per-tenant-relocate.sh` | Same script triggered via controller |

**Why we chose semi-auto:**

1. **Relocation involves data movement** — costly and customer-visible.
2. **Per-tenant short outage** during relocation needs scheduling
   coordination (avoid customer's business hours).
3. **Hot-tenant prediction is hard** — auto-relocation may move a
   tenant that was momentarily hot but would have settled.

**Patch to flip:** `docs/future/auto-tenant-relocation.patch` (outline below).

---

## Tier 3 — Manual by design (no auto path advised at current architecture)

These remain manual because the cost/risk of auto-execution exceeds the
benefit at the current architecture's storage primitive (LevelDB
single-writer).

| Failure mode | Why manual is the right call | Trigger to revisit |
|---|---|---|
| Multi-region simultaneous failure | Implies an extreme correlated event (AWS provider outage); judgment about scope of response is essential | Regulatory require sub-1h multi-region RTO |
| Application schema migrations | Per-app coordination; not purely a platform concern | If migration tempo formalizes (rare in low-code platforms) |
| Cluster recreation from cold | Designed for quarterly DR drill, not unplanned use | If frequent enough to merit automation, the architecture has a more fundamental problem |
| Tenant data restore from a specific timestamp | Per-customer support request; needs human-side ticketing context | Granular restore as product feature → triggers Restic-FSB patch (per `docs/future/restic-fsb-patch.md`) |
| Velero schedule misconfiguration | One-time ops error; auto-detect would fight operator intent | n/a — pure operator discipline |

If LevelDB is replaced with a distributed K-V (TiKV; see
`docs/future/tikv-upgrade-path.md`), some Tier 3 items move to Tier 2
or Tier 1 because the storage primitive supports the auto-recovery
shape. That's the upgrade trigger conversation, not a patch for the
current architecture.

---

## Patches and implementation notes

### `docs/future/auto-az-rotation-patch/auto-az-rotation.patch` — REAL applicable patch ✅

This is a complete, applicable diff (~290 lines across 2 new files
+ 1 values flag). Adds:

1. `infrastructure/terraform/lambda-auto-az-rotation.tf` — Lambda
   declaration + IAM role + EventBridge rule + lifecycle.
2. `infrastructure/lambda/auto-az-rotation/index.py` — Lambda body
   with cooldown check + cross-source Prometheus verification before
   firing rotation.
3. `helm/aegis-statefulset/values.yaml` — adds
   `ha.rotation.auto_trigger_enabled: false` flag (default off).

The Lambda body **does the cooldown + cross-source verification**
before invoking `scripts/dr/az-rotation.sh` via SSM Run Command. This
is the canonical way to handle the "false-positive jitter" risk
documented in § 2a — single-source detection is the failure mode that
makes most "auto-rotation" deployments dangerous.

**Apply:** `git apply docs/future/auto-az-rotation-patch/auto-az-rotation.patch`
(after `git init` on the canonical repo state).

**Verify:** `terraform validate` + `helm lint` after apply.

**Apply only if:** Stage 3 establishes the customer prefers minimum-RTO
over operator judgment AND has a Prometheus federation endpoint to
serve as the cross-source check.

### `docs/future/auto-region-cutover-patch/auto-region-cutover.patch` — REAL applicable patch ✅

Adds Route 53 health-check-driven failover + Lambda that runs Velero
restore in DR region on health-check transition. ~256 lines across:
- `infrastructure/terraform/route53-health-failover.tf` — weighted A-records with health-check association
- `infrastructure/terraform/lambda-auto-region-cutover.tf` — Lambda + IAM + EventBridge wiring
- `infrastructure/lambda/auto-region-cutover/index.py` — Lambda body
- `helm/aegis-statefulset/values.yaml` — `ha.region_cutover.auto_trigger_enabled: false`

**Apply:** `git apply docs/future/auto-region-cutover-patch/auto-region-cutover.patch`

**Apply only if:** Stage 3 establishes RTO target needs sub-30-min
region cutover that operator paging cannot meet. The default ~50-min
region RTO via runbook is appropriate for most Mittelstand profiles.

### `docs/future/auto-cell-expansion-patch/auto-cell-expansion.patch` — REAL applicable patch ✅

Adds custom Kubernetes controller that watches per-cell `tenant_storage_bytes`,
calls customer's FinOps budget-check webhook, and patches the ArgoCD
ApplicationSet generator to provision a new cell when threshold +
budget both pass. ~287 lines:
- `helm/aegis-statefulset/templates/cell-expander-controller.yaml` — Deployment + RBAC
- `infrastructure/lambda/cell-expander/expander.py` — controller body
- `infrastructure/terraform/iam-cell-expander.tf` — IRSA role
- `helm/aegis-statefulset/values.yaml` — `capacity.auto_expansion.*` flags

**Apply only if:** customer has FinOps approval webhook exposed via HTTP
+ accepts auto-spend up to per-cell cost (~€700/month).

### `docs/future/auto-tenant-relocation-patch/auto-tenant-relocation.patch` — REAL applicable patch ✅

Adds CronJob-based relocation controller that runs in the customer-
specified maintenance window, identifies hot tenants, and schedules
bounded relocations via Kubernetes Job → SSM Run Command of the
existing `per-tenant-relocate.sh`. ~213 lines:
- `helm/aegis-statefulset/templates/relocation-controller.yaml` — CronJob + RBAC
- `infrastructure/lambda/relocation-controller/relocator.py` — bin-packer body
- `helm/aegis-statefulset/values.yaml` — `relocation.auto_trigger.*` flags

**Apply only if:** hot-tenant frequency makes manual relocation a burden
AND tenants tolerate brief unavailability during the configured window.

### Uniform-quality discipline

All four patches ship at "directly applicable" level per the architecture
team's standard: terraform / helm / Python implementations are real
(not outline), pre-condition flags are explicit, default-off, and each
patch's `git apply --check` passes against the canonical tracked state.
The customer applies via `git apply <patch>` after their own
`git init` / commit baseline.

---

## Summary table — for Stage 3 conversation

| Auto level | Failure modes covered | Operator discipline needed |
|---|---|---|
| **Tier 1 (always auto, today)** | Pod / node / image / spot capacity / autoscale | Pager rotation; metric review |
| **Tier 2 (semi-auto today, full-auto via patch)** | AZ failure / region cutover / cell expansion / per-tenant relocation | Decision-window judgment; runbook execution |
| **Tier 3 (manual by design)** | Multi-region correlated / schema migrations / cluster cold-recreate / per-customer restore | Incident command; cross-team coordination |

The architecture's choice of "Tier 2 = semi-auto by default" is a
deliberate trade against single-writer LevelDB physics. If the customer
wants any Tier 2 item flipped to full-auto, the patches above are the
mechanism. If the customer wants Tier 3 items also auto-recoverable,
the conversation is "replace the storage primitive" — TiKV per
`docs/future/tikv-upgrade-path.md`, not "add more automation on top of
LevelDB."

---

## Cross-references

- `docs/SUBMISSION.md` § 0 — public-SLA grounding that calibrates these tiers
- `docs/operations/why-cold-dr.md` — why cold DR over active-passive (orthogonal but related)
- `docs/future/restic-fsb-patch.md` — same patch pattern, different topic
- `docs/future/tikv-upgrade-path.md` — what changes if storage primitive flips
- ADR-04 (backup, DR & HA) — architectural decision this catalogues operationally
- ADR-15 (master AZ rotation policy) — manual-by-design rationale for Tier 2a
