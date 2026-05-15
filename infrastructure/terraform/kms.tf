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

  # CloudWatch Logs encryption requires the KMS key policy to explicitly
  # grant the logs service principal — unlike most AWS services, CW Logs
  # does NOT work through IAM-only access on a default key policy.
  policy = data.aws_iam_policy_document.logs_kms.json

  tags = merge(local.common_tags, { Tier = "logs" })
}

data "aws_iam_policy_document" "logs_kms" {
  # Restate root access — once a custom key policy is set it fully
  # replaces the default, so account-IAM-governed access must be
  # re-granted explicitly or terraform loses the ability to manage it.
  statement {
    sid       = "EnableRootAccount"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  # CloudWatch Logs service — required for log-group SSE-KMS (cloudtrail.tf
  # log group). Scoped by encryption-context to this account's log groups.
  statement {
    sid    = "AllowCloudWatchLogs"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.${var.aws_region}.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:*"]
    }
  }

  # CloudTrail uses this same key to encrypt the log files it delivers to
  # the cloudtrail S3 bucket (cloudtrail.tf — both the trail's kms_key_id
  # and the bucket SSE point here). CreateTrail validates key access up
  # front, hence InsufficientEncryptionPolicyException without this grant.
  statement {
    sid       = "AllowCloudTrailEncryptLogFiles"
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:aws:cloudtrail:arn"
      values   = ["arn:aws:cloudtrail:*:${data.aws_caller_identity.current.account_id}:trail/*"]
    }
  }

  statement {
    sid       = "AllowCloudTrailDescribeKey"
    effect    = "Allow"
    actions   = ["kms:DescribeKey"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }
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
