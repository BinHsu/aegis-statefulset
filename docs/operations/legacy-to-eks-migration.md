# Legacy to EKS migration plan

> **Status:** Customer-execution playbook (not an internal architecture
> decision). Companion to ADR-05 — that ADR establishes Strangler-Fig as
> the architectural pattern; this doc is the operational playbook that
> pattern implies.
>
> **Audience:** the customer's platform / SRE team, or a migration
> consultant acting on their behalf. § 1 picks the source-platform
> scenario, § 2 picks the RPO-tightening strategy, § 3 covers the
> EKS-side procedure, § 4 covers traffic cutover. Trade-offs and
> reasoning are pushed to footnotes [^1] – [^8] at the end.

---

## Frame — three unknowns the spec leaves open

The spec asks: *"migrate live production servers to Kubernetes with
minimal impact on daily operations."* Three things it does NOT pin
down — each producing a different right answer:

1. **WHERE legacy lives** — EC2 / on-prem / other cloud / ECS / different
   K8s cluster (§ 1 enumerates five shapes; transfer time differs ~10×).
2. **HOW the app wraps LDB** — clean storage abstraction vs LDB calls
   scattered through business logic (gates § 2 dual-write strategy).
3. **WHAT "minimal impact" means** — zero data loss during planned
   migration vs spending some of the 6 h RPO budget (gates § 2 strategy
   choice).

Stage 3 conversation should pick one answer to each before any work
starts. This document assumes the customer treats 6 h RPO as a budget
that CAN be spent on planned migration; tighter modes in § 2 cost weeks
of refactor in exchange.

---

## § 1 — Source platform matrix

Pick the row that matches legacy.

| Source platform | Sync mechanisms applicable | 2 TB cold-migration time | RPO budget consumed | App changes |
|---|---|---|---|---|
| **EC2 / ASG (same AWS account)** | EBS Snapshot + Snapshot Copy / AWS MGN | ~30–60 min cross-region [^1] | ~40 min of 6 h | None for transfer |
| **EC2 / ASG (different AWS account)** | EBS Snapshot cross-account share + Copy | ~45–90 min | ~45 min | None |
| **On-prem bare-metal** | AWS DataSync / Direct Connect rsync / MGN agent | 2 TB / 1 Gbps WAN ≈ 5 h [^2] | ~5 h | None for transfer; agent install |
| **Other-cloud VM** | MGN cross-cloud / DataSync from object storage | 4–6 h + cross-cloud egress fees | ~5 h + egress cost | None for transfer; agent install |
| **ECS Fargate (EFS-backed)** | EFS replication / DataSync EFS → S3 → EKS | ~2–4 h | ~3 h | None |
| **Existing K8s (different cluster)** | Velero CSI restore cross-cluster | ~30 min | ~30 min | None |

### Stage 3 question — confirm before any work

- Which row matches legacy?
- Is the 6 h RPO ceiling spendable on migration, or strictly reserved for disasters?
- Is there a customer-accepted maintenance window, or must migration be fully transparent?

The answers determine § 2 strategy choice and § 3 timing.

---

## § 2 — RPO tightening — strategies to shrink the data-loss window

Cold cutover in § 3 has a data-loss window equal to the snapshot-to-mount
duration in § 1 (~40 min for EC2, ~5 h for on-prem). Customer may want
to tighten this. Four mechanisms — "WAL log-shipping" is NOT one of them [^3]:

| Strategy | LDB code | App code | RPO achievable | Real cost | Where it runs |
|---|---|---|---|---|---|
| **Rsync incremental (file-level)** | 0 | 0 | 30 sec – 2 min (compaction lag) | Compaction storm = full SSTable retransfer | K8s Job in `aegis-migration` namespace |
| **EBS Snapshot dual-cadence** | 0 | 0 | 5–60 min (snapshot interval) | Storage cost per snapshot; copy time | AWS API; no in-cluster component |
| **AWS MGN block-level continuous** | 0 | 0 | ~10 sec replication lag | Agent install on legacy; AWS MGN per-host fee | AWS MGN service + agent on legacy |
| **App-layer dual-write** | 0 | small–medium [^4] | 0 | Weeks of dual-write SEMANTICS design [^5] | App process (legacy AND EKS) |

### Rsync — runs as K8s Job, not inside the StatefulSet pod

Not inside the main pod (pollutes the image + breaks PSS `restricted`).
Run as a separate Job in `aegis-migration` namespace:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: leveldb-migration-host-{{ host_id }}
  namespace: aegis-migration
spec:
  template:
    spec:
      restartPolicy: OnFailure
      containers:
      - name: rsync-worker
        image: ghcr.io/<org>/alpine-rsync:3.19@sha256:<digest>
        command: ["/bin/sh", "-c"]
        args:
          - |
            rsync -a --delete --partial \
              --rsh="ssh -i /ssh/id_rsa -o StrictHostKeyChecking=no" \
              legacy@$LEGACY_HOST:/var/lib/leveldb/ \
              /mnt/dest/
        env:
          - name: LEGACY_HOST
            valueFrom: { configMapKeyRef: { name: migration-config, key: legacy_host }}
        volumeMounts:
          - { name: ssh-key, mountPath: /ssh, readOnly: true }
          - { name: dest-pvc, mountPath: /mnt/dest }
      volumes:
        - name: ssh-key
          secret: { secretName: legacy-ssh-key, defaultMode: 0400 }
        - name: dest-pvc
          persistentVolumeClaim:
            claimName: data-aegis-statefulset-primary-{{ ordinal }}
  ttlSecondsAfterFinished: 3600
```

The destination PVC must exist BEFORE the Job runs — § 3 step 1 handles
this. For continuous sync up to cutover, wrap in a `CronJob` and run the
final pass during the cutover window.

---

## § 3 — EKS mounting procedure

Independent of § 2 strategy. Six steps.

### Step 1 — Pre-create destination PVCs (per pod, per volume role)

Path γ multi-PVC per ADR-02 — each pod gets a `data` and a `wal` PVC.
For N pods, pre-create 2N PVCs before `helm install`:

```bash
for i in $(seq 0 $((N-1))); do
  for role in data wal; do
    size=$([ "$role" = "data" ] && echo "1843Gi" || echo "205Gi")
    kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $role-aegis-statefulset-primary-$i
  namespace: aegis-app-prod
  labels:
    aegis.io/volume-role: $role
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ebs-gp3-az-aware
  resources: { requests: { storage: $size } }
EOF
  done
done
```

**Shortcut for EC2 source:** add `dataSource: { name: <vs>, kind:
VolumeSnapshot }` to the PVC spec to provision directly from an EBS
Snapshot — skip the rsync Job entirely.

### Step 2 — Wait for PVCs to bind

```bash
kubectl wait --for=jsonpath='{.status.phase}'=Bound \
  pvc/data-aegis-statefulset-primary-0 pvc/wal-aegis-statefulset-primary-0 \
  -n aegis-app-prod --timeout=5m
```

### Step 3 — Run migration Job(s) (skip if PVCs sourced from snapshot)

One Job per pod ordinal, in parallel:

```bash
for i in $(seq 0 $((N-1))); do
  envsubst < migration-job-template.yaml | sed "s/{{ordinal}}/$i/g" | kubectl apply -f -
done
kubectl wait --for=condition=complete \
  job -l app=leveldb-migration -n aegis-migration --timeout=6h
```

### Step 4 — Helm install StatefulSet

StatefulSet discovers the pre-created PVCs and binds them. `OrderedReady`
means pod-0 starts first and waits for `/ready`:

```bash
helm install aegis-statefulset helm/aegis-statefulset/ \
  -f helm/aegis-statefulset/values-prod.yaml -n aegis-app-prod
```

### Step 5 — `/ready` + smoke test

Production LDB MemTable rebuild at 2 TB takes 5–15 min; startup probe
budget is 30 min:

```bash
kubectl rollout status statefulset/aegis-statefulset-primary \
  -n aegis-app-prod --timeout=30m

for i in $(seq 0 $((N-1))); do
  pod="aegis-statefulset-primary-$i.aegis-statefulset-headless.aegis-app-prod"
  ./scripts/chaos/verify-test-data.sh "$pod" "$i"  # samples N keys vs legacy
done
```

Difference rate must be 0 (cold cutover) or within dual-write lag
(continuous sync).

### Step 6 — Update placement table (ADR-03)

```bash
aws dynamodb update-item --table-name placement-table \
  --key "{\"tenant_id\":{\"S\":\"$TENANT\"}}" \
  --update-expression "SET endpoint = :new" \
  --expression-attribute-values \
    "{\":new\":{\"S\":\"aegis-statefulset-primary-$ORDINAL.aegis-app-prod.svc.cluster.local\"}}"
```

API tier placement-table cache TTL (default 5 sec) propagates the change.

---

## § 4 — Traffic cutover

Two routing layers depending on source.

### ALB target group binding (TGB) weighted shift — same VPC / same account

Single ALB, two target groups. Phase shifts [^6]:

| Phase | weight (legacy : EKS) | Soak before next |
|---|---|---|
| Phase 0 | 100 : 0 | (baseline) |
| Phase 1 (canary) | 90 : 10 | 24 h |
| Phase 2 (cohort) | 50 : 50 | 48 h |
| Phase 3 (full) | 0 : 100 | 7 days before decommission |

L7 connection-drained — clients perceive zero connection break.

### Route 53 DNS weighted routing — cross-VPC / cross-region / cross-cloud

1. **One week before cutover** — drop TTL 300 sec → 30 sec so client
   caches expire quickly on cutover day [^7]
2. **Cutover day** — shift weight from legacy → new EKS ALB endpoint
3. **One day after stable** — raise TTL back to 300 sec

### Mapping to § 1 scenarios

| Source scenario | Routing layer |
|---|---|
| EC2 / ASG same VPC | ALB TGB only |
| EC2 cross-region | Route 53 latency routing + per-region ALB |
| On-prem | Route 53 DNS CNAME flip |
| Other-cloud VM | Route 53 DNS-level switch |
| ECS Fargate | TGB (usually) |
| Existing K8s cluster | Velero restore + Service flip |

---

## § 5 — Rollback strategy

| Phase reached | Rollback mechanism | Data-loss cost |
|---|---|---|
| Before placement-table flip | Tear down EKS pods + PVCs; legacy still authoritative | Zero |
| After placement flip, before soak end | Flip placement back to legacy; abandon EKS-side writes | Small window [^8] |
| After soak end | One-way — restore from EKS Velero snapshot if EKS issue surfaces | Last EKS snapshot age (≤ 5 min at default cadence) |

---

## § 6 — Cross-references

- ADR-04 — backup / DR / Three-Layer-DR (the steady-state the customer lands on)
- ADR-05 — Strangler-Fig migration decision (this doc is the operational playbook for that decision)
- `docs/operations/per-tenant-relocation.md` — Pattern 1 vs Pattern 2 four-tier framework (gates whether per-tenant cutover is even possible)
- `docs/operations/runbooks/02-aws-bootstrap-and-chaos-demo.md` — EKS-side bring-up runbook
- `docs/future/README.md` — what happens beyond steady state (T+1y onward; substrate upgrade triggers at T+3y)

---

## Footnotes — trade-offs, math, edge cases

[^1]: **EBS Snapshot Copy timing.** 2 TB cross-region (us-east-1 →
    eu-central-1) is typically ~30 min wall-clock per
    [AWS EBS Snapshot Copy docs](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ebs-copy-snapshot.html).
    Actual time varies with snapshot delta size, the region pair, and
    AWS-internal throttling. Same-region copy is faster (~10 min for
    2 TB). EBS Snapshot is incremental against prior snapshots from the
    same volume — first migration snapshot is full size; subsequent
    "final delta" snapshots in a dual-cadence pattern transfer only
    changed blocks.

[^2]: **On-prem 2 TB / 1 Gbps WAN physics.** Theoretical line rate
    transfer time: `2 × 10¹² × 8 bits / 10⁹ bps = 16 000 sec ≈ 4.4 h`.
    Real-world transfers hit 70–80% line-rate efficiency due to TCP
    overhead, packet loss recovery, and concurrent traffic — so the
    practical figure is 5–6 h, saturating the 6 h RPO budget. Mitigation
    options: AWS Direct Connect (10 Gbps drops this to ~30 min), AWS
    Snowball Edge (physically ship the data, no network involvement,
    days of wall-clock but zero RPO-budget consumption during transit
    if combined with continuous sync at the cutover endpoint), or
    multi-Gbps internet uplink upgrade.

[^3]: **Why "WAL log-shipping" is not a real option.** A reader might
    propose "monitor legacy's LevelDB WAL/LOG file and replay into the
    destination LDB". This sounds elegant but does not work in practice:
    LevelDB's WAL (LOG file) is a per-process crash-recovery artifact;
    there is no public API to "subscribe to writes since LSN N" or
    "replay this WAL on a different instance". The WAL format is
    internal — version-dependent, with no stability contract. Parsing
    WAL bytes directly creates a fragile fork that breaks on LDB
    upgrades. The only ways to add streaming output are: (a) patch LDB
    source to add a hook — maintain a fork forever, or (b) wrap LDB at
    the app layer — effectively dual-write. So there is no "free"
    continuous-sync mechanism for LevelDB; the four strategies in the
    § 2 table are the real options.

[^4]: **Dual-write code-change size depends on app abstraction.** If
    the app already has a centralized storage-access package (a clean
    `storage.Write(key, value)` interface), dual-write is a ~100–200
    LOC change in that one package + semantics design — typically 1–2
    weeks. If LDB calls are scattered through business logic
    (`leveldb.OpenFile()` and `db.Put()` everywhere), the refactor is
    weeks to a month and a missed call site silently breaks the
    dual-write invariant. This is a Stage 3 question worth asking
    early because the answer changes the migration timeline by an
    order of magnitude.

[^5]: **Dual-write SEMANTICS — five corner cases the app must decide.**
    LDB code is unchanged in all dual-write strategies; the harder
    problem is the SEMANTICS the app's storage layer must handle:
    (a) **Legacy write succeeds, EKS write fails** — fail the client
    request (strong consistency, lower availability) vs queue for
    async retry (higher availability, EKS lag);
    (b) **Write ordering across both LDBs** — serial dual-write doubles
    p99 latency; parallel dual-write can diverge order per key on
    rapid-fire same-key writes, leaving final state inconsistent;
    (c) **Idempotency on retry** — client `request_id` + sentinel keys;
    LDB has no native dedup;
    (d) **Backfill vs dual-write overlap** — backfill copies pre-flag
    data, dual-write fires on new data; overlap window needs dedup;
    (e) **Delete operations** — tombstones must reach both stores or
    "resurrect" bugs appear. Each one is a real distributed-systems
    design decision; the LDB code change is the easy part.

[^6]: **ALB TGB phase soak rationale.** Three soak windows balance
    "detect divergence" vs "migration completion timeline". 24 h canary
    catches diurnal traffic patterns (peak hours expose load-dependent
    bugs that 1-h soak misses). 48 h cohort exposes weekly-cycle effects
    at half-rate (so any divergence affects half the cohort, not all).
    7-day full-cutover soak before decommission gives time to detect
    subtle data divergence (e.g. a tenant's monthly batch job that
    surfaces a bug not seen during peak). Operator can tighten these
    if confidence is higher (canary 4 h / cohort 12 h / full 2 days)
    or loosen for higher-stakes deployments.

[^7]: **Route 53 TTL drop rationale (1 week before cutover).** DNS
    resolvers cache records up to the TTL value. Dropping TTL from
    300 sec → 30 sec one week early ensures that by cutover day,
    every active client has refreshed at least once and is honoring
    the shorter TTL. 30 sec is the lower bound most public resolvers
    honor (Cloudflare 1.1.1.1, Google 8.8.8.8). Some corporate /
    aggressive caching resolvers ignore TTL below their floor (commonly
    300 sec) — plan a 5-min "shadow serve" period on legacy on cutover
    day to catch these clients. After 24 h of stable EKS operation,
    raise TTL back to 300 sec to reduce DNS query rate and resolver load.

[^8]: **Rollback after placement flip — data-loss math.** Between
    placement flip and rollback decision, writes have been landing on
    the EKS pod. If rollback happens at T+15min after flip, those 15
    minutes of EKS-side writes are abandoned (legacy did not receive
    them). At the architecture's default 5-min backup cadence, those
    writes ARE captured in EKS-side EBS Snapshots — recoverable via
    Velero restore later if the customer changes their mind, but not
    automatically. Soak window length is the operator's confidence
    threshold: longer soak → more EKS-side data accumulates → bigger
    blast radius on rollback. Typical shape: 24 h canary, 48 h cohort,
    7 days full before decommissioning legacy.

---

*Operational playbook for ADR-05. Architectural decisions live in the
ADR; mechanics live here. Trade-off depth lives in the footnotes.*
