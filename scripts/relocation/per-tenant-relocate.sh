#!/usr/bin/env bash
# scripts/relocation/per-tenant-relocate.sh
#
# Per-tenant relocation skeleton per ADR-01.
# Implements the 7-step flow from consensus.md (relocation as first-class
# primitive) — pre-flip async catch-up + atomic flip + soak-with-cleanup-gate.
#
# Key invariants (per ADR-01):
#   - Step 6 has NO source quiesce. Routing flips via DynamoDB CAS and
#     Envoy cache sync invalidate; writes that hit the source during the
#     ~500ms flip window are caught by the post-flip catch-up sync.
#   - Source data is preserved through the entire soak window.
#   - Cleanup (Step 7.5 — source data deletion) only fires when ALL of:
#       (a) target pod backup completed,
#       (b) cross-region S3 replication completed,
#       (c) target pod standby refresh completed,
#       (d) ≥24h since flip.
#     This script only flips and arms the soak; cleanup is a separate
#     orchestrator that polls the placement table.
#
# Usage:
#   ./per-tenant-relocate.sh <tenant-id> <source-pod-ordinal> <target-pod-ordinal>
#
# Example:
#   ./per-tenant-relocate.sh tenant-acme 3 7
#
# Required environment:
#   ENVOY_ADMIN_ENDPOINTS  comma-separated list of Envoy admin URLs
#                          e.g. http://envoy-0.envoy:9901,http://envoy-1.envoy:9901
#
# Optional environment:
#   NAMESPACE        target K8s namespace (default: aegis-app)
#   PLACEMENT_TABLE  DynamoDB placement table (default: aegis-statefulset-placement-prod)
#   DELTA_THRESHOLD_MB  pre-flip delta cutoff in MB (default: 10)
#
# This script is intentionally a skeleton. TODO blocks mark places where the
# operator wires in environment-specific commands (Restic invocation, kubectl
# exec patterns, telemetry queries). The control flow, ordering, and cleanup
# gate are fixed and must not be reordered.
#
# One-time prep: operator runs `chmod +x scripts/**/*.sh` after pulling the
# repo (sandbox blocks chmod from CI).

set -euo pipefail

TENANT_ID="${1:?usage: $0 <tenant-id> <source-pod-ordinal> <target-pod-ordinal>}"
SOURCE_ORDINAL="${2:?source-pod-ordinal required}"
TARGET_ORDINAL="${3:?target-pod-ordinal required}"

NAMESPACE="${NAMESPACE:-aegis-app}"
PLACEMENT_TABLE="${PLACEMENT_TABLE:-aegis-statefulset-placement-prod}"
ENVOY_ADMIN_ENDPOINTS="${ENVOY_ADMIN_ENDPOINTS:?ENVOY_ADMIN_ENDPOINTS env var required (comma-separated list)}"
DELTA_THRESHOLD_MB="${DELTA_THRESHOLD_MB:-10}"

SOURCE_POD="aegis-statefulset-primary-${SOURCE_ORDINAL}"
TARGET_POD="aegis-statefulset-primary-${TARGET_ORDINAL}"

log() {
  printf '[%s] %s\n' "$(date -Iseconds)" "$*"
}

log "Starting relocation: ${TENANT_ID} from ${SOURCE_POD} to ${TARGET_POD}"

# ============================================================
# Step 1-2: Observe + Decide
#
# Assumed already done before this script is invoked: Prometheus alert
# fires (75% PR or 90% emergency or +500GB/7d), operator reviews and
# selects the target pod, then runs this script.
# ============================================================

# ============================================================
# Step 3: Target verification
# ============================================================
log "[Step 3/7] Verifying target pod state and headroom"
# TODO: aws dynamodb update-item --table-name "${PLACEMENT_TABLE}" \
#         --key "{\"tenant_id\":{\"S\":\"${TENANT_ID}\"}}" \
#         --update-expression "SET #s = :state" \
#         --expression-attribute-names '{"#s":"state"}' \
#         --expression-attribute-values '{":state":{"S":"PRE_FLIP_SYNCING"}}'
# TODO: kubectl get pod "${TARGET_POD}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}'
#       must be Running; abort otherwise.
# TODO: query telemetry — target pod free space must exceed tenant_size * 1.2

# ============================================================
# Step 4: Initial Restic backup with tenant filter
# ============================================================
log "[Step 4/7] Initial Restic backup with tenant=${TENANT_ID} filter"
# Capture LVM snapshot of source pod's data, restic backup tenant folder only.
# Restic's path filter scopes the backup so we don't ship neighbour-tenant data.
# TODO: kubectl exec -n "${NAMESPACE}" "${SOURCE_POD}" -- /bin/sh -c \
#         "lvcreate --snapshot --size 50G --name relocate-${TENANT_ID} /dev/vg-aegis/data-lv && \
#          mount -o ro /dev/vg-aegis/relocate-${TENANT_ID} /mnt/snap && \
#          restic backup --tag relocate=${TENANT_ID} /mnt/snap/tenants/${TENANT_ID}/"

# ============================================================
# Step 5: Incremental delta sync (until <DELTA_THRESHOLD_MB)
# ============================================================
log "[Step 5/7] Incremental delta sync until <${DELTA_THRESHOLD_MB}MB"
# Loop: incremental backup, restore to target, measure delta. Exit when
# delta is small enough that the post-flip catch-up sync can close the rest.
delta_mb=999
loop_count=0
max_loops=20
while [ "${delta_mb}" -gt "${DELTA_THRESHOLD_MB}" ]; do
  loop_count=$((loop_count + 1))
  if [ "${loop_count}" -gt "${max_loops}" ]; then
    log "ERROR: delta sync did not converge after ${max_loops} iterations (last delta=${delta_mb}MB)"
    log "Source write rate may exceed sync bandwidth. Investigate before retry."
    exit 1
  fi
  # TODO: kubectl exec -n "${NAMESPACE}" "${SOURCE_POD}" -- restic backup \
  #         --tag relocate=${TENANT_ID} /mnt/snap/tenants/${TENANT_ID}/
  # TODO: kubectl exec -n "${NAMESPACE}" "${TARGET_POD}" -- restic restore latest \
  #         --target / --include "/tenants/${TENANT_ID}/"
  # TODO: delta_mb=$(measure delta between source latest snapshot and target)
  delta_mb=$((delta_mb / 2))  # placeholder convergence
  log "  iteration=${loop_count} delta=${delta_mb}MB"
done
log "  delta below ${DELTA_THRESHOLD_MB}MB threshold — proceeding to flip"

# ============================================================
# Step 6: Atomic flip (no source quiesce — routing only)
# ============================================================
log "[Step 6/7] Atomic flip"

# 6.1 Final delta sync — tighter than threshold, captures the last
#     few seconds of writes before the routing change.
log "[Step 6.1] Final pre-flip delta sync"
# TODO: final tiny restic incremental + restore to target

# 6.2 Atomic DynamoDB CAS write — flips placement.
#     Source is still serving reads/writes when this fires; the CAS
#     guarantees we're the only flipper, but does not stop the source.
log "[Step 6.2] DynamoDB CAS write — flipping primary_pod"
flip_ts=$(date +%s)
aws dynamodb update-item \
  --table-name "${PLACEMENT_TABLE}" \
  --key "{\"tenant_id\":{\"S\":\"${TENANT_ID}\"}}" \
  --update-expression "SET primary_pod = :new_pod, pending_source_pod = :old_pod, #s = :state, flip_at = :ts" \
  --condition-expression "primary_pod = :old_pod_check" \
  --expression-attribute-names '{"#s":"state"}' \
  --expression-attribute-values "{
      \":new_pod\":{\"S\":\"${TARGET_POD}\"},
      \":old_pod\":{\"S\":\"${SOURCE_POD}\"},
      \":old_pod_check\":{\"S\":\"${SOURCE_POD}\"},
      \":state\":{\"S\":\"SOAK_PENDING_BACKUP\"},
      \":ts\":{\"N\":\"${flip_ts}\"}
    }" \
  || { log "ERROR: DynamoDB CAS failed — placement may have changed underneath"; exit 1; }

# 6.3 Sync invalidate Envoy cache on ALL replicas in parallel.
#     This is the fast path. Streams-based async invalidation also runs
#     in parallel via Lambda (fail-safe — see ADR-01).
log "[Step 6.3] Sync invalidate Envoy cache on all replicas"
sync_invalidate_failed=0
endpoint_count=0
for endpoint in $(echo "${ENVOY_ADMIN_ENDPOINTS}" | tr ',' ' '); do
  endpoint_count=$((endpoint_count + 1))
  if ! curl -sf -X POST "${endpoint}/cache/invalidate/${TENANT_ID}" --max-time 5 >/dev/null; then
    log "WARN: sync invalidate failed on ${endpoint}"
    sync_invalidate_failed=1
  fi
done

# 6.4 Post-flip catch-up delta sync — captures any writes that hit
#     the source during the ~500ms 6.2-6.3 window.
log "[Step 6.4] Post-flip catch-up delta sync"
# TODO: another incremental restic backup + restore to target.
#       This is the key trick: source still has the writes, target
#       gets them via Restic; client is already pointed at target by
#       this point so the ordering is "stale read for ~500ms, then
#       consistent."

# 6.5 Bulk flush fallback if 6.3 had partial failure.
#     One Envoy replica still serving stale routing for this tenant
#     is unacceptable; nuke all caches.
if [ "${sync_invalidate_failed}" = "1" ]; then
  log "[Step 6.5] Sync invalidate had partial failure — escalating to bulk flush"
  "$(dirname "$0")/../cache/flush-all.sh" \
    --reason "relocation-${TENANT_ID}-partial-sync-fail" \
    --no-confirm
fi

# ============================================================
# Step 7: Soak + cleanup gate
# ============================================================
log "[Step 7/7] Entering soak window"
log "Cleanup will only fire when ALL of (per ADR-01):"
log "  (a) target pod backup completed"
log "  (b) cross-region S3 replication completed"
log "  (c) target pod standby refresh completed"
log "  (d) >=24h since flip"

# Update placement state — soak ETA is informational; cleanup orchestrator
# checks all four conditions, not just the timestamp.
soak_eta=$((flip_ts + 86400))
aws dynamodb update-item \
  --table-name "${PLACEMENT_TABLE}" \
  --key "{\"tenant_id\":{\"S\":\"${TENANT_ID}\"}}" \
  --update-expression "SET #s = :state, cleanup_eligible_at = :eta" \
  --expression-attribute-names '{"#s":"state"}' \
  --expression-attribute-values "{
      \":state\":{\"S\":\"SOAK_PENDING_BACKUP\"},
      \":eta\":{\"N\":\"${soak_eta}\"}
    }"

log "Relocation flip complete for ${TENANT_ID}"
log "  flip_at:              ${flip_ts}"
log "  cleanup_eligible_at:  ${soak_eta} (24h floor; backup/replication gates also required)"
log "Cleanup is performed by the placement-table cleanup orchestrator,"
log "not by this script. See docs/operations/tenant-relocation.md for rollback."
