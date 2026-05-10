# Per ADR-07: customer-managed KMS keys per tier.
# Compromise of one key doesn't expose other tiers.

resource "aws_kms_key" "stateful_data" {
  description             = "Encrypts EBS volumes for stateful pods"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = merge(local.common_tags, { Tier = "stateful-data" })
}

resource "aws_kms_alias" "stateful_data" {
  name          = "alias/aegis-statefulset-stateful-data"
  target_key_id = aws_kms_key.stateful_data.key_id
}

resource "aws_kms_key" "backup" {
  description             = "Encrypts S3 backup buckets"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = merge(local.common_tags, { Tier = "backup" })
}

resource "aws_kms_alias" "backup" {
  name          = "alias/aegis-statefulset-backup"
  target_key_id = aws_kms_key.backup.key_id
}

resource "aws_kms_key" "logs" {
  description             = "Encrypts CloudWatch Logs / observability storage"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = merge(local.common_tags, { Tier = "logs" })
}

resource "aws_kms_alias" "logs" {
  name          = "alias/aegis-statefulset-logs"
  target_key_id = aws_kms_key.logs.key_id
}

resource "aws_kms_key" "secrets" {
  description             = "Encrypts AWS Secrets Manager + EKS secrets"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = merge(local.common_tags, { Tier = "secrets" })
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/aegis-statefulset-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

# EKS cluster envelope encryption — separate key from app-tier secrets
resource "aws_kms_key" "cluster" {
  description             = "EKS cluster envelope encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = merge(local.common_tags, { Tier = "cluster-secrets" })
}

# Per ADR-07 § 5th tier — placement table criticality requires separate key.
# Multi-region in prod to support Global Tables cross-region replica DR.
resource "aws_kms_key" "placement_table" {
  description             = "Encrypts DynamoDB placement table (routing source of truth)"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  multi_region            = var.environment == "prod" ? true : false

  tags = merge(local.common_tags, { Tier = "placement-table" })
}

resource "aws_kms_alias" "placement_table" {
  name          = "alias/aegis-statefulset-placement-table"
  target_key_id = aws_kms_key.placement_table.key_id
}
