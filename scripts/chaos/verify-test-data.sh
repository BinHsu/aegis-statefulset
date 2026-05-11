#!/usr/bin/env bash
# scripts/chaos/verify-test-data.sh
#
# Read back the test keys recorded by seed-test-data.sh and compare each
# value to the manifest. Output a verify report (JSON) with match rate +
# mismatch details for the DR report's data-integrity verification step.
#
# Companion: scripts/chaos/seed-test-data.sh produces the manifest this
# script reads.
#
# Usage:
#   APP_URL=https://aegis-app.example.com \
#     ./scripts/chaos/verify-test-data.sh phase-1-recovery
#
# If MANIFEST is unset, the script picks the newest manifest under
# chaos-evidence/*-seed-*/manifest.json. Override with MANIFEST=path if
# you want a specific seed batch.
#
# Required env:
#   APP_URL          full base URL of the app
#
# Required arg:
#   LABEL            verify label (e.g., phase-1-recovery, phase-2-recovery)
#
# Optional env:
#   MANIFEST         path to seed manifest (default: latest in chaos-evidence/)
#   OUTPUT_ROOT      default chaos-evidence
#   TIMEOUT          curl timeout per request seconds (default 5)

set -euo pipefail

LABEL="${1:?usage: $0 <label>   (e.g., phase-1-recovery)}"
APP_URL="${APP_URL:?APP_URL env var required}"
OUTPUT_ROOT="${OUTPUT_ROOT:-chaos-evidence}"
TIMEOUT="${TIMEOUT:-5}"
MANIFEST="${MANIFEST:-}"

# Resolve manifest if not given — pick latest seed manifest
if [ -z "${MANIFEST}" ]; then
  MANIFEST=$(find "${OUTPUT_ROOT}" -type f -name 'manifest.json' -path '*-seed-*' 2>/dev/null \
              | sort | tail -1)
  if [ -z "${MANIFEST}" ]; then
    echo "ERROR: no seed manifest found under ${OUTPUT_ROOT}/*-seed-*/manifest.json" >&2
    echo "       Run scripts/chaos/seed-test-data.sh first, or set MANIFEST=path explicitly" >&2
    exit 2
  fi
fi

[ -f "${MANIFEST}" ] || { echo "ERROR: manifest not found: ${MANIFEST}" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required for manifest parsing" >&2; exit 2; }

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="${OUTPUT_ROOT}/${TIMESTAMP}-${LABEL}-verify"
REPORT="${OUT_DIR}/verify-report.json"
MISMATCH_LOG="${OUT_DIR}/mismatches.txt"

mkdir -p "${OUT_DIR}"

log() {
  printf '[%s] [verify-test-data] %s\n' "$(date -Iseconds)" "$*"
}

log "Verifying against manifest: ${MANIFEST}"
log "App URL: ${APP_URL}"
log "Label: ${LABEL}"

TOTAL=$(jq -r '.key_count' "${MANIFEST}")
log "Manifest declares ${TOTAL} keys"

MATCHES=0
MISMATCHES=0
MISSING=0
ERRORS=0

: > "${MISMATCH_LOG}"

# Iterate keys
TMPKEYS=$(mktemp)
jq -r '.keys[] | "\(.key)\t\(.value)"' "${MANIFEST}" > "${TMPKEYS}"

while IFS=$'\t' read -r KEY EXPECTED; do
  # GET the key from the app. Use raw http_code + body capture.
  RESP=$(curl -sS -m "${TIMEOUT}" -w "\n%{http_code}" \
              "${APP_URL}/data?key=${KEY}" 2>/dev/null || echo $'\n000')
  STATUS=$(printf '%s' "${RESP}" | tail -1)
  BODY=$(printf '%s' "${RESP}" | sed '$d')

  case "${STATUS}" in
    200)
      if [ "${BODY}" = "${EXPECTED}" ]; then
        MATCHES=$((MATCHES + 1))
      else
        MISMATCHES=$((MISMATCHES + 1))
        printf 'MISMATCH %s: expected=%s got=%s\n' "${KEY}" "${EXPECTED}" "${BODY}" >> "${MISMATCH_LOG}"
      fi
      ;;
    404)
      MISSING=$((MISSING + 1))
      printf 'MISSING  %s: expected=%s got=<404>\n' "${KEY}" "${EXPECTED}" >> "${MISMATCH_LOG}"
      ;;
    *)
      ERRORS=$((ERRORS + 1))
      printf 'ERROR    %s: HTTP %s\n' "${KEY}" "${STATUS}" >> "${MISMATCH_LOG}"
      ;;
  esac
done < "${TMPKEYS}"

rm -f "${TMPKEYS}"

# Compute match rate (3 decimal places via awk)
MATCH_RATE=$(awk -v m="${MATCHES}" -v t="${TOTAL}" 'BEGIN { if (t==0) {print 0} else {printf "%.4f", m/t} }')

# Write report
cat > "${REPORT}" <<EOF
{
  "schema_version": 1,
  "verify_timestamp": "${TIMESTAMP}",
  "verify_label": "${LABEL}",
  "manifest_source": "${MANIFEST}",
  "app_url": "${APP_URL}",
  "key_count": ${TOTAL},
  "results": {
    "matches": ${MATCHES},
    "mismatches": ${MISMATCHES},
    "missing": ${MISSING},
    "errors": ${ERRORS}
  },
  "match_rate": ${MATCH_RATE},
  "match_pct": "$(awk -v r="${MATCH_RATE}" 'BEGIN { printf "%.2f%%", r * 100 }')"
}
EOF

log "Done."
log "  Total:      ${TOTAL}"
log "  Matches:    ${MATCHES}"
log "  Mismatches: ${MISMATCHES}"
log "  Missing:    ${MISSING}"
log "  Errors:     ${ERRORS}"
log "  Match rate: $(awk -v r="${MATCH_RATE}" 'BEGIN { printf "%.2f%%", r * 100 }')"
log ""
log "  Report:     ${REPORT}"
if [ "${MISMATCHES}" -gt 0 ] || [ "${MISSING}" -gt 0 ] || [ "${ERRORS}" -gt 0 ]; then
  log "  Mismatches: ${MISMATCH_LOG}"
fi
log ""
log "For DR report § 3.5 / § 4.4:"
log "  {{P*_DATA_MATCH_N}} = ${MATCHES}"
log "  {{P*_TEST_KEYS}}    = ${TOTAL}"
log "  {{P*_DATA_MATCH_PCT}} = $(awk -v r="${MATCH_RATE}" 'BEGIN { printf "%.2f%%", r * 100 }')"
