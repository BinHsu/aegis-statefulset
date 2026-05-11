#!/usr/bin/env bash
# scripts/finops/capture-demo-cost.sh
#
# Pull AWS Cost Explorer for the chaos demo period, tagged
# Project=aegis-statefulset, broken down by service. Outputs:
#   - chaos-evidence/cost-summary.json (raw Cost Explorer response)
#   - chaos-evidence/cost-summary.md   (rendered markdown table for DR report)
#
# Why this script: ad-hoc `aws ce get-cost-and-usage` invocations are easy
# to get wrong (date format, granularity, group-by dimensions). This is the
# tested invocation that produces the table the DR report expects.
#
# Note: AWS Cost Explorer lags by ~24h for the most recent day. For a
# same-day demo, this script captures partial data; re-run the next day
# to refresh the totals. The DR report template names the day-lag caveat.
#
# Usage:
#   ./scripts/finops/capture-demo-cost.sh                  # last 24 h (UTC)
#   START_DATE=2026-05-14 ./scripts/finops/capture-demo-cost.sh
#   START_DATE=2026-05-14 END_DATE=2026-05-15 ./scripts/finops/capture-demo-cost.sh
#
# Required tools: aws CLI, jq.
#
# Environment overrides:
#   START_DATE       default = today (UTC)
#   END_DATE         default = tomorrow (UTC) — Cost Explorer end is exclusive
#   AWS_REGION       default = eu-central-1 (Cost Explorer is global but region needed for the API call)
#   PROJECT_TAG_KEY  default = Project
#   PROJECT_TAG_VAL  default = aegis-statefulset
#   OUTPUT_ROOT      default = chaos-evidence

set -euo pipefail

AWS_REGION="${AWS_REGION:-eu-central-1}"
PROJECT_TAG_KEY="${PROJECT_TAG_KEY:-Project}"
PROJECT_TAG_VAL="${PROJECT_TAG_VAL:-aegis-statefulset}"
OUTPUT_ROOT="${OUTPUT_ROOT:-chaos-evidence}"

# Default to today / tomorrow (Cost Explorer end is exclusive)
START_DATE="${START_DATE:-$(date -u +%Y-%m-%d)}"
END_DATE="${END_DATE:-$(date -u -v+1d +%Y-%m-%d 2>/dev/null || date -u -d 'tomorrow' +%Y-%m-%d)}"

mkdir -p "${OUTPUT_ROOT}"
OUT_JSON="${OUTPUT_ROOT}/cost-summary.json"
OUT_MD="${OUTPUT_ROOT}/cost-summary.md"

log() {
  printf '[%s] [capture-demo-cost] %s\n' "$(date -Iseconds)" "$*"
}

log "Window: ${START_DATE} → ${END_DATE} (UTC; end exclusive)"
log "Tag filter: ${PROJECT_TAG_KEY}=${PROJECT_TAG_VAL}"
log "Note: Cost Explorer lags ~24h on the most recent day. Re-run tomorrow if same-day demo."

# ─── Group by SERVICE — the line-by-line breakdown ─────────────────────
log "Pulling Cost Explorer by SERVICE…"

aws ce get-cost-and-usage \
  --region us-east-1 \
  --time-period "Start=${START_DATE},End=${END_DATE}" \
  --granularity DAILY \
  --metrics "UnblendedCost" \
  --group-by "Type=DIMENSION,Key=SERVICE" \
  --filter "{\"Tags\":{\"Key\":\"${PROJECT_TAG_KEY}\",\"Values\":[\"${PROJECT_TAG_VAL}\"]}}" \
  --output json \
  > "${OUT_JSON}" 2>&1 || {
    log "ERROR: Cost Explorer call failed. Possible causes:"
    log "  - IAM role lacks ce:GetCostAndUsage permission"
    log "  - Tag '${PROJECT_TAG_KEY}=${PROJECT_TAG_VAL}' not yet activated as a cost allocation tag"
    log "    (Activate via Billing console > Cost allocation tags; takes ~24h)"
    log "  - Demo just ran (Cost Explorer lags ~24h for current day)"
    log "Raw error in ${OUT_JSON}"
    exit 1
  }

# ─── Render markdown table for DR report ───────────────────────────────
log "Rendering markdown table to ${OUT_MD}…"

# Sum costs per service across the window
TOTAL=$(jq -r '
  [.ResultsByTime[].Groups[].Metrics.UnblendedCost.Amount | tonumber]
  | add | . // 0
' "${OUT_JSON}")

cat > "${OUT_MD}" <<EOF
# Cost summary — chaos demo

**Window:** ${START_DATE} → ${END_DATE} (UTC; end exclusive)
**Tag filter:** \`${PROJECT_TAG_KEY}=${PROJECT_TAG_VAL}\`
**Captured:** $(date -Iseconds)
**Raw data:** \`cost-summary.json\`

## Line-by-line breakdown (AWS UnblendedCost, USD)

| AWS service | Cost (USD) | Notes |
|---|---|---|
EOF

# Group total per service across the window
jq -r '
  [.ResultsByTime[].Groups[] | {service: .Keys[0], cost: (.Metrics.UnblendedCost.Amount | tonumber)}]
  | group_by(.service)
  | map({service: .[0].service, total: (map(.cost) | add)})
  | sort_by(-.total)
  | .[]
  | "| \(.service) | $\(.total | . * 100 | round / 100) | |"
' "${OUT_JSON}" >> "${OUT_MD}"

cat >> "${OUT_MD}" <<EOF
| **TOTAL** | **\$$(printf '%.2f' "${TOTAL}")** | sum of UnblendedCost across services in window |

## Observed vs target

| | Observed (this window) | Target (per SUBMISSION § 7) | Verdict |
|---|---|---|---|
| Total chaos-demo cost | \$$(printf '%.2f' "${TOTAL}") | \$50–\$100 expected for ~3-hour run | [fill in: PASS / OVER / UNDER] |

## Caveats

- **Cost Explorer 24h lag:** if you ran the demo today, the numbers
  above are partial. Re-run this script tomorrow with
  \`START_DATE=${START_DATE} END_DATE=${END_DATE}\` to get final totals.
- **Tag activation requirement:** the \`${PROJECT_TAG_KEY}\` cost
  allocation tag must be activated in Billing console before Cost
  Explorer respects it as a filter. New activations take up to 24h to
  propagate. Resources tagged before activation are not retroactively
  billed under the tag.
- **End is exclusive:** Cost Explorer treats \`End=${END_DATE}\` as
  midnight UTC of that day — costs accrue *until* but *not on*
  the end date.
- **UnblendedCost vs BlendedCost:** this script uses UnblendedCost
  (what you actually paid, after credits but before Savings Plans
  blending). For accountancy / reconciliation, prefer the
  Billing-and-Cost-Management console's CSV export, which honors
  the customer's actual pricing model.

## What this gets you in the DR report

Paste the line-by-line table into DR report § 6 "Cost analysis (actual
spend)". The \`generate-dr-report.sh\` script does this substitution
automatically if it finds \`cost-summary.md\` in the chaos-evidence
directory.
EOF

log "Done."
log "  Raw JSON: ${OUT_JSON}"
log "  Markdown: ${OUT_MD}"
log ""
log "Total cost in window: \$$(printf '%.2f' "${TOTAL}")"
log ""
log "If the number looks too low / too high, check:"
log "  1) the Project tag is set on every taggable resource (see scripts/finops/per-tenant-cost-attribution.sql for the canonical tag set)"
log "  2) the tag was activated as a cost allocation tag at least 24h before the demo"
log "  3) the time window matches the actual demo window in UTC"
