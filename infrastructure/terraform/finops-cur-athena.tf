# Cost and Usage Report (CUR) → S3 → Athena/Glue per ADR-10.
# Per-tenant cost attribution mechanism: CUR captures every line item with
# RESOURCES + SPLIT_COST_ALLOCATION_DATA enabled; Athena queries join the cost
# lines with the tenant cost dimension propagated from pod labels via Container
# Insights (see scripts/finops/per-tenant-cost-attribution.sql).

# ====================================================================
# CUR delivery bucket (KMS-encrypted, BillingReports principal allowed)
# ====================================================================
resource "aws_s3_bucket" "cur" {
  bucket = "aegis-statefulset-cur-${var.environment}-${data.aws_caller_identity.current.account_id}"

  tags = {
    Component = "finops"
    Tier      = "shared"
    DataClass = "operational"
  }
}

resource "aws_s3_bucket_ownership_controls" "cur" {
  bucket = aws_s3_bucket.cur.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "cur" {
  bucket = aws_s3_bucket.cur.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "cur" {
  bucket = aws_s3_bucket.cur.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_logging" "cur" {
  bucket = aws_s3_bucket.cur.id

  target_bucket = aws_s3_bucket.access_logs.id
  target_prefix = "cur/"
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cur" {
  bucket = aws_s3_bucket.cur.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.logs.id
    }
    bucket_key_enabled = true
  }
}

# Allow the AWS Billing Reports service to write CUR objects.
data "aws_iam_policy_document" "cur_bucket" {
  statement {
    sid    = "AllowCURGetBucketAclAndPolicy"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["billingreports.amazonaws.com"]
    }

    actions = [
      "s3:GetBucketAcl",
      "s3:GetBucketPolicy",
    ]

    resources = [aws_s3_bucket.cur.arn]
  }

  statement {
    sid    = "AllowCURPutObject"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["billingreports.amazonaws.com"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.cur.arn}/*"]
  }
}

resource "aws_s3_bucket_policy" "cur" {
  bucket = aws_s3_bucket.cur.id
  policy = data.aws_iam_policy_document.cur_bucket.json
}

# ====================================================================
# CUR report definition (hourly Parquet with RESOURCES + split-cost data)
# ====================================================================
# The report MUST be created in us-east-1 — AWS limitation, the cur API only
# accepts requests in that region even though the bucket can live anywhere.
# Provider alias `aws.us_east_1` is expected to be configured in versions.tf
# (out of POC scope to wire here; documented as a known follow-up).
resource "aws_cur_report_definition" "main" {
  report_name                = "aegis-statefulset-${var.environment}"
  time_unit                  = "HOURLY"
  format                     = "Parquet"
  compression                = "Parquet"
  additional_schema_elements = ["RESOURCES", "SPLIT_COST_ALLOCATION_DATA"]
  s3_bucket                  = aws_s3_bucket.cur.id
  s3_prefix                  = "cur"
  s3_region                  = var.aws_region
  additional_artifacts       = ["ATHENA"]
  refresh_closed_reports     = true
  report_versioning          = "OVERWRITE_REPORT"

  depends_on = [aws_s3_bucket_policy.cur]
}

# ====================================================================
# Athena workgroup for FinOps queries (KMS-encrypted result location)
# ====================================================================
resource "aws_athena_workgroup" "finops" {
  name = "aegis-statefulset-finops-${var.environment}"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    result_configuration {
      output_location = "s3://${aws_s3_bucket.cur.id}/athena-results/"

      encryption_configuration {
        encryption_option = "SSE_KMS"
        kms_key_arn       = aws_kms_key.logs.arn
      }
    }
  }

  tags = {
    Component = "finops"
    Tier      = "shared"
    DataClass = "operational"
  }
}

# ====================================================================
# Glue catalog database — Athena CUR tables register here
# ====================================================================
resource "aws_glue_catalog_database" "finops" {
  name        = "aegis_statefulset_finops_${var.environment}"
  description = "FinOps cost queries — per ADR-10. Tables registered by AWS CUR Athena integration."
}
