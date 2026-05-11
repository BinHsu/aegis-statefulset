#!/usr/bin/env bash
# scripts/chaos/capture-evidence.sh
#
# Snapshot K8s + Velero + AWS state at a single point in time. Designed
# to be called at each chaos demo checkpoint: baseline, phase-1-injected,
# phase-1-recovered, phase-2-cutover, phase-2-recovered, post-teardown.
#
# Each invocation produces a timestamped subdirectory under
# chaos-evidence/ with:
#   - K8s state: events / pods / pvcs / statefulsets / services / configmaps
#   - Velero state: backups / schedules / restores / recent log tail
#   - AWS state: EBS snapshot inventory tagged Project=aegis-statefulset
#   - Alertmanager firing alerts (if endpoint reachable)
#   - README.md summary of what was captured + the wall-clock timestamp
#
# Usage:
#   ./scripts/chaos/capture-evidence.sh <label>
#
# Example:
#   ./scripts/chaos/capture-evidence.sh baseline
#   ./scripts/chaos/capture-evidence.sh phase-1-subnet-deleted
#   ./scripts/chaos/capture-evidence.sh phase-1-recovery
#   ./scripts/chaos/capture-evidence.sh phase-2-region-cutover
#   ./scripts/chaos/capture-evidence.sh phase-2-recovery
#
# Required tools: kubectl, aws CLI, jq. Optional: curl (for Alertmanager API).
#
# Environment overrides:
#   NAMESPACE             default aegis-app
#   VELERO_NAMESPACE      default velero
#   AWS_REGION            default eu-central-1
#   PROJECT_TAG           default Project=aegis-statefulset
#   ALERTMANAGER_URL      default unset (skipped if empty)
#   OUTPUT_ROOT           default chaos-evidence

set -euo pipefail

LABEL="${1:?usage: $0 <label>   (e.g. baseline, phase-1-subnet-deleted)}"
NAMESPACE="${NAMESPACE:-aegis-app}"
VELERO_NAMESPACE="${VELERO_NAMESPACE:-velero}"
AWS_REGION="${AWS_REGION:-eu-central-1}"
PROJECT_TAG="${PROJECT_TAG:-Project=aegis-statefulset}"
ALERTMANAGER_URL="${ALERTMANAGER_URL:-}"
OUTPUT_ROOT="${OUTPUT_ROOT:-chaos-evidence}"

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="${OUTPUT_ROOT}/${TIMESTAMP}-${LABEL}"

mkdir -p "${OUT_DIR}"

log() {
  printf '[%s] [capture-evidence] %s\n' "$(date -Iseconds)" "$*"
}

log "Label: ${LABEL}"
log "Output: ${OUT_DIR}"

# ─── K8s state ─────────────────────────────────────────────────────────
log "Capturing K8s state (namespace=${NAMESPACE})…"

kubectl get events -A --sort-by='.lastTimestamp' \
  > "${OUT_DIR}/k8s-events.txt" 2>&1 || log "  warn: kubectl events failed"

kubectl get pods -n "${NAMESPACE}" -o yaml \
  > "${OUT_DIR}/k8s-pods.yaml" 2>&1 || log "  warn: kubectl pods failed"

kubectl get pvc -n "${NAMESPACE}" -o yaml \
  > "${OUT_DIR}/k8s-pvcs.yaml" 2>&1 || log "  warn: kubectl pvcs failed"

kubectl get pv -o yaml \
  > "${OUT_DIR}/k8s-pvs.yaml" 2>&1 || log "  warn: kubectl pvs failed"

kubectl get statefulset,deployment,svc,ingress -n "${NAMESPACE}" -o yaml \
  > "${OUT_DIR}/k8s-workloads.yaml" 2>&1 || log "  warn: kubectl workloads failed"

kubectl get nodes -o wide \
  > "${OUT_DIR}/k8s-nodes.txt" 2>&1 || log "  warn: kubectl nodes failed"

kubectl top nodes 2>/dev/null \
  > "${OUT_DIR}/k8s-nodes-top.txt" || log "  warn: kubectl top (metrics-server may be down)"

# Blackbox / service-availability snapshot via probe endpoint (if exposed)
kubectl get probe -A -o yaml 2>/dev/null \
  > "${OUT_DIR}/k8s-probes.yaml" || true

# ─── Velero state ──────────────────────────────────────────────────────
log "Capturing Velero state (namespace=${VELERO_NAMESPACE})…"

kubectl get backups.velero.io -n "${VELERO_NAMESPACE}" -o yaml \
  > "${OUT_DIR}/velero-backups.yaml" 2>&1 || log "  warn: velero backups failed"

kubectl get schedules.velero.io -n "${VELERO_NAMESPACE}" -o yaml \
  > "${OUT_DIR}/velero-schedules.yaml" 2>&1 || log "  warn: velero schedules failed"

kubectl get restores.velero.io -n "${VELERO_NAMESPACE}" -o yaml \
  > "${OUT_DIR}/velero-restores.yaml" 2>&1 || log "  warn: velero restores failed"

# Recent Velero server log tail (last 500 lines)
kubectl logs -n "${VELERO_NAMESPACE}" deployment/velero --tail=500 \
  > "${OUT_DIR}/velero-server.log" 2>&1 || log "  warn: velero log failed"

# ─── AWS state ─────────────────────────────────────────────────────────
log "Capturing AWS state (region=${AWS_REGION}, tag=${PROJECT_TAG})…"

# EBS snapshots tagged Project=aegis-statefulset
aws ec2 describe-snapshots \
  --owner-ids self \
  --region "${AWS_REGION}" \
  --filters "Name=tag:${PROJECT_TAG%%=*},Values=${PROJECT_TAG##*=}" \
  --query 'Snapshots[].{ID:SnapshotId,VolumeId:VolumeId,Start:StartTime,State:State,Size:VolumeSize}' \
  --output json \
  > "${OUT_DIR}/aws-ebs-snapshots.json" 2>&1 || log "  warn: aws snapshots failed"

# Cross-region snapshot inventory in DR region (best-effort; ignore if region differs)
DR_REGION="${DR_REGION:-eu-west-1}"
aws ec2 describe-snapshots \
  --owner-ids self \
  --region "${DR_REGION}" \
  --filters "Name=tag:${PROJECT_TAG%%=*},Values=${PROJECT_TAG##*=}" \
  --query 'Snapshots[].{ID:SnapshotId,VolumeId:VolumeId,Start:StartTime,State:State}' \
  --output json \
  > "${OUT_DIR}/aws-ebs-snapshots-dr.json" 2>&1 || log "  warn: dr-region snapshots failed"

# EBS volumes tagged Project=aegis-statefulset
aws ec2 describe-volumes \
  --region "${AWS_REGION}" \
  --filters "Name=tag:${PROJECT_TAG%%=*},Values=${PROJECT_TAG##*=}" \
  --query 'Volumes[].{ID:VolumeId,AZ:AvailabilityZone,State:State,Size:Size,Tags:Tags}' \
  --output json \
  > "${OUT_DIR}/aws-ebs-volumes.json" 2>&1 || log "  warn: aws volumes failed"

# EKS node group desired counts (master vs standby AZs)
CLUSTER_NAME="${CLUSTER_NAME:-aegis-statefulset-prod}"
aws eks describe-cluster \
  --name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --query 'cluster.{name:name,status:status,version:version,endpoint:endpoint}' \
  --output json \
  > "${OUT_DIR}/aws-eks-cluster.json" 2>&1 || log "  warn: eks cluster describe failed"

aws eks list-nodegroups \
  --cluster-name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --output json \
  > "${OUT_DIR}/aws-eks-nodegroups.json" 2>&1 || log "  warn: eks nodegroups failed"

# ─── Alertmanager firing alerts (if URL provided) ──────────────────────
if [ -n "${ALERTMANAGER_URL}" ]; then
  log "Capturing firing alerts from ${ALERTMANAGER_URL}…"
  curl -fsS "${ALERTMANAGER_URL}/api/v2/alerts?active=true" \
    > "${OUT_DIR}/alerts-firing.json" 2>&1 \
    || log "  warn: alertmanager unreachable; continuing"
else
  log "ALERTMANAGER_URL unset — skipping alert capture (fill in by hand if needed)"
fi

# ─── Summary README for this checkpoint ────────────────────────────────
cat > "${OUT_DIR}/README.md" <<EOF
# Chaos demo evidence — ${LABEL}

**Captured:** ${TIMESTAMP} (UTC)
**Wall clock:** $(date -Iseconds)
**Cluster:** ${CLUSTER_NAME}
**Namespace:** ${NAMESPACE}
**Region:** ${AWS_REGION} (DR: ${DR_REGION})

## What's in this directory

| File | Source | Use in DR report |
|---|---|---|
| \`k8s-events.txt\` | \`kubectl get events -A --sort-by=.lastTimestamp\` | Timeline of detection / scheduling / restore events |
| \`k8s-pods.yaml\` | \`kubectl get pods -n ${NAMESPACE} -o yaml\` | Pod-level state at this checkpoint |
| \`k8s-pvcs.yaml\` | \`kubectl get pvc -n ${NAMESPACE} -o yaml\` | PVC binding state — proves EBS preservation across restore |
| \`k8s-pvs.yaml\` | \`kubectl get pv -o yaml\` | PV → EBS handle mapping |
| \`k8s-workloads.yaml\` | \`kubectl get statefulset,deployment,svc,ingress -n ${NAMESPACE}\` | Workload manifests as restored |
| \`k8s-nodes.txt\` | \`kubectl get nodes -o wide\` | AZ distribution — proves master AZ rotation |
| \`k8s-nodes-top.txt\` | \`kubectl top nodes\` | Resource utilisation snapshot |
| \`velero-backups.yaml\` | Velero Backup CRDs | Operational vs DR schedule outputs at this moment |
| \`velero-schedules.yaml\` | Velero Schedule CRDs | Active cadence config (5-min operational, 4-h DR) |
| \`velero-restores.yaml\` | Velero Restore CRDs | If a restore is in flight, its state lands here |
| \`velero-server.log\` | Velero pod last 500 lines | Restore phase debug detail |
| \`aws-ebs-snapshots.json\` | \`aws ec2 describe-snapshots\` (source region) | Snapshot inventory — proves cadence is firing |
| \`aws-ebs-snapshots-dr.json\` | \`aws ec2 describe-snapshots\` (DR region) | Cross-region replicated snapshots |
| \`aws-ebs-volumes.json\` | \`aws ec2 describe-volumes\` | Volume inventory + AZ + size |
| \`aws-eks-cluster.json\` | \`aws eks describe-cluster\` | Cluster state at this checkpoint |
| \`aws-eks-nodegroups.json\` | \`aws eks list-nodegroups\` | Which AZ groups are at desired>0 |
| \`alerts-firing.json\` | Alertmanager v2 API (if reachable) | Active alerts at this moment — proves detection fired |

## Tips for filling the DR report

- The "K8s events" file is the ground truth for **observed RTO** — find the
  first event in the new master AZ ("Pod ... assigned to node ...") and
  subtract the subnet-delete timestamp.
- The "Velero backups" file gives the **observed RPO** — find the last
  successful backup timestamp before the failure injection.
- The "AWS EBS snapshots" file proves the **5-min cadence is firing** —
  count snapshots in the hour preceding failure; expect ~12.
- The "Velero server log" tail captures the **restore choreography**;
  grep for "Restore completed" to get the exact restore-end timestamp.

Run \`./scripts/finops/capture-demo-cost.sh\` after teardown to fill
the cost section of the report.
EOF

log "Done. ${OUT_DIR}/README.md summarises what was captured."
log "Recommended next steps:"
log "  1) Open the directory and verify the JSON / YAML files are non-empty"
log "  2) Take a Grafana screenshot of service-availability dashboard + save as ${OUT_DIR}/screenshot-service-availability.png"
log "  3) Repeat this script at the next chaos checkpoint with a new label"
