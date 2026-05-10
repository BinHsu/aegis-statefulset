#!/usr/bin/env bash
# scripts/dr/force-detach-pv.sh
#
# Force-detach an EBS volume from a previous node when the StatefulSet
# pod is stuck in `ContainerCreating` because the EBS-CSI driver cannot
# complete the attach-detach handshake (Tier 2e in
# `docs/operations/automation-tiers.md`).
#
# Background — why this exists:
#   The aws-ebs-csi-driver attach-detach state machine occasionally
#   wedges when the previous node is gone (terminated / unreachable)
#   but the volume's `attachmentState=attached` flag persists. New
#   pod scheduling cannot proceed until the volume is force-detached.
#   Karpenter consolidation makes this *more* common because nodes are
#   torn down faster than EBS detach completes.
#
# This is destructive — `aws ec2 detach-volume --force` will discard
# any in-flight writes from the previous instance. It is safe ONLY when
# the previous pod is genuinely dead (not in graceful-drain Terminating).
# This script confirms that state before acting.
#
# Required environment:
#   POD_NAME    StatefulSet pod that is stuck (e.g. aegis-app-0)
#   NAMESPACE   namespace of the pod (e.g. aegis-app)
#   AWS_REGION  AWS region of the cluster
#
# Optional environment:
#   FORCE       set to '1' to skip the operator confirmation prompt
#               (use only for automation that has already verified
#               previous-pod-dead state via independent means)
#
# Exit codes:
#   0  detach succeeded; pod expected to re-attach on next scheduler cycle
#   1  pre-condition failed (previous pod still alive / not Terminating)
#   2  AWS API call failed
#   3  operator declined confirmation
#
# Usage:
#   POD_NAME=aegis-app-0 NAMESPACE=aegis-app AWS_REGION=eu-central-1 \
#     ./scripts/dr/force-detach-pv.sh

set -euo pipefail

POD_NAME="${POD_NAME:?POD_NAME env var required (stuck pod)}"
NAMESPACE="${NAMESPACE:?NAMESPACE env var required}"
AWS_REGION="${AWS_REGION:?AWS_REGION env var required}"
FORCE="${FORCE:-0}"

echo "→ Inspecting pod: $NAMESPACE/$POD_NAME"

POD_PHASE="$(kubectl -n "$NAMESPACE" get pod "$POD_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")"
if [ "$POD_PHASE" != "Pending" ]; then
  echo "error: pod phase is '$POD_PHASE'; expected 'Pending' (stuck on ContainerCreating)" >&2
  echo "  This script is for the EBS attach-stuck case only." >&2
  exit 1
fi

# Find the PVC the stuck pod expects, then map to PV → EBS volume ID
PVC_NAME="$(kubectl -n "$NAMESPACE" get pod "$POD_NAME" \
  -o jsonpath='{.spec.volumes[?(@.persistentVolumeClaim)].persistentVolumeClaim.claimName}')"
if [ -z "$PVC_NAME" ]; then
  echo "error: pod has no PVC volume; nothing to detach" >&2
  exit 1
fi

PV_NAME="$(kubectl -n "$NAMESPACE" get pvc "$PVC_NAME" -o jsonpath='{.spec.volumeName}')"
EBS_VOLUME_ID="$(kubectl get pv "$PV_NAME" -o jsonpath='{.spec.csi.volumeHandle}')"

if [ -z "$EBS_VOLUME_ID" ]; then
  echo "error: PV $PV_NAME has no CSI volumeHandle (expected EBS volume ID)" >&2
  exit 1
fi

echo "  PVC:           $PVC_NAME"
echo "  PV:            $PV_NAME"
echo "  EBS volume:    $EBS_VOLUME_ID"

# Look up the previous attachment in EC2 — must verify the previous instance is dead
ATTACHED_INSTANCE="$(aws ec2 describe-volumes --region "$AWS_REGION" \
  --volume-ids "$EBS_VOLUME_ID" \
  --query 'Volumes[0].Attachments[0].InstanceId' --output text 2>/dev/null || true)"

if [ -z "$ATTACHED_INSTANCE" ] || [ "$ATTACHED_INSTANCE" = "None" ]; then
  echo "  Volume is not currently attached. Nothing to force-detach."
  echo "  The pod may be stuck for a different reason (e.g. node-not-ready)."
  exit 0
fi

echo "  Stuck attachment to: $ATTACHED_INSTANCE"

INSTANCE_STATE="$(aws ec2 describe-instances --region "$AWS_REGION" \
  --instance-ids "$ATTACHED_INSTANCE" \
  --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "missing")"

echo "  Instance state:      $INSTANCE_STATE"

if [ "$INSTANCE_STATE" = "running" ]; then
  echo "error: previous instance is STILL RUNNING. Force-detach is unsafe — the" >&2
  echo "       previous pod may still be writing. Investigate why scheduling has" >&2
  echo "       not migrated the pod cleanly via normal drain." >&2
  exit 1
fi

# Confirm operator intent
if [ "$FORCE" != "1" ]; then
  echo
  echo "About to FORCE-DETACH $EBS_VOLUME_ID from $ATTACHED_INSTANCE (state: $INSTANCE_STATE)."
  echo "This discards any in-flight writes from the previous instance."
  read -r -p "Proceed? (yes/NO): " CONFIRM
  if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted by operator."
    exit 3
  fi
fi

# Execute force-detach
echo "→ Force-detaching $EBS_VOLUME_ID..."
aws ec2 detach-volume --region "$AWS_REGION" \
  --volume-id "$EBS_VOLUME_ID" --force \
  --output table

# Wait for detached state (volume becomes available)
echo "→ Waiting for detached state..."
aws ec2 wait volume-available --region "$AWS_REGION" --volume-ids "$EBS_VOLUME_ID"
echo "✓ Volume detached."

echo
echo "Pod $NAMESPACE/$POD_NAME should reattach on next scheduler cycle."
echo "If it stays stuck, force-rotate by deleting the pod (StatefulSet recreates):"
echo "  kubectl -n $NAMESPACE delete pod $POD_NAME"
