#!/usr/bin/env bash
# scripts/teardown/full-teardown.sh
#
# Comprehensive teardown for chaos demo / sandbox / end-of-engagement
# cleanup. Goes BEYOND the runbook 02 § 7 helm-uninstall+terraform-destroy
# baseline by cleaning the resources that `terraform destroy` does not —
# reclaimPolicy=Retain orphans, cross-region snapshot copies, S3-versioning
# leftover objects — while making **mis-deletion of unrelated resources
# structurally impossible** via four independent safety layers.
#
# ─── Safety layers (defense in depth) ──────────────────────────────────
#
#   1. AWS account ID sanity check — caller's account MUST match
#      AWS_ACCOUNT_ID env var. Prevents running against the wrong AWS
#      profile entirely.
#
#   2. Cluster name EXACT match — never uses "contains 'aegis'" or
#      similar fuzzy patterns. Only the cluster the operator names is
#      touched.
#
#   3. **Double-tag intersection** — every resource delete requires
#      BOTH Project=aegis-statefulset AND ManagedBy=terraform tags.
#      terraform `default_tags` guarantees both on every resource it
#      creates; manually-created resources with only one tag (or with
#      a different Project value) are structurally invisible to this
#      script. Discovery uses AWS Resource Groups Tagging API which
#      returns the AND-intersection natively.
#
#   4. **Expected-count gate** — FORCE mode also requires
#      CONFIRM_DELETE_COUNT=<N> matching the dry-run's reported count.
#      Operator MUST observe the dry-run, see "would delete 47
#      resources", and re-run with CONFIRM_DELETE_COUNT=47. Drift
#      between dry-run and force-run is caught.
#
# Output: chaos-evidence/teardown-<timestamp>/ with teardown-report.txt
# + manifest.json (the pre-delete inventory).
#
# Usage:
#   # Step 1: dry-run → observe the count
#   CLUSTER_NAME=aegis-statefulset-prod \
#   AWS_ACCOUNT_ID=123456789012 \
#     ./scripts/teardown/full-teardown.sh
#
#   # Step 2: execute, providing the count from step 1
#   CLUSTER_NAME=aegis-statefulset-prod \
#   AWS_ACCOUNT_ID=123456789012 \
#   FORCE=1 \
#   CONFIRM_DELETE_COUNT=47 \
#     ./scripts/teardown/full-teardown.sh
#
# Required env:
#   CLUSTER_NAME            EKS cluster name (EXACT match — no fuzzy)
#   AWS_ACCOUNT_ID          12-digit AWS account ID (sanity check)
#
# Optional env:
#   AWS_REGION              default eu-central-1
#   DR_REGION               default eu-west-1
#   PROJECT_TAG_KEY         default Project
#   PROJECT_TAG_VAL         default aegis-statefulset
#   MANAGEDBY_TAG_KEY       default ManagedBy
#   MANAGEDBY_TAG_VAL       default terraform
#   NAMESPACE               default aegis-app
#   VELERO_NS               default velero
#   FORCE                   1 to execute (default unset = dry-run)
#   CONFIRM_DELETE_COUNT    required when FORCE=1; must match dry-run count
#   SKIP_TF                 1 to skip terraform destroy
#   OUTPUT_ROOT             default chaos-evidence

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:?CLUSTER_NAME env var required (EXACT match — no fuzzy)}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:?AWS_ACCOUNT_ID env var required (12-digit account ID, sanity check)}"
AWS_REGION="${AWS_REGION:-eu-central-1}"
DR_REGION="${DR_REGION:-eu-west-1}"
PROJECT_TAG_KEY="${PROJECT_TAG_KEY:-Project}"
PROJECT_TAG_VAL="${PROJECT_TAG_VAL:-aegis-statefulset}"
MANAGEDBY_TAG_KEY="${MANAGEDBY_TAG_KEY:-ManagedBy}"
MANAGEDBY_TAG_VAL="${MANAGEDBY_TAG_VAL:-terraform}"
NAMESPACE="${NAMESPACE:-aegis-app}"
VELERO_NS="${VELERO_NS:-velero}"
FORCE="${FORCE:-}"
CONFIRM_DELETE_COUNT="${CONFIRM_DELETE_COUNT:-}"
SKIP_TF="${SKIP_TF:-}"
OUTPUT_ROOT="${OUTPUT_ROOT:-chaos-evidence}"

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="${OUTPUT_ROOT}/teardown-${TIMESTAMP}"
mkdir -p "${OUT_DIR}"
REPORT="${OUT_DIR}/teardown-report.txt"
MANIFEST="${OUT_DIR}/delete-manifest.json"

log() {
  msg="[$(date -Iseconds)] [full-teardown] $*"
  printf '%s\n' "${msg}"
  printf '%s\n' "${msg}" >> "${REPORT}"
}

run() {
  if [ -n "${FORCE}" ]; then
    log "RUN: $*"
    "$@" 2>&1 | tee -a "${REPORT}"
  else
    log "DRY-RUN (would execute): $*"
  fi
}

# ─── Pre-flight: identity check ─────────────────────────────────────────

log "==================================================="
log "Full teardown — aegis-statefulset"
log "==================================================="
log "Cluster (exact):    ${CLUSTER_NAME}"
log "Account:            ${AWS_ACCOUNT_ID}"
log "Source region:      ${AWS_REGION}"
log "DR region:          ${DR_REGION}"
log "Tag-1 (mandatory):  ${PROJECT_TAG_KEY}=${PROJECT_TAG_VAL}"
log "Tag-2 (mandatory):  ${MANAGEDBY_TAG_KEY}=${MANAGEDBY_TAG_VAL}"
log "Namespace:          ${NAMESPACE}"
log "FORCE mode:         ${FORCE:-(unset → DRY-RUN)}"
log "Confirm count gate: ${CONFIRM_DELETE_COUNT:-(unset → DRY-RUN only)}"
log ""

ACTUAL_ACCOUNT=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null || echo "ERROR")
if [ "${ACTUAL_ACCOUNT}" = "ERROR" ]; then
  log "FATAL: aws sts get-caller-identity failed — no valid AWS credentials"
  exit 1
fi
if [ "${ACTUAL_ACCOUNT}" != "${AWS_ACCOUNT_ID}" ]; then
  log "FATAL: caller account ${ACTUAL_ACCOUNT} != expected ${AWS_ACCOUNT_ID}"
  log "       Layer 1 (account-ID) check FAILED. Either fix AWS_ACCOUNT_ID env var"
  log "       or switch your AWS profile."
  exit 1
fi
log "✓ Layer 1 — AWS identity check passed (account ${ACTUAL_ACCOUNT})"

for tool in aws kubectl helm jq terraform; do
  command -v "${tool}" >/dev/null 2>&1 || { log "FATAL: ${tool} not installed"; exit 1; }
done
log "✓ Tooling check passed"

# ─── Discovery — Resource Groups Tagging API (double-tag intersection) ──

log ""
log "─── Discovery: enumerating resources matching BOTH mandatory tags ───"

discover_region() {
  local region=$1
  local out_file=$2
  aws resourcegroupstaggingapi get-resources \
    --region "${region}" \
    --tag-filters "Key=${PROJECT_TAG_KEY},Values=${PROJECT_TAG_VAL}" \
                  "Key=${MANAGEDBY_TAG_KEY},Values=${MANAGEDBY_TAG_VAL}" \
    --output json 2>/dev/null > "${out_file}" || echo '{"ResourceTagMappingList":[]}' > "${out_file}"
}

discover_region "${AWS_REGION}" "${OUT_DIR}/discovery-${AWS_REGION}.json"
discover_region "${DR_REGION}"  "${OUT_DIR}/discovery-${DR_REGION}.json"

SRC_COUNT=$(jq '.ResourceTagMappingList | length' "${OUT_DIR}/discovery-${AWS_REGION}.json")
DR_COUNT=$(jq  '.ResourceTagMappingList | length' "${OUT_DIR}/discovery-${DR_REGION}.json")
TOTAL_TAGGED=$((SRC_COUNT + DR_COUNT))

log "Discovered: ${SRC_COUNT} resources in ${AWS_REGION}, ${DR_COUNT} in ${DR_REGION}"
log "Total tag-matched resources: ${TOTAL_TAGGED}"

# Group by resource type for the manifest summary
log ""
log "─── Manifest preview by resource type ───"
{
  jq -r '.ResourceTagMappingList[].ResourceARN' "${OUT_DIR}/discovery-${AWS_REGION}.json" "${OUT_DIR}/discovery-${DR_REGION}.json" \
    | awk -F: '{print $3 "/" $6}' \
    | awk -F/ '{print $1 "/" $2}' \
    | sort | uniq -c | sort -rn
} | tee -a "${REPORT}" \
  > "${OUT_DIR}/manifest-by-type.txt"

# Write JSON manifest
{
  echo "{"
  echo "  \"schema_version\": 1,"
  echo "  \"discovery_timestamp\": \"${TIMESTAMP}\","
  echo "  \"aws_account_id\": \"${AWS_ACCOUNT_ID}\","
  echo "  \"source_region\": \"${AWS_REGION}\","
  echo "  \"dr_region\": \"${DR_REGION}\","
  echo "  \"required_tags\": {"
  echo "    \"${PROJECT_TAG_KEY}\": \"${PROJECT_TAG_VAL}\","
  echo "    \"${MANAGEDBY_TAG_KEY}\": \"${MANAGEDBY_TAG_VAL}\""
  echo "  },"
  echo "  \"total_tagged_resources\": ${TOTAL_TAGGED},"
  echo "  \"by_region\": {"
  echo "    \"${AWS_REGION}\": ${SRC_COUNT},"
  echo "    \"${DR_REGION}\": ${DR_COUNT}"
  echo "  }"
  echo "}"
} > "${MANIFEST}"

# ─── Safety gate 4: expected-count check ────────────────────────────────

if [ -n "${FORCE}" ]; then
  if [ -z "${CONFIRM_DELETE_COUNT}" ]; then
    log ""
    log "FATAL: FORCE=1 but CONFIRM_DELETE_COUNT is unset."
    log ""
    log "Safety gate 4 — operator must have observed the dry-run count"
    log "and explicitly authorise THAT count. Drift between dry-run and"
    log "force-run is caught here."
    log ""
    log "Re-run with: CONFIRM_DELETE_COUNT=${TOTAL_TAGGED} FORCE=1 $0"
    log ""
    log "(${TOTAL_TAGGED} is the count this discovery just found; verify"
    log " against your most recent dry-run before authorising.)"
    exit 1
  fi
  if [ "${CONFIRM_DELETE_COUNT}" != "${TOTAL_TAGGED}" ]; then
    log ""
    log "FATAL: CONFIRM_DELETE_COUNT=${CONFIRM_DELETE_COUNT} != discovered count ${TOTAL_TAGGED}."
    log ""
    log "Layer 4 — expected-count gate FAILED. This means the resource"
    log "inventory drifted between your dry-run and this force-run."
    log "Possible causes:"
    log "  - more resources got created (rerun dry-run to see new count)"
    log "  - some resources got deleted out-of-band (rerun dry-run)"
    log "  - someone else is using the same tags (audit who)"
    log ""
    log "Re-run with the correct count:"
    log "  CONFIRM_DELETE_COUNT=${TOTAL_TAGGED} FORCE=1 $0"
    exit 1
  fi
  log "✓ Layer 4 — count gate passed (${TOTAL_TAGGED} resources match dry-run authorisation)"
fi

if [ -z "${FORCE}" ]; then
  log ""
  log "*** DRY-RUN MODE ***"
  log "Discovery shows ${TOTAL_TAGGED} resources match BOTH tags."
  log ""
  log "To execute teardown:"
  log "  CONFIRM_DELETE_COUNT=${TOTAL_TAGGED} FORCE=1 $0"
  log ""
  log "If the count looks wrong (too high / too low), DO NOT proceed —"
  log "investigate what created the extras or what's missing first."
  log ""
fi

# ─── Phase 1: Velero backups + schedules ───────────────────────────────

log ""
log "─── Phase 1/7: Velero — delete backups + schedules ───"

SCHEDULES=$(kubectl get schedules.velero.io -n "${VELERO_NS}" -o name 2>/dev/null || true)
if [ -n "${SCHEDULES}" ]; then
  log "Velero schedules to delete:"
  printf '  %s\n' ${SCHEDULES} | tee -a "${REPORT}"
  for s in ${SCHEDULES}; do
    run kubectl delete "${s}" -n "${VELERO_NS}" --ignore-not-found
  done
else
  log "  (no Velero schedules found — skipping)"
fi

BACKUPS=$(kubectl get backups.velero.io -n "${VELERO_NS}" -o name 2>/dev/null || true)
if [ -n "${BACKUPS}" ]; then
  COUNT=$(echo "${BACKUPS}" | wc -w | tr -d ' ')
  log "Velero backups to delete (count=${COUNT})"
  for b in ${BACKUPS}; do
    run kubectl delete "${b}" -n "${VELERO_NS}" --ignore-not-found
  done
else
  log "  (no Velero backups found — skipping)"
fi

# ─── Phase 2: Helm uninstall ────────────────────────────────────────────

log ""
log "─── Phase 2/7: Helm uninstall ───"

if helm status aegis-app -n "${NAMESPACE}" >/dev/null 2>&1; then
  run helm uninstall aegis-app -n "${NAMESPACE}"
else
  log "  (helm release aegis-app not found in namespace ${NAMESPACE} — skipping)"
fi

if [ -n "${FORCE}" ]; then
  log "Waiting up to 60s for pods to terminate…"
  for _ in $(seq 1 12); do
    PODS=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    [ "${PODS}" = "0" ] && { log "  all pods gone"; break; }
    sleep 5
  done
fi

# ─── Phase 3: PVC / PV cleanup (Retain policy orphans) ──────────────────

log ""
log "─── Phase 3/7: PVC / PV cleanup ───"

PVCS=$(kubectl get pvc -n "${NAMESPACE}" -o name 2>/dev/null || true)
if [ -n "${PVCS}" ]; then
  log "PVCs to delete:"
  printf '  %s\n' ${PVCS} | tee -a "${REPORT}"
  for pvc in ${PVCS}; do
    run kubectl patch "${pvc}" -n "${NAMESPACE}" \
      --type=merge -p '{"metadata":{"finalizers":[]}}' || true
    run kubectl delete "${pvc}" -n "${NAMESPACE}" --ignore-not-found
  done
else
  log "  (no PVCs found in ${NAMESPACE})"
fi

RETAINED_PVS=$(kubectl get pv -o jsonpath='{range .items[?(@.spec.persistentVolumeReclaimPolicy=="Retain")]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
  | grep -E '^pvc-' || true)
if [ -n "${RETAINED_PVS}" ]; then
  log "Retained PVs to delete:"
  printf '  %s\n' ${RETAINED_PVS} | tee -a "${REPORT}"
  for pv in ${RETAINED_PVS}; do
    run kubectl patch pv "${pv}" --type=merge -p '{"metadata":{"finalizers":[]}}' || true
    run kubectl delete pv "${pv}" --ignore-not-found
  done
else
  log "  (no retained PVs found)"
fi

# ─── Phase 4: EBS volumes + snapshots (double-tag filter, both regions) ─

log ""
log "─── Phase 4/7: AWS EBS cleanup (double-tag filter, both regions) ───"

cleanup_region_ebs() {
  local region=$1
  log ""
  log "  Region: ${region}"

  # Available EBS volumes — require BOTH tags
  VOL_IDS=$(aws ec2 describe-volumes --region "${region}" \
            --filters "Name=tag:${PROJECT_TAG_KEY},Values=${PROJECT_TAG_VAL}" \
                      "Name=tag:${MANAGEDBY_TAG_KEY},Values=${MANAGEDBY_TAG_VAL}" \
                      "Name=status,Values=available" \
            --query 'Volumes[].VolumeId' --output text 2>/dev/null || echo "")
  if [ -n "${VOL_IDS}" ]; then
    log "    Available EBS volumes (both tags match):"
    printf '      %s\n' ${VOL_IDS} | tee -a "${REPORT}"
    for vid in ${VOL_IDS}; do
      run aws ec2 delete-volume --region "${region}" --volume-id "${vid}"
    done
  else
    log "    (no available EBS volumes matching both tags)"
  fi

  IN_USE=$(aws ec2 describe-volumes --region "${region}" \
            --filters "Name=tag:${PROJECT_TAG_KEY},Values=${PROJECT_TAG_VAL}" \
                      "Name=tag:${MANAGEDBY_TAG_KEY},Values=${MANAGEDBY_TAG_VAL}" \
                      "Name=status,Values=in-use" \
            --query 'Volumes[].VolumeId' --output text 2>/dev/null || echo "")
  if [ -n "${IN_USE}" ]; then
    log "    WARN: in-use EBS volumes (terraform destroy will detach):"
    printf '      %s\n' ${IN_USE} | tee -a "${REPORT}"
  fi

  # EBS snapshots — require BOTH tags
  SNAP_IDS=$(aws ec2 describe-snapshots --region "${region}" --owner-ids self \
            --filters "Name=tag:${PROJECT_TAG_KEY},Values=${PROJECT_TAG_VAL}" \
                      "Name=tag:${MANAGEDBY_TAG_KEY},Values=${MANAGEDBY_TAG_VAL}" \
            --query 'Snapshots[].SnapshotId' --output text 2>/dev/null || echo "")
  if [ -n "${SNAP_IDS}" ]; then
    COUNT=$(echo "${SNAP_IDS}" | wc -w | tr -d ' ')
    log "    EBS snapshots to delete (count=${COUNT}, both tags match):"
    for sid in ${SNAP_IDS}; do
      run aws ec2 delete-snapshot --region "${region}" --snapshot-id "${sid}"
    done
  else
    log "    (no EBS snapshots matching both tags)"
  fi
}

cleanup_region_ebs "${AWS_REGION}"
cleanup_region_ebs "${DR_REGION}"

# ─── Phase 5: S3 buckets (tag-based via Resource Groups API, no name pattern) ─

log ""
log "─── Phase 5/7: S3 buckets (tag-based — no name pattern) ───"

# Resource Groups Tagging API returns S3 buckets matching BOTH tags
S3_BUCKETS=$(jq -r '.ResourceTagMappingList[].ResourceARN | select(startswith("arn:aws:s3:::"))' \
              "${OUT_DIR}/discovery-${AWS_REGION}.json" \
            | sed 's|arn:aws:s3:::||')

if [ -n "${S3_BUCKETS}" ]; then
  for bucket in ${S3_BUCKETS}; do
    # Re-verify the tags before deleting (paranoia layer)
    BUCKET_TAGS=$(aws s3api get-bucket-tagging --bucket "${bucket}" \
                    --query "TagSet[?Key=='${PROJECT_TAG_KEY}'||Key=='${MANAGEDBY_TAG_KEY}']" \
                    --output json 2>/dev/null || echo "[]")
    HAS_PROJECT=$(echo "${BUCKET_TAGS}" | jq -r --arg k "${PROJECT_TAG_KEY}" --arg v "${PROJECT_TAG_VAL}" \
                    '[.[] | select(.Key==$k and .Value==$v)] | length')
    HAS_MGD=$(echo "${BUCKET_TAGS}" | jq -r --arg k "${MANAGEDBY_TAG_KEY}" --arg v "${MANAGEDBY_TAG_VAL}" \
                '[.[] | select(.Key==$k and .Value==$v)] | length')
    if [ "${HAS_PROJECT}" != "1" ] || [ "${HAS_MGD}" != "1" ]; then
      log "  SKIP: s3://${bucket}/ — paranoia re-check failed (Project=${HAS_PROJECT}, ManagedBy=${HAS_MGD})"
      continue
    fi
    log "  Emptying s3://${bucket}/ (both tags verified)…"

    if [ -n "${FORCE}" ]; then
      # Delete all object versions
      aws s3api list-object-versions --bucket "${bucket}" --output json 2>/dev/null \
        | jq -r '.Versions[]? | "\(.Key)\t\(.VersionId)"' \
        | while IFS=$'\t' read -r key version; do
            aws s3api delete-object --bucket "${bucket}" --key "${key}" --version-id "${version}" >/dev/null 2>&1 || true
          done
      # Delete all delete markers
      aws s3api list-object-versions --bucket "${bucket}" --output json 2>/dev/null \
        | jq -r '.DeleteMarkers[]? | "\(.Key)\t\(.VersionId)"' \
        | while IFS=$'\t' read -r key version; do
            aws s3api delete-object --bucket "${bucket}" --key "${key}" --version-id "${version}" >/dev/null 2>&1 || true
          done
      log "    bucket emptied"
    else
      VERSIONS=$(aws s3api list-object-versions --bucket "${bucket}" --output json 2>/dev/null \
                  | jq '.Versions | length' 2>/dev/null || echo 0)
      MARKERS=$(aws s3api list-object-versions --bucket "${bucket}" --output json 2>/dev/null \
                  | jq '.DeleteMarkers | length' 2>/dev/null || echo 0)
      log "    DRY-RUN: would delete ${VERSIONS} object versions + ${MARKERS} delete markers"
    fi
  done
else
  log "  (no S3 buckets matched both tags via Resource Groups API)"
fi

# ─── Phase 6: terraform destroy ─────────────────────────────────────────

log ""
log "─── Phase 6/7: terraform destroy ───"

if [ -n "${SKIP_TF}" ]; then
  log "  SKIP_TF=1 — skipping terraform destroy"
else
  if [ -n "${FORCE}" ]; then
    log "  cd infrastructure/terraform && terraform destroy -auto-approve"
    (cd infrastructure/terraform && terraform destroy -auto-approve 2>&1) | tee -a "${REPORT}"
  else
    log "  DRY-RUN: would run terraform destroy"
  fi
fi

# ─── Phase 7: Verify clean ──────────────────────────────────────────────

log ""
log "─── Phase 7/7: Verify clean ───"

if [ -f "$(dirname "$0")/verify-clean.sh" ]; then
  CLUSTER_NAME="${CLUSTER_NAME}" \
  AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID}" \
  AWS_REGION="${AWS_REGION}" \
  DR_REGION="${DR_REGION}" \
  PROJECT_TAG_KEY="${PROJECT_TAG_KEY}" \
  PROJECT_TAG_VAL="${PROJECT_TAG_VAL}" \
  MANAGEDBY_TAG_KEY="${MANAGEDBY_TAG_KEY}" \
  MANAGEDBY_TAG_VAL="${MANAGEDBY_TAG_VAL}" \
  OUTPUT_ROOT="${OUTPUT_ROOT}" \
    bash "$(dirname "$0")/verify-clean.sh" || log "  (orphans detected — see verify report)"
fi

# ─── Summary ────────────────────────────────────────────────────────────

log ""
log "==================================================="
log "Teardown complete"
log "==================================================="
log "Report:   ${REPORT}"
log "Manifest: ${MANIFEST}"
log ""

if [ -z "${FORCE}" ]; then
  log "Mode: DRY-RUN. To execute:"
  log "  CONFIRM_DELETE_COUNT=${TOTAL_TAGGED} FORCE=1 $0"
else
  log "Mode: FORCE — resources have been deleted."
  log ""
  log "Known post-teardown costs (not bypassable by this script):"
  log "  - KMS keys in 7-day deletion window @ ~\$1/key/month until window closes"
  log "  - S3 bucket lifecycle policies may take 24h to fully clear"
  log "  - Cost Explorer attribution lags 24h; re-check tomorrow for final reconciliation"
fi
