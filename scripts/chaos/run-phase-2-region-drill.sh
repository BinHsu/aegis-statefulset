#!/usr/bin/env bash
# scripts/chaos/run-phase-2-region-drill.sh
#
# Phase 2 chaos demo: cross-region DR drill, no actual region kill.
#
# This drill exercises the cross-region restore + DNS cutover path
# without taking the primary region offline. The drill stands up DR
# infra (or asserts it is up), restores Velero into the DR region,
# verifies pods Ready, and runs a probe-side validation. DNS cutover
# is offered as an optional step, defaulted off — the drill should be
# repeatable without affecting customers.
#
# Why drill rather than kill: a real region kill is irreversible at
# Mittelstand budget; the cross-region restore + DNS muscle memory is
# the load-bearing path, and that we can practise without risk. The
# decision to actually fail traffic over is a separate, conscious one.
#
# Required environment:
#   PRIMARY_REGION       e.g. eu-central-1
#   DR_REGION            e.g. eu-west-1
#   TERRAFORM_DIR        path to infrastructure/terraform/dr
#   DR_KUBECONFIG        kubeconfig path pointing at DR cluster
#   PROBE_HOSTNAME       hostname to curl for end-to-end check
#                        (default api-dr.aegis.example.com)
#
# Optional flags:
#   --include-cutover    also run Route 53 cutover (default off)
#
# Required by region-cutover.sh if --include-cutover is set:
#   HOSTED_ZONE_ID PRIMARY_ALB DR_ALB RECORD_NAME

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

PRIMARY_REGION="${PRIMARY_REGION:?PRIMARY_REGION env var required}"
DR_REGION="${DR_REGION:?DR_REGION env var required}"
TERRAFORM_DIR="${TERRAFORM_DIR:?TERRAFORM_DIR env var required}"
DR_KUBECONFIG="${DR_KUBECONFIG:?DR_KUBECONFIG env var required}"
PROBE_HOSTNAME="${PROBE_HOSTNAME:-api-dr.aegis.example.com}"

INCLUDE_CUTOVER=0
while [ $# -gt 0 ]; do
  case "$1" in
    --include-cutover) INCLUDE_CUTOVER=1 ;;
    *) echo "Unknown flag: $1"; exit 2 ;;
  esac
  shift
done

log() {
  printf '[%s] [phase-2-region-drill] %s\n' "$(date -Iseconds)" "$*"
}

START_TS=$(date +%s)

log "Phase 2 chaos drill: cross-region restore"
log "  primary=${PRIMARY_REGION}  dr=${DR_REGION}"
log "  cutover=$([ "${INCLUDE_CUTOVER}" -eq 1 ] && echo yes || echo no)"
log "Phase 2 deliberately does NOT kill the primary region."

# Step 1 — assert / provision DR infrastructure.
log "[Step 1/5] Asserting DR infrastructure is up"
(
  cd "${TERRAFORM_DIR}"
  if ! terraform output -raw eks_cluster_name >/dev/null 2>&1; then
    log "  no existing state; running terraform apply"
    terraform init -upgrade
    terraform apply -auto-approve -var "region=${DR_REGION}"
  else
    log "  existing state found; skipping apply"
  fi
)

# Step 2 — Velero restore from latest cross-region backup.
log "[Step 2/5] Velero restore in DR region"
export KUBECONFIG="${DR_KUBECONFIG}"

LATEST=$(velero backup get -o name 2>/dev/null | head -n1)
if [ -z "${LATEST}" ]; then
  log "ERROR: no Velero backups visible from DR region"
  exit 1
fi
log "  source backup: ${LATEST}"

RESTORE_NAME="drill-$(date +%s)"
velero restore create "${RESTORE_NAME}" \
  --from-backup "${LATEST}" \
  --restore-volumes=true \
  --include-namespaces aegis-app,api-tier,envoy \
  --wait

# Step 3 — wait for pods Ready.
log "[Step 3/5] Waiting for pods Ready in DR region"
TIMEOUT=1800
elapsed=0
while [ "${elapsed}" -lt "${TIMEOUT}" ]; do
  total=$(kubectl get pods -n aegis-app --no-headers 2>/dev/null | wc -l | tr -d ' ')
  ready=$(kubectl get pods -n aegis-app --no-headers 2>/dev/null \
          | awk '$2 ~ /^[0-9]+\/[0-9]+$/ {split($2,a,"/"); if (a[1]==a[2]) n++} END {print n+0}')
  log "  ready ${ready}/${total} (elapsed ${elapsed}s)"
  if [ "${total}" -gt 0 ] && [ "${ready}" -eq "${total}" ]; then
    break
  fi
  sleep 30
  elapsed=$((elapsed + 30))
done
if [ "${elapsed}" -ge "${TIMEOUT}" ]; then
  log "ERROR: pods did not become Ready within ${TIMEOUT}s"
  exit 1
fi

# Step 4 — probe-side validation (read checkpoint #5/#6 in chaos demo).
log "[Step 4/5] Probe-side validation against ${PROBE_HOSTNAME}"
if curl -sf "https://${PROBE_HOSTNAME}/healthz" >/dev/null; then
  log "  /healthz OK"
else
  log "  WARN: /healthz failed (DNS may not yet point at DR; that is expected if --include-cutover is off)"
fi

# Read the canary keys written before the drill (T1, T2 by convention).
for key in T1 T2; do
  if value=$(curl -sf "https://${PROBE_HOSTNAME}/data?key=${key}"); then
    log "  read key=${key} -> ${value}"
  else
    log "  WARN: read key=${key} failed"
  fi
done

# Step 5 — optional Route 53 cutover.
if [ "${INCLUDE_CUTOVER}" -eq 1 ]; then
  log "[Step 5/5] Route 53 cutover (progressive)"
  MODE=progressive "${SCRIPT_DIR}/../dr/region-cutover.sh"
else
  log "[Step 5/5] cutover skipped (drill mode)"
fi

END_TS=$(date +%s)
DRILL_MIN=$(( (END_TS - START_TS) / 60 ))

echo
log "Phase 2 drill complete in ${DRILL_MIN} minutes"
log "Cleanup (operator action):"
log "  velero restore delete ${RESTORE_NAME}"
log "  kubectl delete ns aegis-app api-tier envoy --kubeconfig=${DR_KUBECONFIG}"
log "  (terraform destroy for the DR infra is OPTIONAL — keeping it warm"
log "   reduces RTO at the cost of ~\$N/month in baseline fees; see ADR-04)"
