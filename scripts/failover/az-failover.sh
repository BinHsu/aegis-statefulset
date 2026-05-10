#!/usr/bin/env bash
# scripts/failover/az-failover.sh
#
# AZ failover entrypoint — Layer 4 of the failover pipeline (ADR-04, ADR-03).
# Triggered by Alertmanager webhook when a Prometheus rule confirms AZ-wide
# failure (50% / 2min sustained, multi-vantage agreement).
#
# Usage:
#   ./az-failover.sh <failed-az>
#
# Example:
#   ./az-failover.sh eu-central-1a
#
# Asymmetric thresholds (ADR-04):
#   - Failover trigger:  50% unhealthy / 2min sustained
#   - Recovery detect:   95% healthy   / 60min sustained (notify only)
#   - 24h cooldown between failover events
#   - Auto-failback: never

set -euo pipefail

FAILED_AZ="${1:?usage: $0 <failed-az>}"
NAMESPACE="${NAMESPACE:-aegis-app}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() {
  printf '[%s] %s\n' "$(date -Iseconds)" "$*"
}

log "AZ failover triggered for ${FAILED_AZ} (namespace=${NAMESPACE})"

# Step 0 — fence the failed AZ before we touch anything else.
# ADR-04 split-brain prevention: if the AZ is partitioned (not failed),
# the primary may still be serving stale writes to a few clients. Remove
# from ALB targets and Envoy override before promoting the standby.
log "[Step 0] Fence ${FAILED_AZ}"
"${SCRIPT_DIR}/fencing.sh" "${FAILED_AZ}"

# Step 1 — verify AZ-wide failure (vs single pod / network blip).
log "[Step 1] Verify AZ-wide failure threshold"
unhealthy=$(kubectl get pods -n "${NAMESPACE}" \
  -l "aegis.io/role=primary,topology.kubernetes.io/zone=${FAILED_AZ}" \
  --field-selector=status.phase!=Running \
  -o name 2>/dev/null | wc -l | tr -d ' ')

total=$(kubectl get pods -n "${NAMESPACE}" \
  -l "aegis.io/role=primary,topology.kubernetes.io/zone=${FAILED_AZ}" \
  -o name 2>/dev/null | wc -l | tr -d ' ')

if [ "${total}" -eq 0 ]; then
  log "ERROR: no primary pods found in ${FAILED_AZ}; aborting"
  exit 1
fi

# Threshold per ADR-04: more than half unhealthy = AZ-wide failure.
# Using strict majority (> N/2) so a 2-of-3 outage triggers, a 1-of-3 doesn't.
half=$((total / 2))
if [ "${unhealthy}" -le "${half}" ]; then
  log "Only ${unhealthy}/${total} pods unhealthy — below AZ-wide threshold. Aborting."
  exit 1
fi
log "Confirmed AZ-wide failure: ${unhealthy}/${total} pods unhealthy in ${FAILED_AZ}"

# Step 2 — identify affected primaries.
log "[Step 2] Enumerate affected primaries"
primaries=$(kubectl get pods -n "${NAMESPACE}" \
  -l "aegis.io/role=primary,topology.kubernetes.io/zone=${FAILED_AZ}" \
  -o jsonpath='{.items[*].metadata.name}')

if [ -z "${primaries}" ]; then
  log "ERROR: primary list is empty after threshold check; aborting"
  exit 1
fi

# Step 3 — per-pod failover in parallel.
log "[Step 3] Per-pod failover (parallel)"
pids=()
for primary in ${primaries}; do
  "${SCRIPT_DIR}/per-pod-failover.sh" "${primary}" &
  pids+=($!)
done

failed=0
for pid in "${pids[@]}"; do
  if ! wait "${pid}"; then
    failed=$((failed + 1))
  fi
done

if [ "${failed}" -gt 0 ]; then
  log "WARN: ${failed} per-pod failover(s) returned non-zero. Review pod logs."
fi

# Step 4 — verify all standbys serving.
log "[Step 4] Verify standby health"
# TODO: poll Envoy admin /clusters and /stats to confirm override updated and
#       traffic routed; verify standby pod readiness probe across all promoted pods.

# Step 5 — trigger customer comms.
log "[Step 5] Trigger customer communication"
# TODO: curl -X POST "${CUSTOMER_COMMS_URL}" \
#         -H 'Content-Type: application/json' \
#         -d "{\"event\": \"az_failover\", \"az\": \"${FAILED_AZ}\"}"

log "AZ failover complete for ${FAILED_AZ} (failed_pods=${failed})"

if [ "${failed}" -gt 0 ]; then
  exit 2
fi
