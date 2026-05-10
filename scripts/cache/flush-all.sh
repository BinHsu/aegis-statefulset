#!/usr/bin/env bash
# scripts/cache/flush-all.sh
#
# Bulk flush all Envoy caches — operator emergency tool per ADR-03 + ADR-01.
#
# Use cases (4):
#   1. Relocation script Step 6.5 fallback when sync-invalidate hits
#      partial failure (auto, --reason="relocation-...").
#   2. DR boot — cluster reconstructed; ensure no stale cache entries
#      persist from a previous incarnation.
#   3. Config push failed mid-way — caches may have been partially
#      updated to an inconsistent state.
#   4. Suspected cache poisoning — last-resort sanity action.
#
# This is the NUCLEAR option. All Envoy replicas drop their cache;
# the next routing requests fall back to DynamoDB until caches re-warm
# (~30 sec elevated latency, full duration depends on tenant traffic).
#
# Usage:
#   ./flush-all.sh [--reason "<reason>"] [--no-confirm]
#
# Required environment:
#   ENVOY_ADMIN_ENDPOINTS  comma-separated list of Envoy admin URLs
#
# One-time prep: operator runs `chmod +x scripts/**/*.sh` after pulling.

set -euo pipefail

REASON=""
NO_CONFIRM=0

while [ $# -gt 0 ]; do
  case "$1" in
    --reason)
      REASON="${2:?--reason requires a value}"
      shift 2
      ;;
    --no-confirm)
      NO_CONFIRM=1
      shift
      ;;
    -h|--help)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

ENVOY_ADMIN_ENDPOINTS="${ENVOY_ADMIN_ENDPOINTS:?ENVOY_ADMIN_ENDPOINTS env var required}"

log() {
  printf '[%s] %s\n' "$(date -Iseconds)" "$*"
}

if [ "${NO_CONFIRM}" -eq 0 ]; then
  echo "WARNING: This will FLUSH ALL ENVOY CACHES."
  echo "WARNING: All next routing requests will hit DynamoDB (latency spike ~30 sec)."
  echo "WARNING: Reason: ${REASON:-<unspecified — operator manual>}"
  read -rp "Confirm bulk flush? Type 'FLUSH' to proceed: " confirm
  if [ "${confirm}" != "FLUSH" ]; then
    echo "Aborted."
    exit 1
  fi
fi

log "Initiating bulk flush. reason=${REASON:-manual} operator=${USER:-unknown}"

failed=0
total=0
for endpoint in $(echo "${ENVOY_ADMIN_ENDPOINTS}" | tr ',' ' '); do
  total=$((total + 1))
  echo "  Flushing ${endpoint}..."
  if curl -sf -X POST "${endpoint}/cache/flush" --max-time 10 >/dev/null; then
    echo "    OK"
  else
    echo "    FAILED"
    failed=1
  fi
done

# Audit trail — best-effort, do not fail the operation if log dir missing.
audit_line="$(date -Iseconds) BULK_FLUSH reason=${REASON:-manual} operator=${USER:-unknown} replicas=${total}"
if [ -w /var/log/aegis ] 2>/dev/null; then
  echo "${audit_line}" >> /var/log/aegis/cache-flush.log
fi

if [ "${failed}" = "1" ]; then
  log "Bulk flush had failures. Investigate Envoy admin connectivity."
  exit 1
fi

log "Bulk flush complete on all ${total} replicas"
