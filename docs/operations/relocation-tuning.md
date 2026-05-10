# Relocation Threshold Tuning

Cost-vs-precision tuning guide for the relocation triggers and the
cache invalidation TTL. Read this when you want to change one of:

- the 75 % PR threshold
- the 90 % emergency threshold
- the +500 GB / 7-day growth-rate threshold
- the Envoy routing cache TTL
- the delta-sync cutoff (`DELTA_THRESHOLD_MB`)

The defaults in this repo are tuned for "Mittelstand-scale B2B SaaS
with predictable workload, daily ops review, ~24 h onboarding rhythm."
If your operating shape is different, the right defaults probably are
too.

---

## 1. Why these thresholds matter

Two failure modes pull in opposite directions:

- **Too aggressive** (low thresholds, fast triggers) → ops thrash.
  Relocation is operationally non-trivial: delta sync runs Restic for
  minutes, soak ties up two pods worth of capacity for 24 h, the
  cleanup orchestrator does work. Triggering it on noise produces a
  team that's always running relocations and never building.

- **Too lazy** (high thresholds, slow triggers) → overflow risk.
  EBS gp3 grows in seconds via `ModifyVolume`, but pod-level CPU /
  memory ceilings don't, and aggregate cluster pressure can outpace
  capacity expansion's 10-15 minute provisioning cycle.

The defaults sit deliberately on the conservative side of "lazy" —
75 % PR with daily review catches problems before they're emergencies,
and the 90 % emergency tier is the safety net, not the primary
mechanism.

---

## 2. The cost-vs-precision curve

Approximate operational cost vs miss-rate at different threshold
settings. Numbers are illustrative; calibrate against your own
workload.

| Profile | PR thresh | Emergency thresh | 7d growth thresh | Relocations/month | Overflow incidents/yr |
|---|---|---|---|---|---|
| Aggressive | 60 % | 80 % | 200 GB | 8-12 | < 0.1 |
| **Default** | **75 %** | **90 %** | **500 GB** | **2-4** | **~ 1** |
| Lazy | 85 % | 95 % | 1 TB | 0-1 | 3-5 |
| Very lazy | 90 % | 97 % | n/a | 0 | 8-10 |

The "Aggressive" row is rarely worth it for steady workloads — you pay
for ops capacity to handle 2-3× the relocations in exchange for one
fewer incident every other year. Make it pay only when an incident is
expensive (regulated SLA, paid SLA tier, customer-visible degradation).

The "Very lazy" row is what you fall into accidentally when you stop
maintaining the alerting rules. Don't.

---

## 3. Default rationale (75 / 90 / +500 GB / 7d)

- **75 % PR**: gives ~7-14 days of organic growth headroom on a
  typical pod before the next tier fires. Long enough for a code
  review, a CAB ticket, and an off-hours change window.
- **90 % emergency**: leaves ~2-5 days of organic growth buffer
  before a real exhaustion event. Short enough that automation must
  act without operator gating.
- **+500 GB / 7 days**: catches sustained growth, not a one-day load
  test or migration. A single big-import that adds 600 GB and then
  goes flat does not trigger this. A tenant in genuine product
  growth at 80-100 GB/day does.

The 24 h soak floor is independent: it's there because we've seen
delayed-read access patterns surface inconsistencies hours after a
flip, and we want a window to roll back **before** source data is
deleted.

---

## 4. When to tighten thresholds

- **High-growth platform** (onboarding accelerating month-over-month,
  workload mix shifting): tighten PR to 70 %, emergency to 85 %, and
  cap the 7-day growth threshold at 300 GB. Trade ops volume for
  surface area against unknown growth shape.
- **Customer SLO sensitive** (paid SLA, contractual uptime > 99.95 %):
  tighten emergency to 85 % and add a synthetic prober that fires at
  any pod ≥ 80 % regardless of trend. Cost is operational, but your
  SLO budget cannot absorb an exhaustion event.
- **Regulated workload** (audit on cluster state, change windows
  pre-approved weekly): tighten PR threshold; emergency tier should
  rarely fire because PR cycle catches everything.

---

## 5. When to loosen thresholds

- **Stable workload, no organic growth**: existing tenants flat,
  onboarding rate predictable. Thresholds at 75 / 90 will fire
  rarely; you can move PR to 80 % and stop monitoring the 7d trend
  at all. The risk you absorb is "an unexpected 2× growth burst on
  one tenant," which a stable workload by definition doesn't have.
- **Ops budget constrained**: small SRE rotation, no off-hours
  on-call, capacity expansion is cheap because you provision in 50 %
  increments. PR at 80 % and emergency at 95 % saves operator time
  at the cost of more capacity-expansion events. Acceptable when
  capacity is genuinely cheap.
- **Cluster lifetime < 1 year** (e.g., greenfield trial deployment):
  long-tail emergency triggers may never fire before you tear down.
  Don't over-engineer alerting for a workload that won't live long
  enough to exercise it.

---

## 6. Telemetry source trade-offs

The placement service reads pod-level usage from one of three sources:

| Source | Latency | Accuracy | Operational cost |
|---|---|---|---|
| Sidecar-emitted CloudWatch metric | ~60 sec | high (local volume read) | small (one container per pod) |
| Application-emitted Prometheus metric | ~15 sec | medium (only counts what app instruments) | already deployed |
| Pod-level kubelet `stats/summary` | ~30 sec | medium (filesystem-level, captures app + WAL + temp) | free |

Default is **sidecar + Prometheus dual-source**. Sidecar is the source
of truth for the threshold check; Prometheus is the source for the
growth-rate trend (lower noise over a 7d window).

Switching to kubelet-only (free, no instrumentation work) costs you
~15 % accuracy on the threshold — kubelet stats include filesystem-level
overhead that doesn't contribute to tenant data growth, so 75 % kubelet
≈ 78 % real. Acceptable if you tighten the threshold to compensate.

---

## 7. Cache TTL — fresher data costs more

Envoy's routing cache TTL is the default freshness vs DynamoDB load
tradeoff:

| TTL | Stale window after a flip without sync-invalidate | DynamoDB read RPS |
|---|---|---|
| 5 min (default) | ≤ 5 min | low |
| 1 min | ≤ 1 min | 5× |
| 30 sec | ≤ 30 sec | 10× |
| 0 (no cache) | ≤ 0 (never stale) | 100× — unsustainable |

The sync-invalidate path during relocation Step 6.3 makes the TTL
mostly irrelevant for **planned** flips — caches are flushed at the
right moment, so the TTL is just a ceiling on staleness in case
sync-invalidate fails partially. The bulk-flush fallback (Step 6.5)
covers that case explicitly.

Where TTL still matters:

- **Async streams-based invalidation** (Lambda-driven) — runs in
  parallel with sync-invalidate but with seconds-to-minutes lag.
  Lower TTL bounds staleness here as well, but since sync already
  fired, this is belt-and-braces.
- **Cluster reboots** — caches start cold. Lower TTL doesn't matter
  on cold start; first request always hits DynamoDB.

Keep the default 5 min unless you have a specific reason. The
sync-invalidate + bulk-flush combo is what actually keeps caches
honest; TTL is the safety net.

---

## 8. Delta-sync cutoff (`DELTA_THRESHOLD_MB`)

Default is 10 MB. The trade-off:

- Lower (5 MB): tighter pre-flip convergence, smaller post-flip
  catch-up sync. Costs more iterations of the sync loop, may not
  converge under sustained heavy write load.
- Higher (50 MB): faster pre-flip convergence, larger post-flip
  catch-up window. Risk: clients see stale reads for the duration
  of the post-flip catch-up sync (couple of seconds).

For tenants under steady write load, 10 MB is fine. For tenants doing
bulk imports during the relocation, raise to 100 MB or wait for the
import to finish — relocation during a bulk import is fighting the
write rate.
