# ADR-05: Migration — Strangler Fig at the infrastructure layer

## Status
Accepted (POC submission scope)

## Decision

1. **Migrate per-tenant from legacy to the K8s cluster one cell at a time.** The application container is preserved unchanged.
2. **Cutover unit = one cell.** Each cell migration runs: provision empty cell → copy snapshot → reconcile → traffic flip via placement table → soak window → cleanup gate.
3. **Routing identity per-tenant in the placement table is the cutover lever** (ADR-03). Cutover = update one row's `pod` field. Rollback = revert that row.
4. **No app-layer changes.** The customer's application doesn't know it's being migrated.

## Why

- **Application should not need to know it's being migrated.** Strangler Fig at the infrastructure layer is the right shape for stateful workloads: routing changes, state lifts, container untouched.
- **Cell-by-cell limits blast radius.** One revertible cutover at a time; failure of one cell migration doesn't pause the others.
- **Placement table is the natural cutover lever.** It already exists for routing; reusing it for migration adds zero new machinery.
- **Snapshot copy + reconcile is the only LevelDB-safe transport.** LevelDB has no native sync; migration is freeze + snapshot + restore + verify + flip + soak-window delta-replay.

## Trade-offs accepted

- **Migration is not invisible to operators.** Each cell cutover requires a maintenance window (at minimum the snapshot freeze duration) and a watchful operator during soak. The customer pays in operator hours, not customer-facing downtime.
- **Pattern 2 LDB layout makes per-tenant relocation cheap** (rsync the folder). **Pattern 1 requires a key-extract tool and is materially more expensive** (~1 month of tooling work to do correctly). Choice impacts migration timeline.
- **Soak window is operator judgment.** Too short → miss a delta; too long → locks the cell as source-of-truth past the cutover. Default 24 h soak with explicit cleanup gate.

## Out of POC scope (upgrade triggers)

- **Online migration without snapshot freeze.** Trigger: customer SLA forbids the freeze duration; reach for WAL shipping or LevelDB → distributed K-V replacement.
- **Auto-orchestrated cell migration (operator-free).** Trigger: > 2 migrations per quarter, runbook hardened.

## Stage 3 questions

- LDB layout (Pattern 1 vs 2) determines per-tenant relocation tooling cost.
- Acceptable freeze duration during cell cutover (5 min, 30 min, 1 h)?
- Existing tenant→cluster mapping storage in legacy — source of truth for "where does tenant T currently live".

## Cross-references

- *(originally private ADR-016; refined 2026-05-09)*
- ADR-01 — cell-based capacity unit; per-tenant pod identity
- ADR-03 — placement table is the cutover lever
- ADR-04 — snapshot + restore primitives reused from DR pipeline
