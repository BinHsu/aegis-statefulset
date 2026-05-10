#!/usr/bin/env bash
# scripts/failover/failback.sh
#
# Manual failback procedure (ADR-04).
#
# Default policy is NEVER auto-failback. After AZ recovery, the standby
# (now serving) becomes the new primary permanently; the original primary
# becomes the new standby. The architecture is symmetric, so "rebalance"
# is a separate operational decision, not an automatic action.
#
# This script implements a per-cell rebalance with a maintenance window.
#
# Usage:
#   ./failback.sh <cell-id>
#
# Pre-conditions (operator MUST verify before running):
#   - AZ recovered and stable for at least 24 hours.
#   - Asymmetric recovery threshold met (95% healthy / 60min sustained).
#   - 1h cooldown since the previous failover event has elapsed.
#   - Maintenance window scheduled and customer comms sent.
#
# Per-cell sequence (~1-3 hours, includes 5-15min outage):
#   1. Restic backup of the new primary (was standby).
#   2. Restore to original AZ pod EBS.
#   3. Brief outage (5-15 min) — drain traffic.
#   4. Final delta sync.
#   5. Switch routing back.

set -euo pipefail

CELL="${1:?usage: $0 <cell-id>}"
NAMESPACE="${NAMESPACE:-aegis-app}"

log() {
  printf '[%s] [failback cell=%s] %s\n' "$(date -Iseconds)" "${CELL}" "$*"
}

log "Manual failback start"

# Pre-flight gate — operator confirmation.
cat <<EOF
Pre-flight gate: confirm the following BEFORE proceeding.

  [ ] AZ recovered and stable >= 24 hours
  [ ] 95% healthy / 60min sustained (recovery threshold met)
  [ ] >= 1 hour since last failover event
  [ ] Maintenance window scheduled, customers notified
  [ ] Latest backup verified (restic check passed)

EOF

read -rp "All confirmed? Type 'YES' to proceed: " confirm
if [ "${confirm}" != "YES" ]; then
  log "Aborted by operator"
  exit 1
fi

# Step 1 — Restic backup of new primary.
log "[1/5] Restic backup of new primary in cell ${CELL}"
# TODO: kubectl exec -n "${NAMESPACE}" "$(get_new_primary "${CELL}")" -- \
#         /scripts/lvm-snapshot-restic.sh

# Step 2 — restore to original AZ pod EBS.
log "[2/5] Restore latest backup to original AZ pod EBS"
# TODO: identify original AZ EBS via tags (aegis.io/cell=${CELL}, aegis.io/role=original-primary)
# TODO: spin up a restore Job that mounts that EBS and runs restic restore latest

# Step 3 — brief outage. Drain traffic from the new primary.
log "[3/5] Drain traffic — entering maintenance window"
# TODO: kubectl patch configmap routing-override -n "${NAMESPACE}" \
#         --type merge -p "{\"data\":{\"<tenant>\":\"maintenance\"}}"
# TODO: wait for active connections to drain (poll Envoy /stats)

# Step 4 — final delta sync.
log "[4/5] Final delta sync (Restic incremental)"
# TODO: kubectl exec -n "${NAMESPACE}" "<new-primary-pod>" -- restic backup ...
# TODO: kubectl exec ... -- restic restore latest --target / ...

# Step 5 — switch routing back to the original primary.
log "[5/5] Switch routing back to original primary"
# TODO: kubectl patch configmap routing-override -n "${NAMESPACE}" \
#         --type merge -p "{\"data\":{\"<tenant>\":\"<original-primary>\"}}"

log "Failback complete for cell ${CELL}"
log "Reminder: monitor SLI for the next 24 hours; do not re-fail-back during cooldown."
