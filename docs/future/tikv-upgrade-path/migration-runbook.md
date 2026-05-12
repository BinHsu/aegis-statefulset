# TiKV migration runbook — LevelDB → TiKV substrate upgrade

> **Status:** Operational playbook companion to `docs/future/tikv-upgrade-path.md`.
> The upgrade-path doc establishes WHEN to consider this and WHY; this
> runbook spells out HOW — phase-by-phase mechanics, decision gates,
> rollback windows. Apply only after the trigger conditions in the
> strategic doc are met AND the customer has explicitly committed to
> the substrate change.
>
> **Audience:** the customer's platform / SRE team, or a migration
> consultant. Assumes Stage 3 has been done; this is execution
> material, not architectural discussion.

---

## Frame — what this runbook covers and what it doesn't

| In scope | Out of scope |
|---|---|
| LevelDB-on-EKS → TiKV-on-EKS substrate change | Initial customer onboarding to EKS (covered by ADR-05 Strangler-Fig + `legacy-to-eks-migration.md`) |
| Multi-AZ HA via TiKV native replication | Multi-region active-active (covered by `tikv-upgrade-path.md § 4` — separate decision, separate runbook would be needed) |
| Dual-write + backfill + cutover sequence | App-side code changes (customer's engineering team owns; this doc names what they need to build, not how) |
| EKS-side operational mechanics (helm install, monitoring, cutover) | Cost analysis (covered by `tikv-upgrade-path.md § 3` strategic doc + `docs/operations/cost-estimate-methodology.md`) |

**Critical premise:** Customer has confirmed the upgrade trigger fired
(per strategic doc § 6 decision criteria) and committed to weeks-to-
months of application engineering effort. This runbook is wasted
effort if either condition is missing — abort and re-read strategic
doc.

---

## § 1 — Prerequisites + go/no-go gates

### Pre-flight checks (Stage 3 conversation outputs)

| Check | Expected state | Failure mode if not met |
|---|---|---|
| **Trigger condition explicitly confirmed** | Customer SLA outgrew LevelDB physics OR multi-AZ HA needed OR sub-5-min RPO required | Architecture-conversation, not execution — back to `tikv-upgrade-path.md` |
| **App engineering capacity** | 4-8 weeks of focused application work allocated; named eng lead | Migration stalls at Phase 2; the LDB layer changes; dual-write semantics design takes weeks |
| **Customer accepts TiKV operational complexity** | They've confirmed willingness to operate PD + TiKV + monitoring; either via TiKV operator (managed-style) or in-house | TiKV operational burden is real — back to LDB or to managed alternative (DynamoDB Global Tables / Aurora) |
| **Tenant cohort identification done** | Customer knows which tenants are pilot (low-risk) vs cohort vs final | Cutover planning impossible without this |
| **Data volume + key distribution profile** | Total bytes + key cardinality per tenant; identifies hot tenants | Backfill timeline estimation fails |
| **Rollback acceptance** | Customer accepts that post-Phase-7 rollback is one-way (LDB decommissioned) | This is the highest-risk migration this architecture supports |

### Resource sizing — TiKV cluster reference numbers

For a 2 TB LDB-equivalent dataset on the existing architecture, the
TiKV cluster sizing baseline is:

| Component | Count | Instance type | Storage | Role |
|---|---|---|---|---|
| PD (placement driver) | 3 (odd for Raft) | t3.medium | 50 GB gp3 each | Cluster metadata + scheduling decisions |
| TiKV (storage nodes) | 3-9 (3 per AZ × 1-3 AZs) | r6id.2xlarge | 1 TB gp3 each | Data storage with 3× replication factor |
| Monitor | 1 | t3.small | 20 GB | Prometheus + Grafana sidecar (or use existing observability stack per ADR-06) |

Multi-AZ HA requires minimum 3 TiKV nodes split across 3 AZs (one per
AZ for Raft quorum tolerance). Single-AZ TiKV is supported but defeats
the upgrade purpose.

### Decision tree before Phase 1

```
Are all 6 pre-flight checks green?
  │
  ├─ No  → abort; back to tikv-upgrade-path.md Stage 3 conversation
  │
  └─ Yes → does customer's app have a centralized storage-access layer?
            │
            ├─ Yes → Phase 2 dual-write is a 1-2 week effort; proceed
            │
            └─ No  → Phase 2 is weeks-to-month refactor; re-confirm
                     commitment before Phase 1; consider phased adoption
                     (one app first, then siblings)
```

---

## § 2 — Phase 1: TiKV cluster bring-up

**Duration:** 2-3 days including monitoring + load testing
**Risk:** Low — separate cluster, no traffic
**Rollback:** Trivial (`helm uninstall`)

### Steps

| Step | Action | Verification |
|---|---|---|
| 1.1 | Add tikv-operator Helm repo: `helm repo add pingcap https://charts.pingcap.org/` | `helm search repo pingcap/tidb-operator` |
| 1.2 | Install TiKV operator into `tikv-operator` namespace | `kubectl get pods -n tikv-operator` shows controller running |
| 1.3 | Apply TidbCluster CR with PD=3 + TiKV=3 (one per AZ); use [helm/tikv-cluster/values-prod.yaml](TODO_VALUES_REF) | `kubectl get tc -n aegis-tikv` shows `Phase: Running` |
| 1.4 | Wait for cluster ready (~10-15 min); verify Raft healthy via PD API | `kubectl exec -n aegis-tikv <pd-pod> -- pd-ctl member` shows 3 PD members + quorum OK |
| 1.5 | Smoke-test write+read via TiKV Client from a temp pod | Write 1k keys, read back, verify byte-equal |
| 1.6 | Load-test at expected QPS (use realistic key distribution) | p99 latency ≤ target; no Raft membership churn under load |

### Sizing knobs (per `helm/tikv-cluster/values-prod.yaml`)

| Knob | POC default | Production scale |
|---|---|---|
| `pd.replicas` | 3 | 3 (always; odd for Raft quorum) |
| `tikv.replicas` | 3 | 3 to 9 (one per AZ × cells) |
| `tikv.storageClassName` | `ebs-gp3-az-aware` | Same |
| `tikv.requests.storage` | 1Ti | Per-node; total cluster = replicas × this |
| `tikv.resources.limits.memory` | 16Gi | TiKV is memory-hungry; provision 2-4× LDB's allocation |
| `tikv.config.storage.scheduler-worker-pool-size` | 4 | Scale with cores |

### Phase 1 exit gate

Cluster must satisfy all of:

| Gate criterion | Test |
|---|---|
| Raft quorum stable under load test | No leader-election storms in last 1 h of monitoring |
| Cross-AZ latency budget met | TiKV-to-TiKV p99 latency stays below replication SLO (typically < 10 ms) |
| Backup mechanism verified | TiKV BR (Backup & Restore) tool can take + restore a snapshot |
| Monitoring observable | Prometheus scraping all PD + TiKV pods; alerts wired to existing pager |

If any gate fails → fix before Phase 2; do NOT proceed with cluster
that hasn't passed load testing.

---

## § 3 — Phase 2: Dual-write layer (app-side work)

**Duration:** 1-2 weeks (centralized abstraction) to weeks-month (scattered LDB calls)
**Risk:** High — touches production app code
**Rollback:** Feature-flag the dual-write off; resume LDB-only writes

### What the customer's app team builds

Five SEMANTICS decisions the storage-access layer must handle. Each
is a real distributed-systems design choice; pick wrong → divergent
data + silent corruption.

| Corner case | Question | POC-default recommendation |
|---|---|---|
| Legacy write OK, TiKV write fails | Fail request strict, or queue retry? | Queue retry with bounded queue (5 sec ack timeout); alert when queue > 100; this favors availability |
| Write ordering across both stores | Serial (p99 ×2) or parallel (order may diverge)? | Parallel; idempotency on retry handles diverged-order edge case |
| Idempotency on retry | How to dedupe? | Client-provided `request_id` as sentinel key in both LDB and TiKV; check-then-write |
| Backfill vs dual-write race | What if backfill writes pre-flag data while dual-write fires on same key? | Backfill uses `IfAbsent` mode (no overwrite of newer dual-write data) |
| Delete (tombstone) handling | Both stores must receive delete | Same dual-write path as Put; tombstone ID propagation needed |

### Application code shape (pseudocode)

```go
// Storage interface — single point of dual-write enablement
type Store interface {
    Put(ctx context.Context, key, value []byte) error
    Get(ctx context.Context, key []byte) ([]byte, error)
    Delete(ctx context.Context, key []byte) error
}

// Wrapping impl with feature flag
type DualWriteStore struct {
    legacy *LevelDBStore
    tikv   *TiKVStore
    flag   *FeatureFlag  // "dual_write_enabled" / "read_from_tikv"
}

func (d *DualWriteStore) Put(ctx context.Context, key, value []byte) error {
    if !d.flag.Get("dual_write_enabled") {
        return d.legacy.Put(ctx, key, value)
    }
    // Parallel dual-write — both succeed or queue for retry
    errLegacy := d.legacy.Put(ctx, key, value)
    errTiKV := d.tikv.Put(ctx, key, value)
    return reconcile(errLegacy, errTiKV)  // SEMANTICS decision baked here
}
```

### Phase 2 exit gate

| Gate criterion | Test |
|---|---|
| All LDB call sites routed through Store interface | `grep -rn "leveldb\." app/` returns zero matches outside storage package |
| Dual-write flag rollout to 100% of new writes | Feature flag dashboard shows 100% / 0% (no canary mix) |
| Reconciliation queue depth = 0 in steady state | Queue depth alert clear for 24h |
| Same Put/Get/Delete invariant on both stores | 24h shadow read comparison: sample 10k keys/min from new writes; diff rate < 0.001% |

---

## § 4 — Phase 3: Backfill (data migration)

**Duration:** Days to weeks depending on data size + read pressure on legacy
**Risk:** Medium — read-heavy on legacy LDB (potential perf impact on prod)
**Rollback:** Stop backfill job; partial TiKV state is OK if Phase 5 hasn't started yet

### Two backfill modes

| Mode | When | Mechanism |
|---|---|---|
| **Cold backfill** | Small data (≤ 10 GB tenant); maintenance window OK | LDB iterator → TiKV batch Put; downtime per tenant |
| **Hot backfill (default)** | Large data; no downtime acceptable | Background job iterates LDB, writes TiKV with `IfAbsent` (won't overwrite live dual-writes); rate-limited |

### Hot backfill — the standard path

```bash
# Customer-built backfill tool; pseudocode for the operator's runbook
./tikv-backfill \
  --source-leveldb /data \
  --target-pd $TIKV_PD_ENDPOINT \
  --rate-limit-keys-per-sec 1000 \
  --tenant-allowlist alice,bob,carol \
  --mode if-absent \
  --report-every 60s
```

### Monitoring during backfill

| Metric | Alert threshold | Action |
|---|---|---|
| LDB read p99 | > 2× normal | Throttle backfill rate; investigate compaction storm |
| TiKV write throughput | < 80% of load test baseline | Investigate Raft / disk bottleneck |
| Backfill keys-per-sec | drops > 50% from start | Pause backfill; investigate; resume |
| Reconciliation queue depth | > 1000 | Stop backfill; troubleshoot dual-write before continuing |

### Phase 3 exit gate

| Gate criterion | Test |
|---|---|
| All historical keys backfilled | TiKV count == LDB count for each tenant in scope |
| Shadow-read parity | 0.001% diff rate sustained 48h across sampled traffic |
| Reconciliation queue empty | 0 for 24h |
| TiKV cluster healthy under combined load | No leader-election storms during simulated peak traffic |

---

## § 5 — Phase 4: Shadow reads

**Duration:** 1-2 weeks
**Risk:** Low — reads only; no traffic shift yet
**Rollback:** Disable shadow-read flag; reads continue from LDB

Reads continue to be served from LDB (source of truth). For each
production read request, fire a *shadow* read against TiKV in
parallel, compare results, log divergences.

### Setup

```go
func (d *DualWriteStore) Get(ctx context.Context, key []byte) ([]byte, error) {
    primary := d.legacy.Get(ctx, key)

    if d.flag.Get("shadow_read_enabled") {
        go func() {
            shadow, _ := d.tikv.Get(ctx, key)
            if !bytes.Equal(primary.value, shadow) {
                shadowMetric.Inc("divergence", labels)
                log.Warn("shadow_read_divergence", key)
            }
        }()
    }
    return primary
}
```

### Phase 4 exit gate

| Gate criterion | Test |
|---|---|
| Shadow divergence rate | < 0.001% over 1 week of full-traffic shadowing |
| Latency parity | TiKV p99 read ≤ 2× LDB p99 read (within acceptable headroom) |
| No correctness regression spotted | Manual review of any divergence > 1 per day during the week |

---

## § 6 — Phase 5: Read cutover (% gradual shift)

**Duration:** 1-2 weeks (canary → cohort → full)
**Risk:** Medium — production reads start coming from TiKV
**Rollback:** Reset feature flag to legacy reads; instant

| Phase | Read source mix | Soak before next |
|---|---|---|
| 5a Canary | 10% TiKV / 90% LDB | 24 h |
| 5b Cohort | 50% TiKV / 50% LDB | 48 h |
| 5c Full | 100% TiKV / 0% LDB | 7 days before Phase 6 |

Writes still go to both stores (dual-write continues throughout
Phase 5). LDB remains the *backup* for read-cutover rollback.

### Watch metrics during cutover

| Metric | Where | Alert at |
|---|---|---|
| TiKV-read p99 latency | TiKV Grafana dashboard | > 1.5× LDB baseline |
| TiKV-read error rate | Application Prometheus | > 0.01% |
| App-level user-visible errors | Synthetic + real-user monitoring | Any regression from baseline |
| TiKV cluster health | TiKV/PD Grafana | Leader churn, region imbalance, slow stores |

### Phase 5 exit gate

| Gate criterion | Test |
|---|---|
| 100% reads on TiKV stable 7 days | Zero rollback triggered during full-cutover soak |
| Application metrics regression-free | All error rates within steady-state band |
| TiKV cluster operational health | No incident requiring manual intervention during soak |

---

## § 7 — Phase 6: Write cutover (irreversible point)

**Duration:** Atomic flag flip + 7-day soak
**Risk:** High — this is the one-way commit
**Rollback:** Re-enable dual-write to LDB; but LDB will be stale; recovery requires backfill in reverse

After Phase 5 completes, writes are still hitting both stores
(LDB dual-write still on). Phase 6 is when the customer commits:
**stop writing to LDB**. Once that happens, LDB starts drifting from
TiKV — rolling back requires reverse-backfill.

### Step

```
1. Verify Phase 5 exit gates STILL true (re-confirm; 5 days have passed since gate check)
2. Customer engineering / SRE leads sign off
3. Flip flag: dual_write_enabled = false (TiKV-only writes from now on)
4. Watch metrics for 24h CONTINUOUSLY (war-room style)
5. Begin 7-day soak; LDB starts to drift but stays available read-only
6. After 7 days clean → Phase 7
```

### Phase 6 watch metrics

Same as Phase 5 + new:

| Metric | Where | Alert at |
|---|---|---|
| TiKV-only write success rate | App Prometheus | < 99.99% |
| LDB drift rate | Sample compare LDB read vs TiKV read for keys still in LDB | Expected; tracks drift accumulation |
| Customer escalations | Support ticket flow | Any |

### Rollback window during Phase 6 7-day soak

If a critical TiKV issue surfaces during the 7-day soak BEFORE
Phase 7:

| Time since flip | Rollback procedure |
|---|---|
| < 1 h | Re-enable dual-write flag; LDB still has near-current state; small data-loss window |
| 1-24 h | Same; data-loss window grows linearly |
| 1-7 days | Re-enable dual-write; LDB is stale by ~Phase 6 duration; backfill TiKV → LDB before un-failing-over (this is the painful rollback) |

After Phase 7, no rollback. Plan accordingly.

---

## § 8 — Phase 7: LDB decommission

**Duration:** Atomic — one decision day
**Risk:** Highest — one-way; LDB infrastructure goes away
**Rollback:** None — past this point, only TiKV-native disaster recovery applies

| Step | Action |
|---|---|
| 8.1 | Phase 6 7-day soak complete, all gates green |
| 8.2 | Customer leads sign-off (engineering + product + on-call) on the decommission |
| 8.3 | Take final LDB snapshot to Glacier (long-term retention, not recovery target) |
| 8.4 | Scale LDB StatefulSet to 0 replicas (pods terminate, PVCs retained) |
| 8.5 | Monitor for 24h — no missing-data complaints |
| 8.6 | Delete LDB PVCs (Retain reclaim still saves the underlying EBS; manual deletion if confident) |
| 8.7 | Update ADR / docs — architecture is now TiKV-based (this doc's premise inverts) |

After Phase 7, the architecture is fundamentally TiKV-based.
ADR-01 / ADR-02 / ADR-04 should be updated to reflect the new
substrate, and a new strategic doc would name the next horizon
(multi-region active-active via TiCDC, per `tikv-upgrade-path.md § 4`).

---

## § 9 — Total timeline

| Phase | Best case | Typical | Worst case |
|---|---|---|---|
| Phase 1 cluster bring-up | 2 days | 3 days | 1 week |
| Phase 2 dual-write code | 1 week | 2-3 weeks | 1 month |
| Phase 3 backfill | 3 days | 1 week | 1 month (large data + rate limits) |
| Phase 4 shadow reads | 1 week | 2 weeks | 1 month |
| Phase 5 read cutover | 2 weeks | 3 weeks | 2 months (cautious soaks) |
| Phase 6 write cutover + soak | 1 week | 1 week | 2 weeks |
| Phase 7 decommission | 1 day | 1 day | Same |
| **Total** | **~6 weeks** | **~10 weeks** | **~6 months** |

For Mittelstand-scale customer: expect ~2-3 months from sign-off to LDB decommission, the variance dominated by Phase 2 application engineering bandwidth and Phase 3 backfill timeline (which is data-size-bound).

---

## § 10 — Stage 3 discussion points

If a customer is in the "should we plan TiKV for next year?" conversation
(per `tikv-upgrade-path.md § 9`), these are the questions to put on the
table:

| Question | Why it matters |
|---|---|
| Is the trigger condition explicit (SLA tighter than current ~25 min AZ-failure RTO, or sub-5-min RPO, or multi-region active-active becoming a product feature)? | Without a clear trigger, this migration is engineering spending without an SLA gain |
| Do you have 4-8 weeks of application engineering capacity allocated? | Phase 2 SEMANTICS design + Phase 3 backfill tooling is the timeline bottleneck |
| What's your appetite for operational complexity in PD + TiKV cluster ops? | Real cost beyond the migration: PD elections, region balancing, Raft tuning — customer's SRE team needs to absorb this |
| Have you considered managed alternatives — DynamoDB Global Tables, Aurora? | TiKV is one of four real substrate alternatives (per `tikv-upgrade-path.md § 7`); managed alts have less ops burden |
| Is post-Phase-7 one-way commit acceptable? | This is the highest-risk migration in the architecture; rollback after decommission means TiKV-native disaster recovery only |
| Do you have a phased adoption plan (one app/cohort first, then siblings)? | Big-bang substrate upgrade is the worst possible plan; phased adoption de-risks |

---

## Cross-references

| Document | Relationship |
|---|---|
| [`tikv-upgrade-path.md`](../tikv-upgrade-path.md) | Strategic doc — WHY and WHEN; this runbook is the operational HOW |
| [`docs/operations/legacy-to-eks-migration.md`](../../operations/legacy-to-eks-migration.md) | Sister playbook for the EARLIER migration (legacy host → EKS-on-LDB); this doc assumes that one already happened |
| [ADR-04](../../adr/ADR-04-backup-dr-and-ha.md) | Current substrate's DR / HA story — context for what's being replaced |
| [`docs/future/README.md`](../README.md) | Substrate-upgrade horizon (T+3y); when this runbook becomes relevant |

---

*Operational runbook for `tikv-upgrade-path.md`. Strategic decisions
live in the parent doc; mechanics live here.*
