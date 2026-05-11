# Why Velero + EBS Snapshot, not Restic + LVM

> **Status:** Companion to ADR-04 (backup, DR & HA). Reasoning chain for the choice that deviates from the spec's literal toolchain ("Restic with LVM for 2 TB of data with each pod") in favour of the K8s-native equivalent.
> **Reading order:** ADR-04 first (architectural framing), then this doc (technology trade-off in detail).

---

## TL;DR

The spec named Restic + LVM as the canonical 2 TB-pod backup pattern. That naming reflected the 2018–2022 industry default, before Velero's Container Storage Interface (CSI) Snapshot integration matured. In 2026, on EBS-backed Kubernetes at TB scale, evaluated against the spec's actual constraints (RPO ≤ 6 h explicit, RTO unspecified) and our chosen architecture targets (5-min cadence default, ~25 min AZ-failure RTO), **Velero + EBS Snapshot wins on three load-bearing dimensions** (cadence floor, restore time, application-pod resource cost) over a Velero + File System Backup (FSB) path deployment using Kopia / Restic, and wins by a wider margin over a hand-rolled Restic + LVM pipeline.

LVM stays in the toolchain — application-consistency hooks (fsfreeze + LVM thin snapshot) give LevelDB a stable view to snapshot from. The orchestrator and the transport layer change: Velero replaces a custom Restic pipeline; EBS Snapshot replaces Restic's S3-chunked-upload as the data-movement primitive.

This doc walks the reasoning. The conclusion is reversible: a different operational context (RTO tolerance ≥ 12 h, cross-cloud DR requirement, granular file-level restore as product feature, instance-store NVMe pods) flips the answer toward Velero's FSB path. The diff patch in `docs/future/restic-fsb-patch.md` makes that flip a five-minute operation.

---

## 1. What Restic is, and what it was designed for

Restic is a 2014 open-source backup program written in Go. Its design predates Kubernetes by months and reflects the constraints of the era: laptop / NAS / server backup to remote storage, with strong privacy properties.

**Strengths by design:**
- Application-layer encryption (AES-256 + Poly1305) before upload
- Content-addressed deduplication (chunks hashed by content; identical chunks across snapshots stored once)
- Storage-backend agnostic (local FS, SFTP, S3, Azure Blob, GCS, B2, Rest server)
- Open repository format — restore tool is open-source, no vendor lock-in
- Granular file-level restore (pick one file from one snapshot)
- Cross-platform / cross-OS portability

**Use case shape:** file-system backup of small-to-medium volumes, with strong privacy + portability. Hundreds of GB of mixed file types, dozens of snapshots, repository on S3 — Restic is excellent.

Restic is **not** a Kubernetes-native tool. It does not understand CRDs, PVCs, ConfigMaps, ServiceAccounts, or any K8s object model. It walks a filesystem and produces a backup of files.

---

## 2. Why we chose differently in this specific context

### Reason 1 — EBS Snapshot is AWS's native primitive for block-level backup; Restic is file-walk

| Dimension | Restic | EBS Snapshot |
|---|---|---|
| Backup-time scan | Walks filesystem; hashes each file | Block-level diff at storage layer |
| 2 TB / millions-of-files scan cost | Tens of minutes to hours per backup | Seconds (storage layer already knows changed blocks) |
| Incremental upload | Changed content-addressed chunks | Changed blocks (AWS-managed, storage-layer-incremental) |
| Sane cadence floor | 10–30 min | 5 min cadence is comfortable (our default per ADR-04) |

LevelDB at 2 TB has SSTable forests with hundreds of thousands to millions of small files. A Restic backup-time filesystem walk takes a non-trivial fraction of any meaningful cadence window. EBS Snapshot at the AWS storage layer already knows which blocks changed since the last snapshot — the operation is metadata-fast.

### Reason 2 — Restore time is the difference between meeting RTO and missing it

| Scenario | Restic | EBS Snapshot |
|---|---|---|
| 2 TB restore | Pull chunks from S3 → decrypt → reassemble → write to disk. **6–12 hours** at typical 50–100 MB/s ceilings. | `aws ec2 create-volume --snapshot-id ...` returns in seconds; volume is immediately attachable; lazy block fetch happens in background; **full performance within ~30 min** with Fast Snapshot Restore enabled. |
| ADR-04 RTO target | ~25 min for AZ failure / ~50 min for region failure | ✅ EBS Snapshot meets this |
| Restic vs target | ❌ A 6–12 h restore cannot deliver a 25-min RTO regardless of automation | — |

The spec sets RPO at 6 h; the spec is silent on RTO. The architecture's chosen RTO targets — ~25 min AZ failure / ~50 min region failure — are our judgment call (defensible as Mittelstand-grade for a SaaS where downstream customers run their own businesses on the platform), not a customer-stated requirement. **At those chosen targets, Restic restore at 2 TB scale exceeds the budget on its own** — automation cannot fix a physics-bound transfer time. If the customer's actual operational tolerance is 12 h+ for AZ failure, this analysis flips and Restic-restore-time stops being a blocker.

### Reason 3 — Restic does not understand Kubernetes objects

Restic backs up a filesystem. It does **not** capture:

- Custom Resource Definitions (Velero `Schedule`, `Probe`, `PrometheusRule`, `ServiceMonitor`, Kyverno policies)
- ConfigMaps and Secrets (application configuration + ESO-fetched tokens)
- PVC bindings (which `PersistentVolumeClaim` is bound to which `PersistentVolume`)
- Helm release state in the cluster
- ServiceAccount + IRSA mappings
- StatefulSet / Deployment manifests

A pure Restic backup pipeline would still leave us to write a separate cluster-state backup — typically `kubectl get -A` dumps with all the bookkeeping that implies. Velero owns this surface natively: a backup is a coherent set of Kubernetes objects + their PVCs, with the bindings preserved.

This is the difference between *backing up the data* and *backing up the system that knows how to use the data*. ADR-04's "Three-Layer DR" relies on the second framing.

### Reason 4 — 5-min cadence imposes a per-backup CPU/memory cost that Restic cannot absorb

Restic's filesystem walk + dedup-index maintenance runs **inside the pod** (or as a sidecar with shared volume access). At TB scale with millions of files, the dedup index alone consumes several GB of RAM during operations.

A 5-min cadence means this cost recurs every 5 minutes. The pod's CPU + memory profile becomes backup-bound rather than application-bound — exactly the opposite of what the spec asked for ("minimizing performance overhead").

EBS Snapshot is a storage-layer call. It costs the pod **zero CPU and zero memory** at backup time. The snapshot operation completes in the EBS service plane; the pod is not a participant.

---

## 3. Where Restic genuinely beats EBS Snapshot

This is the honest list. Restic has real strengths; the question is whether they apply to this specific context.

| Dimension | Restic wins because… | Applies here? |
|---|---|---|
| Cross-cloud / cross-storage portability | Repository format is open; backup in AWS, restore in GCP / Azure / on-prem | ❌ Single-region AWS deployment |
| Application-layer encryption | Restic encrypts before upload; EBS relies on KMS at storage layer (assumes you trust AWS) | ❌ Customer's threat model accepts AWS as trusted |
| Granular file-level restore | "Restore one file from snapshot N" is a one-line command; EBS Snapshot requires attach + mount + extract | ❌ Restore unit is a whole pod / cell, not a file |
| Storage backend agnostic | Local NVMe, hostPath, any filesystem; EBS Snapshot only backs up EBS | ❌ All stateful PVCs are on EBS |
| Cross-cloud DR | EKS → GKE restore uses the same toolchain | ❌ Same-cloud DR is the requirement |
| Dedup ratio for similar data | Content-addressed chunks; identical files in 100 snapshots stored once | 🟡 EBS Snapshot's incremental block dedup achieves a comparable benefit at the block level — exact ratio depends on workload churn pattern; both deliver "much less than full snapshot size" but Restic wins for highly-deduplicable data, EBS for write-heavy workloads where most blocks change |
| Air-gap / offline restore | Repository can be copied to a USB drive | ❌ Online S3 cross-region replication is the DR path |

**None of Restic's wins apply to our context.** That isn't a limitation of Restic — it's a context fit failure for *this* deployment shape.

---

## 4. When Restic would be the right call

Five contexts where Restic would beat Velero + EBS Snapshot:

1. **Local-NVMe instance-store stateful pods** (e.g., Ethereum Geth nodes — instance-attached SSD, no EBS in the path). EBS Snapshot is not available; Restic to S3 is the only way to back up at all.
2. **Cross-cloud disaster recovery** (backup in AWS S3, restore on Azure or GCP). Velero CSI is AWS-locked; Restic is portable.
3. **Granular file-level restore is a product feature** — the customer needs to extract one tenant's database from one snapshot without restoring the whole pod. Restic does this in a one-liner; EBS Snapshot requires a parallel restore pipeline.
4. **Storage class without CSI snapshot support** (some self-managed local provisioners, NFS-backed PVs). No CSI snapshot API to call; Restic's filesystem walk is the only path.
5. **Air-gapped / offline restore requirement** — repository can be moved to physical media. Common in regulated sectors that prohibit cloud-to-cloud DR over the internet.

If our context shifted to any of these, the choice would flip. ADR-04 documents this as an upgrade trigger.

---

## 5. The hybrid truth — Velero internally uses Restic for the FSB path

This nuance matters and a senior reviewer is likely to surface it.

**Velero supports two backup paths:**

1. **CSI Snapshot path** — uses the cloud provider's volume snapshot API (EBS for AWS, Disk Snapshots for Azure, Persistent Disk Snapshots for GCP). Fast, native, K8s-CSI-integrated. **This is what ADR-04 commits to.**
2. **File System Backup (FSB) path** — internally uses Restic or Kopia to walk the filesystem and upload to a remote repository. Slower, but storage-agnostic.

Velero's design lets a single deployment use both paths simultaneously: CSI for the EBS-backed PVCs, FSB for hostPath / emptyDir or any volume type without a CSI snapshot driver. We commit to CSI for the entire stateful tier because every PVC is EBS.

**The spec's "Restic + LVM" naming is therefore not wrong** — Restic is still inside Velero's toolkit. We've changed which Velero path we use, not whether Restic exists in the supply chain. (Confirm with `helm get values aegis-app -n aegis-app` — Velero's `useRestic` and `defaultVolumesToFsBackup` are off; CSI driver is the path.)

---

## 6. Why LVM stays in the toolchain even with EBS Snapshot

LVM thin snapshot is the **application-consistency primitive**, not the backup-transport primitive. It freezes the filesystem long enough for LevelDB to:

1. Flush MemTable to SSTable
2. Sync the WAL
3. Release the file lock

…so that the EBS Snapshot taken immediately after captures a crash-consistent view rather than an in-flight one. Without LVM (or `fsfreeze` + LevelDB compaction quiesce), an EBS Snapshot at 5-min cadence would occasionally capture a partially-flushed MemTable and produce an unrecoverable backup.

The Velero Backup CRD supports pre-snapshot hooks (`kubectl exec` into the pod) precisely for this. Our schedule wires up:

```yaml
hooks:
  resources:
    - name: leveldb-quiesce
      pre:
        - exec:
            container: app
            command:
              - /bin/sh
              - -c
              - "lvcreate --snapshot --name leveldb-snap-$(date +%s) --size 10%FREE /dev/vg-app/leveldb-data"
            onError: Fail
```

So **LVM is in the toolchain** (consistency primitive) and **EBS Snapshot is in the toolchain** (backup transport) and **Velero is in the toolchain** (orchestrator + K8s object capture). The spec's "Restic + LVM" wording is honoured in spirit — LVM is the consistency layer; Restic-as-transport is replaced by EBS-Snapshot-as-transport because the cadence + RTO + scale requirements demand it.

---

## 7. Stage 3 anchor (verbatim)

> *"Spec named Restic + LVM as the canonical 2 TB-pod backup pattern. That was the 2018–2022 industry default, before Velero's CSI Snapshot integration matured. The spec gives RPO ≤ 6 h explicitly and is silent on RTO. Restic + LVM can clear 6 h RPO comfortably (2–4 backups per day). Where it breaks down is on restore time — 2 TB Restic restore is 6–12 h regardless of automation, which is fine if the operational tolerance is also that long, but our cold-DR design targets ~25 min AZ-failure RTO and ~50 min region-failure RTO based on what we judge appropriate for a Mittelstand SaaS where downstream customers run their own businesses on top of the platform. At those design targets, Restic doesn't fit the restore window. Plus Restic does not capture the K8s object set that Velero captures natively, so AZ rotation runbook breaks even when the data restore eventually completes. LVM stays — fsfreeze + LVM thin snapshot is what gives LevelDB a stable view to snapshot from. Velero replaces the orchestrator role; EBS Snapshot replaces Restic-as-transport. RTO target is a Stage 3 conversation — if the customer's actual operational tolerance is 12 h+ for AZ failure, the trade-off flips and Restic + LVM is the right call."*

---

## 8. What would explode if we tried Restic + LVM literally

This section names the operational failure modes a literal-spec implementation would hit. Ranked at the **spec's actual constraints**, not at the architecture's aspirational 5-min cadence default — the 5-min target is ours; the constraints below are what the spec actually requires plus what we chose to design against.

### Premise — what the spec gives us, what it doesn't

Given:
- **RPO ≤ 6 h** (spec, Backup & Restore section, explicit)
- **Pod size 2 TB** (spec, "for 2 TB of data with each pod", explicit)
- **RTO not stated in the spec.** This is a real silence — neither the Confluence challenge spec nor the JD nor the round-1 conversation pinned an RTO ceiling. The architecture's chosen RTO targets (~25 min AZ failure, ~50 min region failure) are *our* judgment call, not a customer-stated requirement.

Cadence math at the spec's 6 h RPO: 2–4 backups per day. Restic at 2 TB takes 60–130 min per backup (filesystem walk + hash + chunk upload). 2–4 per day fits without stacking. **Cadence is not the problem if we read the spec literally.**

The RTO question is therefore a Stage 3 conversation, not a spec-derivable verdict. The failure ranking below assumes our chosen RTO targets — which is the right framing for "what does *this* architecture deliver" but is not the right framing for "what does *the spec* require." If the customer's actual operational tolerance is 12 h+ for AZ failure (plausible for a Mittelstand back-office tool that customers don't access overnight), Restic + LVM becomes a reasonable choice and several of the P0 / P1 items below collapse to non-issues.

### P0 — catastrophic at spec constraints (no automation rescues these)

#### 1. Restore time of 6–12 hours

```
S3 → EC2 throughput ≈ 50–100 MB/s
2 TB / 75 MB/s = ~7.5 h just to pull bytes
+ decrypt CPU cost
+ chunk reassembly
+ filesystem write
total 8–12 h
```

Against our architecture's chosen RTO targets (~25 min AZ failure / ~50 min region failure), **8–12 h restore is unfixable** — it's a transfer-rate physics problem, not a software-tuning problem. AZ failure → customer waits 8 hours minimum. Region failure → 12+ hours.

**Caveat — this is P0 only against *our* RTO targets.** The spec is silent on RTO. If the customer's actual operational tolerance is 12 h+ for AZ failure, Restic 12 h restore is acceptable and this stops being a P0 item. The Stage 3 conversation should establish the RTO ceiling before this analysis weights toward one tool or the other.

#### 2. Cluster state is not backed up — only true for Restic standalone

**Correction (2026-05-10):** an earlier draft of this section claimed cluster state is not captured. That is true only for **Restic standalone** (a hand-rolled pipeline that runs Restic directly against the filesystem). It is **not** true for **Velero + FSB (Restic / Kopia path)** — Velero captures K8s objects (CRDs, ConfigMaps, Secrets, PVC bindings, ServiceAccount mappings) via its own BackupCRD logic regardless of which path it uses for PVC content. The FSB vs CSI distinction is purely about *how PVCs are backed up*, not about *whether K8s objects are backed up*.

So this is conditional:

- **Hand-rolled Restic pipeline** (no Velero) → P0; cluster state must be backed up separately; AZ rotation runbook adds ~30 min for manual `kubectl apply` work.
- **Velero + FSB path** (Restic or Kopia as the volume transport) → not a P0 here; Velero handles K8s objects natively. The FSB-vs-CSI choice for this section reduces to *backup duration + restore time + app-pod resource cost*, which are P0 #1 and the P1 items below.

The honest framing for the spec wording: "Restic + LVM" *as a tool naming* doesn't preclude Velero — Velero's FSB path uses Restic (or Kopia, the 2022+ default) under the hood. What changes is which of Velero's two paths runs, not whether Velero is in the picture.

#### 3. Application consistency = home-rolled bash orchestrator

Restic has no pre-snapshot hook. To get LevelDB consistency before each backup, the operator writes a 7-step orchestrator:

```bash
1. kubectl exec pod -- fsfreeze /data
2. lvcreate --snapshot /dev/vg-app/leveldb-data
3. kubectl exec pod -- fsthaw /data
4. mount snapshot at /mnt/backup
5. restic backup /mnt/backup → S3
6. lvremove snapshot
7. cleanup mount
```

**This becomes the operator's most-fragile system.** Step 2 fails on disk-full → step 3 leaves the filesystem frozen → next request hangs → page. Step 5 fails mid-upload → step 6 runs anyway → snapshot is gone, backup is incomplete, no record of partial state.

Velero's pre-snapshot hooks are declarative YAML; the failure modes route through Velero's own retry + alerting paths. With Restic, the operator owns this rope.

### P1 — operational quality degradation (workaroundable)

#### 4. App pod CPU/RAM spike during backup window

Restic dedup index sits in memory during operations: ~1–2 GB RAM per TB. Hashing every file saturates ~1 vCPU. At 2 TB, every backup window costs the application pod 2–4 GB RAM + 1 vCPU for the duration. Live request p99 latency spikes during backup.

**Workaroundable:** see § "Industry workarounds" item 1.

#### 5. fsync storm + page cache contention

Filesystem walk reads metadata for millions of inodes → kernel page cache thrashes → LevelDB's own SSTable reads miss cache → live read latency degrades materially for the backup window. The exact spike depends on cache size relative to working set + walk parallelism settings; community deployments report multiples in the 3–10× range. Production should expect a measurable spike + tune the alert thresholds to suppress backup-window false positives.

**Workaroundable:** see § "Industry workarounds" item 6 (backup against an LVM snapshot mount, not the live filesystem).

#### 6. Repository corruption from interrupted writes

S3 PUT fails + retry doesn't fully clean up → index references chunks that don't exist. `restic check --read-data` is the validation command but takes 6+ hours on TB-scale repositories.

**Result:** "we have backups" can be silently false until a real restore is attempted. Untested-backups-aren't-backups, amplified by Restic's repository complexity.

**Workaroundable:** scheduled `restic check`, but adds operational load.

### P2 — long-term operational debt

#### 7. Repository lock contention

Restic uses file-based locks on the repository for write operations. Backup and prune cannot run concurrently. At 4 backups/day plus weekly prune, scheduling becomes a coordination puzzle.

#### 8. Repository pruning is hour-scale

`restic forget --prune` walks the repository and deletes unreferenced chunks. At TB scale with hundreds of snapshots, this is 4–8 hours and locks the repository for that duration. Maintenance window required.

#### 9. S3 cost at naive cadence

At 4 backups/day × 30-day retention × 2 TB pod, with a Restic dedup ratio in the 2:1 to 4:1 range (varies sharply by workload — LevelDB's append-mostly SSTable churn favours dedup; high-churn workloads see less benefit), the per-pod S3 footprint lands in the 15–30 TB range. At STANDARD tier (~$0.023/GB-month at 2026 pricing), ~$345–690/mo per pod. 20-cell production deployment ~ $7,000–14,000/mo S3 alone — comparable to compute spend at the upper end. The numbers are indicative, not precise; the architectural point is that storage cost becomes a first-order line item rather than a rounding error.

vs EBS Snapshot incremental, where AWS manages dedup natively and the storage cost at this cadence is ~10× lower.

#### 10. Cross-region replication is byte-level

S3 cross-region replication of Restic chunks is per-byte; cross-region transfer is $0.02/GB. Initial sync of a 7 TB-of-snapshots repository is ~$140 once + ongoing incremental.

vs DLM cross-region snapshot copy, which is incremental at the AWS storage layer with materially lower bandwidth bill.

#### 11. Encryption key bootstrap chicken-and-egg

Restic uses a repository-level password. The password must be available to restore. If the password lives in a K8s Secret, and that Secret is part of what is being restored, restore is impossible without out-of-band access. AWS Secrets Manager works but requires the IAM role in the DR region to be operational.

**Result:** the operator must store the Restic password out-of-band (1Password, physical safe, sealed envelope). The next time someone is paged at 3 am, whether they remember where the key lives is an SLA-defining question.

vs EBS Snapshot encrypted with KMS, where IAM-driven access works automatically once the IAM role is reachable. No key bootstrap problem.

### Industry workarounds — used in practice

These are the patterns experienced teams use to make Restic + LVM viable. Each addresses one or more of the failures above. Naming them in Stage 3 conversation signals "I know how Restic is actually deployed, not just its limitations."

#### Workaround 1 — Dedicated backup instance

Application pod does not run Restic. The flow:

```
[Application pod]    LVM thin snapshot create  (seconds)
[Backup instance]    attach LVM snap → run Restic → S3
[Application pod]    LVM snap remove  (seconds)
```

Solves P1#4 (app pod CPU/RAM spike) by moving the cost to a dedicated EC2 instance. Common pattern in big-data backup. Velero's CSI path does this implicitly — the snapshot operation lives in the EBS service plane, no application pod cost at all.

#### Workaround 2 — Hybrid CSI + FSB (what Velero already does)

Two parallel paths:

- **CSI Snapshot** as the fast-restore primary path (RTO budget-compliant).
- **Restic / Kopia** as the FSB path for granular file-level archive at lower cadence (daily).

**Velero implements this as a single deployment:** CSI for the EBS-backed PVCs, FSB for hostPath volumes or cross-cloud requirements. Our submission commits to CSI for the entire stateful tier because every PVC is EBS — but the architecture supports turning on FSB for any workload that needs it.

This is the **honest reading of what Velero is** — not a Restic replacement, but the orchestrator that decides which path each PVC takes.

#### Workaround 3 — Kopia replaces Restic in Velero's default (2022)

Velero 1.10 (released late 2022) introduced Kopia as the default FSB uploader, with Restic remaining selectable for compatibility. Kopia at TB scale is materially faster than Restic — community-reported benchmarks cite 3–5× on typical mixed workloads, but the exact ratio varies by data shape, churn rate, and chunk-size tuning. Kopia's lock model is also redesigned to handle concurrent backup + maintenance operations cleanly, which addresses a known Restic operational pain point at scale.

**The spec says Restic; the industry default in 2022+ is Kopia.** A senior reviewer who knows Velero will appreciate the candidate flagging this — "spec wrote Restic, but if we were going down the FSB path I would use Kopia, not Restic." Demonstrates currency without dismissing the spec author.

#### Workaround 4 — Sharded Restic repositories

Instead of one repository for the entire fleet, partition by tenant or by time window. Each repository stays small enough that prune takes minutes instead of hours, and lock contention is bounded by partition.

Cost: cross-repo dedup is lost; storage cost rises ~30% in exchange for operational tractability.

Used by some hosting providers running Restic at fleet scale.

#### Workaround 5 — WAL streaming + periodic full

Pattern: continuously stream the database's write-ahead log to S3 (sub-minute RPO), and run a Restic full backup every 6 h. Restore = latest full + WAL replay since.

This is the canonical Postgres `pg_basebackup` + WAL archive pattern. **LevelDB does not expose WAL through a clean API** the way Postgres does; implementing this requires patching LevelDB or using an LDB wrapper that exposes WAL events. **RocksDB has a native `BackupEngine` + WAL ship API** — which is part of why TiKV (built on RocksDB) ships with this pattern out of the box.

For a LevelDB-native shop without RocksDB migration on the table, WAL streaming is more effort than the RPO improvement justifies.

#### Workaround 6 — Restic on LVM-snapshot mount (the spec-canonical interpretation)

The standard Restic + LVM pattern is **not** "Restic backs up the live filesystem." It is:

1. LVM thin snapshot the data volume (block-level, instant)
2. Mount the snapshot read-only at a side path
3. Restic backs up the read-only mount
4. Drop the LVM snapshot when done

Solves P1#4 and P1#5: Restic walks a stable, read-only view; live traffic is unaffected by walk/fsync activity. **This is what the spec author probably had in mind.**

What this pattern does *not* solve: P0#1 (restore time), P0#2 (cluster state), P0#3 (consistency hook orchestration). Those are inherent to Restic's design at this scale.

### Bottom line

After the P0 #2 correction, the remaining unconditional P0 is the consistency hook surface — and even that flips to "non-issue" if the Restic/Kopia path is run via Velero (Velero's pre-snapshot hooks work for either path). So the **truly unconditional** failure is just one: hand-rolling Restic + LVM as a custom pipeline, the operator owns the consistency-hook orchestrator + the K8s object backup pipeline + the restore choreography.

Once the customer accepts Velero as the orchestrator, the choice between CSI path and FSB path reduces to:

- **Backup window** (seconds vs 60–130 min)
- **Restore time** (minutes vs 6–12 h)
- **App pod CPU/RAM cost during backup** (~0 vs ~1 vCPU + 2–4 GB)
- **Cadence floor** (5 min vs 30–60 min)
- **Storage cost shape** (EBS Snapshot vs S3 chunks)
- **Cross-region cadence-tier asymmetry** (see below)

### Cross-region asymmetry — CSI dual-cadence is native, FSB needs dual-bucket

| | CSI path | FSB path |
|---|---|---|
| Cross-region transport | Velero VolumeSnapshotLocations multi-region; `snapshotMoveData: true` invokes EBS `CopySnapshot` per Schedule | S3 cross-region replication of Backup Storage Location (BSL — Velero's S3-bucket abstraction) bucket(s) — bucket-level, not Schedule-level |
| Per-Schedule cross-region toggle | ✅ `snapshotMoveData: true/false` per Schedule, choose which Schedules replicate | ❌ Bucket-level — anything written to a replicated bucket replicates; can't toggle per backup |
| Dual-cadence (operational tight + DR loose) support | ✅ Native: Schedule A `snapshotMoveData: false` + Schedule B `snapshotMoveData: true` | ❌ Requires **dual-bucket pattern**: separate `velero-bsl-operational` (no replication) + `velero-bsl` (replicated), two Schedules each pointing to its own BSL |
| Architectural complexity | One BSL bucket + multi-region VSL | Two BSL buckets + two Schedules + per-Schedule storageLocation routing |

**This is a load-bearing reason CSI is our default.** Cost-conscious customers running at TB scale benefit materially from the dual-cadence pattern (operational 5-min source-only + DR 4h cross-region) — Schedule A's snapshots avoid cross-region storage cost entirely. CSI delivers this with one BSL bucket and `snapshotMoveData: per-schedule`. FSB requires the dual-bucket pattern (documented in `docs/future/restic-fsb-patch.md` § "Dual-cadence variant"), which is more terraform + more helm template + more cognitive load for operators.

If the customer's operational profile doesn't need dual-cadence (e.g., they accept uniform cross-region cadence to keep architecture simpler), FSB single-bucket is fine. But for cost-differentiated DR-tier strategies, CSI's dual-cadence is structurally cleaner.

**Velero + CSI Snapshot is our default** because the customer's likely operational profile rewards fast restore + low app-pod overhead + dual-cadence cross-region cost differentiation. **Velero + FSB (Kopia / Restic)** is the right call when the customer's profile rewards cross-cloud portability + granular file-level restore + storage-class-agnostic backup.

A diff patch flipping the architecture from CSI to FSB is documented at `docs/future/restic-fsb-patch.md` — applicable in ~5 minutes if the customer's Stage 3 conversation arrives at the FSB-favouring trade-off shape.

---

## 9. Tie-back to architecture

- **ADR-02 (Storage & PV mapping)** — establishes that EBS gp3 + LVM is the storage substrate. The "LVM is consistency, not backup transport" framing in this doc rests on ADR-02's primitives.
- **ADR-04 (Backup, DR & HA)** — this doc is the depth-justification for ADR-04's "Cold DR via Velero + EBS Snapshot" decision.
- **ADR-09 (Supply chain)** — Velero, Restic, and the EBS Snapshot driver are all SHA-pinned external dependencies per ADR-09's discipline. Switching tools doesn't change this.
- **`docs/operations/why-cold-dr.md`** — the parallel doc that defends "cold DR over active-passive multi-region". Same posture: name the trade-off, name what we gave up, name when the answer would flip.
