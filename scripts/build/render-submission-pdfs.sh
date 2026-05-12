#!/usr/bin/env bash
# render-submission-pdfs.sh — produce the 4 submission PDFs from their .md sources
#
# Outputs (under docs/submission-pdfs/, gitignored):
#   01_Architecture_Overview.pdf  <- README.md
#   02_Migration_Plan.pdf         <- docs/operations/legacy-to-eks-migration.md
#   03_DR_Demo_Report.pdf         <- chaos-evidence/DR_report.md
#                                    (requires generate-dr-report.sh to have run first)
#   04_Future_Architecture.pdf    <- docs/future/README.md
#
# Each PDF is generated fresh from its .md source — 1:1 mapping, no PDF-only
# content, no drift risk. Edit the .md to change the PDF.
#
# Usage:
#   ./scripts/build/render-submission-pdfs.sh [--skip-dr]
#
# Options:
#   --skip-dr   Skip 03_DR_Demo_Report (use if chaos demo hasn't run yet)
#
# Thu morning runbook 05 (submission email) attaches the 4 PDFs from
# docs/submission-pdfs/ to the email.

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="$PROJ_ROOT/docs/submission-pdfs"
HELPER="$PROJ_ROOT/scripts/build/render-markdown-pdf.sh"

SKIP_DR=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-dr) SKIP_DR=1; shift ;;
    -h|--help) head -25 "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ ! -x "$HELPER" ]]; then
  echo "ERROR: helper not executable: $HELPER" >&2
  echo "  chmod +x $HELPER" >&2
  exit 3
fi

mkdir -p "$OUT_DIR"

log() { printf '\n=== %s ===\n' "$*"; }
fail=0

# --- 01 Architecture Overview ---
log "01 — Architecture Overview"
"$HELPER" \
  "$PROJ_ROOT/README.md" \
  "$OUT_DIR/01_Architecture_Overview.pdf" \
  --title "aegis-statefulset — Architecture Overview" \
  || fail=$((fail+1))

# --- 02 Migration Plan ---
log "02 — Migration Plan"
"$HELPER" \
  "$PROJ_ROOT/docs/operations/legacy-to-eks-migration.md" \
  "$OUT_DIR/02_Migration_Plan.pdf" \
  --title "Legacy to EKS Migration Plan" \
  || fail=$((fail+1))

# --- 03 DR Demo Report ---
log "03 — DR Demo Report"
DR_MD="$PROJ_ROOT/chaos-evidence/DR_report.md"
if [[ $SKIP_DR -eq 1 ]]; then
  echo "  --skip-dr passed; skipping"
elif [[ ! -f "$DR_MD" ]]; then
  echo "  WARNING: $DR_MD not found"
  echo "  Run scripts/dr-report/generate-dr-report.sh first (after chaos demo)"
  echo "  Skipping for now; re-run this script after the demo"
  fail=$((fail+1))
else
  "$HELPER" \
    "$DR_MD" \
    "$OUT_DIR/03_DR_Demo_Report.pdf" \
    --title "Disaster Recovery — Chaos Demo Report" \
    || fail=$((fail+1))
fi

# --- 04 Future Architecture ---
log "04 — Future Architecture"
"$HELPER" \
  "$PROJ_ROOT/docs/future/README.md" \
  "$OUT_DIR/04_Future_Architecture.pdf" \
  --title "Future Architecture — Evolution Paths" \
  || fail=$((fail+1))

# --- Summary ---
echo
log "Summary"
ls -lh "$OUT_DIR/"*.pdf 2>/dev/null || echo "  (no PDFs produced)"
echo

if [[ $fail -gt 0 ]]; then
  echo "Completed with $fail failure(s) — see logs above" >&2
  exit 1
fi

echo "All 4 PDFs ready in: $OUT_DIR"
echo "Attach these to the submission email per runbook 05."
