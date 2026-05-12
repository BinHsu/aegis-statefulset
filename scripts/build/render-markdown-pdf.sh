#!/usr/bin/env bash
# render-markdown-pdf.sh — generic Markdown → PDF renderer
#
# Usage:
#   ./render-markdown-pdf.sh <input.md> <output.pdf> [--title "Optional Title"]
#
# The renderer is deliberately minimal: it converts a single Markdown source
# into a single PDF artifact, no placeholder substitution, no template logic,
# no PDF-only headers / footers / cover pages baked into the script.
#
# This is the canonical 1:1 .md → .pdf path that backs the 4-PDF submission
# package. Each PDF maps to exactly one .md source of truth; if you want to
# change the PDF, edit the .md.
#
# Toolchain:
#   pandoc --from gfm --to pdf --pdf-engine=weasyprint
#   Fallback to pandoc default PDF engine, then to standalone HTML.
#
# Exit codes:
#   0 — PDF produced
#   1 — usage error
#   2 — input file missing
#   3 — toolchain missing
#   4 — rendering failure (no fallback succeeded)

set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 <input.md> <output.pdf> [--title "Title"]

Arguments:
  <input.md>    Path to source markdown (must exist)
  <output.pdf>  Path to write PDF (parent dir must exist or will be created)

Options:
  --title T     Optional document title passed to pandoc as -M title=T

Examples:
  $0 README.md docs/submission-pdfs/01_Architecture_Overview.pdf \\
      --title "aegis-statefulset — Architecture Overview"

  $0 docs/operations/legacy-to-eks-migration.md \\
      docs/submission-pdfs/02_Migration_Plan.pdf \\
      --title "Legacy to EKS Migration Plan"
EOF
}

if [[ $# -lt 2 ]]; then
  usage >&2
  exit 1
fi

INPUT_MD="$1"
OUTPUT_PDF="$2"
shift 2

TITLE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --title)
      TITLE="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

log() { printf '%s\n' "$*" >&2; }

# Validate inputs
if [[ ! -f "$INPUT_MD" ]]; then
  log "ERROR: input file not found: $INPUT_MD"
  exit 2
fi

if ! command -v pandoc >/dev/null 2>&1; then
  log "ERROR: pandoc not installed. Install via: brew install pandoc"
  exit 3
fi

# Ensure output directory exists
OUTPUT_DIR="$(dirname "$OUTPUT_PDF")"
mkdir -p "$OUTPUT_DIR"

# Build pandoc args
PANDOC_ARGS=(
  "$INPUT_MD"
  --from gfm
  --to pdf
  --pdf-engine=weasyprint
  --resource-path="$(dirname "$INPUT_MD"):docs:."
  --toc
  --toc-depth=2
  -o "$OUTPUT_PDF"
)

if [[ -n "$TITLE" ]]; then
  PANDOC_ARGS+=(-M "title=$TITLE")
fi

log "Rendering: $INPUT_MD → $OUTPUT_PDF"
log "  Engine: weasyprint (primary)"

if pandoc "${PANDOC_ARGS[@]}" 2>/dev/null; then
  log "  ✓ weasyprint succeeded"
  log "  Output: $OUTPUT_PDF ($(du -h "$OUTPUT_PDF" | cut -f1))"
  exit 0
fi

log "  ✗ weasyprint failed; trying pandoc default PDF engine"
PANDOC_ARGS_FALLBACK=(
  "$INPUT_MD"
  --from gfm
  --to pdf
  --resource-path="$(dirname "$INPUT_MD"):docs:."
  --toc
  --toc-depth=2
  -o "$OUTPUT_PDF"
)
if [[ -n "$TITLE" ]]; then
  PANDOC_ARGS_FALLBACK+=(-M "title=$TITLE")
fi

if pandoc "${PANDOC_ARGS_FALLBACK[@]}" 2>/dev/null; then
  log "  ✓ pandoc default engine succeeded"
  log "  Output: $OUTPUT_PDF ($(du -h "$OUTPUT_PDF" | cut -f1))"
  exit 0
fi

log "  ✗ PDF rendering failed; emitting HTML fallback at ${OUTPUT_PDF%.pdf}.html"
pandoc "$INPUT_MD" \
  --from gfm \
  --to html5 \
  --standalone \
  --toc \
  --toc-depth=2 \
  --resource-path="$(dirname "$INPUT_MD"):docs:." \
  -o "${OUTPUT_PDF%.pdf}.html" || {
    log "  ✗ HTML fallback also failed"
    exit 4
  }
log "  Open in browser and File > Print > Save as PDF, or install weasyprint:"
log "    brew install weasyprint"
exit 4
