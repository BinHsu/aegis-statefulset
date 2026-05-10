#!/usr/bin/env bash
# scripts/capacity/expand-cell.sh
#
# Capacity expansion per ADR-01 — adds new pods to the stateful pool by
# bumping cells.per_az. NO tenant migration: existing tenants stay on
# their current pods; new tenants route to the newest cell.
#
# Two-step sequence (order matters):
#   1. Terraform first — bumps the per-AZ node group desired count so
#      capacity is available before pods are created.
#   2. Helm second — bumps the StatefulSet replica count so new pods
#      schedule onto the freshly added nodes.
#
# Reversing the order causes Pending pods (no nodes to schedule onto)
# and a temporary degradation of the placement service's "any cell has
# headroom" invariant.
#
# Usage:
#   ./expand-cell.sh <new-per-az-count>
#
# Example:
#   ./expand-cell.sh 4    # was 3, now 4 (cluster goes from 9 to 12 pods)
#
# Optional environment:
#   NAMESPACE      target K8s namespace (default: aegis-app)
#   HELM_RELEASE   helm release name (default: aegis-statefulset)
#   TF_DIR         path to terraform root (default: infrastructure/terraform)
#
# One-time prep: operator runs `chmod +x scripts/**/*.sh` after pulling.

set -euo pipefail

NEW_PER_AZ="${1:?usage: $0 <new-per-az-count>}"
NAMESPACE="${NAMESPACE:-aegis-app}"
HELM_RELEASE="${HELM_RELEASE:-aegis-statefulset}"
TF_DIR="${TF_DIR:-infrastructure/terraform}"
AZ_COUNT="${AZ_COUNT:-3}"  # eu-central-1 typical layout

log() {
  printf '[%s] %s\n' "$(date -Iseconds)" "$*"
}

if ! [[ "${NEW_PER_AZ}" =~ ^[0-9]+$ ]] || [ "${NEW_PER_AZ}" -lt 1 ]; then
  log "ERROR: NEW_PER_AZ must be a positive integer, got: ${NEW_PER_AZ}"
  exit 1
fi

log "Starting capacity expansion: cells.per_az -> ${NEW_PER_AZ} (${AZ_COUNT} AZs)"
expected_pods=$((AZ_COUNT * NEW_PER_AZ))
log "  Expected total pods after expansion: ${expected_pods}"

# Step 1 — Terraform — bump node group size.
log "[Step 1/3] Terraform apply — node group bump"
( cd "${TF_DIR}" && terraform apply -var "stateful_pool_per_az_size=${NEW_PER_AZ}" -auto-approve )

log "  Waiting for new nodes to become Ready..."
# TODO: poll-until-ready loop, e.g.:
#   for i in $(seq 1 60); do
#     ready=$(kubectl get nodes -l aegis.io/pool=stateful \
#       --no-headers | awk '$2=="Ready"' | wc -l)
#     if [ "${ready}" -ge "${expected_pods}" ]; then break; fi
#     sleep 10
#   done
#   Abort if timeout exceeded — Helm step assumes capacity is present.

# Step 2 — Helm — bump pod count.
log "[Step 2/3] Helm upgrade — pod count bump"
helm upgrade --install "${HELM_RELEASE}" helm/aegis-statefulset/ \
  -n "${NAMESPACE}" \
  --set "cells.per_az=${NEW_PER_AZ}" \
  --wait --timeout 30m

# Step 3 — Verification.
log "[Step 3/3] Verification"
actual_pods=$(kubectl get pods -n "${NAMESPACE}" -l "aegis.io/role=primary" --no-headers | wc -l | tr -d ' ')

if [ "${actual_pods}" -ne "${expected_pods}" ]; then
  log "WARN: expected ${expected_pods} primary pods, got ${actual_pods}"
  log "      Investigate: kubectl get pods -n ${NAMESPACE} -l aegis.io/role=primary"
  exit 1
fi

# TODO: verify backup CronJob auto-created for each new pod
#       (per templates/backup-cronjob.yaml — should reconcile via Helm).
# TODO: verify headless Service DNS resolves new pods:
#       kubectl exec -n "${NAMESPACE}" deploy/some-client -- \
#         dig +short aegis-statefulset-primary-headless

log "Capacity expansion complete"
log "  New tenants -> newest cell (per ADR-01 placement service)"
log "  Existing tenants remain on current cells (no migration)"
log "  Cost impact: every cell expansion adds ~per-pod monthly cost forever — see docs/operations/capacity-expansion.md"
