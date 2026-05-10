#!/usr/bin/env bash
# scripts/failover/fencing.sh
#
# Split-brain prevention (ADR-04). Before promoting standbys, the failed
# AZ's primaries must be fenced — removed from ALB targets and from the
# Envoy override map — so a partitioned-but-alive primary cannot keep
# accepting writes after its standby starts serving.
#
# Usage:
#   ./fencing.sh <failed-az>
#
# Two layers of fencing:
#   1. ALB target removal — the data plane stops sending traffic to the
#      failed AZ's pods at the load-balancer layer.
#   2. Envoy maintenance mode — the override map for tenants on the
#      failed primaries is set to a "maintenance" placeholder so even
#      direct internal calls are rejected until per-pod-failover.sh
#      writes the real override (primary -> standby).

set -euo pipefail

FAILED_AZ="${1:?usage: $0 <failed-az>}"
NAMESPACE="${NAMESPACE:-aegis-app}"
ALB_TARGET_GROUP_ARN="${ALB_TARGET_GROUP_ARN:-}"

log() {
  printf '[%s] [fence] %s\n' "$(date -Iseconds)" "$*"
}

log "Fencing AZ ${FAILED_AZ}"

# Layer 1 — ALB target deregistration.
log "[1/2] Deregister ${FAILED_AZ} targets from ALB"
if [ -z "${ALB_TARGET_GROUP_ARN}" ]; then
  log "WARN: ALB_TARGET_GROUP_ARN not set; skipping ALB-layer fence"
else
  # Discover primary pod IPs in the failed AZ
  ips=$(kubectl get pods -n "${NAMESPACE}" \
    -l "aegis.io/role=primary,topology.kubernetes.io/zone=${FAILED_AZ}" \
    -o jsonpath='{.items[*].status.podIP}')

  for ip in ${ips}; do
    if [ -z "${ip}" ]; then
      continue
    fi
    log "Deregistering ${ip} from ${ALB_TARGET_GROUP_ARN}"
    aws elbv2 deregister-targets \
      --target-group-arn "${ALB_TARGET_GROUP_ARN}" \
      --targets "Id=${ip}" \
      || log "WARN: deregister failed for ${ip} (continuing)"
  done
fi

# Layer 2 — Envoy override maintenance entries.
log "[2/2] Set Envoy override to maintenance for ${FAILED_AZ} primaries"
primaries=$(kubectl get pods -n "${NAMESPACE}" \
  -l "aegis.io/role=primary,topology.kubernetes.io/zone=${FAILED_AZ}" \
  -o jsonpath='{.items[*].metadata.name}')

# Build a JSON patch with one "maintenance" entry per primary.
# The Envoy filter chain renders "maintenance" as 503 with a friendly body.
patch_body='{"data":{'
first=1
for p in ${primaries}; do
  if [ "${first}" -eq 0 ]; then
    patch_body="${patch_body},"
  fi
  patch_body="${patch_body}\"${p}\":\"maintenance\""
  first=0
done
patch_body="${patch_body}}}"

if [ "${first}" -eq 1 ]; then
  log "WARN: no primaries to fence in ${FAILED_AZ}"
else
  kubectl patch configmap -n "${NAMESPACE}" routing-override \
    --type merge \
    -p "${patch_body}" \
    || log "WARN: routing-override patch failed (continuing)"
fi

log "Fencing complete for ${FAILED_AZ}"
