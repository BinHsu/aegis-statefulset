#!/usr/bin/env bash
# scripts/migration/per-shard-cutover.sh
#
# Per-shard cutover skeleton for Strangler Fig migration (ADR-05).
# 9-step sequence per consensus.md § 10. Each step is reversible.
#
# Usage:
#   ./per-shard-cutover.sh <shard-ordinal>
#
# Example:
#   ./per-shard-cutover.sh 0
#
# Environment overrides:
#   NAMESPACE          — target K8s namespace (default: aegis-app)
#   LEGACY_HOST_PREFIX — DNS prefix of legacy single-tenant servers
#                        (default: legacy-host)
#   STATEFULSET        — primary StatefulSet name (default: aegis-statefulset-primary)
#
# This script is intentionally a skeleton: TODO blocks mark places where
# the operator wires in environment-specific commands (snapshot, S3 path,
# DNS zone). The control flow, ordering, and rollback semantics are fixed.

set -euo pipefail

SHARD="${1:?usage: $0 <shard-ordinal>}"
NAMESPACE="${NAMESPACE:-aegis-app}"
LEGACY_HOST_PREFIX="${LEGACY_HOST_PREFIX:-legacy-host}"
STATEFULSET="${STATEFULSET:-aegis-statefulset-primary}"

LEGACY_HOST="${LEGACY_HOST_PREFIX}-${SHARD}"
K8S_POD="${STATEFULSET}-${SHARD}"

log() {
  printf '[%s] %s\n' "$(date -Iseconds)" "$*"
}

log "Starting cutover for shard ${SHARD} (${LEGACY_HOST} -> ${K8S_POD})"

# Step 1 — snapshot legacy + Restic backup
log "[Step 1/9] LVM snapshot of ${LEGACY_HOST} + Restic backup -> S3"
# TODO: ssh "${LEGACY_HOST}" "lvcreate --snapshot --size 100G --name pre-cutover /dev/vg-aegis/data-lv"
# TODO: restic backup --tag "legacy-${SHARD}" --tag "cutover" /mnt/legacy-snapshot

# Step 2 — pre-create PV from snapshot
log "[Step 2/9] Pre-create PV pointing to restored EBS in K8s"
# TODO: aws ec2 create-volume --snapshot-id <snap-id> --availability-zone <az>
#       Tags must match ADR-02 conventions:
#       kubernetes.io/created-for/pvc/name = data-${K8S_POD}
#       kubernetes.io/created-for/pvc/namespace = ${NAMESPACE}
#       aegis.io/pod-ordinal = ${SHARD}
# TODO: kubectl apply -f "pv-${SHARD}.yaml"

# Step 3 — Helm upgrade so pod-N starts with pre-existing data
log "[Step 3/9] Helm upgrade — pod-${SHARD} starts and binds to pre-created PV"
# TODO: helm upgrade aegis-statefulset helm/aegis-statefulset \
#         --namespace "${NAMESPACE}" \
#         --reuse-values \
#         --set "stateful.primary.replicas=$((SHARD + 1))"

# Step 4 — read-only validation against legacy
log "[Step 4/9] Read-only validation against ${LEGACY_HOST}"
# TODO: ./identity-preservation-check.sh "${SHARD}"
#       Compares row counts, checksums, and tenant identity between
#       legacy and new pod. Aborts cutover on mismatch.

# Step 5 — final delta sync
log "[Step 5/9] Final delta sync (Restic incremental, ~minutes)"
# TODO: restic backup --tag "legacy-${SHARD}" --tag "delta" /mnt/legacy-snapshot
# TODO: kubectl exec -n "${NAMESPACE}" "${K8S_POD}" -- restic restore latest \
#         --target / --include "/var/lib/aegis/data"

# Step 6 — DNS / IP cutover
log "[Step 6/9] DNS / IP cutover ${LEGACY_HOST} -> ${K8S_POD}"
# TODO: aws route53 change-resource-record-sets --hosted-zone-id "${ZONE_ID}" \
#         --change-batch file://route53-cutover-${SHARD}.json
#       The ExternalName Service from ADR-05 is now the canonical target.

# Step 7 — legacy enters standby (rollback path preserved)
log "[Step 7/9] Legacy ${LEGACY_HOST} enters standby — rollback path preserved"
# TODO: ssh "${LEGACY_HOST}" "systemctl stop aegis-app"
#       Keep the host running but service stopped; data intact for rollback.

# Step 8 — soak (24-48h)
log "[Step 8/9] Soak — monitor SLI for 24-48 hours before decommission"
# Operator action: watch dashboards (cell-capacity, pod-detail, customer-drill-down)
# for the cutover shard. Abort and rollback if SLO violated.

# Step 9 — decommission legacy (interactive confirmation)
log "[Step 9/9] Decommission ${LEGACY_HOST}"
read -rp "Decommission ${LEGACY_HOST}? Type 'YES' to confirm: " confirm
if [ "${confirm}" = "YES" ]; then
  log "Decommissioning ${LEGACY_HOST}"
  # TODO: aws ec2 terminate-instances --instance-ids "${LEGACY_INSTANCE_ID}"
  # TODO: aws ec2 delete-volume --volume-id "${LEGACY_VOLUME_ID}"  # only after verified backup
else
  log "Decommission skipped. Re-run with confirmation when soak is complete."
fi

log "Cutover for shard ${SHARD} complete"
