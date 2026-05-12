# Future plan — Literal LVM (init-container) on EBS (diff patch)

> **Status:** Opt-in alternative to the canonical multi-PVC (Path γ) layout.
> Apply this patch only when an operator explicitly chooses the
> spec-literal Linux LVM stack — e.g. for parity with a legacy on-prem
> LevelDB host that already runs LVM, or to retain LVM-only features
> (thin snapshots independent of CSI, in-host volume expansion across
> multiple PVs). Otherwise stay on the default multi-PVC layout.
> **Reading order:** ADR-02 §"EBS shape" first (full reasoning on why
> multi-PVC became default), then this doc (mechanics + apply
> instructions for the literal-LVM path).

---

## 1. Why this patch exists, and why it is not the default

The take-home spec named "Linux LVM" as the storage-management layer.
For the period 2018–2022, that was the canonical 2 TB-pod pattern: a
single EBS volume, LVM thin pool on top, dual logical volumes
(`data` + `wal`), `fsfreeze` + LVM thin snapshot as the
quiesce-and-capture step, Restic as the transport.

Modern Kubernetes database operators (TiDB Operator, K8ssandra,
CloudNativePG) deliver the same operational guarantees — WAL/data
IOPS isolation, crash-consistent snapshot semantics, online expansion
— without the literal LVM stack:

- **WAL/data IOPS isolation** → two PVCs ⇒ two EBS volumes ⇒ two
  independent IOPS budgets (gp3 baseline per-volume). Equivalent to
  LVM dual-LV on a single physical volume.
- **Crash-consistent snapshots** → CSI `VolumeSnapshot` against AWS
  EBS Snapshot is crash-consistent by construction; an
  application-level pre-snapshot hook (Velero pre-hook → `fsfreeze`
  or app admin endpoint) gives application-consistent capture.
- **Online expansion** → CSI volume resize per PVC; `kubectl patch
  pvc … --type=merge -p '{"spec":{"resources":{"requests":
  {"storage":"XGi"}}}}'`.

We do not need the literal LVM stack to get those properties on
modern K8s, and the literal stack carries real cost: an init
container running with `SYS_ADMIN` + `MKNOD` capabilities (PSS
`restricted` blocks it; a Kyverno `PolicyException` is required),
`volumeMode: Block` raw-block PVCs (rather than the default
filesystem mode), `mountPropagation: Bidirectional` on the main
container (also blocked by `restricted`), and a host-level dependency
on `lvm2` userspace + kernel `dm-thin-pool` module being present and
loaded on every stateful node.

This doc is the **deliberate, considered alternative** for operators
who specifically want the literal LVM stack. Applying it is a
~15-minute operation. Maintaining it forever is the operator's
choice — every PSS audit, every node-image refresh, every cluster
upgrade re-validates the exception.

---

## 2. Trade-off chart — what flipping costs vs gains

### Day-2 ops surface

| Dimension | Multi-PVC (default Path γ) | Literal LVM (this patch, Path α) |
|---|---|---|
| EBS volumes per pod | 2 (data + wal) | 1 (vg `aegis-vg` carved into LVs) |
| EBS Snapshot per backup | 2 (atomic via CSI `VolumeGroupSnapshot` or coordinated) | 1 (snapshot the single EBS) |
| Pod admission cost | clean — fits PSS `restricted` directly | Kyverno `PolicyException` scoped to the StatefulSet's namespace+container |
| Init container | none | privileged-ish (caps: `SYS_ADMIN`, `MKNOD`); idempotent LVM init script |
| Node-level dependency | none (CSI plugin only) | `lvm2` userspace + `dm-thin-pool` kernel module on every stateful node |
| Resize / repartition | `kubectl patch pvc` per PVC | `lvextend` inside the pod (capability cost) **or** `lvextend` via privileged debug pod |
| Snapshot coordination | CSI takes both PVCs atomically when targeting one Velero Backup | LVM thin snapshot inside the host VG — atomic by construction on one EBS |

### Operational properties (where literal LVM wins)

| Property | Multi-PVC | Literal LVM | Notes |
|---|---|---|---|
| In-host thin snapshot (no AWS API call) | ❌ | ✅ | LVM thin snap is sub-second, AWS-API-free; useful for in-pod consistency checks |
| Volume layout reshape without AWS API | ❌ | ✅ | `lvextend` / `lvreduce` / new LV creation inside the VG |
| Parity with legacy on-prem LevelDB host | ❌ | ✅ | If the customer already runs LVM on bare metal, this matches mental model |
| WAL/data IOPS isolation | ✅ | ✅ | Multi-PVC: independent EBS gp3 baselines; LVM: dual LVs on single PV share the PV's IOPS budget |
| Crash-consistent snapshot | ✅ | ✅ | Both rely on Velero pre-hook (`fsfreeze` or app admin endpoint) for application consistency |
| Online expansion | ✅ | ✅ | Multi-PVC: CSI resize per PVC; LVM: `pvresize` after EBS modify, then `lvextend` |

### Security posture (where literal LVM costs)

| Security control | Multi-PVC | Literal LVM | Mitigation if literal LVM is chosen |
|---|---|---|---|
| Pod Security Standards profile | `restricted` (default) | needs `PolicyException` | Kyverno PolicyException scoped to single StatefulSet + init container |
| Init container privileges | none required | `SYS_ADMIN`, `MKNOD` | drop after init completes — only the init container has them |
| Main container privileges | none required | `mountPropagation: Bidirectional` on `/dev` mount | scope to single mountPath; the main app does not get `SYS_ADMIN` |
| Auditor question "why is this namespace privileged-ish?" | not raised | raised | documented control (see ADR-07 § 4 pattern — same shape as Wazuh / Falco / Tetragon exceptions) |

---

## 3. What this patch ships

Three artefacts. None of them touch the application container image
— the LVM init machinery lives entirely in init-container + node-level
prerequisites + admission policy.

### 3a. StatefulSet diff (single primary template)

The patch flips `data` and `wal` from `volumeMode: Filesystem` (the
default) to `volumeMode: Block`, adds a privileged init container
that builds the VG + thin pool + dual LVs + filesystems and mounts
them, and adds `mountPropagation: Bidirectional` on the main
container so the mounts the init container performs become visible
in the main container's mount namespace.

```diff
@@ helm/aegis-statefulset/templates/statefulset-primary.yaml @@
       containers:
         - name: app
           # ... existing fields unchanged ...
+          # mountPropagation: Bidirectional needed because the LVM
+          # init container mounts /data and /wal inside the pod's
+          # mount namespace; the propagation flag is what makes
+          # those mounts visible here. PSS restricted blocks this;
+          # see Kyverno PolicyException below.
           volumeMounts:
             - name: data
-              mountPath: /data
+              devicePath: /dev/aegis-data
             - name: wal
-              mountPath: /wal
+              devicePath: /dev/aegis-wal
+            - name: lvm-mount
+              mountPath: /data
+              mountPropagation: Bidirectional
+            - name: lvm-mount-wal
+              mountPath: /wal
+              mountPropagation: Bidirectional
             - name: tmp
               mountPath: /tmp
+      initContainers:
+        - name: lvm-init
+          image: aegis-lvm-init:v1@sha256:TODO_PIN_REAL_DIGEST
+          # ^ small image: alpine + lvm2 + util-linux. Built from
+          # scripts/build/build-lvm-init.sh; SHA pinned per ADR-09.
+          securityContext:
+            privileged: false
+            capabilities:
+              add: ["SYS_ADMIN", "MKNOD"]
+              drop: ["ALL"]
+          volumeDevices:
+            - name: data
+              devicePath: /dev/aegis-data
+            - name: wal
+              devicePath: /dev/aegis-wal
+          volumeMounts:
+            - name: lvm-mount
+              mountPath: /mnt/data
+              mountPropagation: Bidirectional
+            - name: lvm-mount-wal
+              mountPath: /mnt/wal
+              mountPropagation: Bidirectional
+          command: ["/lvm-init.sh"]
+      volumes:
+        - name: lvm-mount
+          emptyDir: {}
+        - name: lvm-mount-wal
+          emptyDir: {}
   volumeClaimTemplates:
     - metadata:
         name: data
       spec:
+        volumeMode: Block
         accessModes: ["ReadWriteOnce"]
         storageClassName: {{ .Values.storage.storage_class }}
         resources:
           requests:
             storage: {{ .Values.stateful.cells.storage.data }}
     - metadata:
         name: wal
       spec:
+        volumeMode: Block
         accessModes: ["ReadWriteOnce"]
         storageClassName: {{ .Values.storage.storage_class }}
         resources:
           requests:
             storage: {{ .Values.stateful.cells.storage.wal }}
```

Note: even with literal LVM, we keep **two** PVCs (one feeding the
VG that hosts the `data` LV, one feeding the VG that hosts the `wal`
LV) rather than one big PVC partitioned by LVM only. Two PVCs gives
two EBS volumes ⇒ two independent gp3 IOPS budgets; LVM on top adds
in-host snapshot capability without sacrificing that. The
single-PVC-with-LVM-only variant is a third path that trades IOPS
isolation for one fewer EBS volume — usually the wrong trade and not
documented here.

### 3b. Kyverno PolicyException (admission carve-out)

ADR-07 § 4 establishes the pattern: legitimate exceptions to PSS
`restricted` (Wazuh DaemonSet, Falco, Tetragon) run as
`PolicyException` resources scoped to the exact pods that need the
exception. This patch adds one such exception for the stateful
namespace's init container.

```yaml
# gitops/policies/kyverno/exceptions/lvm-init.yaml
apiVersion: kyverno.io/v2
kind: PolicyException
metadata:
  name: lvm-init-exception
  namespace: aegis-app-prod
  annotations:
    policies.kyverno.io/title: LVM init container — capabilities + mountPropagation
    policies.kyverno.io/severity: medium
    policies.kyverno.io/subject: Pod
    policies.kyverno.io/description: |
      The aegis-statefulset primary pod's init container needs
      SYS_ADMIN + MKNOD to assemble the LVM VG + thin pool + LVs,
      and the main container needs mountPropagation: Bidirectional
      to see the mounts the init container makes inside the pod
      mount namespace. Both are blocked by PSS restricted by default.
      Scope: aegis-app-prod namespace, aegis-statefulset-primary
      StatefulSet only. Reviewed by: SRE-lead, security-lead.
spec:
  exceptions:
    - policyName: restricted
      ruleNames:
        - host-namespaces
        - capabilities
        - privilege-escalation
  match:
    any:
      - resources:
          kinds: ["Pod"]
          namespaces: ["aegis-app-prod"]
          selector:
            matchLabels:
              app.kubernetes.io/name: aegis-statefulset
              aegis.io/role: primary
```

The exception is **deliberately narrow** — namespace pinned, label
selector pinned, ruleset enumerated. Widening it to "any pod in any
namespace" defeats the point.

### 3c. Idempotent LVM init script

The script is `/lvm-init.sh` inside the init container image. It
must be idempotent: pods restart, init runs again, the script must
detect "already initialised" and skip past the destructive steps
without losing the existing thin pool / LVs / filesystems.

```bash
#!/bin/sh
# /lvm-init.sh — idempotent LVM bring-up for aegis-statefulset
# Inputs:  /dev/aegis-data  (raw block PV, larger volume)
#          /dev/aegis-wal   (raw block PV, smaller volume)
# Outputs: /mnt/data and /mnt/wal mounted, propagated to main container
set -euo pipefail

VG_DATA="aegis-vg-data"
VG_WAL="aegis-vg-wal"
LV_DATA="data"
LV_WAL="wal"
THIN_POOL="aegis-thin"
DATA_DEV="/dev/aegis-data"
WAL_DEV="/dev/aegis-wal"

# --- VG data side --------------------------------------------------
if ! pvs --noheadings "$DATA_DEV" >/dev/null 2>&1; then
  echo "Initialising PV on $DATA_DEV"
  pvcreate -ff -y "$DATA_DEV"
fi
if ! vgs --noheadings "$VG_DATA" >/dev/null 2>&1; then
  echo "Creating VG $VG_DATA"
  vgcreate "$VG_DATA" "$DATA_DEV"
fi
if ! lvs --noheadings "$VG_DATA/$THIN_POOL" >/dev/null 2>&1; then
  echo "Creating thin pool $THIN_POOL (95% of VG)"
  lvcreate -y -l 95%VG --thinpool "$THIN_POOL" "$VG_DATA"
fi
if ! lvs --noheadings "$VG_DATA/$LV_DATA" >/dev/null 2>&1; then
  echo "Creating thin LV $LV_DATA (sized to underlying VG)"
  # Initial thin LV size = 95% of VG; expandable later via lvextend
  lvcreate -y -V "$(vgs --noheadings -o vg_size --units b "$VG_DATA" | tr -d ' ')B" \
           --thin -n "$LV_DATA" "$VG_DATA/$THIN_POOL"
fi
if ! blkid "/dev/$VG_DATA/$LV_DATA" | grep -q 'TYPE="ext4"'; then
  echo "mkfs.ext4 on /dev/$VG_DATA/$LV_DATA"
  mkfs.ext4 -F "/dev/$VG_DATA/$LV_DATA"
fi
mkdir -p /mnt/data
mountpoint -q /mnt/data || mount -o noatime "/dev/$VG_DATA/$LV_DATA" /mnt/data

# --- VG wal side ---------------------------------------------------
if ! pvs --noheadings "$WAL_DEV" >/dev/null 2>&1; then
  pvcreate -ff -y "$WAL_DEV"
fi
if ! vgs --noheadings "$VG_WAL" >/dev/null 2>&1; then
  vgcreate "$VG_WAL" "$WAL_DEV"
fi
if ! lvs --noheadings "$VG_WAL/$LV_WAL" >/dev/null 2>&1; then
  lvcreate -y -l 95%VG -n "$LV_WAL" "$VG_WAL"
fi
if ! blkid "/dev/$VG_WAL/$LV_WAL" | grep -q 'TYPE="ext4"'; then
  mkfs.ext4 -F "/dev/$VG_WAL/$LV_WAL"
fi
mkdir -p /mnt/wal
mountpoint -q /mnt/wal || mount -o noatime "/dev/$VG_WAL/$LV_WAL" /mnt/wal

echo "lvm-init complete"
```

Idempotency notes:
- Every step is guarded by a `pvs` / `vgs` / `lvs` / `blkid` /
  `mountpoint` probe before the destructive command. Re-running on
  an already-initialised pod is a no-op.
- `pvcreate -ff` is *force-force* — only reached when `pvs` says the
  device is not yet a PV. This is the deliberate first-time
  destructive step on a fresh EBS volume.
- The thin pool is sized at 95% of the VG to leave headroom for
  snapshot metadata; thin LV is initially sized at full VG size and
  grows via `lvextend` post-CSI-resize.

### 3d. Node-level prerequisite (Bottlerocket OS / managed nodegroup)

The kernel module `dm-thin-pool` must be loadable; `lvm2` userspace
must exist. On Amazon EKS-managed Bottlerocket nodes, both are
present in the standard AMI. On custom AMIs, verify with:

```bash
ls /lib/modules/$(uname -r)/kernel/drivers/md/dm-thin-pool.ko*
which pvcreate vgcreate lvcreate
```

For Bottlerocket, no additional config is needed — load is on
demand. For Amazon Linux 2 / Ubuntu custom AMIs, ensure the user
data installs `lvm2` and runs `modprobe dm-thin-pool` at boot.

---

## 4. Apply / unapply

### Apply (literal-LVM path)

```bash
# 1. Build + push the init-container image
./scripts/build/build-lvm-init.sh  # (operator must add this script)
LVM_INIT_DIGEST=$(docker inspect aegis-lvm-init:v1 \
  --format='{{index .RepoDigests 0}}' | cut -d@ -f2)

# 2. Patch values-prod.yaml — enable LVM init mode
yq -i ".stateful.lvm_init.enabled = true" helm/aegis-statefulset/values-prod.yaml
yq -i ".stateful.lvm_init.image_digest = \"$LVM_INIT_DIGEST\"" helm/aegis-statefulset/values-prod.yaml

# 3. Apply the StatefulSet template diff
git apply docs/future/lvm-init-patch/lvm-init.patch

# 4. Apply Kyverno PolicyException FIRST (before StatefulSet rollout)
kubectl apply -f gitops/policies/kyverno/exceptions/lvm-init.yaml

# 5. Helm upgrade (rolling restart will recreate pods with init container)
helm upgrade aegis-statefulset helm/aegis-statefulset/ \
  -f helm/aegis-statefulset/values-prod.yaml -n aegis-app-prod

# 6. Verify init container ran cleanly
kubectl logs -n aegis-app-prod aegis-statefulset-primary-0 -c lvm-init
# Expect: "Initialising PV on /dev/aegis-data" + "Creating VG …" + "lvm-init complete"
```

**Critical ordering:** PolicyException must be applied before the
StatefulSet rollout — otherwise the new pods fail admission and the
StatefulSet is stuck with `0/1 Ready`. Order-of-operations matters.

### Unapply (back to multi-PVC default)

Unapply is destructive. The LVM-laid filesystems on the EBS volumes
are not bit-compatible with what plain-`Filesystem`-mode CSI will
mount. The migration path is:

1. Velero backup of the StatefulSet's PVCs (CSI Snapshot).
2. Delete the StatefulSet + PVCs.
3. Revert the StatefulSet template patch + delete the
   PolicyException.
4. Restore from Velero — Velero re-creates PVCs in `Filesystem`
   mode + the snapshot data is laid down as a plain filesystem on
   each PVC. (This step requires that the Velero Backup was taken
   with the snapshot data as raw block, then restored into
   filesystem-mode PVCs; for some CSI drivers this is automatic, for
   others it requires a `velero restore --change-storage-class`
   workaround. Operator must validate on their CSI plugin version.)

In practice, **the unapply path is much costlier than apply**. Choose
literal LVM only if the operator commits to staying on it.

---

## 5. When literal LVM would be the right call

The patch is documented but not the default because the trade-off
weight favours multi-PVC for the vast majority of operational
profiles. The cases where literal LVM is the right call are
specific:

- **Existing legacy host pattern parity.** The customer runs a
  legacy on-prem LevelDB host with LVM thin pool + dual LV; the
  migration target should match the mental model to reduce
  operator-cognitive cost during cutover.
- **In-host thin snapshot independent of CSI.** Some
  application-level operations (in-pod consistency probe, hot
  schema-rewrite) want a snapshot they can produce without an AWS
  API call. LVM thin snap is sub-second, AWS-API-free; CSI
  VolumeSnapshot is seconds + an EBS API call.
- **Customer policy mandates literal Linux storage stack** for
  audit/regulatory reasons (rare; usually only seen at on-prem
  parity sites or strict government/financial regimes).

Every other operational profile — including the architecture's
target Mittelstand-scale B2B SaaS — gets the same benefits via
multi-PVC without the security-policy cost.

---

## 6. Cross-references

- ADR-02 § "EBS shape" — reasoning behind multi-PVC default
- ADR-07 § 4 — PSS restricted + Kyverno PolicyException pattern
- ADR-07 § 8 — precedent for privileged DaemonSet exceptions (Wazuh
  / Falco / Tetragon) — the same shape this patch follows
- ADR-09 — image SHA pinning rule that applies to
  `aegis-lvm-init:v1@sha256:...`
- `docs/operations/why-velero-not-restic.md` — backup transport
  reasoning; the LVM choice does not change the backup transport
  decision
