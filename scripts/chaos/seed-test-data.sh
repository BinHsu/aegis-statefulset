#!/usr/bin/env bash
# scripts/chaos/seed-test-data.sh
#
# Write N test key-value pairs to the application via its HTTP POST /data
# endpoint, and record the writes to a manifest for later verification.
# This is the prerequisite for the DR report's data-integrity verification
# step (§ 3.5 in the template) — without seed-then-verify, "100% match"
# is a hand-wave.
#
# Companion: scripts/chaos/verify-test-data.sh reads back via GET /data?key=
# and reports match rate against this manifest.
#
# Usage:
#   APP_URL=https://aegis-app.example.com ./scripts/chaos/seed-test-data.sh 100
#
# Required env:
#   APP_URL          full base URL of the app (e.g., https://aegis-app.example.com)
#
# Optional env:
#   N                count of keys (overrides positional arg if both given)
#   LABEL            seed label (default: "pre-phase-1")
#   OUTPUT_ROOT      default chaos-evidence
#   PARALLEL         number of concurrent POSTs (default 10)
#   TIMEOUT          curl timeout per request seconds (default 5)

set -euo pipefail

N="${N:-${1:-100}}"
LABEL="${LABEL:-pre-phase-1}"
APP_URL="${APP_URL:?APP_URL env var required (full base URL of the app, e.g., https://aegis-app.example.com)}"
OUTPUT_ROOT="${OUTPUT_ROOT:-chaos-evidence}"
PARALLEL="${PARALLEL:-10}"
TIMEOUT="${TIMEOUT:-5}"

# BVA: validate N is positive integer
case "${N}" in
  ''|*[!0-9]*) echo "ERROR: N must be a positive integer (got: '${N}')" >&2; exit 2 ;;
esac
if [ "${N}" -lt 1 ]; then
  echo "ERROR: N must be ≥ 1 (got: ${N})" >&2
  exit 2
fi

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="${OUTPUT_ROOT}/${TIMESTAMP}-seed-${LABEL}"
MANIFEST="${OUT_DIR}/manifest.json"

mkdir -p "${OUT_DIR}"

log() {
  printf '[%s] [seed-test-data] %s\n' "$(date -Iseconds)" "$*"
}

log "Seeding ${N} test keys to ${APP_URL}"
log "Label: ${LABEL}"
log "Manifest will land at: ${MANIFEST}"

# Pre-flight: probe the app once to verify it's reachable
if ! curl -fsS -o /dev/null -m "${TIMEOUT}" "${APP_URL}/healthz" 2>/dev/null; then
  log "WARN: ${APP_URL}/healthz did not return 200; continuing anyway"
  log "      (if this is wrong, you'll see all POSTs fail in the loop below)"
fi

# Write manifest header
cat > "${MANIFEST}" <<EOF
{
  "schema_version": 1,
  "seed_timestamp": "${TIMESTAMP}",
  "seed_label": "${LABEL}",
  "app_url": "${APP_URL}",
  "key_count": ${N},
  "keys": [
EOF

# Generate + POST each key. Sequential for determinism + clean manifest.
# (Parallel POSTs would speed this up but complicate ordered manifest writes;
# N=100 sequential at ~10 POST/sec is 10 seconds — acceptable for chaos demo.)
SUCCESS=0
FAILED=0
FIRST_ENTRY=1
PADDING=$(printf '%d' "${N}" | wc -c | tr -d ' ')

for i in $(seq 1 "${N}"); do
  KEY=$(printf "chaos-test-%0${PADDING}d" "${i}")
  VALUE="chaos-test-value-${TIMESTAMP}-${KEY}"

  # POST the key. Capture HTTP status code.
  STATUS=$(curl -sS -o /dev/null -w "%{http_code}" -m "${TIMEOUT}" \
                -X POST -H "Content-Type: application/json" \
                -d "{\"key\":\"${KEY}\",\"value\":\"${VALUE}\"}" \
                "${APP_URL}/data" 2>/dev/null || echo "000")

  if [ "${STATUS}" = "204" ] || [ "${STATUS}" = "201" ] || [ "${STATUS}" = "200" ]; then
    SUCCESS=$((SUCCESS + 1))
  else
    FAILED=$((FAILED + 1))
  fi

  # Append to manifest (comma BEFORE entry, except for first)
  if [ "${FIRST_ENTRY}" -eq 1 ]; then
    FIRST_ENTRY=0
  else
    echo "    ," >> "${MANIFEST}"
  fi
  printf '    {"key": "%s", "value": "%s", "write_status": "%s"}' \
    "${KEY}" "${VALUE}" "${STATUS}" >> "${MANIFEST}"

  # Light progress every 10 keys
  if [ $((i % 10)) -eq 0 ]; then
    log "  ${i}/${N} (success=${SUCCESS} failed=${FAILED})"
  fi
done

# Close manifest
cat >> "${MANIFEST}" <<EOF

  ],
  "summary": {
    "total": ${N},
    "success": ${SUCCESS},
    "failed": ${FAILED}
  }
}
EOF

log "Done. ${SUCCESS}/${N} keys seeded successfully (${FAILED} failed)."

if [ "${FAILED}" -gt 0 ]; then
  log "WARN: ${FAILED} POSTs returned non-2xx. The verify step will count those keys as 'missing'."
fi

log ""
log "Next steps:"
log "  1) Run the chaos demo (Phase 1 + Phase 2) — see runbook 02 § 4-5"
log "  2) At each recovery checkpoint, run verify against this manifest:"
log "     MANIFEST='${MANIFEST}' APP_URL='${APP_URL}' \\\\"
log "       ./scripts/chaos/verify-test-data.sh phase-1-recovery"
log "  3) Match rate goes into DR report § 3.5 / § 4.4"
