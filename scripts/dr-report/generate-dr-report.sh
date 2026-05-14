#!/usr/bin/env bash
# scripts/dr-report/generate-dr-report.sh
#
# Render docs/operations/dr-report-template.md into
# docs/submission-pdfs/03_DR_Demo_Report.pdf (the canonical submission PDF).
#
# Auto-fills the placeholders that can be derived without operator input
# (date, git SHA, region, cluster name, etc.) AND inlines the cost-summary
# table from chaos-evidence/cost-summary.md if present. Leaves operator-
# specific timings + decisions + lessons-learned as `[fill in]` for the
# operator to complete by hand BEFORE running this script.
#
# Workflow:
#   1) Run the chaos demo end-to-end (runbook 02 § 4-5)
#   2) Run capture-evidence.sh at each checkpoint
#   3) Run capture-demo-cost.sh after teardown
#   4) Hand-edit dr-report-template.md (or a copy) to fill the [fill in] markers
#   5) Run this script — outputs docs/submission-pdfs/03_DR_Demo_Report.pdf
#
# Why pandoc: already on Bin's machine (verified at session start),
# produces clean PDFs from markdown with a single command. Chrome
# headless is the documented fallback if pandoc PDF engine misses
# any features.
#
# Usage:
#   ./scripts/dr-report/generate-dr-report.sh                    # default values
#   AWS_REGION=us-east-1 ./scripts/dr-report/generate-dr-report.sh
#
# Environment overrides:
#   AWS_REGION       default eu-central-1
#   DR_REGION        default eu-west-1
#   CLUSTER_NAME     default aegis-statefulset-prod
#   MASTER_AZ        default eu-central-1a
#   STANDBY_AZS      default "eu-central-1b, eu-central-1c"
#   OPERATOR         default $(whoami)
#   TEMPLATE_PATH    default docs/operations/dr-report-template.md
#   EVIDENCE_DIR     default chaos-evidence
#   OUTPUT_PDF       default docs/submission-pdfs/03_DR_Demo_Report.pdf
#   OUTPUT_MD        default chaos-evidence/DR_report.md (the filled-in markdown)

set -euo pipefail

AWS_REGION="${AWS_REGION:-eu-central-1}"
DR_REGION="${DR_REGION:-eu-west-1}"
CLUSTER_NAME="${CLUSTER_NAME:-aegis-statefulset-prod}"
MASTER_AZ="${MASTER_AZ:-eu-central-1a}"
STANDBY_AZS="${STANDBY_AZS:-eu-central-1b, eu-central-1c}"
OPERATOR="${OPERATOR:-$(whoami)}"
TEMPLATE_PATH="${TEMPLATE_PATH:-docs/operations/dr-report-template.md}"
EVIDENCE_DIR="${EVIDENCE_DIR:-chaos-evidence}"
OUTPUT_PDF="${OUTPUT_PDF:-docs/submission-pdfs/03_DR_Demo_Report.pdf}"
OUTPUT_MD="${OUTPUT_MD:-${EVIDENCE_DIR}/DR_report.md}"

log() {
  printf '[%s] [generate-dr-report] %s\n' "$(date -Iseconds)" "$*"
}

# Precondition checks
[ -f "${TEMPLATE_PATH}" ] || { log "ERROR: template not found at ${TEMPLATE_PATH}"; exit 1; }
command -v pandoc >/dev/null 2>&1 || { log "ERROR: pandoc not installed. brew install pandoc"; exit 1; }

# Derived values
EXECUTION_DATE="$(date -u +%Y-%m-%d)"
GENERATION_TIMESTAMP="$(date -Iseconds)"
GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo 'not-a-git-repo')"

mkdir -p "$(dirname "${OUTPUT_MD}")"

# Start from template
cp "${TEMPLATE_PATH}" "${OUTPUT_MD}"

# Auto-substitute placeholders that have deterministic values
log "Substituting auto-fillable placeholders…"

# Cross-platform sed (BSD/macOS uses -i ''; GNU uses -i)
sed_inplace() {
  if [[ "$(uname)" == "Darwin" ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

sed_inplace "s|{{EXECUTION_DATE}}|${EXECUTION_DATE}|g" "${OUTPUT_MD}"
sed_inplace "s|{{GENERATION_TIMESTAMP}}|${GENERATION_TIMESTAMP}|g" "${OUTPUT_MD}"
sed_inplace "s|{{GIT_SHA}}|${GIT_SHA}|g" "${OUTPUT_MD}"
sed_inplace "s|{{AWS_REGION}}|${AWS_REGION}|g" "${OUTPUT_MD}"
sed_inplace "s|{{DR_REGION}}|${DR_REGION}|g" "${OUTPUT_MD}"
sed_inplace "s|{{CLUSTER_NAME}}|${CLUSTER_NAME}|g" "${OUTPUT_MD}"
sed_inplace "s|{{MASTER_AZ}}|${MASTER_AZ}|g" "${OUTPUT_MD}"
sed_inplace "s|{{STANDBY_AZS}}|${STANDBY_AZS}|g" "${OUTPUT_MD}"
sed_inplace "s|{{OPERATOR}}|${OPERATOR}|g" "${OUTPUT_MD}"

# Inline the cost table if cost-summary.md exists
COST_SUMMARY="${EVIDENCE_DIR}/cost-summary.md"
if [ -f "${COST_SUMMARY}" ]; then
  log "Inlining cost-summary.md table into § 6…"
  # Extract just the line-by-line breakdown table (between "## Line-by-line breakdown" and the next "##")
  COST_TABLE="$(awk '/^## Line-by-line breakdown/,/^## Observed vs target/' "${COST_SUMMARY}" \
                 | sed '$d')"  # drop the trailing "## Observed..." header
  # Write to a temp file to handle multiline substitution
  TMPCOST="$(mktemp)"
  printf '%s\n' "${COST_TABLE}" > "${TMPCOST}"
  # Insert at the {{COST_LINE_BY_LINE_TABLE}} marker
  awk -v insertfile="${TMPCOST}" '
    /\{\{COST_LINE_BY_LINE_TABLE\}\}/ {
      while ((getline line < insertfile) > 0) print line
      next
    }
    { print }
  ' "${OUTPUT_MD}" > "${OUTPUT_MD}.tmp" && mv "${OUTPUT_MD}.tmp" "${OUTPUT_MD}"
  rm -f "${TMPCOST}"

  # Try to extract the total from cost-summary.md
  TOTAL_COST="$(grep -E '^\| \*\*TOTAL\*\* \|' "${COST_SUMMARY}" 2>/dev/null \
                 | sed -E 's/.*\$\*\*([0-9.]+)\*\*.*/\1/' \
                 | head -1)"
  if [ -n "${TOTAL_COST}" ]; then
    sed_inplace "s|{{TOTAL_COST_USD}}|${TOTAL_COST}|g" "${OUTPUT_MD}"
  fi
else
  log "  No cost-summary.md found at ${COST_SUMMARY} — leaving § 6 placeholders for hand fill"
  log "  Run scripts/finops/capture-demo-cost.sh first, then re-run this."
fi

# Count remaining placeholders so the operator knows what's left
REMAINING="$(grep -c '{{' "${OUTPUT_MD}" || true)"
HAND_FILLS="$(grep -c '\[fill in' "${OUTPUT_MD}" || true)"

log "Markdown ready: ${OUTPUT_MD}"
log "Remaining {{PLACEHOLDER}} markers: ${REMAINING} (operator-specific timings + counts)"
log "Remaining [fill in] markers:    ${HAND_FILLS} (operator-written verdicts + lessons)"

# Render to PDF
log "Rendering to ${OUTPUT_PDF} via pandoc…"

# Pandoc HTML pipeline produces nicer styling for tables than direct PDF engine
# Fallback to direct PDF if HTML→PDF tooling unavailable
if pandoc "${OUTPUT_MD}" \
    --from gfm \
    --to pdf \
    --pdf-engine=weasyprint \
    --resource-path="docs:." \
    -o "${OUTPUT_PDF}" 2>/dev/null; then
  log "  weasyprint engine succeeded"
elif pandoc "${OUTPUT_MD}" \
    --from gfm \
    --to pdf \
    --resource-path="docs:." \
    -o "${OUTPUT_PDF}" 2>/dev/null; then
  log "  pandoc default PDF engine succeeded"
else
  log "  pandoc PDF rendering failed; falling back to HTML"
  pandoc "${OUTPUT_MD}" \
    --from gfm \
    --to html5 \
    --standalone \
    --resource-path="docs:." \
    -o "${OUTPUT_PDF%.pdf}.html"
  log "  Saved as HTML: ${OUTPUT_PDF%.pdf}.html"
  log "  To convert to PDF: open in Chrome → File > Print > Save as PDF"
  log "  Or install weasyprint: brew install weasyprint"
  exit 0
fi

log "Done."
log "  Filled markdown: ${OUTPUT_MD}"
log "  PDF:             ${OUTPUT_PDF}"
log ""
log "If the PDF still has {{PLACEHOLDER}} or [fill in] markers, fill them in"
log "in ${OUTPUT_MD} and re-run this script — it's idempotent."
