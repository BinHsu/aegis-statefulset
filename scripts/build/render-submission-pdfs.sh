#!/usr/bin/env bash
# render-submission-pdfs.sh — produce the 5 submission PDFs from their .md sources
#
# Outputs (under docs/submission-pdfs/, committed to repo):
#   00_Submission_Overview.pdf    <- docs/SUBMISSION.md                       (chrome — SVG diagrams)
#   01_Architecture_Overview.pdf  <- README.md                                (chrome — SVG diagrams)
#   02_Migration_Plan.pdf         <- docs/operations/legacy-to-eks-migration.md (chrome — SVG diagrams)
#   03_DR_Demo_Report.pdf         <- chaos-evidence/DR_report.md              (weasyprint — text-only)
#                                    (requires generate-dr-report.sh to have run first)
#   04_Future_Architecture.pdf    <- docs/future/README.md                    (weasyprint — text-only)
#
# Engine choice rationale:
#   - chrome helper      — needed when source markdown embeds SVG with inline
#                          <text> labels (architecture diagrams). weasyprint
#                          drops <text> from SVG, so ALB/API/Envoy labels
#                          disappear from the rendered PDF.
#   - weasyprint helper  — preferred for text-heavy markdown without SVG;
#                          smaller output, faster render.
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
# Runbook 05 (submission email) attaches the 5 PDFs from docs/submission-pdfs/
# to the email.

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="$PROJ_ROOT/docs/submission-pdfs"
HELPER_WEASY="$PROJ_ROOT/scripts/build/render-markdown-pdf.sh"
HELPER_CHROME="$PROJ_ROOT/scripts/build/render-markdown-pdf-chrome.sh"

SKIP_DR=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-dr) SKIP_DR=1; shift ;;
    -h|--help) head -30 "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

for h in "$HELPER_WEASY" "$HELPER_CHROME"; do
  if [[ ! -x "$h" ]]; then
    echo "ERROR: helper not executable: $h" >&2
    echo "  chmod +x $h" >&2
    exit 3
  fi
done

mkdir -p "$OUT_DIR"

log() { printf '\n=== %s ===\n' "$*"; }
fail=0

# --- 00 Submission Overview (chrome — has architecture diagram + ADR matrix tables) ---
log "00 — Submission Overview"
"$HELPER_CHROME" \
  "$PROJ_ROOT/docs/SUBMISSION.md" \
  "$OUT_DIR/00_Submission_Overview.pdf" \
  --title "aegis-statefulset — Submission" \
  || fail=$((fail+1))

# --- 01 Architecture Overview (chrome — README embeds all 7 architecture diagrams) ---
log "01 — Architecture Overview"
"$HELPER_CHROME" \
  "$PROJ_ROOT/README.md" \
  "$OUT_DIR/01_Architecture_Overview.pdf" \
  --title "aegis-statefulset — Architecture Overview" \
  || fail=$((fail+1))

# --- 02 Migration Plan (chrome — d8/d9 decision-matrix diagrams + tables) ---
log "02 — Migration Plan"
"$HELPER_CHROME" \
  "$PROJ_ROOT/docs/operations/legacy-to-eks-migration.md" \
  "$OUT_DIR/02_Migration_Plan.pdf" \
  --title "Legacy to EKS Migration Plan" \
  || fail=$((fail+1))

# --- 03 DR Demo Report (weasyprint — text + tables, no SVG) ---
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
  "$HELPER_WEASY" \
    "$DR_MD" \
    "$OUT_DIR/03_DR_Demo_Report.pdf" \
    --title "Disaster Recovery — Chaos Demo Report" \
    || fail=$((fail+1))
fi

# --- 04 Future Architecture (weasyprint — prose-heavy, no SVG) ---
log "04 — Future Architecture"
"$HELPER_WEASY" \
  "$PROJ_ROOT/docs/future/README.md" \
  "$OUT_DIR/04_Future_Architecture.pdf" \
  --title "Future Architecture — Evolution Paths" \
  || fail=$((fail+1))

# --- Summary ---
echo
log "Summary"
ls -lh "$OUT_DIR/"*.pdf 2>/dev/null || echo "  (no PDFs produced)"
echo

PRODUCED=$(ls -1 "$OUT_DIR"/*.pdf 2>/dev/null | wc -l | tr -d ' ')

if [[ $SKIP_DR -eq 1 ]]; then
  echo "$PRODUCED of 5 PDFs ready in: $OUT_DIR (03 DR Demo skipped per --skip-dr)"
  echo "Re-run without --skip-dr after the chaos demo to produce 03_DR_Demo_Report.pdf."
else
  echo "$PRODUCED of 5 PDFs ready in: $OUT_DIR"
fi
echo "Attach these to the submission email per runbook 05."

if [[ $fail -gt 0 ]]; then
  echo
  echo "WARNING: $fail PDF(s) failed to render — see logs above" >&2
  exit 1
fi
