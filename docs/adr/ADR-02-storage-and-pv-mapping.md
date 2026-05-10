# ADR-02: Storage architecture and pod-to-PV mapping discipline

## Status

Proposed (POC submission scope; subject to confirmation in Stage 3 conversation).

## Thesis

EBS volumes are the only irreplaceable asset in this architecture; everything else — pods, nodes, etcd, even the cluster — is reproducible. Storage decisions therefore optimise for the survival and addressability of EBS data first, and for cost or density second. The result is a single-master-AZ stateful pool with one pod per node, a 2 TB gp3 volume managed via LVM, online-expandable in place, and a four-layer mapping discipline that lets the binding from `app-statefulset-primary-N` to its EBS volume be reconstructed even if etcd is wiped.

## Context (why these decisions belong together)

This ADR consolidates four storage and capacity decisions that were originally written as separate documents but only make sense as a single position. They share one premise — "EBS is treasure, infrastructure is cattle" — and four consequences flow directly from it:

1. The volume itself must be the right shape (size, type, layout) to serve the workload while staying within the backup-time budget that gates RPO.
2. The binding from pod identity to volume identity must survive every realistic failure: pod crash, node loss, etcd loss, full cluster destruction.
3. The node hosting the pod must give the workload predictable resources, with a failure scope that maps cleanly onto a single tenant cohort rather than several.
4. Horizontal scaling must respect the fact that adding a pod does not redistribute data on existing pods — so "scaling" decomposes into two operationally distinct modes.

These four are intertwined: the LVM layout exists to make backup non-disruptive, which gates the backup window, which gates how large a pod is allowed to grow before relocation is preferred over expansion. The 1:1 pod-to-node ratio exists so that node failure equals exactly one pod failure, which is what the four-layer mapping discipline assumes when it walks EBS tags during DR. Splitting these into separate ADRs hid the shared logic.

The current architecture also adds one constraint that reshapes earlier framing: stateful workloads run in a single master AZ. AZ-B and AZ-C have subnets, NAT, and node groups defined but desired-count zero — they exist for cold-DR rehydration via Velero + EBS Snapshot, not for live failover. This narrows the storage problem from "multi-AZ EBS coordination" to "single-AZ EBS with off-region snapshot rehydration," which is a much smaller footprint and removes the need for cross-AZ EBS replication primitives in the baseline.

## Decisions

### EBS shape: gp3 2 TB default, LVM-managed, online-expandable

The spec calls for "Restic backup with LVM for 2 TB of data with each pod" with RPO 6 hours. This implies a per-pod EBS volume in the 2 TB range, LVM as the volume manager, and backup that does not take the pod offline. Each of those requirements pushes the design in a specific direction.

The default volume is `gp3` at 2 TB with baseline IOPS (3000) and throughput (125 MB/s). At 2 TB the gp3 baseline is sufficient for LevelDB workloads at typical cohort sizes — the dominant cost is sequential writes during compaction, not random IOPS — and `io2` would cost five to ten times more for guaranteed IOPS that the workload does not need. The per-pod cost lands at roughly $160/month for storage alone (gp3 is approximately $0.08 per GB-month), which is bounded and predictable. If a specific customer profile needs more, a separate StorageClass with higher provisioned IOPS is the per-pod escape hatch; the baseline does not get pulled up by exceptions.

The volume is laid out as one physical volume → one volume group (`vg-app`) → multiple logical volumes:

- `leveldb-data` at roughly 90% of the VG — the active database files.
- `leveldb-wal` at roughly 5% — the write-ahead log, separated because its IO profile (sequential, append-only) differs from the data files (random read plus sequential write during compaction). Separating it onto its own LV avoids COW write amplification on the WAL during snapshots and allows different backup policy if that ever becomes useful.
- A 5% snapshot reserve for COW during LVM snapshots — the rule-of-thumb size that holds all blocks changed during a backup window on a 2 TB volume, with margin for write-heavy workload spikes.

The 5% snapshot reserve is sized against the 5-minute Velero schedule (ADR-04). At that cadence the snapshot LV only holds blocks changed during a five-minute window, so 100 GB of COW reserve is comfortable margin even under sustained write load. The reserve is a parameter, not a hard ceiling: the backup script monitors snapshot LV usage and either extends or aborts before the reserve fills, raising an alert rather than producing a corrupt snapshot.

LVM is not optional here. Restic on a live LevelDB filesystem races compaction; without a stable point-in-time view, the backup is at best inconsistent and at worst corrupt. LVM snapshot is block-level COW: instant, crash-consistent, no measurable performance impact on the active filesystem, and it gives Restic a stable mount point to walk. The spec asks for LVM by name, and the architectural reason matches the ask.

Separating WAL onto its own LV is operational hygiene rather than a performance optimisation. The WAL has a different IO profile from the data files — sequential and append-only, versus the random-read-plus-sequential-write pattern of compaction — and a separate LV lets the snapshot exclude it cleanly when the recovery model treats the WAL as replay-from-source rather than as backed-up state. It also avoids COW write amplification on the WAL during snapshot windows, which matters because the WAL is the most write-intensive part of the volume during normal operation. The cost is one additional LV to manage; the benefit is that the WAL's IO profile is never accidentally entangled with the data files' backup window.

The StorageClass sets `allowVolumeExpansion: true`. EBS supports online resize, and LVM's `pvresize` → `lvextend` → `resize2fs` (or `xfs_growfs`) chain runs without unmounting. This matters because the 2 TB cap is not a physical EBS limit — gp3 supports up to 16 TiB — it is a backup-time budget. A 2 TB pod backs up in roughly 4-8 hours under typical change rates, which fits within the 6-hour RPO window. A 4 TB pod takes 8-16 hours, which violates the RPO on heavy-write days. So 2 TB is the line where the backup discipline still works, and online expansion is the path for the cases where it is acceptable to widen the cadence.

### When to expand vs relocate (the gateway between two operational primitives)

When pod usage approaches the cap, two paths exist, and the choice is not arbitrary. It depends on the tenant distribution within the pod:

```
Pod usage > 70% AND single tenant > 50% of pod size
  → Relocate that dominant tenant to a dedicated cell
  → Rationale: tenant is large enough to dominate any cohabited pod;
    cohabitation is producing the same problem it would produce elsewhere

Pod usage > 80% AND single tenant > 30% of pod size
  → Relocate that tenant (greedy or to a dedicated cell)
  → Rationale: removing one large tenant frees enough headroom that the
    remaining cohort fits within the 2 TB backup-budget envelope

Pod usage > 80% AND no tenant > 30% (uniform cohort growth)
  → Online-expand pod EBS in place
  → Accept the longer backup window: 4 TB pod ≈ 8-16h backup
  → Operator must explicitly approve the RPO posture change
  → Trade-off: keep all tenants in place; relocation cost avoided
```

This is a tree, not a single rule, because online expansion and relocation each pay a different cost. Expansion is "do nothing to the customer" but extends the backup window and erodes RPO compliance. Relocation is "move one customer's data" — operationally heavier, but it preserves the backup window across all pods. The right answer depends on whether the pod's growth is concentrated in a single dominant tenant (relocate that tenant) or spread evenly across the cohort (expand). The migration ADR (ADR-05) encodes the threshold values and the runbook for the relocation path; the storage decision here is the gateway that decides which runbook to invoke.

### Pod-to-PV mapping: four independent layers, reclaimPolicy=Retain

The premise — "EBS is treasure" — implies that no operational action should ever delete EBS data, and the binding from pod identity to volume identity must survive arbitrary cluster failures. K8s offers several primitives for this binding (StatefulSet ordinal naming, PVC-PV claimRef, CSI volumeHandle, EBS volume tags), but they form a chain of references where any single broken link can orphan data. The discipline is to maintain four independent layers, each able to reconstruct the binding if higher layers are lost:

1. **StatefulSet ordinal naming.** Pod `app-statefulset-primary-N` always claims PVC `data-app-statefulset-primary-N`. Declarative, deterministic, lives in the Helm chart.
2. **K8s etcd PVC-PV binding state.** PVC `data-app-statefulset-primary-N` is bound to PV `pv-app-N` with `claimRef`. Persists across pod restart but lost if etcd is wiped.
3. **CSI driver volume handle.** The PV's `volumeHandle` is the EBS volume ID. Lives in PV spec; survives pod and node replacement as long as the PV resource itself survives.
4. **EBS volume tags (DR fallback).** Tags on the EBS volume itself encode the K8s identity:
   - `kubernetes.io/created-for/pvc/name` = `data-app-statefulset-primary-N`
   - `kubernetes.io/created-for/pvc/namespace`
   - `app/pod-ordinal` = N
   - `app/cluster` = cluster name
   - `app/originating-server` = legacy server-N (for migration provenance)

When etcd is lost, the DR script walks the AWS API for EBS tags, reconstructs PV manifests with `claimRef` pointing back at the right PVC name, and `helm install` brings up pods that re-bind to existing EBS. That recovery path only works because the tags are maintained at the volume level; if they were only in etcd, they would be lost together with the binding they were supposed to back up. The four layers fail independently: pod crash does not break PVC binding, node failure does not break PV, etcd loss is recoverable from EBS tags, and even if a single tag is corrupted the other three layers still anchor the binding. Multi-layer redundancy with no single point of failure is the architectural intent — each layer compensates for the loss of the layer above it.

EBS tags are deliberately framed as the operator's seatbelt, not as the primary binding. In the worst-case scenario — entire cluster destroyed, etcd backup unavailable, no Helm history — an operator can list EBS volumes in the AWS console, identify them by tag, and reconstruct manifests by hand. Tags are the ground truth that lives outside K8s; everything else is a reference into that truth. The migration path (ADR-05) leans on this property: when the legacy `server-N` is mapped to K8s `app-statefulset-primary-N`, the tag `app/originating-server` records that mapping permanently, and the binding survives even if every K8s record is lost.

Three discipline rules lock this in:

- StorageClass sets `reclaimPolicy: Retain`. The default `Delete` policy deletes EBS when a PV is deleted, which is catastrophic for this model. `Retain` is the only correct setting for stateful workloads, and codifying it as a discipline rule prevents the accidental change later. This is non-negotiable.
- StatefulSet name is locked once deployed. Renaming a StatefulSet renames every pod, which renames every PVC, which orphans every EBS volume from K8s' point of view. Recovery is possible via the tag-walk path, but rename is not an "oops" operation — it is a planned migration.
- Both PVC and PV carry finalisers preventing accidental deletion. Combined with `Retain`, this is three-layer protection against `kubectl delete pvc -A`.

The accepted cost is that orphaned EBS volumes accumulate when pods are permanently retired and their PVCs deleted. The volume remains in AWS until an operator manually deletes it via the console, with explicit confirmation. That is the right asymmetry: accidental retention is recoverable, accidental deletion is not.

A subtler cost is EBS tag drift over time. If tags are not maintained on EBS resize or restore events, the DR fallback degrades silently — the recovery script walks the AWS API and finds tags that no longer reflect current pod identity. Mitigated by Terraform managing the tags as part of the EBS resource definition (drift surfaces in `terraform plan`), and by CI checks that verify tag compliance against the K8s state on a schedule. The discipline rule is that tag changes flow through the IaC pipeline; manual `aws ec2 create-tags` is a process violation, not a workflow.

### Node pool: 1 pod per node, single master AZ, on-demand stateful

The node hosting a stateful pod must give the pod predictable resources and a clean failure scope. Two extremes were considered. High density (N stateful pods per node) is cost-efficient but introduces noisy-neighbour effects — page cache contention, EBS IOPS contention, kernel resource limits — that degrade tail latency unpredictably; node failure also takes N pods at once, which makes blast-radius reasoning harder. Low density (1 stateful pod per node) is the boring-correct default for a POC demonstrating reliability of a stateful platform.

The chosen node shape is `r6id.2xlarge` (8 vCPU, 64 GB RAM, NVMe instance store). The 64 GB RAM accommodates LevelDB working set plus OS page cache for a 2 TB EBS workload; 8 vCPU is sufficient for compaction overlapped with serving traffic; the NVMe instance store is useful for temp space and snapshot spillover during backup. The right shape for the default per-pod profile, with the option to use a different StorageClass-and-instance-type pair for enterprise pods that need 16 vCPU / 128 GB.

The `r6id` family was preferred specifically for the NVMe instance store, which is operationally useful during backup — the LVM snapshot can be staged through local NVMe before being uploaded to S3 by Restic, smoothing the IO pattern away from the EBS volume during the most write-amplified phase. Bare-metal `i3en` was considered as an alternative for ultra-high-IOPS profiles but rejected as overkill at this scale; the trigger to revisit is per-pod sustained IOPS demand exceeding gp3 capability, which would also be the trigger to consider `io2 Block Express` for the EBS volume itself.

Stateful pods run in a single master AZ ASG. AZ-B and AZ-C ASGs are defined with desired=0 and exist only for the cold-DR rehydration path: when the master AZ fails, Velero restores into one of the warm-standby AZs by scaling its node group up and applying the rehydrated PV manifests. There is no live cross-AZ stateful workload in this architecture; HA is achieved through cold DR with documented RTO, not through active-passive replication. The detailed DR flow lives in ADR-04.

ASG sizing for the master AZ:

- `min` = `desired` = N stateful pods (one node per pod plus headroom for surge during rolling update, expressed as `max = desired + 1`).
- On-demand only, no spot. Spot interruption combined with EBS detach-and-reattach in the same AZ is brittle, especially during capacity pressure when spot is interrupted because demand is high — exactly when the platform needs to be reliable. The savings (60-70% on EC2) do not justify the reliability hit for stateful.
- ASG plus a Lambda lifecycle hook for graceful node drain — pre-stop hook flushes LevelDB, unmounts LVM cleanly, then deregisters from the target group.

Karpenter handles the stateless tier in parallel: multi-AZ subnet selection, mixed spot 70% / on-demand 30%, diverse instance types in the m6i family, HPA-driven response in roughly 30 seconds. Karpenter's strengths — spot mixing, instance diversity, fast scale-up — are exactly what stateless wants and exactly what stateful does not want; Karpenter's consolidation logic in particular is aggressive and would evict stateful pods to bin-pack. Two pools, two tools, no overlap.

The 1:1 ratio also pays off in capacity reasoning. With one pod per node, the topology can be read directly from the AWS console: "9 stateful pods means 9 master-AZ nodes plus warm-standby capacity in two other AZs at desired=0." Pod count equals node count plus a small surge. Operators do not have to reconstruct the bin-packing decisions of the scheduler to understand what the cluster looks like physically. That clarity is worth the cost of the unused capacity per node — particularly for a POC where the priority is "demonstrate that the platform behaves predictably" rather than "extract the last 20% of efficiency."

### Horizontal scaling: two modes, one slow, one fast

The naive answer to "can we autoscale this?" is "yes, HPA on the StatefulSet, scale on CPU." That answer assumes the workload is stateless. For a per-tenant stateful system, adding a pod does not shed load from existing pods — existing tenants stay on their cell, and the new pod only helps with new tenant capacity. Pretending otherwise is the source of considerable operational confusion ("I scaled up, why didn't latency drop?").

Horizontal scaling here decomposes into two modes with very different operational profiles:

**Mode 1 — resharding existing tenants (slow).** Triggered when a specific cell sustains greater than 85% utilisation with no organic slowdown in sight. The action is to move existing tenants from over-utilised cells to new or under-utilised cells. Operationally this is a manual, planned-maintenance procedure: per-cell migration takes one to three hours (Restic backup → restore on new pod → cutover via the routing primitive in ADR-03 → soak), and the blast radius if it goes wrong is significant. POC scope is a documented procedure, not automation. Operators get paged at 85% per-cell utilisation; humans schedule the maintenance window.

**Mode 2 — empty pod fill (fast).** Triggered when aggregate cluster utilisation crosses 70%. The action is to provision a new (primary, standby) pair preemptively so that new tenant onboarding has a destination cell with headroom. The new pod starts empty and is ready to accept signups within minutes; there is no data migration, just Helm upgrade plus a placement-table update directing new signups to the new cell. POC scope automates this: the cell provisioning is a Helm chart parameter, and the placement service writes new tenant rows to the latest available cell.

The two thresholds (70% aggregate for Mode 2, 85% per-cell for Mode 1) align with the cell architecture. Mode 2 keeps the cluster ahead of demand by adding capacity before any individual cell becomes saturated; Mode 1 is the recovery path when Mode 2's preemptive provisioning is not enough — usually because a specific cell has a hot tenant or skewed cohort.

Stateless scaling is orthogonal: HPA per Deployment on CPU / request rate, Karpenter handles the underlying nodes in roughly 30 seconds, no custom logic. It is mentioned here only to make explicit that the stateful tier's mode-aware framing does not apply to stateless — there, the standard pattern works because adding a pod genuinely does shed load.

The mode-aware framing matters because it changes how operators think about capacity alerts. A single-mode HPA-style alert ("cell-3 over 80%") gives the operator no information about which response is appropriate; the same threshold could mean "provision the next cell preemptively" (Mode 2 territory if aggregate is also climbing) or "schedule a rebalance window for the dominant tenant in cell-3" (Mode 1 territory if a single tenant is dominating the cell). The decomposition into two modes with two thresholds gives the alert a concrete next action: 70% aggregate triggers a Helm upgrade adding the next (primary, standby) pair, while 85% per-cell triggers a paged ticket with the relocation runbook attached. Both alerts can be true at once, and they do not contradict each other; they describe different problems with different blast radii.

The accepted trade-offs: Mode 1 requires operator attention (each rebalance is hours of work, and there is no shortcut for the data-move step); the 70% / 85% thresholds are initial guesses that will need tuning against actual workload telemetry; cell utilisation must be measurable, which puts a derived PromQL metric on the operational dashboard.

### Graceful shutdown — the in-pod side of node drain

The infrastructure layer has the node-drain story (ASG lifecycle hook
+ drain Lambda in `infrastructure/terraform/lifecycle-hooks.tf`). The
in-pod side has to match, or the drain is a fiction. Three primitives:

- **`terminationGracePeriodSeconds: 60`** on the StatefulSet template
  (`stateful.termination_grace_seconds` in `values.yaml`). The K8s
  default is 30s — too short for a real LevelDB instance to flush
  MemTable + WAL + release the file lock. 60s is the headroom; tune
  upward for very large MemTable footprints.

- **`preStop` lifecycle hook** with a 10-second sleep. K8s sends the
  container SIGTERM and removes the pod from Service endpoints
  *concurrently*; the sleep gives load-balancer drain time to complete
  before the process actually starts shutting down — avoids the
  5–10 second window where the ALB still sends traffic to a pod that
  has stopped accepting connections.

- **In-app SIGTERM handler.** The application catches SIGTERM, calls
  `http.Server.Shutdown(ctx)` to drain in-flight requests, then
  flushes its data layer (in production: `leveldb.Close()`; in the
  POC mock: `fsync` on `/data`). The mock implements the canonical
  shape in `app/main.go` — exposed for production teams to lift the
  pattern wholesale.

Without all three, every K8s rolling update is a LevelDB corruption
risk. The `lifecycle-hooks.tf` comment about "the pod, evicted
gracefully, terminates with its preStop hook, flushes LevelDB" is
honest only when the StatefulSet template + the app actually wire up
these three primitives. They do, in this submission.

### How the four decisions compose

These four decisions are not independent; each makes the others tractable. The 2 TB cap exists because the backup window must fit the RPO budget; the LVM snapshot exists because the backup must run without unmounting; the 1:1 pod-to-node ratio exists because compaction-heavy LevelDB cannot tolerate noisy neighbours during the snapshot window; the four-layer mapping discipline exists because if any of the previous three is violated under failure, an operator must still be able to find the EBS volume that owns a specific tenant's data and put it back into service.

The mode-aware scaling decomposition closes the loop: Mode 2 (empty-pod fill) is the cheap path that delays the need for Mode 1, and Mode 1's relocation runbook is what the expand-vs-relocate tree calls into when a pod approaches its 2 TB cap with a dominant tenant. Removing any one of these decisions destabilises the others. Density tuning would invalidate the 1:1 simplification of node-failure-equals-one-pod-failure, which the four-layer mapping assumes when it reasons about which tags to walk during DR. Skipping LVM would force a different backup primitive, which would change the RPO budget, which would invalidate the 2 TB cap. The decisions are tightly coupled because they share one constraint — every action must preserve the EBS treasure — and that constraint cuts across all four.

## Trade-offs accepted

- **2 TB uniform default is wasteful for small-cohort pods.** A pod hosting ten small tenants under 10 GB each only uses about 100 GB. The 2 TB EBS is 95% empty, costing roughly $160/month for almost-unused storage. Variable per-pod sizing was deferred because it requires custom operator logic; uniform sizing also simplifies migration. The trigger to revisit is the appearance of enterprise-tier customers who want dedicated pods with custom EBS size.
- **LVM adds operational primitives operators must understand.** PV / VG / LV / snapshot / extent are non-trivial. Mitigated by runbooks (`scripts/backup/lvm-snapshot-restic.sh`) that wrap the commands and by keeping the layout stable across pods so the cognitive load is paid once.
- **Online expansion is one-way.** EBS cannot shrink. If a pod is over-provisioned, the only recovery is to migrate the tenant cohort to a smaller pod and decommission the old volume — same path as a manual rebalance.
- **Snapshot LV consumes space proportional to write rate.** A backup window with heavy LevelDB compaction can blow past the 5% reserve. The backup script monitors snapshot LV usage and aborts/extends as needed; the alert fires before it becomes a data-loss issue.
- **Higher node cost per pod.** Each pod has a dedicated 8 vCPU / 64 GB node, much of which is idle when LevelDB is at low load. Bin-packing would do better. The trade-off is reliability and predictability for cost, paid first.
- **No spot savings for stateful.** Roughly 60-70% on EC2 cost forgone. The savings would not justify reliability hits on a stateful platform.
- **Mode 1 stays manual in POC.** Per-cell rebalance is hours of operator time and is not free. Mitigated in practice by Mode 2's preemptive cell provisioning, which delays the need for Mode 1.
- **Orphaned EBS volumes accumulate over time.** When a pod is permanently retired, the EBS volume remains until an operator deletes it explicitly. Accepted as the right asymmetry — accidental retention is recoverable, accidental deletion is not.

## Alternatives considered

- **Raw EBS without LVM.** Mount EBS directly as ext4/xfs. Rejected because Restic on a live filesystem races LevelDB writes; LVM snapshot is the canonical fix and the spec asks for it explicitly.
- **`io2` with provisioned IOPS as default.** Better IOPS guarantees, much higher cost. Rejected as default because gp3 performance is sufficient at typical cohort sizes; the StorageClass parameter remains tunable per-pod for enterprise profiles that need more.
- **EFS / network-attached filesystem.** Avoids AZ-pinning entirely. Rejected because EFS is POSIX network filesystem with much higher latency than EBS; LevelDB's mmap-based read path performs poorly, and per-pod data locality is lost.
- **Variable per-pod EBS sizing baked into chart.** Each pod gets a different EBS size based on tenant cohort. Rejected for POC because it requires custom operator logic; deferred to the upgrade trigger.
- **External binding service for pod-to-EBS mapping.** A separate database that stores the binding authoritatively, with K8s as a consumer. Rejected because it adds an operational dependency that itself must be backed up; K8s primitives plus EBS tags are sufficient.
- **`reclaimPolicy: Delete` with operator-level safeguards.** Use the default and catch dangerous operations in admission control. Rejected because operators do `kubectl delete pvc -A` and admission controllers lag; `Retain` is the boring-correct default.
- **2-3 stateful pods per node (medium density).** Rejected for POC because noisy-neighbour effects are real, especially under LevelDB compaction; density tuning happens after production telemetry shows stable tail latency under multi-pod-per-node load tests.
- **Spot for stateful with EBS detach/reattach automation.** Rejected because it is brittle under capacity pressure when spot is interrupted because demand is high — exactly when the platform needs to be reliable.
- **Karpenter for the stateful pool.** Rejected currently because Karpenter's consolidation logic is aggressive and may evict stateful pods to bin-pack; revisit when AWS publishes stable PVC-aware Karpenter provisioning.
- **Single HPA on StatefulSet (no mode distinction).** Apply HPA to the stateful StatefulSet based on CPU. Rejected because adding a pod does not shed existing-tenant load; the metric does not reflect what scaling can fix.
- **Manual scaling only (no automation).** Rejected because Mode 2 (empty pod fill) is genuinely automatable and is the most common operational scenario.
- **Vertical scaling instead of horizontal.** Increase pod resources rather than adding pods. Rejected as primary because vertical scaling has hard limits (largest instance type, max EBS size); horizontal via cells is the long-term answer. VPA can complement individual pod tuning but is not the main strategy.
- **Auto-rebalance (Mode 1 automated).** Rejected for POC because high blast radius requires careful staging that is hard to automate safely. Documented as a future operator pattern.

## Out of POC scope (upgrade triggers)

- **Variable per-pod EBS sizing via operator pattern.** Trigger: enterprise-tier customers want dedicated pods with custom EBS size; operator watches tenant footprint and resizes.
- **`io2 Block Express` for ultra-high-IOPS LevelDB compaction.** Trigger: per-pod LevelDB exceeds 5,000 sustained IOPS for compaction.
- **EBS Direct API for backup without filesystem snapshot.** Trigger: 2 TB is no longer enough and backup time becomes the bottleneck.
- **Density tuning to 2-3 pods per node.** Trigger: production telemetry shows stable tail latency under multi-pod-per-node load tests.
- **Karpenter for stateful when PVC-awareness matures.** Trigger: AWS publishes stable PVC-aware Karpenter provisioning that respects scheduling constraints for stateful pods.
- **Bare-metal `i3en` for ultra-high-IOPS profiles.** Trigger: per-pod sustained IOPS demand exceeds gp3 capability and `io2` cost is also unjustified.
- **Mode 1 automation.** Trigger: more than one manual rebalance per quarter. Build an operator that drains and migrates during configured maintenance windows.
- **Vertical scaling automation (VPA).** Trigger: per-pod resource profile becomes highly variable. Add VPA in recommendation mode first.
- **Predictive scaling.** Trigger: traffic patterns become predictable enough that pre-emptive cell provisioning aligns with calendar.
- **Cross-cluster pod identity for multi-cluster federation.** Trigger: multi-cluster topology.
- **Tag-based access control on EBS.** IAM policy that restricts EBS deletion based on `app/cluster` tag. Operational hardening rather than a POC blocker.

## Stage 3 questions

| # | Question | Why it matters |
|---|---|---|
| 1 | Tenant size distribution: how many pods are <500 GB, 500 GB - 2 TB, >2 TB? | Determines whether online expansion or relocation is the dominant operational path. |
| 2 | Within each pod, what fraction of tenants are >50% of pod size? | Drives the >50% / >30% thresholds in the expand-vs-relocate tree. |
| 3 | Per-pod resource profile expectation: is 8 vCPU / 64 GB sufficient for a typical cohort, or are there enterprise pods that need 16 vCPU / 128 GB? | Tunable via Helm values; ADR doesn't depend on the answer but pool sizing does. |
| 4 | Workload growth pattern: steady organic growth (Mode 2 dominant), or bursty enterprise onboarding (Mode 1 may be needed sooner)? | Affects threshold tuning and how aggressively Mode 2 cell provisioning runs. |
| 5 | Are there enterprise customers that need dedicated pods with non-default EBS size or instance type today? | Determines whether variable sizing is "POC scope nice-to-have" or "day-one blocker." |

## Cross-references

- ADR-01 (architecture and topology) — establishes the per-tenant pod model and the single-master-AZ topology that this storage design depends on.
- ADR-03 (routing and ingress) — the placement table primitive that the relocation path writes to during rebalance; storage decisions about expand-vs-relocate cascade into routing flips.
- ADR-04 (backup, DR and HA) — owns the Restic + LVM-snapshot backup runbook, the 5-minute Velero schedule, and the cold-DR rehydration into warm-standby AZs that the master-AZ-only stateful pool depends on.
- ADR-05 (migration / Strangler Fig) — owns the relocation runbook (greedy and dedicated-cell paths) referenced by the expand-vs-relocate tree.
- ADR-07 (security and runtime) — IAM and KMS keys for the EBS volumes and for the snapshot pipeline.
- ADR-10 (FinOps) — gp3 baseline cost model and the cost tracking for over-provisioned-storage waste.

(Originally split across private ADR-007 / ADR-008 / ADR-017 / ADR-018; consolidated 2026-05-09.)
