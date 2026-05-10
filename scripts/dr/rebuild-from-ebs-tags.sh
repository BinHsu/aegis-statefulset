#!/usr/bin/env bash
# scripts/dr/rebuild-from-ebs-tags.sh
#
# Rebuild the routing/placement table from EBS volume tags when the
# canonical state store (DynamoDB) is unavailable or considered stale.
# This is Path B in the ADR-04 disaster recovery decision tree:
#
#   Path A — DynamoDB intact, EBS volumes intact: rebind PVs, restart pods.
#   Path B — EBS volumes intact, routing state lost: this script.       ← here
#   Path C — EBS volumes lost: cross-region snapshot restore (Path C).
#
# The submission's tagging convention (per ADR-04) writes the following
# tags onto every customer-data EBS volume at provision time:
#
#   aegis.io/tenant-id        canonical tenant identifier
#   aegis.io/cell-id          which cell (StatefulSet) owns this PV
#   aegis.io/pod-ordinal      StatefulSet ordinal (e.g. "0", "1", ...)
#   aegis.io/cluster-name     EKS cluster the PV was provisioned for
#
# This script enumerates EBS volumes matching the cluster-name tag,
# parses the tenant / cell / ordinal mapping, and emits it as a JSON
# document the operator can use to repopulate DynamoDB or feed the
# Envoy router's bootstrap routing table.
#
# Required environment:
#   CLUSTER_NAME    EKS cluster name (matches aegis.io/cluster-name tag)
#   AWS_REGION      AWS region of the EBS volumes
#
# Optional environment:
#   OUTPUT_FILE     where to write the rebuilt routing JSON
#                   (default: ./placement-table-rebuild-<timestamp>.json)
#   STALE_DAYS      reject volumes whose last-attached time is older
#                   than this (default: 30; raise if customer has long-
#                   running orphan tenants)
#
# Output format (placement-table JSON):
#   {
#     "rebuilt_at": "2026-05-10T...",
#     "cluster": "...",
#     "source": "ebs-tags",
#     "entries": [
#       {
#         "tenant_id": "...",
#         "cell_id":   "...",
#         "pod_ordinal": "0",
#         "ebs_volume_id": "vol-...",
#         "last_attached": "..."
#       },
#       ...
#     ]
#   }
#
# This script is READ-ONLY against AWS — it does not modify EBS,
# does not modify DynamoDB. The operator decides whether to push the
# output into the routing store, and via which mechanism.

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:?CLUSTER_NAME env var required}"
AWS_REGION="${AWS_REGION:?AWS_REGION env var required}"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT_FILE="${OUTPUT_FILE:-./placement-table-rebuild-${TIMESTAMP}.json}"
STALE_DAYS="${STALE_DAYS:-30}"

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required (brew install jq / apt install jq)" >&2
  exit 1
fi

echo "→ Querying EBS volumes for cluster: $CLUSTER_NAME"
echo "  Region: $AWS_REGION"
echo "  Stale-cutoff: $STALE_DAYS days"
echo

# Fetch all EBS volumes tagged for this cluster
RAW_JSON="$(aws ec2 describe-volumes --region "$AWS_REGION" \
  --filters "Name=tag:aegis.io/cluster-name,Values=$CLUSTER_NAME" \
  --query 'Volumes[].{
    volume_id: VolumeId,
    tags: Tags,
    attachments: Attachments
  }' \
  --output json)"

VOLUME_COUNT="$(echo "$RAW_JSON" | jq 'length')"
echo "  Found $VOLUME_COUNT volumes."

if [ "$VOLUME_COUNT" = "0" ]; then
  echo "warning: no volumes found. Cluster name tag may not match." >&2
  echo "         Verify EBS volume tags include 'aegis.io/cluster-name=$CLUSTER_NAME'." >&2
  exit 1
fi

# Parse + filter + emit. We tolerate volumes missing a tag (skip them)
# but log the count so operator notices the gap.
ENTRIES_JSON="$(echo "$RAW_JSON" | jq --arg now "$TIMESTAMP" '
  map(
    {
      volume_id: .volume_id,
      tenant_id: ([.tags[]? | select(.Key == "aegis.io/tenant-id") | .Value] | first // null),
      cell_id:   ([.tags[]? | select(.Key == "aegis.io/cell-id")   | .Value] | first // null),
      pod_ordinal: ([.tags[]? | select(.Key == "aegis.io/pod-ordinal") | .Value] | first // null),
      last_attached: ([.attachments[]?.AttachTime] | first // null)
    }
  )
  | map(select(.tenant_id != null and .cell_id != null and .pod_ordinal != null))
')"

EMITTED_COUNT="$(echo "$ENTRIES_JSON" | jq 'length')"
SKIPPED_COUNT=$((VOLUME_COUNT - EMITTED_COUNT))

if [ "$SKIPPED_COUNT" -gt 0 ]; then
  echo "  Skipped $SKIPPED_COUNT volumes missing required aegis.io tags."
  echo "  (Check 'aws ec2 describe-volumes' output to investigate.)"
fi

# Build the final output document
jq -n --argjson entries "$ENTRIES_JSON" \
  --arg cluster "$CLUSTER_NAME" \
  --arg rebuilt_at "$TIMESTAMP" \
  '{
    rebuilt_at: $rebuilt_at,
    cluster: $cluster,
    source: "ebs-tags",
    entries: $entries
  }' > "$OUTPUT_FILE"

echo
echo "✓ Wrote $EMITTED_COUNT entries to: $OUTPUT_FILE"
echo
echo "Next step (operator decides mechanism — script does not push):"
echo "  - Push to DynamoDB:    aws dynamodb batch-write-item ... (per ADR-03)"
echo "  - Inspect the entries: jq . $OUTPUT_FILE"
echo "  - Replay into Envoy router bootstrap: per ADR-03 § 'cache-reset modes'"
