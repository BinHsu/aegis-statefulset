#!/usr/bin/env bash
# scripts/chaos/run-phase-1-az-failure.sh
#
# Phase 1 chaos demo: simulate an AZ failure by deleting the source AZ's
# stateful subnet.
#
# Why subnet delete: it is a hard, atomic blast — different from "drain
# nodes" or "shut down instances". Subnet deletion forces ENIs to detach
# and prevents new pods from scheduling, mirroring the network-partition
# component of a real AZ outage. The 3-step sequence (drain ASG, wait
# for ENIs, delete subnet) is the only way to delete cleanly; AWS
# refuses to delete a subnet with attached ENIs.
#
# This script is destructive in the demo environment by design. Do NOT
# run against production.
#
# Required environment:
#   CLUSTER_NAME    EKS cluster name
#   SUBNET_ID       subnet to delete (the stateful subnet in SOURCE_AZ)
#
# Optional environment:
#   REGION          default eu-central-1
#   AZ              default eu-central-1a (label only; SUBNET_ID is the real handle)
#   POLL_INTERVAL   seconds between polls (default 30)
#   DRAIN_TIMEOUT   seconds to wait for instances + ENIs to clear (default 600)

set -euo pipefail

REGION="${REGION:-eu-central-1}"
AZ="${AZ:-eu-central-1a}"
SUBNET_ID="${SUBNET_ID:?SUBNET_ID env var required}"
CLUSTER="${CLUSTER_NAME:?CLUSTER_NAME env var required}"
POLL_INTERVAL="${POLL_INTERVAL:-30}"
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-600}"

log() {
  printf '[%s] [phase-1-az-failure] %s\n' "$(date -Iseconds)" "$*"
}

log "Phase 1 chaos: kill AZ ${AZ} via subnet delete (${SUBNET_ID}, region=${REGION})"

# Step 1 — drain the ASG behind the stateful node group in the AZ.
log "[T+0] Setting stateful node group desired_size=0"
aws eks update-nodegroup-config \
  --cluster-name "${CLUSTER}" \
  --nodegroup-name "stateful-master-${AZ}" \
  --scaling-config "desiredSize=0,minSize=0,maxSize=1"

# Step 2 — wait for instances drained (boundary discipline per BVA).
log "[Step 2/4] Waiting for EC2 instances in ${SUBNET_ID} to terminate"
elapsed=0
while [ "${elapsed}" -lt "${DRAIN_TIMEOUT}" ]; do
  count=$(aws ec2 describe-instances --region "${REGION}" \
            --filters "Name=subnet-id,Values=${SUBNET_ID}" \
                      "Name=instance-state-name,Values=running,pending" \
            --query 'Reservations[].Instances[].InstanceId' \
            --output text \
          | wc -w | tr -d ' ')
  if [ "${count}" = "0" ]; then
    log "  all instances terminated"
    break
  fi
  log "  ${count} instance(s) remain; waiting ${POLL_INTERVAL}s (elapsed ${elapsed}s)"
  sleep "${POLL_INTERVAL}"
  elapsed=$((elapsed + POLL_INTERVAL))
done
if [ "${elapsed}" -ge "${DRAIN_TIMEOUT}" ]; then
  log "ERROR: instances did not terminate within ${DRAIN_TIMEOUT}s"
  exit 1
fi

# Step 3 — wait for ENIs detached.
log "[Step 3/4] Waiting for ENIs in ${SUBNET_ID} to detach"
elapsed=0
while [ "${elapsed}" -lt "${DRAIN_TIMEOUT}" ]; do
  count=$(aws ec2 describe-network-interfaces --region "${REGION}" \
            --filters "Name=subnet-id,Values=${SUBNET_ID}" "Name=status,Values=in-use" \
            --query 'NetworkInterfaces[].NetworkInterfaceId' \
            --output text \
          | wc -w | tr -d ' ')
  if [ "${count}" = "0" ]; then
    log "  all ENIs detached"
    break
  fi
  log "  ${count} ENI(s) still in-use; waiting ${POLL_INTERVAL}s (elapsed ${elapsed}s)"
  sleep "${POLL_INTERVAL}"
  elapsed=$((elapsed + POLL_INTERVAL))
done
if [ "${elapsed}" -ge "${DRAIN_TIMEOUT}" ]; then
  log "ERROR: ENIs did not detach within ${DRAIN_TIMEOUT}s"
  exit 1
fi

# Step 4 — delete subnet (the actual blast).
log "[Step 4/4] Deleting subnet ${SUBNET_ID}"
aws ec2 delete-subnet --subnet-id "${SUBNET_ID}" --region "${REGION}"

echo
log "AZ ${AZ} subnet deleted."
log "Next:  scripts/dr/az-rotation.sh  with SOURCE_AZ=${AZ} TARGET_AZ=<healthy AZ>"
