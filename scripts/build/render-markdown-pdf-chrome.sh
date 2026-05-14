#!/usr/bin/env bash
# render-markdown-pdf-chrome.sh — Markdown → PDF via Chrome headless
#
# Sister of render-markdown-pdf.sh (weasyprint).  Use this one when the
# source markdown embeds SVG with inline <text> elements (architecture
# diagrams, flowcharts). weasyprint renders the geometry but drops the
# <text>, so labels like "ALB" / "API" / "Envoy" disappear from the PDF.
# Chrome renders SVG natively — text included.
#
# Pipeline:
#   pandoc <input.md> --to html5 --embed-resources --standalone
#     → inline HTML with base64-embedded SVG resources
#   Chrome --headless --print-to-pdf
#     → final PDF with SVG text intact
#
# Usage:
#   ./render-markdown-pdf-chrome.sh <input.md> <output.pdf> [--title "Title"]
#
# Toolchain:
#   - pandoc (Markdown → HTML)
#   - Google Chrome (HTML → PDF headless)
#
# When to use which renderer:
#   - render-markdown-pdf.sh        (weasyprint) — text-heavy markdown
#                                                  without SVG <text>
#   - render-markdown-pdf-chrome.sh (Chrome)     — markdown with
#                                                  architecture diagrams /
#                                                  any SVG that has labels

set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 <input.md> <output.pdf> [--title "Title"]

Arguments:
  <input.md>    Path to source markdown (must exist)
  <output.pdf>  Path to write PDF (parent dir created if missing)

Options:
  --title T     Document title passed to pandoc as -M title=T
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
    --title) TITLE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 1 ;;
  esac
done

log() { printf '%s\n' "$*" >&2; }

[[ -f "$INPUT_MD" ]] || { log "ERROR: input not found: $INPUT_MD"; exit 2; }
command -v pandoc >/dev/null 2>&1 || { log "ERROR: pandoc not installed (brew install pandoc)"; exit 3; }

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [[ ! -x "$CHROME" ]]; then
  CHROME=$(command -v chromium 2>/dev/null || command -v google-chrome 2>/dev/null || echo "")
fi
[[ -x "$CHROME" ]] || { log "ERROR: Chrome / Chromium not found"; exit 3; }

# Resolve all paths to absolute before we leave CWD.
INPUT_MD="$(cd "$(dirname "$INPUT_MD")" && pwd)/$(basename "$INPUT_MD")"
OUTPUT_PDF="$(cd "$(dirname "$OUTPUT_PDF")" 2>/dev/null && pwd || echo "$(dirname "$OUTPUT_PDF")")/$(basename "$OUTPUT_PDF")"
mkdir -p "$(dirname "$OUTPUT_PDF")"

INPUT_DIR="$(dirname "$INPUT_MD")"
TMP_HTML="$(mktemp -t markdown-html.XXXXXX).html"
trap 'rm -f "$TMP_HTML"' EXIT

log "Rendering: $INPUT_MD → $OUTPUT_PDF"
log "  Engine: Chrome headless (via pandoc → HTML)"

# Step 1: Markdown → standalone, embedded-resources HTML.
# `--embed-resources` (modern flag; deprecated `--self-contained` still
# works) inlines images as base64 data: URIs so Chrome doesn't need to
# resolve relative paths after we move out of the source directory.
PANDOC_ARGS=(
  "$INPUT_MD"
  --from gfm
  --to html5
  --embed-resources --standalone
  --resource-path="${INPUT_DIR}:$(cd "$INPUT_DIR" && cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" && pwd):."
  --toc --toc-depth=2
  -o "$TMP_HTML"
)
[[ -n "$TITLE" ]] && PANDOC_ARGS+=(-M "title=$TITLE")

pandoc "${PANDOC_ARGS[@]}" || { log "  ✗ pandoc HTML step failed"; exit 4; }
log "  ✓ pandoc produced HTML ($(du -h "$TMP_HTML" | cut -f1))"

# Step 2: HTML → PDF via Chrome headless.
# NOTE: `--print-to-pdf-no-header` is a no-op in Chrome 148+ (still emits
# the date/title header AND the file:// + page-number footer — the latter
# leaks the local /var/folders/<macOS-per-user-hash>/ temp path into the
# PDF). `--no-pdf-header-footer` is the working flag in modern headless.
"$CHROME" \
  --headless --disable-gpu --no-sandbox \
  --print-to-pdf="$OUTPUT_PDF" \
  --no-pdf-header-footer \
  "file://$TMP_HTML" >/dev/null 2>&1 || {
  log "  ✗ Chrome PDF print failed"; exit 4;
}

log "  ✓ Chrome rendered PDF"
log "  Output: $OUTPUT_PDF ($(du -h "$OUTPUT_PDF" | cut -f1))"
exit 0
