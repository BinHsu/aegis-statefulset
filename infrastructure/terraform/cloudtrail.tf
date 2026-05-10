# CloudTrail + audit-log foundation per ADR-07.
#
# Multi-region trail with log file integrity validation, KMS-encrypted with
# the dedicated kms-logs key (ADR-07), delivered to an S3 bucket with
# Object Lock COMPLIANCE-mode 7-year retention, and forwarded to CloudWatch
# Logs for Wazuh ingestion (ADR-07).
#
# The audit log bucket is the system-of-record for compliance evidence
# (SOC 2 CC7.2, ISO 27001 A.8.15, GDPR Art. 32, NIST 800-53 AU-2/AU-3/AU-9).
# Object Lock COMPLIANCE-mode means even AWS root cannot delete a log object
# during the retention window — that is the strongest tamper protection AWS
# offers, and the threat model assumes "attacker has compromised an admin
# account" is in-scope.

# ---- S3 bucket: audit log archive ----
resource "aws_s3_bucket" "cloudtrail" {
  bucket = "aegis-statefulset-cloudtrail-${var.environment}-${data.aws_caller_identity.current.account_id}"

  # Object Lock requires this flag at bucket creation; cannot be enabled later.
  object_lock_enabled = true

  tags = {
    Component = "audit"
    Tier      = "shared"
    DataClass = "operational"
    Purpose   = "cloudtrail-archive"
  }
}

resource "aws_s3_bucket_versioning" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  versioning_configuration {
    status = "Enabled" # required for Object Lock
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.logs.id
    }
    bucket_key_enabled = true # FinOps per ADR-10 — reduces KMS API call cost
  }
}

resource "aws_s3_bucket_logging" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  target_bucket = aws_s3_bucket.access_logs.id
  target_prefix = "cloudtrail-archive/"
}

# Object Lock COMPLIANCE mode: not even root can delete during retention.
# 7 years (2555 days) per ADR-07 — covers SOC 2 / ISO 27001 / common
# regulator expectations. COMPLIANCE-mode is irreversible by design.
resource "aws_s3_bucket_object_lock_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    default_retention {
      mode = "COMPLIANCE"
      days = 2555 # 7 years
    }
  }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle: keep current version available for queries 90 days hot,
# then transition to Glacier Instant Retrieval. Object Lock retention
# overrides any expiry actions, so this is a cost-tier policy not a
# deletion policy.
resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    id     = "audit-log-cold-tier"
    status = "Enabled"

    filter {}

    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }
  }
}

# Bucket policy required by CloudTrail to deliver objects.
resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  policy = data.aws_iam_policy_document.cloudtrail_bucket.json
}

data "aws_iam_policy_document" "cloudtrail_bucket" {
  statement {
    sid    = "AWSCloudTrailAclCheck"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.cloudtrail.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudtrail:${var.aws_region}:${data.aws_caller_identity.current.account_id}:trail/aegis-statefulset-${var.environment}"]
    }
  }

  statement {
    sid    = "AWSCloudTrailWrite"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.cloudtrail.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudtrail:${var.aws_region}:${data.aws_caller_identity.current.account_id}:trail/aegis-statefulset-${var.environment}"]
    }
  }
}

# ---- CloudTrail itself ----
resource "aws_cloudtrail" "main" {
  name           = "aegis-statefulset-${var.environment}"
  s3_bucket_name = aws_s3_bucket.cloudtrail.id

  is_multi_region_trail         = true
  is_organization_trail         = false
  enable_log_file_validation    = true # SHA-256 hash chain — ADR-07 tamper protection
  include_global_service_events = true

  kms_key_id = aws_kms_key.logs.arn

  # Capture data plane events for backup buckets — every read/write/delete on
  # customer-data-derived backup objects is an audit event. CloudTrail data
  # events bill per event; the backup bucket has low-volume access patterns
  # so cost is bounded (FinOps-aware per ADR-10).
  event_selector {
    read_write_type           = "All"
    include_management_events = true

    data_resource {
      type   = "AWS::S3::Object"
      values = ["${aws_s3_bucket.backup_source.arn}/"]
    }
  }

  # CloudWatch Logs integration — forwards trail events to CW Logs which the
  # Wazuh manager (ADR-07) ingests. The audit log thus appears in two places:
  # tamper-protected S3 (system-of-record) and CW Logs (queryable hot tier).
  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.cloudtrail_cwlogs.arn

  depends_on = [
    aws_s3_bucket_policy.cloudtrail,
    aws_s3_bucket_object_lock_configuration.cloudtrail,
  ]

  tags = {
    Component = "audit"
    Tier      = "shared"
  }
}

# ---- CloudWatch Logs group (90-day hot tier per ADR-07) ----
resource "aws_cloudwatch_log_group" "cloudtrail" {
  name              = "/aws/cloudtrail/aegis-statefulset-${var.environment}"
  retention_in_days = 90 # ADR-07 hot tier
  kms_key_id        = aws_kms_key.logs.arn

  tags = {
    Component = "audit"
  }
}

resource "aws_iam_role" "cloudtrail_cwlogs" {
  name = "aegis-statefulset-cloudtrail-cwlogs-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudtrail.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Component = "audit"
  }
}

resource "aws_iam_role_policy" "cloudtrail_cwlogs" {
  name = "cloudtrail-cwlogs"
  role = aws_iam_role.cloudtrail_cwlogs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
      }
    ]
  })
}
