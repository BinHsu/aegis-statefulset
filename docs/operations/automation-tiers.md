# Automation tiers — what auto-recovers, what doesn't, and why

> Companion to ADR-04 (backup, DR & HA). Catalogues every failure mode
> we consider in scope for this architecture, the level of automation
> applied today, and the conditions under which the architecture *could*
> flip the level. Each Tier 2 row decomposes against the four senior
> automation segments — detection, mechanism, decision, cost commitment —
> so the reader can see exactly which segments are auto and which remain
> human-gated, and what would have to change to promote.

---

## Tier matrix at a glance

<img src="../diagrams/d7-automation-tier-matrix.svg" alt="Three tiers of automation — Tier 1 fully auto / Tier 2 semi-auto by design / Tier 3 manual by design — with the four-segment senior framework (detection / mechanism / decision / cost commitment)" width="100%" />

The three tiers map to the four-segment senior framework (detection /
mechanism / decision / cost commitment). Tier 1 has all four segments
auto and is the K8s + AWS managed baseline. Tier 2 has detection +
mechanism auto but decision + cost human-gated by design — promotion
to Tier 1 needs the customer's organisation to have solved the gating
upstream. Tier 3 is principled manual — auto would do the wrong thing
or would need per-customer ticketing context. Tier 3 → Tier 2
promotion typically requires a storage-primitive change (LevelDB →
TiKV); Tier 2 → Tier 1 typically requires the customer's chaos /
FinOps / audit gates to be already auto.

## Spec scope vs. architectural assumptions

This doc covers the spec-literal failure-mode set plus a wider set of
operational scenarios that show up for stateful K8s on cloud in
practice. We mark each entry's grounding so the panel can see the line.

| Source | Items |
|---|---|
| **Spec literal** (Stage 2 spec verbatim) | Pod / node failures · 2 TB/pod backup with RPO 6 h · Restore procedure · Autoscaling · Live-prod migration · Failure / node-issue / backup-error monitoring |
| **Spec implicit** (extrapolation from spec wording, defensible) | AZ-scope failure (broader reading of "node failures") · DR drill (implicit in "thorough restore") |
| **Architectural assumption** (our choice; Stage 3 confirms) | Multi-AZ stateful tier · Multi-region cold-DR · Cell-based multi-tenancy · Per-tenant hot-spot operations · GDPR-grade tenant deletion |
| **Storage-primitive specific** (LevelDB / EBS / LSM tree pain points) | PV detach-attach failures · Per-pod disk exhaustion (LSM 2× requirement) · Compaction stall · MANIFEST corruption · Backup integrity drift |

**Why we list more than spec-literal:** the panel will ask. Limiting to
spec-literal would dodge the "what about X" questions that determine
whether the architecture is real or paper. Each non-literal entry is
either industry-standard SaaS practice (multi-tenancy / DR / GDPR) or
LevelDB-storage-primitive-specific (compaction / MANIFEST / 2× disk).

The architecture is calibrated against the customer's published 99.5%
uptime SLA + 24 h-implicit-RPO baseline (per `docs/SUBMISSION.md` § 0).
Whether to flip any Tier 2 item to Tier 1 is a Stage 3 conversation —
the right answer depends on the customer's *aspirational* SLA + the
organisational maturity of their decision + cost-commitment gates.

---

## Tier 1 — Fully auto-recovered today (no operator action)

These work without human intervention. They're the K8s + AWS managed
baseline; the architecture builds on top.

| Failure mode | Recovery mechanism | Typical recovery time | Operator notification |
|---|---|---|---|
| Single pod crash | kubelet `livenessProbe` restart | seconds | metric only (CrashLoopBackOff alert if rate > threshold) |
| Pod OOM | kubelet restart + `RestartPolicy: Always` | seconds | metric only |
| Container image pull failure | kubelet retry with exponential backoff | seconds-minutes | metric only |
| Single node hardware failure | EKS managed node group ASG replaces; StatefulSet rebinds PVC | ~5–10 min | Slack notification (informational) |
| Single AZ subnet flap (transient) | AZ-rotation logic doesn't fire below threshold | n/a (no action taken) | metric only |
| Stateless tier load spike | HPA + Karpenter | seconds-minutes | metric only |
| Cluster controller drift (dev only) | ArgoCD `selfHeal: true` | minutes | Slack notification |
| Helm release version drift (dev only) | ArgoCD auto-sync | minutes | Slack notification |
| Velero backup transient failure | Velero internal retry (3× exponential backoff) | seconds | alert only if N consecutive fail |

These cover ~80–90 % of incidents in normal operation. The remaining
~10–20 % are the AZ-and-above events the next tier addresses.

---

## Tier 2 — Auto-detect, manual-execute (architecture default)

These the architecture detects automatically (within ~30 sec via
Prometheus + ALB health + Blackbox probe) but **executes manually** via
a runbook. The operator has a 5–10 min decision window between page and
action — intentional, see § "Why we chose semi-auto" per row below.

**Senior framing — four segments of automation** (per the
[automation-rebalance industry pattern][1]):

```
detection       → can be auto (metrics + probes)
mechanism       → can be auto (runbook script wrapped in Lambda / controller)
decision        → human-gated by default ("is this real, is this safe to act on")
cost commitment → human-gated by default (FinOps approval, audit trail)
```

For each Tier 2 row below, the table shows which segment is auto today,
which would have to change to promote to Tier 1, and the industry
reference points. We do **not** ship a generic full-auto Lambda diff
because the decision + cost gates are organisation-specific — a generic
skeleton would be either dangerous (bypasses the gate) or useless
(re-implements the gate per customer).

[1]: # "Reference: AWS Well-Architected Reliability pillar; Google SRE book Ch. 18 'Automation at Google'."

---

### 2a. AZ failure rotation

| Segment | Today | Auto-promotion conditions |
|---|---|---|
| Detection | ✅ ALB health degraded + Blackbox probe + Prometheus pod-failure alerts (~30 sec) | Already auto |
| Mechanism | ✅ Runbook `scripts/dr/az-rotation.sh` (manual invocation) | Wrap in Lambda + EventBridge with cooldown + cross-source verification (~1–2 days work) |
| Decision | ❌ Operator: "transient or sustained?" within 5–10 min window | Customer's chaos-engineering maturity has solved single-source-detection false-positive problem (e.g., Prometheus federation cross-region check is reliable + assertion catalogue exists) |
| Cost commitment | n/a (no marginal $ cost; cost is customer-visible degradation if false-positive fires) | n/a — but customer has explicit error-budget framework that absorbs false-positive cost |

**Recovery time today:** ~25 min (5–10 min decision + 5 min node-group scale-up + 10–15 min Velero restore).
**Full-auto recovery time:** ~15–20 min (no decision delay).

**Why semi-auto today:**

1. **Auto-failback is unsafe with single-writer LevelDB.** Once the
   new master AZ has accepted writes, those writes don't exist in the
   original master. If the original AZ recovers and an automated rule
   fails back, those writes are lost (or require reverse-sync, which
   ADR-04 explicitly retired).
2. **False-positive AZ-failure jitter has real customer cost.** A
   spurious "AZ-A is down" event triggers a 25-min rotation; if AZ-A
   wasn't actually down, that 25 min is customer-visible degradation
   × every active tenant. At 99.5% SLA's 3.6 h/month budget, one false
   positive eats ~12% of the month.
3. **Cascading failure judgment.** "Is this AZ-A failing, or is AWS
   regional networking having a bad day, or is our own observability
   stack lying to us?" These are pattern-matching calls that humans
   are currently better at than rule-based automation.

**Industry reference points:** AWS Well-Architected Reliability pillar
(automated recovery with explicit guardrails); Netflix Chaos Monkey
(AZ-level for stateless, manual rotation for stateful DBaaS).

---

### 2b. Region failure cutover

| Segment | Today | Auto-promotion conditions |
|---|---|---|
| Detection | ✅ Cross-region observability + AWS Health API + Route 53 health-checks (~1 min) | Already auto |
| Mechanism | ✅ Runbook `scripts/dr/region-failure-recovery.sh` | Route 53 weighted-record-with-health-check + Lambda triggering Velero restore in DR region (~2–3 days work) |
| Decision | ❌ Operator: "real region outage, or transient correlated event?" (5–15 min window) | Customer accepts auto-cutover risk (rare to ever do — distributed-by-design DBs like Spanner / Cockroach are the only systems where this is routine) |
| Cost commitment | ❌ DR-region warm capacity provisioning costs hundreds of $ on every cutover | Customer has explicit DR-spend budget pre-approved + accepts that spurious cutover costs are recoverable |

**Recovery time today:** ~50 min (10 min decision + 25 min Velero restore + 15 min DNS / TTL propagation).
**Full-auto recovery time:** ~35–45 min.

**Why semi-auto today:**

1. **Same write-loss issue as AZ rotation, amplified at region scope.**
   Cross-region cutover is even more destructive of in-flight writes.
2. **Cross-region cluster bootstrap costs real money.** A spurious
   region-cutover event provisions a full DR-region cluster, runs Velero
   restore (~25 min), and may rack up several hundred $ before being
   un-cutover.
3. **DNS TTL means customer-visible cutover takes minutes regardless.**
   Auto-cutover doesn't actually save customer-experience time if TTL
   is set conservatively (which it should be for stateful tier where
   cutover is destructive).

**Industry reference points:** Google SRE book Ch. 26 "Data integrity"
(human-in-loop for cross-region cutover of stateful systems); 95%+ of
SaaS run cold-DR with manual cutover decision; only distributed-by-design
storage primitives (Spanner / Cockroach / DynamoDB Global Tables) make
auto-cutover safe.

---

### 2c. Cell capacity exhaustion

| Segment | Today | Auto-promotion conditions |
|---|---|---|
| Detection | ✅ Prometheus alert on `tenant_storage_bytes` per cell crossing threshold | Already auto |
| Mechanism | ✅ Runbook `scripts/capacity/expand-cell.sh` (provisions new cell via ApplicationSet patch) | Custom K8s controller watching threshold + patching ApplicationSet (~1–2 days work) |
| Decision | ❌ Operator decides: "expand cell" or "relocate hot tenants out" | Operator-policy ConfigMap encodes decision rules; Stage 3 establishes policy is stable enough to encode |
| Cost commitment | ❌ Each new cell adds ~€700/month per `cost-estimate-methodology.md` | FinOps approval webhook exposed via HTTP API + customer accepts auto-spend up to per-cell cost |

**Recovery time today:** Hours-to-days (planned operation, not incident response).
**Full-auto recovery time:** Minutes-to-hours.

**Why semi-auto today:**

1. **Cell expansion involves cost commitment.** Auto-expansion can
   blow the cost budget without operator approval.
2. **Hot-tenant identification is a judgment call.** Telemetry shows
   *which* tenants are hot; deciding whether to move them, expand the
   cell, or accept the contention requires understanding customer
   impact + capacity-plan trajectory.
3. **Expansion is rarely incident-driven.** It's a planned operation
   measured in days; auto-firing on a Friday afternoon is the wrong
   tempo.

**Industry reference points:** AWS cell-based architecture pattern
(public 2018+); Salesforce pod expansion is per-quarter capacity-plan
exercise, not reactive; HPA / Karpenter / Cluster Autoscaler handle
*replica* scaling within an existing cell automatically — those are
in Tier 1.

---

### 2d. Per-tenant hot-spot relocation

| Segment | Today | Auto-promotion conditions |
|---|---|---|
| Detection | ✅ Prometheus alert on per-tenant request rate / IOPS share | Already auto |
| Mechanism | ✅ Runbook `scripts/relocation/per-tenant-relocate.sh` | CronJob bin-packer running in customer-specified maintenance window (~1–2 days work) |
| Decision | ❌ Operator decides: which tenant, target cell, schedule | Bin-packing policy production-tuned + per-cell totals telemetry + scheduling policy encoded |
| Cost commitment | ❌ Per-tenant brief unavailability during relocation; customer-visible | Tenants have accepted maintenance-window unavailability in contract / SLA |

**Why semi-auto today:**

1. **Relocation involves data movement** — costly and customer-visible.
2. **Per-tenant short outage** during relocation needs scheduling
   coordination (avoid customer's business hours).
3. **Hot-tenant prediction is hard** — auto-relocation may move a
   tenant that was momentarily hot but would have settled.

**Industry reference points:** Salesforce pod migrations are per-batch
manual approve; MongoDB chunk balancer is auto only for sharded clusters
(distributed-by-design); Vitess re-sharding is operator-initiated.
Auto-relocation for non-distributed-by-design systems is essentially
unique to a few mature SaaS orgs (Salesforce-scale).

---

### 2e. PV / EBS detach-attach failure ⭐ LevelDB+EKS specific

| Segment | Today | Auto-promotion conditions |
|---|---|---|
| Detection | ✅ Pod stuck `ContainerCreating` + EBS volume attachment-state stuck (CloudWatch metric + K8s event) | Already auto |
| Mechanism | ✅ Runbook `scripts/dr/force-detach-pv.sh` (AWS CLI `detach-volume --force`) | Lambda subscribing to pod-events SNS topic (~1 day work) |
| Decision | ❌ Operator confirms: "is the previous pod definitely dead, not in `Terminating`?" | Pod-state check fully reliable across grace-period edge cases (rarely true in practice) |
| Cost commitment | n/a | n/a |

**Why semi-auto today:**

1. **Force-detach risks data corruption** if the previous pod is still
   writing. AWS CLI `detach-volume --force` is the industry workaround
   for stuck attach-detach but is destructive if used prematurely.
2. **Pod `Terminating` state is unreliable** during graceful drain —
   the API may report `Terminating` while the pod is actually still
   flushing LevelDB writes to disk via the SIGTERM handler.

**Industry reference points:** documented AWS EBS-CSI driver issue
(GitHub kubernetes-sigs/aws-ebs-csi-driver); standard ops pattern is
human-confirmed force-detach. Karpenter consolidation makes this *more*
common because nodes get torn down faster than EBS detach completes.

---

### 2f. Per-pod disk space exhaustion (LSM 2× requirement) ⭐ LevelDB specific

| Segment | Today | Auto-promotion conditions |
|---|---|---|
| Detection | ✅ Per-PV usage metric crossing threshold (e.g. 80% of 2 TB allocated) | Already auto |
| Mechanism | ✅ Runbook: online-resize EBS (`aws ec2 modify-volume`) + `resize2fs`, OR migrate hot tenant to new cell | Lambda triggering `modify-volume` (~1 day work) |
| Decision | ❌ Operator: "expand PV (cheaper but pod stuck on this AZ) or migrate tenant out (more flexible, more disruption)" | Capacity-plan policy encodes the decision rule |
| Cost commitment | ❌ Larger EBS volume costs ~$0.08/GB/month for gp3 | Pre-approved per-cell expansion budget |

**Why semi-auto today:**

1. **LSM tree compaction needs ~2× free disk** for level merges.
   Hitting 80% threshold means compaction has already started failing,
   not "approaching the limit". Auto-resize must include grace headroom
   for the compaction storm that follows.
2. **Decision between resize vs migrate is policy-driven.** Resize
   keeps tenant pinned to AZ; migrate frees capacity but causes
   per-tenant downtime.

**Industry reference points:** Facebook RocksDB tuning guide explicitly
documents 2× disk requirement; AWS EBS gp3 supports online resize but
filesystem expansion (`resize2fs`) requires K8s pod restart in many
configurations.

---

### 2g. Compaction stall / write-amplification storm ⭐ LevelDB specific

| Segment | Today | Auto-promotion conditions |
|---|---|---|
| Detection | ✅ LevelDB internal metrics (`level0_num_files`, `compaction_pending_bytes`, `write_stalls`) scraped to Prometheus | Already auto |
| Mechanism | ✅ Runbook: tune compaction threads / level-size ratios in app config + restart pod, OR migrate hot tenant out | Application-layer hot reload of LevelDB compaction tunables (~complex; depends on app) |
| Decision | ❌ Operator: "tune compaction (transient burst)? scale vertically (sustained write rate)? migrate tenant (single-tenant abuse)?" | Workload-shape signature recognised + auto-classified (very rare; usually app-specific) |
| Cost commitment | varies | Customer-specific |

**Why semi-auto today:**

1. **Compaction stall is a *symptom*, not a failure mode.** Three
   distinct root causes (transient write burst / sustained write rate
   exceeding compaction throughput / single-tenant pathological access
   pattern) need different responses; auto-action without classification
   is dangerous.
2. **Application-side LevelDB tunables vary by app.** This is the
   customer's app, not the platform's; platform can monitor + alert
   but the action is in the app's runtime config.

**Industry reference points:** Facebook RocksDB tuning guide; LevelDB
documentation `doc/impl.md` § "Compaction"; this is an operational
concern documented since LevelDB's 2011 release. Most production K-V
deployments expose compaction-tuning as runtime config.

---

### 2h. Backup integrity verify-restore drift

| Segment | Today | Auto-promotion conditions |
|---|---|---|
| Detection | ✅ Scheduled verify-restore drill (weekly Velero `restore --verify` to scratch namespace) + EBS-snapshot integrity check | Already auto |
| Mechanism | ✅ Runbook: select older known-good backup, retry restore | Auto-fallback to N-1 backup tag (~1 day work) |
| Decision | ❌ Operator: "accept data loss to N-1 backup, or escalate to vendor-side EBS snapshot recovery?" | Data-loss tolerance encoded as policy (rare — usually escalates anyway) |
| Cost commitment | ❌ Vendor-side EBS snapshot recovery is AWS support case | n/a |

**Why semi-auto today:**

1. **Silent corruption is rare but irrecoverable.** Failed verify-restore
   drill is the *only* signal; without it, operator discovers corruption
   only when needing the backup for real.
2. **Choosing N-1 backup vs escalation is judgment call.** Depends on
   how much data loss the customer absorbs vs how much wall-clock the
   AWS support case will cost.

**Industry reference points:** AWS EBS snapshot integrity bugs are
documented (rare but real, e.g. 2018 cross-region replication bug);
NIST SP 800-34 R1 explicitly requires verify-restore drills for
recovery-confidence; ISO 27001 Annex A.12.3 same. Velero `restore --verify`
is the standard implementation.

---

## Tier 3 — Manual by design (no auto path advised at current architecture)

These remain manual because the cost / risk of auto-execution exceeds
the benefit at the current architecture's storage primitive (LevelDB
single-writer). Each row has a defensible "why manual is the right call"
— these are principled exclusions, not gaps.

| Failure mode | Why manual is the right call | Trigger to revisit |
|---|---|---|
| Multi-region simultaneous failure | Implies an extreme correlated event (AWS provider outage); judgment about scope of response is essential. Auto-action could amplify the incident if root cause is unknown. | Regulatory require sub-1h multi-region RTO |
| Cluster recreation from cold | Designed for quarterly DR drill, not unplanned use. If frequent enough to merit automation, the architecture has a more fundamental problem. | If frequency rises above 1/quarter unexpectedly |
| Tenant data restore from a specific timestamp | Per-customer support request; needs human-side ticketing context (which tenant, what timestamp, who authorised). | Granular per-tenant point-in-time restore as product feature → triggers Restic-FSB patch (per `docs/future/restic-fsb-patch.md`) |
| ⭐ LevelDB MANIFEST file corruption | Extremely rare LevelDB internal-state bug or fsync failure. Recovery is from backup (Velero restore). Auto-detection is possible (DB fails to open) but auto-action is just "restore from backup", which is destructive — operator must confirm last-known-good backup tag. | If frequency rises above 1/year (would indicate fundamental fsync / EBS reliability issue) |
| ⭐ GDPR tenant deletion / right-to-be-forgotten | Per-customer compliance request; needs legal-side ticketing context (jurisdiction, timeline, retention-override policy). Auto-deletion across backup retention windows is policy-specific. | n/a — manual is the regulated answer |

If LevelDB is replaced with a distributed K-V (TiKV; see
`docs/future/tikv-upgrade-path.md`), some Tier 3 items move to Tier 2
or Tier 1 because the storage primitive supports the auto-recovery
shape (multi-master writes survive node loss without manual rotation).
That's the upgrade-trigger conversation, not a patch for the current
architecture.

---

## Why we don't ship Tier 2 → Tier 1 promotion as a generic patch

Earlier drafts of this architecture included four "auto-X" patches
(applicable Lambda + IAM + EventBridge / custom controller diffs) that
flipped each Tier 2 row to full-auto. They were dropped from the final
submission for three reasons:

1. **Decision + cost gates are organisation-specific.** The interesting
   work to flip semi-auto → full-auto is *not* the Lambda body — it's
   wiring up the customer's chaos-engineering assertion catalogue,
   their FinOps webhook, their audit policy. A generic Lambda body
   would either bypass these gates (dangerous) or re-implement them
   per customer (~the same effort as starting from scratch).
2. **Industry reality is semi-auto for stateful.** Distributed-by-design
   systems (Spanner / Cockroach / Cassandra) handle these failure modes
   in the storage layer; LevelDB single-writer cannot. Shipping a
   "look, it can be automated" patch for a system structurally outside
   that family is a category error.
3. **The matrix is the deliverable.** A senior platform engineer's job
   is to identify *which segments are auto, which are gated, and what
   would have to change to promote* — not to ship Lambda skeletons.
   The Tier 2 tables above are exactly that artefact.

The one exception is `docs/future/restic-fsb-patch/` — backup transport
choice (CSI ↔ FSB) is binary and not gated on organisational maturity,
so it ships as an applicable diff.

---

## Summary table — for Stage 3 conversation

| Auto level | Failure modes covered | Operator discipline needed |
|---|---|---|
| **Tier 1 (always auto, today)** | Pod / node / image / spot capacity / autoscale / Velero retry | Pager rotation; metric review |
| **Tier 2 (semi-auto by design)** | AZ rotation · region cutover · cell expansion · per-tenant relocation · PV detach-attach · per-pod disk exhaustion · compaction stall · backup integrity drift | Decision-window judgment; runbook execution; per-row policy gates (FinOps / chaos-engineering / capacity-plan) |
| **Tier 3 (manual by design)** | Multi-region correlated · cluster cold-recreate · per-customer point-in-time restore · LevelDB MANIFEST corruption · GDPR tenant deletion | Incident command; cross-team coordination; legal / compliance review |

The architecture's choice of "Tier 2 = semi-auto by default" is a
deliberate trade against single-writer LevelDB physics + industry SaaS
norm of human-gated decision + cost. If the customer wants any Tier 2
item flipped to full-auto, the conversation is *which segments are
already auto for them and which gates they want platform-side*, not
"apply this patch". If the customer wants Tier 3 items also
auto-recoverable, the conversation is "replace the storage primitive"
— TiKV per `docs/future/tikv-upgrade-path.md`, not "add more automation
on top of LevelDB."

---

## Cross-references

- `docs/SUBMISSION.md` § 0 — public-SLA grounding that calibrates these tiers
- `docs/operations/why-cold-dr.md` — why cold DR over active-passive (orthogonal but related)
- `docs/future/restic-fsb-patch.md` — the one applicable patch (backup transport)
- `docs/future/tikv-upgrade-path.md` — what changes if storage primitive flips
- ADR-04 (backup, DR & HA) — architectural decision this catalogues operationally
- ADR-15 (master AZ rotation policy) — manual-by-design rationale for Tier 2a
