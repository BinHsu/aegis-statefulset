# Tenant Relocation Runbook

Operator runbook for `scripts/relocation/per-tenant-relocate.sh` per ADR-01.

Relocation is the response to **per-pod overflow** — a single pod's PV is
filling up because of one large tenant or several growing tenants on the
same pod. Capacity expansion (ADR-01) does not solve this; new cells
help **new** tenants land in roomy pods, but existing tenants stay where
they are unless explicitly relocated.

---

## 1. When to relocate — three-tier triggers

The placement service emits Prometheus alerts at three levels:

| Tier | Trigger | Response | Operator role |
|---|---|---|---|
| **PR (planning)** | pod EBS used ≥ 75 % | open PR, schedule relocation in next change window | manual review of suggested target |
| **Emergency** | pod EBS used ≥ 90 % | automation runs `per-tenant-relocate.sh` immediately | post-hoc review; intervene only on failure |
| **Growth-rate** | tenant grew ≥ 500 GB in 7 days | open PR, capacity-plan within 14 days | review whether growth is sustained or a load test |

**Decision rule:** Always prefer PR-tier relocation (planned) over emergency
(automated). Emergency tier exists because we'd rather have a working
service with an opinionated automated decision than a paged engineer
reasoning about it at 3 a.m. — but the PR path produces fewer surprises.

---

## 2. Decision flowchart — relocate vs expand vs leave alone

```
              pod EBS >= 75% ?
                     |
         ----------- + -----------
        |                          |
        no                       yes
        |                          |
   no action               does ONE tenant
                           dominate the pod?
                                  |
                       ----------- + -----------
                      |                          |
                     yes                        no
                      |                          |
              relocate that tenant       relocate the LARGEST
              to a roomy pod             tenant to a roomy pod
              (single target)            (multi-tenant overflow)

              also consider:
              - is this tenant on a path
                to need a dedicated cell?
                (>= 30% of one pod alone)
              - if yes, target = empty cell
              - if no, target = any pod
                with > 40% headroom
```

**Online expand (PVC resize) is NOT a substitute for relocation.** Online
expand grows the volume but does nothing about the pod's CPU / memory
ceiling, and it eventually hits AWS gp3 max size. Relocation is the
correct response to a hot pod.

**Capacity expansion (ADR-01) is for aggregate cluster pressure**, not
for a single hot pod. Don't add a new cell hoping it will help an
overloaded existing pod — it won't, because existing tenants stay put.

---

## 3. Pre-flight checklist

Before running the script, confirm in this order:

1. **Target pod exists and is Running**
   ```
   kubectl get pod aegis-statefulset-primary-<target-ord> -n aegis-app
   ```

2. **Target pod has headroom for the tenant**
   target free space ≥ (tenant size × 1.2). The 20 % buffer absorbs the
   delta-sync data and a normal week of growth post-flip.

3. **Target cell health is green**
   - all pods in the cell Ready
   - latest backup CronJob succeeded (`kubectl get jobs -n aegis-app`)
   - no in-flight relocations targeting the same pod

4. **Backup pipeline is healthy**
   Restic repository is reachable from both source and target pods, and
   recent snapshots are listable. The relocation script depends on
   Restic for the delta sync; a broken backup pipeline blocks Step 4.

5. **Cross-region S3 replication is up-to-date**
   Soak-window cleanup gate (b) requires this; if replication is
   backlogged, the soak will not advance to cleanup.

6. **No existing tenant entry in `SOAK_PENDING_*` state for this tenant**
   ```
   aws dynamodb get-item --table-name aegis-statefulset-placement-prod \
     --key '{"tenant_id":{"S":"<tenant-id>"}}'
   ```
   The script's CAS guard catches this, but checking up-front is cheaper
   than a mid-script abort.

---

## 4. Running the script

```
export ENVOY_ADMIN_ENDPOINTS="http://envoy-0.envoy:9901,http://envoy-1.envoy:9901,http://envoy-2.envoy:9901"
export NAMESPACE="aegis-app"
export PLACEMENT_TABLE="aegis-statefulset-placement-prod"

./scripts/relocation/per-tenant-relocate.sh tenant-acme 3 7
#                                            ^^^^^^^^^^ ^ ^
#                                            tenant-id  | target-pod-ordinal
#                                                       source-pod-ordinal
```

Script returns 0 on successful flip + soak armed, non-zero on:

- DynamoDB CAS failure (placement changed underneath us — abort and re-plan)
- Delta sync did not converge after 20 iterations (source write rate
  exceeds sync bandwidth — investigate before retry)
- Pre-flight verification failure (target pod not Running, no headroom)

---

## 5. Monitoring during execution

Open Grafana dashboard `capacity-headroom` and watch:

- **`Active relocations`** panel — should show this tenant in
  `PRE_FLIP_SYNCING` for the duration of Step 5, then transition to
  `SOAK_PENDING_BACKUP` after Step 6.2.
- **`Cache hit rate`** panel — expect a brief dip during Step 6.3
  (sync invalidate flushes this tenant's entries on every replica).
  If hit rate drops sharply across all tenants, Step 6.5 fired the
  bulk flush — check script logs.
- **Source pod write IOPS** — should remain steady through Steps 4–6.
  Source is not quiesced; clients keep writing during the entire flow.
- **Target pod read IOPS** — spikes during initial restore (Step 4),
  then settles to incremental delta restore through Step 5, then takes
  over fully after Step 6.2.

The flip itself (Step 6.2 → 6.3) is sub-second. The script logs the
exact `flip_at` timestamp; correlate with any client-visible blip.

---

## 6. Soak window expectations

After the flip, the placement entry is in state `SOAK_PENDING_BACKUP`.
**Source data is preserved and the source pod is still running.** This is
the foundation of the soak rollback path.

Cleanup (Step 7.5 — source data deletion) only fires when ALL four
conditions are met:

| Condition | Source | Typical wait |
|---|---|---|
| (a) target pod backup completed | backup CronJob status | 0 – 6 h |
| (b) cross-region S3 replication completed | S3 replication metric | 5 min – 2 h |
| (c) target pod standby refresh completed | standby orchestrator state | 0 – 4 h |
| (d) ≥ 24 h since flip | wall clock | exactly 24 h |

The 24 h floor exists to let any delayed read after the flip surface a
problem **before** we permanently delete source data. If conditions
(a)–(c) take longer than 24 h, soak just extends until they're met —
the floor is a minimum, not a maximum.

**If a condition misses for >48 h, page on-call.** Likely root causes:
backup pipeline broken, S3 replication backlog, standby refresh stuck.

---

## 7. Rollback procedures

Three windows, three procedures.

### 7.1 Pre-flip rollback (during Steps 1–5)

The script has not yet performed the DynamoDB flip. Just kill the script
(Ctrl-C) and clean up:

```
# Reset state to NORMAL — placement was never flipped, but if Step 3
# transitioned to PRE_FLIP_SYNCING, undo it.
aws dynamodb update-item --table-name aegis-statefulset-placement-prod \
  --key '{"tenant_id":{"S":"<tenant-id>"}}' \
  --update-expression "SET #s = :state REMOVE pending_source_pod, flip_at" \
  --expression-attribute-names '{"#s":"state"}' \
  --expression-attribute-values '{":state":{"S":"NORMAL"}}'

# Optional: prune the partial Restic snapshots tagged for this relocation
restic forget --tag relocate=<tenant-id> --prune
```

Source still serves — no client impact.

### 7.2 Post-flip rollback during soak (state = `SOAK_PENDING_*`)

Source data is intact. Routing reverts by writing back the original
primary_pod via DynamoDB, then bulk-flushing Envoy:

```
aws dynamodb update-item --table-name aegis-statefulset-placement-prod \
  --key '{"tenant_id":{"S":"<tenant-id>"}}' \
  --update-expression "SET primary_pod = pending_source_pod, #s = :state REMOVE pending_source_pod, flip_at, cleanup_eligible_at" \
  --expression-attribute-names '{"#s":"state"}' \
  --expression-attribute-values '{":state":{"S":"NORMAL"}}'

./scripts/cache/flush-all.sh --reason "relocation-rollback-<tenant-id>"
```

Writes that landed on the target during soak are NOT automatically
back-synced. If target was active >a few minutes, run a manual Restic
delta back to source before flushing — or accept the data loss and
restore from target's backup post-rollback. Decision lives with
on-call senior.

### 7.3 Post-cleanup rollback (state = `CLEANUP_DONE`)

**Cannot rollback.** Source data has been deleted. The only path is
disaster recovery: restore the tenant from Restic snapshots into a
chosen pod via the standard DR procedure. See `scripts/dr/recover-cluster.sh`
and the relocation-aware DR runbook in `dr-during-relocation.md`.

This is why the cleanup gate is so conservative — once we cross it,
there is no undo button.

---

## 8. Hot tenant detection — relocate vs leave alone

A tenant qualifies as "hot" and warrants relocation when ANY of:

- size ≥ 30 % of one pod's PV
- 7-day growth rate ≥ 500 GB/week
- read or write IOPS ≥ 70 % of the pod's gp3 baseline
- the tenant is responsible for ≥ 50 % of the pod's read/write traffic

If the pod is below 75 % EBS and no single tenant qualifies as hot,
**leave it alone.** Relocation is operationally expensive (delta sync,
soak, cleanup orchestrator load) — don't trigger it for cosmetic
balance.

For tenants approaching "needs dedicated cell" status (≥ 30 % of one
pod alone, or projected to be in 90 days), the target should be an
**empty cell**, not a roomy mid-cell pod. Set the tenant up so that
the next growth cycle does not require another relocation.

---

## 9. Emergency procedure (90 % automation)

When pod EBS hits 90 %, the automation pipeline runs
`per-tenant-relocate.sh` itself, picking:

- **tenant**: the largest tenant on the affected pod
- **target**: the cell with the highest aggregate headroom

The operator role at 90 % is **post-hoc review**, not gating:

1. Receive page; open the dashboard.
2. Verify the automation chose a sensible target (cell health green,
   target pod has headroom, no in-flight relocation already targeting it).
3. If the automation aborted (CAS failure, sync bandwidth issue),
   manually intervene: rerun with explicit operator-chosen target, or
   capacity-expand the cluster if no target has headroom.
4. After flip, confirm soak progresses normally over the next 24 h.

If automation cannot find ANY target with headroom, the cluster is
genuinely full — capacity-expand FIRST (`scripts/capacity/expand-cell.sh`),
THEN relocate. Capacity expansion lands new pods within ~10 minutes;
that's faster than the 90 % alert escalating to actual exhaustion if
the underlying growth rate is not pathological.
