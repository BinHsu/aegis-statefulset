# ADR-04: Backup, DR & HA

## Status
Accepted (POC submission scope)

## Decision

1. **Cold DR via Velero + EBS Snapshot.** No active-passive standby pods. AZ failure = manual rotation: scale the standby AZ node group from `desired=0` via `aws eks update-nodegroup-config`, then Velero restore from the latest in-region EBS Snapshot. RTO ~25 min for AZ failure.
2. **Dual-cadence pattern: operational tier + DR tier.** Two independent Velero `Schedule` CRDs:
   - **Schedule A (operational):** 5-min cadence default. `snapshotMoveData: false`, source-region only, BSL `velero_bsl_operational` (no replication). For fast roll-back of bad deploys / accidental state corruption. RPO ~30 sec.
   - **Schedule B (DR tier):** 4-hour cadence default. `snapshotMoveData: true`, both `source-region` + `dr-region` VolumeSnapshotLocations, BSL `velero_bsl` (cross-region replicated). For region-failure recovery.
   - **Cadence math:** spec RPO ≤ 6 h; DR cadence + backup-duration + retry-margin ≤ ceiling. 4h + 15min + 30min = 4h45m ≤ 6h (1h15m headroom). Sane DR upper bound 5h; 6h zero margin; daily breaches by 4×.
   - **Operator-tunable** via `backup.operational.cadence_minutes` (default 5) and `backup.dr.cadence_hours` (default 4).
3. **Cross-region snapshot copy via Velero VolumeSnapshotLocations multi-region** (CSI path). Schedule B's `snapshotMoveData: true` invokes EBS `CopySnapshot` API to replicate to `dr_region` (default `eu-west-1`). DR snapshots stored as Glacier Instant Retrieval. Cross-region RTO ~50 min including Velero restore in the DR region. **Earlier architecture used AWS DLM lifecycle policy for cross-region copy; that approach was retired because DLM `target_tags` filter operates on volumes, not on the snapshot tags Velero applies — the configuration silently no-op'd. The Velero VSL multi-region pattern owns the cross-region copy directly via Velero, which keeps the K8s-context-aware orchestrator in charge end-to-end.**
4. **Three-Layer DR with clear ownership.**
   - Layer 1 (Terraform) — VPC, EKS cluster, IAM, KMS, S3 buckets, ALB, Route 53.
   - Layer 2 (Helm via Terraform `helm_release`) — cluster controllers: ALB controller, Karpenter, ESO, Kyverno, cert-manager, **Velero itself**.
   - Layer 3 (Velero) — application namespaces (`aegis-app`, `api-tier`, `envoy`, `monitoring`) and their PVCs.
   Each layer with the right tool. No double management.
5. **Master AZ rotation: ad-hoc operator decision, no auto-failback.** Once rotated to AZ-B, AZ-B is the new master indefinitely. AZ-A's eventual return does NOT trigger automatic rebalance — that is a separate scheduled maintenance event.
6. **Detection automatic; execution manual.** Prometheus alerts + ALB health checks + Blackbox external probe fire within ~30 sec; operator paged; runbook executed within a 5-10 min decision window.
7. **LDB layout cascade.** Pattern 1 (shared LDB with key prefix) and Pattern 2 (per-tenant folder) both supported. Per-tenant relocation cost differs sharply between the two; capability matrix in this ADR § "LDB layout — what each pattern enables".

## Why

- **LevelDB has zero native sync APIs.** Any "warm" replica is, in practice, a snapshot copy with the replica running idle. Paying for idle warm-standby pods buys ~40 min of RTO at ~$1,500/month. The spec is silent on RTO; the architecture's chosen target is ~25 min AZ failure / ~50 min region — our design judgment, defensible as Mittelstand-grade for a SaaS where downstream customers run their own businesses on top of the platform. Against that target, the warm-standby trade is poor; if the customer's actual operational tolerance is sub-15-min, the conversation moves to "which storage primitive supports hot DR" rather than tooling on top of LevelDB.
- **Velero is the K8s-native primitive for application-layer DR.** It captures CRDs, ConfigMaps, Secrets, PVCs, and PV bindings as a coherent set. Bespoke EBS-snapshot scripts miss the application context that makes a restore meaningful.
- **5-min cadence is well inside the spec ceiling.** The cost-RPO curve is linear; the operator picks the operating point. Default is tight; relaxing to 1 h saves ~$200/mo and degrades RPO to ~30 min — both numbers explicit in the chart.
- **Three-Layer DR avoids contention.** Terraform-managed, Helm-managed, and Velero-managed objects must not double-manage the same resource — `docs/operations/scope-boundaries.md` enforces the contract. Each layer's restore time is bounded by what it owns.
- **Manual DR posture is the only safe pattern when writes have accepted in the new master AZ.** Auto-failback would either lose those writes (restore-from-pre-failure) or require reverse-sync. Reverse-sync is the rejected path.
- **Detection-automatic + execution-manual matches the operator's actual decision shape.** The 5-10 min decision window is when the operator decides "transient or sustained" — no asymmetric-threshold automation adds value inside that window.

## Trade-offs accepted

- **AZ rotation RTO floor is operator paging latency + decision time.** Typical 5-10 min from page to action. RTO ~25 min total for AZ failure recovery, dominated by node-group scale-up + Velero restore.
- **Cross-region RTO is dominated by Velero restore (~25 min) + DLM snapshot import (~15-20 min).** ~50 min end-to-end is the floor for this DR shape.
- **Cold DR has higher RTO than hot/warm DR options.** Defensible only because LevelDB physics make hot replicas expensive theatre.
- **Master AZ asymmetry over cluster lifetime.** After several rotations, AZ-A might be the warm-standby for months while AZ-B serves. Operations team keeps all three AZ node groups patched and ready.
- **Pattern 1 LDB layout makes per-tenant relocation expensive** (~1 month of tooling work to extract one tenant's keys cleanly). Pattern 2 is cheap (rsync the folder). Choice cascades to migration cost.

## LDB layout — what each pattern enables

| Capability | Pattern 1 (shared LDB, key prefix) | Pattern 2 (per-tenant folder) |
|---|---|---|
| Per-tenant size telemetry | Requires custom prefix-scan tool | `du -sh /data/tenants/<id>/` |
| Per-tenant cost attribution | Requires custom telemetry | Pod label + folder size, native CUR |
| Per-tenant relocation | ~1 month tooling (extract / transport / delta-replay / cleanup) | rsync the folder |
| Per-tenant point-in-time restore | Restore full LDB then delete other tenants' keys | Restore only that folder |
| Memory footprint | One LevelDB cache, one compaction stream | N caches, N compactions |
| Backup granularity | Full pod snapshot | Per-tenant subset feasible |
| Operator clarity | Single LevelDB to debug | One per tenant; `ls` is the inventory |

Pattern choice is application architecture, not platform. The architecture supports both. POC mock uses Pattern 2 for clean chaos demo; production usually runs Pattern 1.

## Out of POC scope (upgrade triggers)

- **Sub-5-min RPO.** Trigger: WAL shipping or LevelDB → distributed K-V replacement.
- **Sub-15-min cross-region RTO.** Trigger: customer SLA demands hot DR; reach for active-active multi-region with a different storage layer.
- **Automated AZ rotation.** Trigger: > 2 manual rotations per quarter. Build operator with explicit gates (Slack approval / two-person rule / scheduled maintenance window).
- **Backup-verification automation.** Trigger: regulatory requirement; the POC has the machinery (cross-region copy, retention policy) but not the periodic restore-and-mount schedule.

## Stage 3 questions

- RPO target — single number across customers, or tiered? POC defaults to a single 5-min cadence; tiered would be a per-cohort knob.
- LDB layout — Pattern 1 vs Pattern 2? Cascades to relocation tooling cost.
- Acceptable RTO ceiling for AZ failure. POC delivers ~25 min via cold DR; acceptable, or trigger for hot DR upgrade?
- Backup-verification cadence in customer's existing practice.
- **Granular file-level restore — is per-tenant LDB extract a product feature?** If yes, enabling Velero's FSB path alongside the CSI path becomes attractive (FSB makes single-file restore a one-liner). The diff to flip is documented in `docs/future/restic-fsb-patch.md`. If no, the CSI-only default stands.
- **Customer's actual operational tolerance for storage-cost vs restore-time trade-off** — informs whether the cadence default and the CSI vs FSB choice both stay where the POC defaults put them.

## Cross-references

- *(originally split across private ADR-011 / ADR-012 / ADR-013 / ADR-014 / ADR-015 / ADR-047 / ADR-048 / ADR-049 / ADR-050; consolidated 2026-05-09; private ADR-014 active-passive periodic refresh retired in this consolidation)*
- ADR-01 — single master AZ topology; cells as backup unit
- ADR-02 — EBS + LVM as the backup substrate
- ADR-03 — placement table reconstructed during DR via Layer-3 Velero restore
- `docs/operations/why-cold-dr.md` — full reasoning chain for cold DR over active-passive
- `docs/operations/why-velero-not-restic.md` — reasoning chain for Velero + EBS Snapshot over the spec's literal Restic + LVM naming
- `docs/operations/region-failure-recovery.md` — operator runbook
- `docs/operations/scope-boundaries.md` — ownership contract between layers
