#!/usr/bin/env bash
# scripts/dr/warm-routing-table.sh
#
# DR Path B — routing table loss (ADR-04).
#
# Override store (ConfigMap or Redis) is empty or wiped, but pods and
# data are healthy. Recovery walks pod-on-disk truth: each pod knows
# which tenants it serves; we compare actual placement to hash result
# and write override entries only for divergences.
#
# Target RTO: 10-30 min. RPO: 0 (no data involved).
#
# Usage:
#   ./warm-routing-table.sh
#
# Required environment:
#   NAMESPACE        — K8s namespace (default: aegis-app)
#   POD_LABEL        — pod selector (default: app.kubernetes.io/name=aegis-statefulset)
#   OVERRIDE_CM_NAME — routing override ConfigMap (default: routing-override)
#
# Application contract: each pod exposes GET /admin/local-tenants returning
# a JSON list of tenant_id strings.

set -euo pipefail

NAMESPACE="${NAMESPACE:-aegis-app}"
POD_LABEL="${POD_LABEL:-app.kubernetes.io/name=aegis-statefulset}"
OVERRIDE_CM_NAME="${OVERRIDE_CM_NAME:-routing-override}"

log() {
  printf '[%s] [dr-path-b] %s\n' "$(date -Iseconds)" "$*"
}

log "Path B — warm routing table from pod-on-disk truth"

# Step 1 — enumerate pods.
log "[1/4] Enumerate pods matching selector"
pods=$(kubectl get pods -n "${NAMESPACE}" -l "${POD_LABEL}" \
         -o jsonpath='{.items[*].metadata.name}')

if [ -z "${pods}" ]; then
  log "ERROR: no pods found for selector ${POD_LABEL} in ${NAMESPACE}"
  exit 1
fi

# Discover the active pod set for hash comparison.
pod_array=()
for p in ${pods}; do
  pod_array+=("${p}")
done
pod_count=${#pod_array[@]}
log "Found ${pod_count} pods"

# Step 2 — query each pod for its local tenants.
log "[2/4] Query each pod's GET /admin/local-tenants"
override_data='{}'

for pod in "${pod_array[@]}"; do
  tenants=$(kubectl exec -n "${NAMESPACE}" "${pod}" -- \
              curl -sf http://localhost:8080/admin/local-tenants 2>/dev/null \
            || echo '[]')

  # Step 3 — compute hash placement for each tenant; emit override only on divergence.
  for tenant_id in $(echo "${tenants}" | jq -r '.[]'); do
    # Hash placement: stable hash mod pod_count (placeholder — real
    # implementation matches Envoy's consistent_hash configuration, e.g.,
    # ring-hash with a known seed).
    hash_value=$(printf '%s' "${tenant_id}" | sha256sum | cut -c1-8)
    hash_index=$(( 0x${hash_value} % pod_count ))
    expected_pod="${pod_array[${hash_index}]}"

    if [ "${expected_pod}" != "${pod}" ]; then
      log "  divergence: tenant=${tenant_id} actual=${pod} expected=${expected_pod}"
      override_data=$(echo "${override_data}" \
        | jq --arg tid "${tenant_id}" --arg pod "${pod}" \
            '. + {($tid): $pod}')
    fi
  done
done

# Step 4 — write override ConfigMap.
divergence_count=$(echo "${override_data}" | jq 'length')
log "[4/4] Writing ${divergence_count} override entries to ${OVERRIDE_CM_NAME}"

kubectl create configmap "${OVERRIDE_CM_NAME}" \
  -n "${NAMESPACE}" \
  --from-literal=overrides="${override_data}" \
  --dry-run=client -o yaml \
  | kubectl apply -f -

log "Path B recovery complete. Override table seeded from pod-on-disk truth."
