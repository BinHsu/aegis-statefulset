#!/usr/bin/env bash
# scripts/dr/region-cutover.sh
#
# Route 53 weighted-routing cutover from primary region to DR region
# (ADR-04 Path C, ADR-04 Layer 3).
#
# Approach: weighted DNS rather than failover policy. Two A-records in a
# weighted set, weights initially 100/0. Cutover steps the DR weight up
# in increments while monitoring health, with an emergency 0/100 path.
# Weighted routing avoids the bistable flap behaviour of failover policy
# under partial-region degradation, and keeps the operator in control.
#
# Required environment:
#   HOSTED_ZONE_ID       Route 53 hosted zone ID for api.aegis.example.com
#   RECORD_NAME          DNS record (e.g. api.aegis.example.com)
#   PRIMARY_ALB          ALB DNS name in primary region
#   DR_ALB               ALB DNS name in DR region
#   PRIMARY_REGION       e.g. eu-central-1
#   DR_REGION            e.g. eu-west-1
#
# Optional environment:
#   MODE                 progressive | emergency  (default: progressive)
#   STEP_DELAY_SECONDS   default 120 between weight steps in progressive mode
#
# Usage:
#   MODE=progressive ./region-cutover.sh   # 100/0 -> 75/25 -> 25/75 -> 0/100
#   MODE=emergency   ./region-cutover.sh   # 100/0 -> 0/100 immediately

set -euo pipefail

HOSTED_ZONE_ID="${HOSTED_ZONE_ID:?HOSTED_ZONE_ID env var required}"
RECORD_NAME="${RECORD_NAME:?RECORD_NAME env var required}"
PRIMARY_ALB="${PRIMARY_ALB:?PRIMARY_ALB env var required}"
DR_ALB="${DR_ALB:?DR_ALB env var required}"
PRIMARY_REGION="${PRIMARY_REGION:?PRIMARY_REGION env var required}"
DR_REGION="${DR_REGION:?DR_REGION env var required}"
MODE="${MODE:-progressive}"
STEP_DELAY_SECONDS="${STEP_DELAY_SECONDS:-120}"

log() {
  printf '[%s] [region-cutover] %s\n' "$(date -Iseconds)" "$*"
}

# Apply a (primary_weight, dr_weight) pair to the Route 53 weighted set.
apply_weights() {
  local primary_w="$1"
  local dr_w="$2"
  local change_batch
  change_batch=$(cat <<JSON
{
  "Comment": "region-cutover: primary=${primary_w} dr=${dr_w}",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${RECORD_NAME}",
        "Type": "A",
        "SetIdentifier": "primary-${PRIMARY_REGION}",
        "Weight": ${primary_w},
        "AliasTarget": {
          "HostedZoneId": "Z215JYRZR1TBD5",
          "DNSName": "${PRIMARY_ALB}",
          "EvaluateTargetHealth": true
        }
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${RECORD_NAME}",
        "Type": "A",
        "SetIdentifier": "dr-${DR_REGION}",
        "Weight": ${dr_w},
        "AliasTarget": {
          "HostedZoneId": "Z32O12XQLNTSW2",
          "DNSName": "${DR_ALB}",
          "EvaluateTargetHealth": true
        }
      }
    }
  ]
}
JSON
)
  # Note: hosted-zone IDs above are AWS-published per-region ALB hosted-zone
  # IDs; for production, parameterise via aws elbv2 describe-load-balancers
  # or read from terraform output. Hardcoded here for the POC.

  log "Applying weights primary=${primary_w} dr=${dr_w}"
  aws route53 change-resource-record-sets \
    --hosted-zone-id "${HOSTED_ZONE_ID}" \
    --change-batch "${change_batch}" \
    > /dev/null
}

# Probe a hostname; print "OK" or "FAIL".
probe() {
  local host="$1"
  if curl -sf -o /dev/null --max-time 5 "https://${host}/healthz"; then
    echo OK
  else
    echo FAIL
  fi
}

log "Region cutover: ${PRIMARY_REGION} -> ${DR_REGION} (mode=${MODE})"
log "Pre-cutover health: primary=$(probe "${PRIMARY_ALB}"), dr=$(probe "${DR_ALB}")"

case "${MODE}" in
  emergency)
    log "[Emergency] Stepping straight to 0/100"
    apply_weights 0 100
    ;;
  progressive)
    # 100/0 is already in place. Step up DR weight.
    for step in "75 25" "25 75" "0 100"; do
      read -r p d <<<"${step}"
      apply_weights "${p}" "${d}"
      log "Sleeping ${STEP_DELAY_SECONDS}s before next step"
      sleep "${STEP_DELAY_SECONDS}"
      log "Health check after step: dr=$(probe "${DR_ALB}")"
    done
    ;;
  *)
    log "ERROR: unknown MODE='${MODE}' (expected progressive | emergency)"
    exit 1
    ;;
esac

echo
log "Cutover complete. DR region is serving traffic."
log "Verify customer paths:"
log "  curl https://${RECORD_NAME}/healthz"
log "  curl 'https://${RECORD_NAME}/data?key=T1'"
log "Failback: re-run with primary=100, dr=0 once primary region recovers"
log "and a Velero backup from DR has been restored to primary."
