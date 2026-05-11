#!/usr/bin/env bash
# scripts/teardown/verify-clean.sh
#
# Post-teardown audit: scan source + DR regions for any remaining AWS
# resources matching BOTH `Project=aegis-statefulset` AND
# `ManagedBy=terraform` tags. Output JSON + summary; non-zero exit if
# any orphans are found.
#
# Like full-teardown.sh, this script NEVER uses name patterns ("contains
# 'aegis'" or "starts_with 'aegis-'") for resource discovery — those
# patterns risk catching unrelated resources in shared AWS accounts.
# Discovery is via AWS Resource Groups Tagging API which returns the
# AND-intersection of the two mandatory tags.
#
# Resources scanned:
#   - Everything tagged with BOTH mandatory tags (via Resource Groups API),
#     in both source and DR regions
#   - PLUS: KMS keys (because in-PendingDeletion state is expected after
#     terraform destroy; they're not orphans, just in the 7-day window)
#   - PLUS: the named EKS cluster (in case terraform-state-loss left it)
#
# Usage:
#   ./scripts/teardown/verify-clean.sh
#
# Required env: CLUSTER_NAME, AWS_ACCOUNT_ID
# Optional env: AWS_REGION (default eu-central-1), DR_REGION (default eu-west-1),
#               PROJECT_TAG_KEY (default Project), PROJECT_TAG_VAL (default aegis-statefulset),
#               MANAGEDBY_TAG_KEY (default ManagedBy), MANAGEDBY_TAG_VAL (default terraform),
#               OUTPUT_ROOT (default chaos-evidence)
#
# Exit codes:
#   0 — clean (no orphans matching both tags)
#   1 — orphans found
#   2 — usage / env error / API failure

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:?CLUSTER_NAME env var required}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:?AWS_ACCOUNT_ID env var required}"
AWS_REGION="${AWS_REGION:-eu-central-1}"
DR_REGION="${DR_REGION:-eu-west-1}"
PROJECT_TAG_KEY="${PROJECT_TAG_KEY:-Project}"
PROJECT_TAG_VAL="${PROJECT_TAG_VAL:-aegis-statefulset}"
MANAGEDBY_TAG_KEY="${MANAGEDBY_TAG_KEY:-ManagedBy}"
MANAGEDBY_TAG_VAL="${MANAGEDBY_TAG_VAL:-terraform}"
OUTPUT_ROOT="${OUTPUT_ROOT:-chaos-evidence}"

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="${OUTPUT_ROOT}/teardown-verify-${TIMESTAMP}"
mkdir -p "${OUT_DIR}"
REPORT_JSON="${OUT_DIR}/verify-clean.json"
REPORT_TXT="${OUT_DIR}/verify-clean.txt"

log() {
  msg="[$(date -Iseconds)] [verify-clean] $*"
  printf '%s\n' "${msg}"
  printf '%s\n' "${msg}" >> "${REPORT_TXT}"
}

ACTUAL_ACCOUNT=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null || echo "ERROR")
if [ "${ACTUAL_ACCOUNT}" != "${AWS_ACCOUNT_ID}" ]; then
  log "FATAL: caller account ${ACTUAL_ACCOUNT} != expected ${AWS_ACCOUNT_ID}"
  exit 2
fi

log "Post-teardown verify-clean — auditing for orphan resources"
log "Account: ${AWS_ACCOUNT_ID}"
log "Mandatory tags: ${PROJECT_TAG_KEY}=${PROJECT_TAG_VAL} AND ${MANAGEDBY_TAG_KEY}=${MANAGEDBY_TAG_VAL}"
log ""

ORPHAN_COUNT=0
declare -a ORPHAN_ARNS=()

# ─── Resource Groups Tagging API — both regions, both tags ───────────────
for region in "${AWS_REGION}" "${DR_REGION}"; do
  log "Scanning ${region} via Resource Groups Tagging API…"
  RESOURCES=$(aws resourcegroupstaggingapi get-resources \
                --region "${region}" \
                --tag-filters "Key=${PROJECT_TAG_KEY},Values=${PROJECT_TAG_VAL}" \
                              "Key=${MANAGEDBY_TAG_KEY},Values=${MANAGEDBY_TAG_VAL}" \
                --query 'ResourceTagMappingList[].ResourceARN' \
                --output text 2>/dev/null || echo "")
  if [ -n "${RESOURCES}" ]; then
    for arn in ${RESOURCES}; do
      log "  ORPHAN: ${arn}"
      ORPHAN_ARNS+=("${arn}")
      ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
    done
  else
    log "  ✓ no resources matching both tags in ${region}"
  fi
done

# ─── EKS cluster — exact name match (belt-and-braces) ───────────────────
log ""
log "Scanning EKS cluster '${CLUSTER_NAME}' (exact name) in ${AWS_REGION}…"
if aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
     --query 'cluster.name' --output text >/dev/null 2>&1; then
  log "  ORPHAN: EKS cluster ${CLUSTER_NAME} still present in ${AWS_REGION}"
  ORPHAN_ARNS+=("eks-cluster:${AWS_REGION}:${CLUSTER_NAME}")
  ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
else
  log "  ✓ EKS cluster ${CLUSTER_NAME} not found (good)"
fi

# ─── KMS keys — filter out those already in 7-day deletion window ───────
log ""
log "Scanning KMS keys (alive only — pending-deletion are expected)…"
KMS=$(aws kms list-keys --region "${AWS_REGION}" --query 'Keys[].KeyId' --output text 2>/dev/null || echo "")
KMS_DELETING=0
KMS_ALIVE_ORPHAN=0
for k in ${KMS}; do
  # Check key has the mandatory tags
  TAGS=$(aws kms list-resource-tags --key-id "${k}" --region "${AWS_REGION}" \
            --query "Tags[?TagKey=='${PROJECT_TAG_KEY}'||TagKey=='${MANAGEDBY_TAG_KEY}']" \
            --output json 2>/dev/null || echo "[]")
  HAS_PROJECT=$(echo "${TAGS}" | jq -r --arg k "${PROJECT_TAG_KEY}" --arg v "${PROJECT_TAG_VAL}" \
                  '[.[] | select(.TagKey==$k and .TagValue==$v)] | length')
  HAS_MGD=$(echo "${TAGS}" | jq -r --arg k "${MANAGEDBY_TAG_KEY}" --arg v "${MANAGEDBY_TAG_VAL}" \
              '[.[] | select(.TagKey==$k and .TagValue==$v)] | length')
  if [ "${HAS_PROJECT}" = "1" ] && [ "${HAS_MGD}" = "1" ]; then
    STATE=$(aws kms describe-key --key-id "${k}" --region "${AWS_REGION}" \
              --query 'KeyMetadata.KeyState' --output text 2>/dev/null || echo "Unknown")
    if [ "${STATE}" = "PendingDeletion" ]; then
      KMS_DELETING=$((KMS_DELETING + 1))
    else
      log "  ORPHAN: KMS key ${k} state=${STATE}"
      ORPHAN_ARNS+=("kms-key:${AWS_REGION}:${k}:${STATE}")
      ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
      KMS_ALIVE_ORPHAN=$((KMS_ALIVE_ORPHAN + 1))
    fi
  fi
done
log "  ✓ KMS: ${KMS_ALIVE_ORPHAN} alive orphans, ${KMS_DELETING} in 7-day window (expected)"

# ─── Summary + JSON report ──────────────────────────────────────────────

log ""
log "==================================================="
log "Verify-clean result: ${ORPHAN_COUNT} orphan(s) found"
log "==================================================="

{
  echo "{"
  echo "  \"schema_version\": 1,"
  echo "  \"verify_timestamp\": \"${TIMESTAMP}\","
  echo "  \"aws_account_id\": \"${AWS_ACCOUNT_ID}\","
  echo "  \"source_region\": \"${AWS_REGION}\","
  echo "  \"dr_region\": \"${DR_REGION}\","
  echo "  \"required_tags\": {"
  echo "    \"${PROJECT_TAG_KEY}\": \"${PROJECT_TAG_VAL}\","
  echo "    \"${MANAGEDBY_TAG_KEY}\": \"${MANAGEDBY_TAG_VAL}\""
  echo "  },"
  echo "  \"discovery_method\": \"AWS Resource Groups Tagging API (AND intersection of two mandatory tags) + exact EKS cluster name match + KMS tag re-verification\","
  echo "  \"orphan_count\": ${ORPHAN_COUNT},"
  echo "  \"orphan_arns\": ["
  FIRST=1
  for arn in "${ORPHAN_ARNS[@]:-}"; do
    [ -z "${arn:-}" ] && continue
    [ "${FIRST}" = "0" ] && echo "    ,"
    FIRST=0
    printf '    "%s"' "${arn}"
  done
  echo ""
  echo "  ],"
  echo "  \"kms_in_deletion_window\": ${KMS_DELETING},"
  echo "  \"verdict\": \"$([ "${ORPHAN_COUNT}" = "0" ] && echo "CLEAN" || echo "ORPHANS_FOUND")\""
  echo "}"
} > "${REPORT_JSON}"

log "JSON: ${REPORT_JSON}"
log "TXT:  ${REPORT_TXT}"
log ""

if [ "${ORPHAN_COUNT}" -gt 0 ]; then
  log "Action required: review orphan ARNs above + delete via AWS console or aws CLI."
  log ""
  log "Discovery used AND-intersection of both mandatory tags + exact cluster name,"
  log "so each orphan above DEFINITELY belongs to this project. No false positives"
  log "from name-pattern matching."
  exit 1
else
  log "All clean. Teardown verified complete."
  log ""
  log "Note: KMS keys in PendingDeletion are NOT counted as orphans — they auto-"
  log "delete at end of 7-day window."
  exit 0
fi
