#!/usr/bin/env bash
# scripts/dr/region-failure-recovery.sh
#
# Comprehensive region failover wrapper. Orchestrates the full flow when
# the primary region is lost (ADR-04 Path C, ADR-04, ADR-04).
#
# Phases:
#   1. Provision DR region infrastructure (terraform apply, ~25 min).
#   2. Velero restore from cross-region snapshots (~15 min).
#   3. Wait for pods Ready in DR region.
#   4. Route 53 cutover via region-cutover.sh.
#   5. Print verification commands and customer-comms reminder.
#
# Each phase is opt-in via --phase / --skip-* flags so the operator can
# resume from a partial run. The script is intentionally chatty; total
# RTO target is ~50 minutes per ADR-04.
#
# Required environment (or pass --terraform-dir / --dr-region):
#   DR_REGION                e.g. eu-west-1
#   PRIMARY_REGION           e.g. eu-central-1
#   TERRAFORM_DIR            path to infrastructure/terraform/dr
#   HOSTED_ZONE_ID           Route 53 hosted zone ID
#   RECORD_NAME              DNS record name (e.g. api.aegis.example.com)
#   PRIMARY_ALB              primary region ALB DNS
#   DR_ALB                   DR region ALB DNS (resolved post-apply)
#
# Optional flags:
#   --skip-terraform         skip phase 1 (infra already up)
#   --skip-restore           skip phase 2 (Velero restore already done)
#   --skip-cutover           skip phase 4 (DNS cutover deferred)
#   --emergency              use emergency cutover mode (0/100 immediate)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

DR_REGION="${DR_REGION:?DR_REGION env var required}"
PRIMARY_REGION="${PRIMARY_REGION:?PRIMARY_REGION env var required}"
TERRAFORM_DIR="${TERRAFORM_DIR:?TERRAFORM_DIR env var required}"

SKIP_TERRAFORM=0
SKIP_RESTORE=0
SKIP_CUTOVER=0
CUTOVER_MODE=progressive

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-terraform) SKIP_TERRAFORM=1 ;;
    --skip-restore)   SKIP_RESTORE=1 ;;
    --skip-cutover)   SKIP_CUTOVER=1 ;;
    --emergency)      CUTOVER_MODE=emergency ;;
    *) echo "Unknown flag: $1"; exit 2 ;;
  esac
  shift
done

log() {
  printf '[%s] [region-recovery] %s\n' "$(date -Iseconds)" "$*"
}

START_TS=$(date +%s)

log "Region failure recovery starting"
log "  primary=${PRIMARY_REGION}  dr=${DR_REGION}"
log "  cutover mode=${CUTOVER_MODE}"
log "Target RTO: ~50 minutes (ADR-04)"

# --- Phase 1: Provision DR region infra ---------------------------------
if [ "${SKIP_TERRAFORM}" -eq 0 ]; then
  log "[Phase 1/4] terraform apply in DR region"
  (
    cd "${TERRAFORM_DIR}"
    terraform init -upgrade
    terraform plan -out=dr.tfplan -var "region=${DR_REGION}"
    terraform apply -auto-approve dr.tfplan
  )
  log "Phase 1 complete (infra up in ${DR_REGION})"
else
  log "[Phase 1/4] skipped (--skip-terraform)"
fi

# --- Phase 2: Velero restore from cross-region snapshots ---------------
if [ "${SKIP_RESTORE}" -eq 0 ]; then
  log "[Phase 2/4] Velero restore from cross-region backup"
  LATEST=$(velero backup get -o name 2>/dev/null | head -n1)
  if [ -z "${LATEST}" ]; then
    log "ERROR: no Velero backups visible from DR region"
    exit 1
  fi
  log "  source backup: ${LATEST}"

  velero restore create "region-recovery-$(date +%s)" \
    --from-backup "${LATEST}" \
    --restore-volumes=true \
    --include-namespaces aegis-app,api-tier,envoy \
    --wait
  log "Phase 2 complete (Velero restore finished)"
else
  log "[Phase 2/4] skipped (--skip-restore)"
fi

# --- Phase 3: Wait for pods Ready in DR region --------------------------
log "[Phase 3/4] Waiting for pods Ready in DR region"
TIMEOUT=1800  # 30 minutes
elapsed=0
while [ "${elapsed}" -lt "${TIMEOUT}" ]; do
  total=$(kubectl get pods -n aegis-app --no-headers 2>/dev/null | wc -l | tr -d ' ')
  ready=$(kubectl get pods -n aegis-app --no-headers 2>/dev/null \
          | awk '$2 ~ /^[0-9]+\/[0-9]+$/ {split($2,a,"/"); if (a[1]==a[2]) n++} END {print n+0}')
  log "  pods ready: ${ready}/${total} (elapsed ${elapsed}s)"
  if [ "${total}" -gt 0 ] && [ "${ready}" -eq "${total}" ]; then
    log "  all pods Ready"
    break
  fi
  sleep 30
  elapsed=$((elapsed + 30))
done
if [ "${elapsed}" -ge "${TIMEOUT}" ]; then
  log "ERROR: pods did not become Ready within ${TIMEOUT}s"
  exit 1
fi
log "Phase 3 complete"

# --- Phase 4: Route 53 cutover ------------------------------------------
if [ "${SKIP_CUTOVER}" -eq 0 ]; then
  log "[Phase 4/4] Route 53 cutover (mode=${CUTOVER_MODE})"
  MODE="${CUTOVER_MODE}" "${SCRIPT_DIR}/region-cutover.sh"
  log "Phase 4 complete"
else
  log "[Phase 4/4] skipped (--skip-cutover)"
fi

END_TS=$(date +%s)
RTO_MIN=$(( (END_TS - START_TS) / 60 ))

echo
log "Region failure recovery complete"
log "  Total elapsed: ${RTO_MIN} minutes"
log "  Target RTO:    ~50 minutes (ADR-04)"
echo
log "Customer comms (operator action):"
log "  - Send status-page update: 'Service restored in ${DR_REGION}'"
log "  - Send customer email if degraded > 30 min"
log "  - File post-mortem ticket within 24h"
