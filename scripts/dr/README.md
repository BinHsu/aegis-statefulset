# Disaster Recovery Runbook

This directory holds the three DR recovery scripts and the operator runbook
that ties them together. The architecture decisions are in
`_context/adr/ADR-04-cluster-recovery-three-paths.md`; this document is the
**operational** companion: which path to pick, what to verify, what success
looks like.

> **Before reading further:** the design principle is
> *"infrastructure is cattle, EBS is treasure."* Cluster, deployments,
> routing, container images — all declarative, recreatable in 30-60 minutes.
> Customer data on EBS is the only irreplaceable asset. The three paths
> below differ in which assumptions hold, not in which data they protect.

---

## Decision tree — which path do I run?

```
                    ┌──────────────────────────────────┐
                    │ Is customer data on EBS intact?  │
                    └──────────────────────────────────┘
                                  │
                ┌─────── yes ─────┴────── no ───────┐
                ▼                                    ▼
   ┌───────────────────────────┐         ┌─────────────────────┐
   │ Are pods running and      │         │ Path C              │
   │ serving traffic?          │         │ restore-from-s3.sh  │
   └───────────────────────────┘         │ RTO 6-12h           │
            │                            │ RPO ≤ cadence (1h)  │
   ┌── yes ─┴── no ──┐                   └─────────────────────┘
   ▼                  ▼
┌────────────────┐  ┌───────────────────────┐
│ Path B         │  │ Path A                │
│ warm-routing   │  │ recover-cluster.sh    │
│ -table.sh      │  │ RTO ~30 min           │
│ RTO 10-30 min  │  │ RPO 0                 │
│ RPO 0          │  │                       │
└────────────────┘  └───────────────────────┘
```

| Path | Trigger | RTO | RPO | Script |
|---|---|---|---|---|
| **A** | EBS intact, cluster destroyed | ~30 min | 0 | `recover-cluster.sh` |
| **B** | Routing table wiped, pods + data healthy | 10-30 min | 0 | `warm-routing-table.sh` |
| **C** | EBS lost, full S3 restore needed | 6-12 h | ≤ cadence | `restore-from-s3.sh` |

**Drift handling rule (ADR-04):** when IaC declarations and infrastructure
state disagree, **trust infrastructure state**. Discovered EBS count
overrides `helm values`. Close the drift in IaC after recovery via PR.

---

## Path A — EBS survives, cluster destroyed

**Most common scenario.** Etcd corrupted, EKS upgrade gone wrong, namespace
nuked, cluster recreation needed. EBS volumes are still there with their
tags intact.

### Prerequisites

- AWS CLI configured with `ec2:DescribeVolumes`, `ec2:CreateVolume` (no-op),
  `autoscaling:SetDesiredCapacity`.
- `kubectl` pointed at the new (or recovered) cluster.
- `helm` 3.13+, `jq` available.

### Run

```bash
export AWS_REGION=eu-central-1
export CLUSTER_NAME=aegis-prod
export NAMESPACE=aegis-app

./recover-cluster.sh
```

The script:

1. Discovers EBS volumes via `aegis.io/cluster=${CLUSTER_NAME}` tag.
2. Generates `PersistentVolume` manifests with `claimRef` pre-binding so the
   StatefulSet's PVCs adopt the existing EBS instead of provisioning new.
3. Reconciles ASG desired count to match discovered EBS count (drift handling).
4. Applies PV manifests after a `--dry-run=client` operator review.
5. `helm upgrade --install` at the discovered replica count.
6. Delegates routing-table rebuild to `warm-routing-table.sh` (Path B logic).

### Success criteria

- All discovered EBS volumes have a corresponding `PersistentVolume` in `Bound` state.
- Pods reach `Ready` within 30 minutes of `helm install` returning.
- Routing override ConfigMap seeded; sample tenant requests succeed end-to-end.
- No data loss verified by sampling tenant identities (compare to a known-good
  pre-disaster export).

---

## Path B — routing table loss

**Subtle scenario.** Override ConfigMap deleted, Redis migration gone wrong,
namespace event rebuilt the wrong CM. Pods and data are fine; only the
routing layer is broken.

### Prerequisites

- Application contract: each pod exposes `GET /admin/local-tenants`
  returning a JSON list of tenant identifiers.
- `kubectl exec` access to pods.

### Run

```bash
export NAMESPACE=aegis-app
./warm-routing-table.sh
```

The script:

1. Enumerates pods matching `app.kubernetes.io/name=aegis-statefulset`.
2. Queries each pod's `/admin/local-tenants`.
3. Compares actual placement to consistent-hash result.
4. Writes override entries **only for divergences** — most tenants match
   the hash and need no entry (~95% per consensus.md § 3).

### Success criteria

- Override ConfigMap exists and contains an `overrides` key with valid JSON.
- Divergence count is non-zero but well below the total tenant count
  (typical: hundreds, not thousands).
- Sample requests for divergent tenants resolve to the correct pod.

---

## Path C — EBS lost, full restore from S3

**Worst case.** Source region or all EBS lost. Restore from cross-region
S3 backups using Restic.

### Prerequisites

- Cross-region S3 bucket with Restic snapshots present (verify via
  `restic snapshots` from a workstation before starting).
- `RESTIC_PASSWORD_FILE` available via ESO (ADR-07).
- New cluster + new EBS provisioned (Helm install creates them).
- Operator-supplied `REPLICA_COUNT` matching pre-disaster shard count.

### Run

```bash
export NAMESPACE=aegis-app
export RESTIC_REPOSITORY=s3:s3.amazonaws.com/aegis-backup-dr/aegis-prod
export REPLICA_COUNT=9

./restore-from-s3.sh
```

The script:

1. `helm install` provisions empty PVCs + EBS.
2. Waits for all PVCs to bind (timeout = `REPLICA_COUNT * 5 min`).
3. Spawns one restore Job per pod ordinal; restores run in parallel.
4. Waits for completion; pods start with restored data.
5. After completion, run `warm-routing-table.sh` to seed the override.

### Success criteria

- All restore Jobs reach `Complete` within 12 hours.
- All pods reach `Ready`.
- Sample queries against restored tenants return data consistent with the
  last backup timestamp; data loss bounded to ≤ cadence (1h default).

---

## DR drill cadence

Quarterly drill via `.github/workflows/dr-drill.yml` (cron `0 6 1 1,4,7,10 *`).
Each drill exercises one path against an ephemeral cluster (kind/k3d) with
seeded EBS-equivalent volumes. Reports filed as GitHub issues with the
`dr-drill` label.

Manual drills via `workflow_dispatch` any time — useful before a known risky
change (cluster upgrade, Karpenter rollout, IAM refactor).

---

## After any DR event — close the loop

1. **Update IaC** to reflect any drift the recovery surfaced (e.g., replica
   count changed from 9 to 12 because someone manually scaled in production
   and the IaC was stale).
2. **File a post-mortem** issue with: trigger, observed RTO, observed RPO,
   any procedural gaps the runbook didn't cover.
3. **Re-run the drill** for the path used, on the recovered cluster, within
   30 days. Confirms the runbook still works on the actual production state.

---

## Related

- `_context/adr/ADR-04-cluster-recovery-three-paths.md` — architectural reasoning
- `_context/adr/ADR-02-pod-to-pv-mapping-discipline.md` — EBS tag conventions
- `_context/adr/ADR-03-consistent-hash-override-delta.md` — override semantics
- `_context/adr/ADR-04-backup-cadence-configurable.md` — backup cadence and RPO bounds
- `_context/adr/ADR-07-secrets-management-eso.md` — Restic password sourcing
- `_context/consensus.md` § 11 — full DR design discussion
