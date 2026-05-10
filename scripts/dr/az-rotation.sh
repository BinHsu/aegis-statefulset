#!/usr/bin/env bash
# scripts/dr/az-rotation.sh
#
# Rotate the master AZ for the stateful + stateless tiers without a
# Terraform apply (ADR-04, ADR-04). Used for both:
#   - Phase 1 chaos demo: scripted recovery after subnet delete in source AZ
#   - Production AZ-failure runbook
#
# Approach:
#   1. Scale up the standby node group in the target AZ.
#   2. Scale up the stateless tier in the target AZ.
#   3. Wait for nodes to be Ready in the target AZ.
#   4. Velero restore from the latest cross-region backup, restoring volumes
#      so the StatefulSet's PVCs come back with the data on them.
#   5. Scale the failed (source) AZ node group to zero so capacity does
#      not drift back when the AZ is repaired.
#
# This script intentionally does NOT touch Terraform — node groups in
# every AZ exist already with desiredSize=0. AZ rotation is a runtime
# scaling decision, not a topology change. (ADR-01 modified.)
#
# Required environment:
#   CLUSTER_NAME    EKS cluster name (e.g. aegis-statefulset-prod)
#   SOURCE_AZ       AZ that failed (e.g. eu-central-1a)
#   TARGET_AZ       AZ to promote to master (e.g. eu-central-1b)
#
# Optional environment:
#   STATEFUL_POOL_SIZE   default 1  (cells.per_az * replicas_per_cell)
#   STATELESS_POOL_SIZE  default 3  (API + Envoy + headroom)
#   READINESS_TIMEOUT    default 1800 (seconds; 30 min)

set -euo pipefail

CLUSTER="${CLUSTER_NAME:?CLUSTER_NAME env var required}"
SOURCE_AZ="${SOURCE_AZ:?SOURCE_AZ env var required (failed AZ)}"
TARGET_AZ="${TARGET_AZ:?TARGET_AZ env var required (new master AZ)}"
STATEFUL_POOL_SIZE="${STATEFUL_POOL_SIZE:-1}"
STATELESS_POOL_SIZE="${STATELESS_POOL_SIZE:-3}"
READINESS_TIMEOUT="${READINESS_TIMEOUT:-1800}"

log() {
  printf '[%s] [az-rotation] %s\n' "$(date -Iseconds)" "$*"
}

log "AZ rotation: ${SOURCE_AZ} -> ${TARGET_AZ} (cluster=${CLUSTER})"

# Step 1 — Scale up stateful node group in the target AZ.
log "[1/5] Scaling up stateful node group in ${TARGET_AZ} (size=${STATEFUL_POOL_SIZE})"
aws eks update-nodegroup-config \
  --cluster-name "${CLUSTER}" \
  --nodegroup-name "stateful-standby-${TARGET_AZ}" \
  --scaling-config "desiredSize=${STATEFUL_POOL_SIZE}"

# Step 2 — Scale up stateless tier in the target AZ.
log "[2/5] Scaling up stateless node group in ${TARGET_AZ} (size=${STATELESS_POOL_SIZE})"
aws eks update-nodegroup-config \
  --cluster-name "${CLUSTER}" \
  --nodegroup-name "stateless-standby-${TARGET_AZ}" \
  --scaling-config "desiredSize=${STATELESS_POOL_SIZE}"

# Step 3 — Wait for at least one node Ready in the target AZ.
log "[3/5] Waiting for nodes Ready in ${TARGET_AZ} (timeout ${READINESS_TIMEOUT}s)"
elapsed=0
while [ "${elapsed}" -lt "${READINESS_TIMEOUT}" ]; do
  ready=$(kubectl get nodes -l "topology.kubernetes.io/zone=${TARGET_AZ}" \
            --no-headers 2>/dev/null \
          | awk '$2 == "Ready" {n++} END {print n+0}')
  if [ "${ready}" -ge 1 ]; then
    log "  ${ready} node(s) Ready in ${TARGET_AZ}"
    break
  fi
  log "  ${ready} node(s) Ready; waiting (elapsed ${elapsed}s)"
  sleep 30
  elapsed=$((elapsed + 30))
done

if [ "${elapsed}" -ge "${READINESS_TIMEOUT}" ]; then
  log "ERROR: target AZ nodes did not become Ready within ${READINESS_TIMEOUT}s"
  exit 1
fi

# Step 4 — Velero restore from the latest backup, with volumes.
log "[4/5] Velero restore from latest backup"
LATEST=$(velero backup get -o name 2>/dev/null | head -n1)
if [ -z "${LATEST}" ]; then
  log "ERROR: no Velero backups found"
  exit 1
fi
log "  source backup: ${LATEST}"

velero restore create "az-rotation-$(date +%s)" \
  --from-backup "${LATEST}" \
  --restore-volumes=true \
  --include-namespaces aegis-app,api-tier,envoy \
  --wait

# Step 5 — Scale the failed (source) AZ node group to zero so capacity
# does not drift back if/when the AZ is repaired before we rebalance.
log "[5/5] Scaling source AZ ${SOURCE_AZ} stateful node group to zero"
aws eks update-nodegroup-config \
  --cluster-name "${CLUSTER}" \
  --nodegroup-name "stateful-standby-${SOURCE_AZ}" \
  --scaling-config "desiredSize=0"

echo
log "AZ rotation complete: ${TARGET_AZ} is now master"
log "Verify by querying API:"
log "  curl https://api.aegis.example.com/data?key=T1"
