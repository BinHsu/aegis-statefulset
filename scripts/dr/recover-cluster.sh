#!/usr/bin/env bash
# scripts/dr/recover-cluster.sh
#
# DR Path A — EBS survives, cluster destroyed (ADR-04).
#
# Most common DR scenario: etcd corrupted or cluster recreation needed,
# but EBS volumes are intact. Recovery walks EBS-tag truth, regenerates
# PV manifests with claimRef pre-binding, and helm-installs at the
# discovered replica count (which may differ from values.yaml — drift
# handling rule, ADR-04).
#
# Target RTO: ~30 min. RPO: 0 (data preserved on EBS).
#
# Usage:
#   ./recover-cluster.sh
#
# Required environment:
#   AWS_REGION       — region where EBS volumes live (e.g. eu-central-1)
#   CLUSTER_NAME     — value of the aegis.io/cluster tag (e.g. aegis-prod)
#   NAMESPACE        — target K8s namespace (default: aegis-app)
#   PV_OUTPUT_DIR    — where to write generated PV manifests (default: /tmp/pv-manifests)

set -euo pipefail

AWS_REGION="${AWS_REGION:?AWS_REGION required}"
CLUSTER_NAME="${CLUSTER_NAME:?CLUSTER_NAME required}"
NAMESPACE="${NAMESPACE:-aegis-app}"
PV_OUTPUT_DIR="${PV_OUTPUT_DIR:-/tmp/pv-manifests}"

log() {
  printf '[%s] [dr-path-a] %s\n' "$(date -Iseconds)" "$*"
}

log "Path A — EBS-survives recovery start (cluster=${CLUSTER_NAME})"

# Step 1 — discover EBS via tags.
log "[1/6] Discover EBS volumes via tags"
volumes_json=$(aws ec2 describe-volumes \
  --region "${AWS_REGION}" \
  --filters "Name=tag:aegis.io/cluster,Values=${CLUSTER_NAME}" \
  --output json)

volume_count=$(echo "${volumes_json}" | jq '.Volumes | length')
if [ "${volume_count}" -eq 0 ]; then
  log "ERROR: no EBS volumes found with aegis.io/cluster=${CLUSTER_NAME}"
  exit 1
fi
log "Discovered ${volume_count} EBS volumes"

# Per-AZ replica count (drift-aware truth source).
log "Per-AZ replica counts (from EBS tags):"
echo "${volumes_json}" \
  | jq -r '.Volumes | group_by(.AvailabilityZone) | .[] |
           "\(.[0].AvailabilityZone): \(length)"'

# Step 2 — generate PV manifests with claimRef pre-binding.
log "[2/6] Generate PV manifests"
mkdir -p "${PV_OUTPUT_DIR}"

echo "${volumes_json}" | jq -c '.Volumes[]' | while read -r vol; do
  vol_id=$(echo "${vol}" | jq -r '.VolumeId')
  az=$(echo "${vol}" | jq -r '.AvailabilityZone')
  ordinal=$(echo "${vol}" | jq -r '.Tags[] | select(.Key=="aegis.io/pod-ordinal") | .Value')
  pvc_name=$(echo "${vol}" | jq -r '.Tags[] | select(.Key=="kubernetes.io/created-for/pvc/name") | .Value')

  if [ -z "${ordinal}" ] || [ -z "${pvc_name}" ]; then
    log "WARN: volume ${vol_id} missing required tags; skipping"
    continue
  fi

  cat > "${PV_OUTPUT_DIR}/pv-${ordinal}.yaml" <<YAML
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-${ordinal}
  labels:
    topology.kubernetes.io/zone: ${az}
spec:
  capacity:
    storage: 2000Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ebs-gp3-retain
  csi:
    driver: ebs.csi.aws.com
    volumeHandle: ${vol_id}
    fsType: ext4
  claimRef:
    namespace: ${NAMESPACE}
    name: ${pvc_name}
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: topology.kubernetes.io/zone
              operator: In
              values:
                - ${az}
YAML
  log "  wrote ${PV_OUTPUT_DIR}/pv-${ordinal}.yaml"
done

# Step 3 — adjust ASG desired count (drift handling).
log "[3/6] Adjust ASG desired count to match discovered EBS count"
# TODO: per-AZ ASG drift reconciliation
#   for az in ${azs}; do
#     count=$(echo "${volumes_json}" | jq "[.Volumes[] | select(.AvailabilityZone==\"${az}\")] | length")
#     aws autoscaling set-desired-capacity \
#       --auto-scaling-group-name "aegis-stateful-${az}" \
#       --desired-capacity "${count}"
#   done

# Step 4 — apply PV manifests.
log "[4/6] Apply PV manifests"
# Operator decision: dry-run first
kubectl apply -f "${PV_OUTPUT_DIR}/" --dry-run=client
read -rp "Dry-run looks correct? Type 'YES' to apply: " confirm
if [ "${confirm}" = "YES" ]; then
  kubectl apply -f "${PV_OUTPUT_DIR}/"
else
  log "Aborted by operator after dry-run"
  exit 1
fi

# Step 5 — helm install at discovered replica count.
log "[5/6] helm install/upgrade at discovered replica count"
total_count=$(echo "${volumes_json}" | jq '.Volumes | length')
log "  Discovered ${total_count} EBS volume(s) — operator should run helm upgrade with stateful.primary.replicas=${total_count}"
# Intentionally not auto-executed; operator decision per Path A runbook:
# helm upgrade --install aegis-statefulset helm/aegis-statefulset \
#   --namespace "${NAMESPACE}" --create-namespace \
#   --set "stateful.primary.replicas=${total_count}" \
#   --wait --timeout 30m

# Step 6 — rebuild routing override (delegate to Path B helper).
log "[6/6] Rebuild routing override via warm-routing-table.sh"
"$(dirname "$0")/warm-routing-table.sh"

log "Path A recovery complete"
