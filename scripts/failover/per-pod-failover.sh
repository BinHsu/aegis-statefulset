#!/usr/bin/env bash
# scripts/failover/per-pod-failover.sh
#
# Per-primary failover sub-script. Promotes the matching standby for a
# single primary pod (ADR-04 step body).
#
# Usage:
#   ./per-pod-failover.sh <primary-pod-name>
#
# Sequence per ADR-04:
#   1. Pull latest backup if newer than standby's data
#   2. Scale standby pod from 0 -> 1
#   3. Wait for LevelDB warm-up (5-15 min)
#   4. Update Envoy override (primary -> standby)
#   5. Verify health
#
# Exits non-zero if any step fails so the caller (az-failover.sh) can
# count failed pods and surface a partial-failure exit code.

set -euo pipefail

PRIMARY="${1:?usage: $0 <primary-pod-name>}"
NAMESPACE="${NAMESPACE:-aegis-app}"

# Convention from helm/aegis-statefulset: standby StatefulSet has the same
# ordinal as the primary, prefix differs. Adjust if the chart uses a
# different naming scheme.
STANDBY="${PRIMARY//primary/standby}"

# Warm-up budget — primary range from ADR-04 is 5-15 min. We poll up to 20.
WARMUP_TIMEOUT_SECONDS="${WARMUP_TIMEOUT_SECONDS:-1200}"
WARMUP_POLL_INTERVAL_SECONDS="${WARMUP_POLL_INTERVAL_SECONDS:-15}"

log() {
  printf '[%s] [%s] %s\n' "$(date -Iseconds)" "${PRIMARY}" "$*"
}

log "Per-pod failover start (standby=${STANDBY})"

# Step 1 — pull latest backup if newer than standby's data.
# The standby refresh CronJob runs on cadence; on failover we opportunistically
# pull a fresher backup if one landed in S3 since the last refresh.
log "[1/5] Pull latest backup if newer than standby's data"
# TODO: kubectl exec -n "${NAMESPACE}" "${STANDBY}-restore-pod" -- \
#         /scripts/refresh-from-latest.sh
#       The restore pod is a transient sidecar that mounts the standby EBS;
#       see helm/aegis-statefulset/templates/standby-refresh-cronjob.yaml.

# Step 2 — scale standby pod 0 -> 1.
log "[2/5] Scale standby pod 0 -> 1"
# Standby StatefulSet pods are scaled to 0 by default (ADR-04). Use
# kubectl scale with --replicas equal to the standby's ordinal+1 if the
# standby chart uses one StatefulSet per AZ; otherwise, use a per-pod
# annotation or a dedicated scale subresource.
# TODO: kubectl scale statefulset -n "${NAMESPACE}" "${STANDBY%-*}" \
#         --replicas="<ordinal+1>"

# Step 3 — wait for LevelDB warm-up.
log "[3/5] Wait for LevelDB warm-up (timeout ${WARMUP_TIMEOUT_SECONDS}s)"
elapsed=0
while [ "${elapsed}" -lt "${WARMUP_TIMEOUT_SECONDS}" ]; do
  if kubectl get pod -n "${NAMESPACE}" "${STANDBY}" \
       -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null \
       | grep -q true; then
    log "Standby ${STANDBY} is ready (warm-up ${elapsed}s)"
    break
  fi
  sleep "${WARMUP_POLL_INTERVAL_SECONDS}"
  elapsed=$((elapsed + WARMUP_POLL_INTERVAL_SECONDS))
done

if [ "${elapsed}" -ge "${WARMUP_TIMEOUT_SECONDS}" ]; then
  log "ERROR: standby ${STANDBY} did not become ready within ${WARMUP_TIMEOUT_SECONDS}s"
  exit 1
fi

# Step 4 — update Envoy override (primary -> standby).
log "[4/5] Update Envoy override ${PRIMARY} -> ${STANDBY}"
# TODO: kubectl patch configmap -n "${NAMESPACE}" routing-override \
#         --type merge \
#         -p "$(jq -n --arg p "${PRIMARY}" --arg s "${STANDBY}" \
#               '{data: {($p): $s}}')"
#       Envoy reloads the ConfigMap via xDS within seconds.

# Step 5 — verify health: standby is in Envoy's healthy upstream set.
log "[5/5] Verify standby is in Envoy's healthy upstream set"
# TODO: kubectl exec -n "${NAMESPACE}" deployment/envoy-ingress -- \
#         curl -s localhost:9901/clusters \
#         | grep -q "${STANDBY}.*health_flags::healthy"

log "Per-pod failover complete"
