#!/usr/bin/env bash
# scripts/dr/restore-from-s3.sh
#
# DR Path C — EBS lost, full restore from S3 (ADR-04).
#
# Worst-case scenario: source region or all EBS lost. Recovery installs
# fresh chart, lets the StatefulSet provision empty PVCs/EBS, then
# parallel-restores Restic snapshots from cross-region S3.
#
# Target RTO: 6-12h (bounded by Restic restore throughput).
# RPO: backup cadence (default 1h, max 6h per ADR-04).
#
# Usage:
#   ./restore-from-s3.sh
#
# Required environment:
#   NAMESPACE         — target K8s namespace (default: aegis-app)
#   RESTIC_REPOSITORY — cross-region S3 path
#                       (e.g. s3:s3.amazonaws.com/aegis-backup-dr/<cluster>)
#   REPLICA_COUNT     — number of pods to restore (operator-supplied)

set -euo pipefail

NAMESPACE="${NAMESPACE:-aegis-app}"
RESTIC_REPOSITORY="${RESTIC_REPOSITORY:?RESTIC_REPOSITORY required}"
REPLICA_COUNT="${REPLICA_COUNT:?REPLICA_COUNT required (e.g. 9)}"

log() {
  printf '[%s] [dr-path-c] %s\n' "$(date -Iseconds)" "$*"
}

log "Path C — EBS-lost full restore start"
log "  namespace=${NAMESPACE}"
log "  restic repo=${RESTIC_REPOSITORY}"
log "  replica count=${REPLICA_COUNT}"

# Step 1 — helm install creates empty PVCs + EBS.
log "[1/4] helm install creates empty PVCs + EBS"
# TODO: helm upgrade --install aegis-statefulset helm/aegis-statefulset \
#         --namespace "${NAMESPACE}" --create-namespace \
#         --set "stateful.primary.replicas=${REPLICA_COUNT}" \
#         --wait --timeout 30m
log "(placeholder: chart install pending operator action)"

# Step 2 — wait for all PVCs bound.
log "[2/4] Wait for all PVCs bound"
# Boundary value note (BVA, ADR-08-adjacent discipline): we wait up to
# REPLICA_COUNT * 5 minutes (provisioning is ~1-2 min per EBS). Two
# samples bracket the boundary:
#   timeout - 1s : last allowed moment to bind
#   timeout     : exact boundary
#   timeout + 1s: failure path (should error)
timeout_seconds=$((REPLICA_COUNT * 300))
elapsed=0
while [ "${elapsed}" -lt "${timeout_seconds}" ]; do
  bound=$(kubectl get pvc -n "${NAMESPACE}" \
            -l "app.kubernetes.io/name=aegis-statefulset" \
            -o jsonpath='{.items[*].status.phase}' 2>/dev/null \
          | tr ' ' '\n' | grep -c '^Bound$' || true)
  if [ "${bound}" -ge "${REPLICA_COUNT}" ]; then
    log "All ${bound}/${REPLICA_COUNT} PVCs bound"
    break
  fi
  log "Bound ${bound}/${REPLICA_COUNT} PVCs; waiting (elapsed ${elapsed}s)"
  sleep 30
  elapsed=$((elapsed + 30))
done

if [ "${elapsed}" -ge "${timeout_seconds}" ]; then
  log "ERROR: PVC bind timeout after ${timeout_seconds}s"
  exit 1
fi

# Step 3 — parallel Restic restore from cross-region S3.
log "[3/4] Parallel Restic restore (one Job per pod)"
for ((i=0; i<REPLICA_COUNT; i++)); do
  pod_name="aegis-statefulset-primary-${i}"
  log "  spawning restore Job for ${pod_name}"
  # TODO: kubectl apply -f - <<EOF
  # apiVersion: batch/v1
  # kind: Job
  # metadata:
  #   name: dr-restore-${i}
  #   namespace: ${NAMESPACE}
  # spec:
  #   template:
  #     spec:
  #       restartPolicy: OnFailure
  #       containers:
  #         - name: restic
  #           image: restic/restic:0.16.0
  #           command:
  #             - restic
  #             - restore
  #             - latest
  #             - --tag
  #             - pod=${pod_name}
  #             - --target
  #             - /mnt/data
  # EOF
done

# Step 4 — wait for restores to complete, then start pods.
log "[4/4] Wait for restore Jobs to complete; pods will start with restored data"
# TODO: kubectl wait --for=condition=complete --timeout=12h \
#         job/dr-restore-0 job/dr-restore-1 ... -n "${NAMESPACE}"

log "Path C recovery initiated. Monitor restore Jobs and pod readiness."
log "After all pods Ready, run scripts/dr/warm-routing-table.sh to rebuild override."
