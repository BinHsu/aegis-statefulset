#!/usr/bin/env bash
# scripts/chaos/capture-cloudwatch-evidence.sh
#
# After a chaos-demo run, capture AWS-native observability evidence from
# CloudWatch into docs/evidence/. Complements the in-cluster chaos log
# (which proves K8s/CSI behaviour) by capturing the AWS-layer view:
# EBS volume IO, EKS control-plane metrics, DynamoDB placement table
# activity, and a configurable window of audit-log API events.
#
# Why bash-with-AWS-CLI instead of Python:
#   - Same dependencies as the chaos demo script — no new toolchain.
#   - Each `aws cloudwatch get-metric-statistics` call writes its own
#     JSON file; downstream analysis (anomaly review, MTTR
#     calculations) can consume them directly without parsing
#     intermediate Python output.
#
# Env-var overrides (all optional):
#   AWS_PROFILE       — AWS profile with read on the workload account
#                       (default: aegis-staging-admin)
#   AWS_REGION        — region of the cluster (default: eu-central-1)
#   CLUSTER           — EKS cluster name
#                       (default: aegis-statefulset-staging)
#   NAMESPACE         — K8s namespace of the stateful workload
#                       (default: aegis-app)
#   POD_NAME          — pod whose PVs to capture EBS metrics for
#                       (default: aegis-aegis-statefulset-primary-0)
#   PLACEMENT_TABLE   — DynamoDB placement table name
#                       (default: aegis-statefulset-placement-staging)
#   WINDOW_START      — ISO-8601 UTC start of the capture window
#                       (default: 30 min before now)
#   WINDOW_END        — ISO-8601 UTC end of the capture window
#                       (default: now)
#   OUT_DIR           — where to write JSON evidence files
#                       (default: docs/evidence/cloudwatch/)
#   PERIOD_SECONDS    — metric granularity in seconds (default: 60 = 1 min)

set -euo pipefail

# AWS_PROFILE + AWS_REGION are exported so child processes (kubectl's
# exec plugin → `aws eks get-token`, aws CLI) inherit them. Without
# the export, kubectl ends up calling `aws` with no credentials.
export AWS_PROFILE="${AWS_PROFILE:-aegis-staging-admin}"
export AWS_REGION="${AWS_REGION:-eu-central-1}"
CLUSTER="${CLUSTER:-aegis-statefulset-staging}"
NAMESPACE="${NAMESPACE:-aegis-app}"
POD_NAME="${POD_NAME:-aegis-aegis-statefulset-primary-0}"
PLACEMENT_TABLE="${PLACEMENT_TABLE:-aegis-statefulset-placement-staging}"
PERIOD_SECONDS="${PERIOD_SECONDS:-60}"

# Default window: 30 min ending now (chaos demo typically completes
# inside 5 min; 30 min gives context before + after).
if [[ -z "${WINDOW_END:-}" ]]; then
  WINDOW_END=$(date -u +%Y-%m-%dT%H:%M:%SZ)
fi
if [[ -z "${WINDOW_START:-}" ]]; then
  WINDOW_START=$(date -u -v-30M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
              || date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/docs/evidence/cloudwatch}"
mkdir -p "$OUT_DIR"

heading() { echo; echo "=== $* ==="; }

heading "Capture metadata"
echo "Timestamp:        $(date -Iseconds)"
echo "AWS profile:      $AWS_PROFILE"
echo "AWS region:       $AWS_REGION"
echo "Cluster:          $CLUSTER"
echo "Namespace:        $NAMESPACE"
echo "Pod:              $POD_NAME"
echo "Placement table:  $PLACEMENT_TABLE"
echo "Window:           $WINDOW_START → $WINDOW_END"
echo "Period:           ${PERIOD_SECONDS}s"
echo "Output dir:       $OUT_DIR"

# Sanity: identity check
heading "Identity check"
aws sts get-caller-identity --profile "$AWS_PROFILE" --output json \
  | tee "$OUT_DIR/00-caller-identity.json"

# ---------------------------------------------------------------------
# Step 1 — resolve PVCs → PV names → EBS volume IDs
# Parallel arrays (instead of associative arrays — macOS bash 3.2 compat).
#
# Two resolution paths:
#   1. Preferred: kubectl current-context, using the EBS CSI driver's
#      `volumeHandle` field which is the EBS volume ID.
#   2. Fallback: AWS EC2 describe-volumes filtered by the cluster's
#      ownership tag, then matched by PV name in the
#      `kubernetes.io/created-for/pv/name` tag. Used when the caller
#      has AWS read access but is not in the cluster aws-auth /
#      AccessEntry list (e.g. SSO PlatformAdmin reading from a CI
#      runner that hasn't been granted cluster-RBAC).
# ---------------------------------------------------------------------
heading "Resolving PVs → EBS volume IDs"
PVC_NAMES=()
VOL_IDS=()

# Try kubectl first
KUBECTL_PROBE=$(kubectl get pvc -n "$NAMESPACE" \
  -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

if [[ -n "$KUBECTL_PROBE" ]]; then
  echo "  Path: kubectl (current-context $(kubectl config current-context))"
  for pvc in "data-${POD_NAME}" "wal-${POD_NAME}"; do
    pv_name=$(kubectl get pvc -n "$NAMESPACE" "$pvc" \
              -o jsonpath='{.spec.volumeName}' 2>/dev/null || echo "")
    if [[ -z "$pv_name" ]]; then
      echo "    $pvc → (PVC not found, skipping)"
      continue
    fi
    vol_id=$(kubectl get pv "$pv_name" \
             -o jsonpath='{.spec.csi.volumeHandle}' 2>/dev/null || echo "")
    echo "    $pvc → PV $pv_name → EBS $vol_id"
    PVC_NAMES+=("$pvc")
    VOL_IDS+=("$vol_id")
  done
else
  echo "  Path: kubectl unavailable → AWS EC2 describe-volumes fallback"
  echo "  (the caller is reading AWS APIs but is not in the cluster RBAC;"
  echo "   common when a CI principal captures evidence post-incident)"

  # AWS DescribeVolumes JSON: each Volume has Tags. We match by:
  #   - cluster ownership tag: kubernetes.io/cluster/<cluster>=owned
  #   - PV name tag:           kubernetes.io/created-for/pv/name=<pv>
  for pvc in "data-${POD_NAME}" "wal-${POD_NAME}"; do
    vol_id=$(aws ec2 describe-volumes \
      --region "$AWS_REGION" \
      --filters "Name=tag:kubernetes.io/cluster/${CLUSTER},Values=owned" \
                "Name=tag:kubernetes.io/created-for/pvc/name,Values=$pvc" \
      --query 'Volumes[0].VolumeId' --output text 2>/dev/null || echo "")
    if [[ -z "$vol_id" || "$vol_id" == "None" ]]; then
      echo "    $pvc → (no EBS volume tagged for this PVC, skipping)"
      continue
    fi
    echo "    $pvc → EBS $vol_id (via tags)"
    PVC_NAMES+=("$pvc")
    VOL_IDS+=("$vol_id")
  done
fi

# ---------------------------------------------------------------------
# Step 2 — EBS metrics per volume
# ---------------------------------------------------------------------
heading "EBS metrics (per-volume IO over the capture window)"
EBS_METRICS=(
  VolumeWriteBytes
  VolumeReadBytes
  VolumeWriteOps
  VolumeReadOps
  VolumeQueueLength
  VolumeIdleTime
)
for i in "${!PVC_NAMES[@]}"; do
  pvc="${PVC_NAMES[$i]}"
  vol_id="${VOL_IDS[$i]}"
  [[ -z "$vol_id" ]] && continue
  for metric in "${EBS_METRICS[@]}"; do
    outfile="$OUT_DIR/ebs-${pvc}-${metric}.json"
    aws cloudwatch get-metric-statistics \
      --profile "$AWS_PROFILE" --region "$AWS_REGION" \
      --namespace AWS/EBS --metric-name "$metric" \
      --dimensions "Name=VolumeId,Value=$vol_id" \
      --start-time "$WINDOW_START" --end-time "$WINDOW_END" \
      --period "$PERIOD_SECONDS" \
      --statistics Sum Average Maximum \
      --output json > "$outfile" || true
    datapoints=$(grep -c '"Timestamp"' "$outfile" 2>/dev/null || echo 0)
    echo "  $pvc / $metric → $datapoints datapoints → $(basename "$outfile")"
  done
done

# ---------------------------------------------------------------------
# Step 3 — EKS control-plane metrics
# ---------------------------------------------------------------------
heading "EKS control-plane metrics"
# Documented namespace varies: AWS/EKS for cluster-level health,
# ContainerInsights for richer metrics (only when Container Insights
# addon is enabled). Probe both.
for ns in AWS/EKS ContainerInsights; do
  outfile="$OUT_DIR/eks-control-plane-list-${ns//\//-}.json"
  aws cloudwatch list-metrics --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --namespace "$ns" --dimensions "Name=ClusterName,Value=$CLUSTER" \
    --output json > "$outfile" 2>/dev/null || echo "{\"Metrics\":[]}" > "$outfile"
  count=$(grep -c '"MetricName"' "$outfile" || echo 0)
  echo "  namespace $ns → $count metrics emitted → $(basename "$outfile")"
done

# ---------------------------------------------------------------------
# Step 4 — DynamoDB placement table metrics
# ---------------------------------------------------------------------
heading "DynamoDB placement table metrics"
DDB_METRICS=(
  ConsumedReadCapacityUnits
  ConsumedWriteCapacityUnits
  ProvisionedReadCapacityUnits
  SuccessfulRequestLatency
)
for metric in "${DDB_METRICS[@]}"; do
  outfile="$OUT_DIR/dynamodb-${PLACEMENT_TABLE}-${metric}.json"
  aws cloudwatch get-metric-statistics \
    --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --namespace AWS/DynamoDB --metric-name "$metric" \
    --dimensions "Name=TableName,Value=$PLACEMENT_TABLE" \
    --start-time "$WINDOW_START" --end-time "$WINDOW_END" \
    --period "$PERIOD_SECONDS" \
    --statistics Sum Average Maximum \
    --output json > "$outfile" || true
  datapoints=$(grep -c '"Timestamp"' "$outfile" 2>/dev/null || echo 0)
  echo "  $metric → $datapoints datapoints → $(basename "$outfile")"
done

# ---------------------------------------------------------------------
# Step 5 — EKS audit log: pod delete events in the namespace
# ---------------------------------------------------------------------
heading "EKS audit log — pod delete events"
START_MS=$(($(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$WINDOW_START" +%s 2>/dev/null \
            || date -u -d "$WINDOW_START" +%s) * 1000))
END_MS=$(($(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$WINDOW_END" +%s 2>/dev/null \
            || date -u -d "$WINDOW_END" +%s) * 1000))

LOG_GROUP="/aws/eks/$CLUSTER/cluster"
FILTER='{ $.verb = "delete" && $.objectRef.resource = "pods" && $.objectRef.namespace = "'$NAMESPACE'" }'

audit_out="$OUT_DIR/eks-audit-pod-delete.json"
aws logs filter-log-events \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  --log-group-name "$LOG_GROUP" \
  --start-time "$START_MS" --end-time "$END_MS" \
  --filter-pattern "$FILTER" \
  --output json > "$audit_out" 2>/dev/null || {
  echo "  filter-log-events failed (control-plane audit log may not be enabled)"
  echo "{}" > "$audit_out"
}
event_count=$(grep -c '"eventId"' "$audit_out" || echo 0)
echo "  pod-delete events in window → $event_count → $(basename "$audit_out")"

# ---------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------
heading "SUMMARY"
echo "Capture window: $WINDOW_START → $WINDOW_END (period ${PERIOD_SECONDS}s)"
echo "Files written:"
ls -la "$OUT_DIR/" | awk 'NR>1 && /\.json$/ {printf "  %s  %s\n", $5, $9}'
echo ""
echo "✅ CloudWatch evidence capture complete."
echo "   Pair with /tmp/chaos-stateful-pod-kill-*.log (in-cluster evidence)"
echo "   and docs/evidence/grafana-*.png (Grafana stack evidence)."
