# Future plan — Restic / Kopia FSB path (diff patch)

> **Status:** Optional alternative to the canonical CSI Snapshot path.
> Apply this patch only after Stage 3 conversation confirms the trade-off
> shape favours FSB. Otherwise stay on the default.
> **Reading order:** `docs/operations/why-velero-not-restic.md` first
> (full reasoning), then this doc (mechanics + apply instructions).

---

## 1. Why this patch exists

The architecture's default is Velero + CSI Snapshot path. The spec named "Restic + LVM" as the canonical 2 TB-pod backup pattern, which corresponds to Velero's **File System Backup (FSB)** path using Kopia (Velero 1.10+ default) or Restic (legacy compat).

We didn't build the FSB path into `values.yaml` as a knob because:
- A toggleable knob doubles the CI surface (both paths have to stay green)
- Knob-shaped configurability invites accidental flipping; an explicit patch invites deliberate flipping
- The vast majority of operational profiles favour CSI; FSB is the exception, not a peer

This doc is the **deliberate, considered alternative**: a diff patch that flips the architecture from CSI to FSB. Applying it is a five-minute operation. Maintaining it forever is the customer's choice.

---

## 2. Trade-off chart — what flipping costs vs gains

### Backup-time

| Dimension | CSI Snapshot (default) | FSB (Kopia / Restic) |
|---|---|---|
| 2 TB pod backup duration | seconds (storage-plane call) | 60–130 min (filesystem walk + hash + chunk upload) |
| Pod CPU during backup | 0 % additional | ~1 vCPU saturated for the duration |
| Pod RAM during backup | 0 additional | ~2–4 GB (dedup index in process) |
| Live request p99 during backup | unchanged | spikes 5–10× (fsync storm + page cache thrash) |
| Min sane cadence | 5 min comfortable | 30–60 min floor; 5-min cadence is physically impossible |
| Cross-AZ traffic at backup time | metadata only | actual data upload to S3 |

### Restore-time

| Dimension | CSI | FSB |
|---|---|---|
| 2 TB restore time | volume available in seconds; full perf ~30 min with FSR | 6–12 hours |
| Restore CPU profile | 0 (block fetch is async) | decrypt + reassembly is CPU-bound |
| Parallelism | block fetch parallelizes naturally | single-process restore is the throughput floor |

### Storage cost (per pod / month, indicative)

| Cadence | CSI (EBS Snapshot) | FSB (S3 STANDARD) | FSB (S3 → GLACIER IR) |
|---|---|---|---|
| 5-min | ~$300 | physically infeasible | infeasible |
| 1-hour | ~$200 | ~$200 | ~$80 |
| 6-hour (spec floor) | ~$150 | ~$150 | ~$60 |

### Cross-region cost

| Dimension | CSI | FSB |
|---|---|---|
| Mechanism | DLM block-level incremental | S3 byte-level cross-region replication |
| Bandwidth $$ at scale | low (block-incremental) | ~5× higher (full byte transfer) |

### What does NOT change between paths

- **K8s object capture** — Velero's BackupCRD logic captures CRDs, ConfigMaps, Secrets, PVC bindings, ServiceAccount mappings, Helm release state regardless of CSI vs FSB.
- **Application consistency hooks** — `spec.template.hooks.resources[].pre/post` exec hooks (fsfreeze, LDB quiesce) work in both paths.
- **Schedule + retention + cross-region replication** — Velero Schedule CRD is the same primitive.
- **IRSA + KMS integration** — same IAM role, same KMS keys.
- **Three-Layer DR ownership boundary** (per ADR-04) — Velero is still Layer 3; the path change is internal to Layer 3.

---

## 3. When to apply this patch

Apply if **all** of these are true:

1. **Customer's operational RTO tolerance ≥ 8 hours** for AZ failure (≥ 12 h for region failure). The FSB restore time floor is unfixable; if the tolerance is tighter, this patch is the wrong call regardless of preference.
2. **Cross-cloud DR is on the roadmap** OR **granular file-level restore is a product feature**. If neither applies, FSB is paying its cost without delivering its strength.
3. **Customer accepts the application-pod CPU/RAM cost during backup windows** (or the deployment has an option to run backup against a side-attached LVM snapshot via a dedicated backup node — see `docs/operations/why-velero-not-restic.md` § "Industry workarounds" #1).

Apply with caution if:

- Tenant fleet is large enough that the per-pod backup cost adds up. A 100-pod cluster spends 100× the per-pod CPU at backup time.
- Customer's existing observability is fragile. The p99 latency spike during backup windows will surface as an alert; need to tune alert thresholds first.

Do NOT apply if:

- Customer's RTO tolerance is sub-1 h. FSB cannot meet this regardless of automation.
- The architecture is on a 5-min cadence target. FSB cannot sustain that cadence at 2 TB.
- The team isn't prepared to operate the consistency-hook orchestration. FSB needs the hooks; CSI gets them too but the failure mode if hooks misfire is much more visible at FSB cadence.

---

## 4. The diff

Three files change. Total ~25 lines of patch.

### 4a. `infrastructure/terraform/cluster-controllers.tf`

Add two `set` blocks to the `helm_release "velero"` resource (after the existing `serviceAccount.server.annotations` block, before the `configuration.backupStorageLocation[0]` blocks):

```diff
   set {
     name  = "serviceAccount.server.annotations.eks\\.amazonaws\\.com/role-arn"
     value = aws_iam_role.velero.arn
   }
 
+  # FSB path — node-agent DaemonSet runs on every node, doing the
+  # filesystem walk + chunk upload via Kopia (Velero 1.10+ default
+  # uploader; switch to "restic" only for legacy compatibility).
+  # See docs/future/restic-fsb-patch.md for the trade-off context.
+  set {
+    name  = "deployNodeAgent"
+    value = "true"
+  }
+
+  set {
+    name  = "configuration.uploaderType"
+    value = "kopia"
+  }
+
   set {
     name  = "configuration.backupStorageLocation[0].name"
     value = "default"
   }
```

### 4b. `helm/aegis-statefulset/templates/velero-schedule.yaml`

Two changes inside `spec.template`:

```diff
 spec:
   schedule: "*/{{ .Values.backup.cadence_minutes }} * * * *"
   template:
     includedNamespaces:
       - {{ .Release.Namespace }}
     ...
-    snapshotVolumes: true
+    # FSB path — defaultVolumesToFsBackup makes Velero use the FSB path
+    # for every PVC in the included namespaces. snapshotVolumes is
+    # ignored when this is true.
+    defaultVolumesToFsBackup: true
+    snapshotVolumes: false
     ttl: "{{ .Values.backup.retention_days }}d"
     storageLocation: default
-    volumeSnapshotLocations:
-      - default
+    # volumeSnapshotLocations not used in FSB path.
```

### 4c. `helm/aegis-statefulset/values.yaml`

Relax the cadence default — FSB cannot sustain 5-min on 2 TB pods:

```diff
 backup:
-  # POC default: 5 minutes. Cost-RPO curve in
-  # docs/operations/backup-cadence-curve.md.
-  cadence_minutes: 5
+  # FSB path default: 60 min (5-min cadence is physically infeasible
+  # for 2 TB pods on the FSB transport — filesystem walk alone is
+  # 30-60 min). Operator-tunable down to 30 min if pods are smaller.
+  cadence_minutes: 60
   retention_days: 7
```

### 4d. (Optional) `helm/aegis-statefulset/values.yaml` — increase pod resources

If the operator keeps the same pod resource budget after flipping, the application pod will OOM during backup windows (Kopia's index in process). Bump the limit:

```diff
 stateful:
   ...
   resources:
     requests:
       cpu: 100m
       memory: 256Mi
     limits:
-      cpu: 500m
-      memory: 1Gi
+      # FSB path — Kopia / Restic dedup index runs in-process and needs
+      # ~2-4 GB RAM at 2 TB scale. Headroom required for backup windows.
+      cpu: 2000m
+      memory: 4Gi
```

---

## 5. Apply instructions

```bash
# 1. Save the diff above as a single patch file
cat > restic-fsb.patch <<'EOF'
... (paste the three diff blocks above)
EOF

# 2. Apply (from repo root)
git apply restic-fsb.patch

# 3. Verify
helm lint helm/aegis-statefulset/
terraform -chdir=infrastructure/terraform fmt -check -recursive
terraform -chdir=infrastructure/terraform validate

# 4. Commit
git add infrastructure/terraform/cluster-controllers.tf \
        helm/aegis-statefulset/templates/velero-schedule.yaml \
        helm/aegis-statefulset/values.yaml
git commit -m "Switch backup transport from CSI Snapshot to FSB (Kopia)

Per docs/future/restic-fsb-patch.md trade-off analysis. Stage 3
conversation arrived at the FSB-favouring shape (operator confirmed
RTO tolerance ≥ 8h and granular file-level restore is a product
feature). RPO degrades from ~30 sec to ~30 min at 1-hour cadence;
restore time ~10× longer; storage cost roughly equivalent at
relaxed cadence; cluster-state capture unchanged."

# 5. Apply via terraform + helm
cd infrastructure/terraform && terraform apply
helm upgrade --install aegis-app helm/aegis-statefulset/ -n aegis-app
```

### CI freshness check scope (upstream publishing discipline, not customer gate)

The CI step at `.github/workflows/pr-validation.yml` validates this patch
applies cleanly against the canonical repo state — keeping the patch fresh
as the chart evolves. This is **upstream publishing discipline**, not a
customer-side gate.

Customers who apply this patch in their own deployment do **not** need to
disable the CI. The check uses idempotent `git apply --reverse` auto-detection:
if the patch is already applied in the customer's tree, the CI step records
*"notice: patch is downstream-applied, skipping forward-apply check"* and
exits cleanly. Forward-apply check only fires when the patch is in its
unapplied state.

Operator workflow:
- **Upstream side** (this repo): CI fails if chart drift breaks the patch —
  fix the patch source via `recountdiff` or update against new chart structure.
- **Downstream side** (customer's fork after applying): CI auto-detects
  applied state and skips the check. No manual disable needed.

---

## 6. Post-flip operational notes

After applying, three architecture documents need amendment:

1. **`docs/adr/ADR-04-backup-dr-and-ha.md`** — Decision §1 ("Cold DR via Velero + EBS Snapshot") needs a "transport switched to FSB" note. RTO target needs revision (~10× longer). Trade-offs accepted needs the new app-pod CPU/RAM cost.
2. **`docs/operations/why-cold-dr.md`** — the cost-RPO curve numbers need updating to FSB scale.
3. **`_context/STATE.md`** — header status note "Wave 4 — Cold DR via Velero adopted" should append "; transport flipped to FSB per restic-fsb-patch.md".

Three runtime alerts need re-tuning:

1. **Latency p99 alert** — must absorb the backup-window spike; raise threshold + add backup-window suppression annotation.
2. **Pod memory alert** — must absorb the dedup index footprint; raise threshold for backup windows.
3. **Backup-completion alert** — adjust the "missed backup" threshold from 15 min to 4 h to match the new cadence + duration.

One observability dashboard needs a new panel:

- Backup-pipeline dashboard (per `gitops/grafana/dashboards/`) gains a "node-agent CPU/RAM" panel grouped by node, since the per-node DaemonSet is now where the backup cost lives.

---

## 7. Reverting the patch

Reverse the diff (`git apply -R restic-fsb.patch`), re-apply terraform + helm, undo the documentation amendments. The rollback window is bounded by the FSB path's S3 bucket retention — once a backup has been written via FSB, restoring it via CSI is not possible. Plan a 30-day overlap window where both paths' artefacts are kept.

---

## 8. What this patch does NOT change

- K8s object capture (Velero handles regardless of path)
- Application consistency hooks (work in both paths)
- IRSA + KMS integration (same role, same keys)
- ALB / Envoy / API tier behaviour (network plane untouched)
- Master AZ topology (compute plane untouched)
- DynamoDB placement table (routing plane untouched)
- Three-Layer DR ownership boundary (the path is internal to Layer 3)
- Anonymisation gate / pre-commit hook / CI workflows (build plane untouched)
- ADR-09 supply chain discipline (still SHA-pin, still Cosign sign)

The architecture *shape* is invariant under this patch. The only thing that changes is **how Velero moves bytes when backing up PVCs**.

---

## 9. Tie-back

- `docs/operations/why-velero-not-restic.md` — full reasoning chain for why CSI is the default
- `docs/adr/ADR-04-backup-dr-and-ha.md` — backup, DR, HA architecture
- `docs/operations/why-cold-dr.md` — cold DR vs active-passive trade-off (orthogonal to this patch)
