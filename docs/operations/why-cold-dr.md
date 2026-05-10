# Why cold DR over active-passive multi-region

> Architectural reasoning for ADR-04 (cold DR via Velero + EBS snapshot).

The default reflex on a senior architecture review is "active-passive
multi-region" — keep a warm replica in eu-west-1, fail over fast. The
submission deliberately picks cold DR instead. This document explains
why.

---

## 1. LevelDB has zero native sync APIs

LevelDB is a single-writer, file-based, embedded library. There is no
streaming replication, no logical-replication slot, no CDC plug-in, no
binlog. The only export channels are:

1. The on-disk SST files (snapshot copy).
2. The application's own write path (if instrumented).

Active-passive multi-region with a warm replica means we'd be choosing
one of:

- **Periodic SST snapshot copy to the DR region every N minutes.** This
  is structurally identical to what cold DR already does — just with the
  replica running, doing nothing useful, costing money.
- **Application-level replication** (the app writes to two regions
  simultaneously). Requires app changes, contradicts ADR-05 (Strangler
  Fig at the infrastructure layer — application untouched).
- **Block-level EBS replication.** AWS does not offer cross-region EBS
  replication as a managed primitive. Cross-region EBS *snapshot copy*
  is what's available — and that's what we're already doing.

There is no shape of "warm replica" that gives us a meaningfully better
RPO than the snapshot path. The "warm" in "warm-DR" would be cosmetic.

---

## 2. Refresh cycle vs cadence collision

Active-passive multi-region means "the standby is as fresh as cadence
allows." With 5-minute cadence, the standby is ≤5 minutes stale. With
1-hour cadence, ≤1 hour stale.

But cold DR is *also* "as fresh as cadence allows" — by definition,
because the cadence is the same lever in both cases. The difference
is RTO, not RPO:

| Posture | RPO | RTO | Cost |
|---|---|---|---|
| Cold DR (cadence = 5 min)        | ≤5 min | ~50 min | $X |
| Active-passive (cadence = 5 min) | ≤5 min | ~10 min | $X + $1,500/mo |

The improvement is ~40 minutes of RTO. The cost is roughly +$1,500/month
for warm replicas (DR-region nodes running, EBS pre-attached, control
plane fees).

The spec gives RPO ≤6 hours explicitly and is silent on RTO. The
architecture's chosen RTO target (~25 min AZ failure / ~50 min region)
is our design judgment — defensible as Mittelstand-grade for a SaaS
where downstream customers run their own businesses on top, but not a
spec-derivable number. **Stage 3 conversation should establish the
customer's actual operational tolerance before this trade-off
crystallises.** At our chosen target, cold DR meets the budget;
spending $18K/year for the 40-minute RTO improvement is wasted unless
the customer's actual RTO tolerance is sub-15-min, in which case the
trade-off shape changes and the conversation moves to "which storage
primitive supports hot DR" — not "Velero or active-passive on top of
LevelDB."

---

## 3. Restic doesn't support incremental apply

If we wanted to keep a warm DR replica genuinely warm (i.e., 5-minute
fresh, no big restore at cutover), we'd need to apply each new snapshot
incrementally to the replica. Restic's restore is "restore a snapshot,"
not "apply diff between snapshots N and N+1." The replica would have to
either:

1. Re-restore the full 2 TB EBS every 5 minutes (impossible in 5 min).
2. Apply via filesystem-level diff (rsync), which loses Restic's
   point-in-time integrity guarantees.
3. Replay an application-level write stream (which doesn't exist —
   see § 1).

None of these is acceptable. The math forces "cold DR with cadence" or
"hot with cluster-aware DB-replication primitives" — and LevelDB
doesn't offer the latter.

---

## 4. EBS detach-recreate-attach dance complexity

Even if we wanted to do hot-DR by detaching EBS in primary and
re-attaching in DR, the dance is:

1. Quiesce the writer (single-writer requirement).
2. Snapshot.
3. Cross-region copy snapshot (~5-15 min for 2 TB).
4. Recreate EBS in DR region.
5. Detach from primary.
6. Re-attach in DR region.
7. Restart pod with PV pointing at new EBS.

Steps 3 and 7 dominate the timeline; the architecture cannot reduce
them. So you end up with a "hot" replica that is, on every cycle,
spending most of its time in the cold-DR critical path.

The cleanest design is to skip the pretence: cold DR with cross-region
snapshot replication, recover when needed.

---

## 5. RTO improvement vs cost increase trade-off

| Lever | Cost delta | RTO impact |
|---|---|---|
| Active-passive multi-region (warm replica) | +$1,500/mo | RTO 50 min → 10 min |
| Cold DR with hot pre-warmed cluster (controllers up, no app pods) | +$200/mo | RTO 50 min → 30 min |
| Cold DR with terraform helm_release for controllers (current Layer 2) | +$0/mo  | baseline 50 min |

The middle row is what ADR-04 actually delivers as Layer 2 — controllers
warm via Terraform `helm_release`, which is "free" because it's just IaC
applied once, not a continuously-running replica. The "warm replica"
upgrade buys 20 minutes more of RTO at $200/mo, which is a defensible
spend for some SLAs but not the default.

The "active-passive multi-region" upgrade buys 40 minutes more at
$1,500/mo. Against the architecture's chosen ~25 min AZ-failure target
(spec is silent on RTO; the target is a design judgment, not a customer
mandate), this is unfavourable. If the customer's actual operational
tolerance demands sub-15-min recovery the trade-off shape changes.

---

## 6. Cold DR is self-consistent with 5-min cadence + manual DR posture

The architecture's self-consistency check:

- Cadence is 5 min (typical, configurable to 1 min).
- DR is a *declared* event — operator opens the runbook, not a robot.
- Manual DR + 5-min cadence + cold target = recovery in ~50 min, RPO ≤5 min.

This is the trade-off the operator is choosing when they pick cold DR.
It's an honest contract. Active-passive multi-region pretends to give
"5-second RTO" but, in reality, gives "5-second RTO if you trust your
auto-failover triggers, 50-min RTO if you don't and the human is on
holiday." The cold-DR design has a single mode and a single number.

---

## When *would* we revisit?

ADR-04 isn't sealed. The triggers to switch from cold DR to
active-passive multi-region:

1. **Customer SLA tightens to sub-30-minute RTO.** At that point the
   $1,500/mo is forced.
2. **The application gains replication primitives.** If the team
   replaces LevelDB with a DB that has built-in multi-region replication
   (CockroachDB, FoundationDB, Aurora Global), the architecture
   collapses to "follow the database's recommended topology" and the
   cold-DR rationale evaporates.
3. **WAL shipping is added** (per `SUBMISSION.md` § 9 item #1). Sub-5-
   min RPO would justify the warm-replica spend.

Until one of those triggers fires, cold DR is the correct posture for
this workload at this budget.

---

## Cross-reference

- ADR-04 — Cold DR via Velero + EBS snapshot
- ADR-04 — Three-Layer DR
- ADR-04 — Three-path recovery
- ADR-04 — Active-passive periodic refresh (intra-region)
- `docs/operations/region-failure-recovery.md` — runbook
- `scripts/dr/region-failure-recovery.sh` — automation
