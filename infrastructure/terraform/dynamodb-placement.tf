# DynamoDB placement table — POC reference for routing storage
# Per ADR-03 (rewritten 2026-05-09) — placement table contract
#
# IMPORTANT: This is POC reference. Production should evaluate whether
# existing tenant->cluster mapping satisfies the 6-property contract:
#   1. Atomic write with CAS
#   2. Strongly consistent reads
#   3. Multi-AZ durable
#   4. Low read latency
#   5. CDC / change stream capability
#   6. Audit log
# If yes, retain existing storage; this DynamoDB resource is greenfield only.

resource "aws_dynamodb_table" "placement" {
  name         = "aegis-statefulset-placement-${var.environment}"
  billing_mode = "PAY_PER_REQUEST" # On-demand for variable load
  hash_key     = "tenant_id"

  # Stream enabled for cache invalidation fan-out (per ADR-03 4-layer protection)
  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  attribute {
    name = "tenant_id"
    type = "S"
  }

  # Multi-AZ durability is automatic; PITR for point-in-time recovery
  point_in_time_recovery {
    enabled = true
  }

  # KMS encryption at rest with placement_table tier key (per ADR-07)
  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.placement_table.arn
  }

  # Tags follow FinOps default_tags (per ADR-10)
  tags = {
    Component = "routing"
    Tier      = "shared"
    DataClass = "operational"
  }

  # Cross-region replica for DR (Global Tables) — per ADR-04 補強
  # Conditional on environment to avoid Global Table cost in dev
  dynamic "replica" {
    for_each = var.environment == "prod" ? [var.dr_region] : []
    content {
      region_name            = replica.value
      kms_key_arn            = aws_kms_replica_key.placement_table_dr[0].arn
      point_in_time_recovery = true
    }
  }
}

# DR region replica KMS key (only in prod)
resource "aws_kms_replica_key" "placement_table_dr" {
  count = var.environment == "prod" ? 1 : 0

  provider                = aws.dr_region
  description             = "Replica of placement_table KMS key in DR region"
  primary_key_arn         = aws_kms_key.placement_table.arn
  deletion_window_in_days = 30

  tags = {
    Component = "routing"
    Tier      = "shared"
    Purpose   = "DR"
  }
}

# DynamoDB Streams -> Lambda for cache invalidation fan-out
# (Lambda function itself out of POC scope; see scripts/cache/ for pattern)
output "placement_table_stream_arn" {
  value       = aws_dynamodb_table.placement.stream_arn
  description = "Placement table DynamoDB Stream ARN. Lambda subscribes to invalidate Envoy cache."
}

output "placement_table_name" {
  value       = aws_dynamodb_table.placement.name
  description = "Placement table name for application configuration"
}

output "placement_table_arn" {
  value       = aws_dynamodb_table.placement.arn
  description = "Placement table ARN for IAM policies"
}

output "placement_table_kms_key_id" {
  value       = aws_kms_key.placement_table.key_id
  description = "Placement table KMS key ID (per ADR-07 5th tier)"
}
