# Backup buckets per ADR-04 (configurable backup cadence) and ADR-04
# (cross-region S3 replication is the baseline — cross-region EBS is not).

# Source bucket — same region as the cluster
resource "aws_s3_bucket" "backup_source" {
  bucket = "aegis-statefulset-backup-${var.environment}-${data.aws_caller_identity.current.account_id}"

  tags = local.common_tags
}

resource "aws_s3_bucket_versioning" "backup_source" {
  bucket = aws_s3_bucket.backup_source.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backup_source" {
  bucket = aws_s3_bucket.backup_source.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.backup.id
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "backup_source" {
  bucket                  = aws_s3_bucket.backup_source.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_logging" "backup_source" {
  bucket = aws_s3_bucket.backup_source.id

  target_bucket = aws_s3_bucket.access_logs.id
  target_prefix = "backup-source/"
}

resource "aws_s3_bucket_lifecycle_configuration" "backup_source" {
  bucket = aws_s3_bucket.backup_source.id

  rule {
    id     = "expire-incomplete-multipart"
    status = "Enabled"
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "transition-to-glacier"
    status = "Enabled"
    transition {
      days          = 30
      storage_class = "GLACIER_IR"
    }
    expiration {
      days = 90 # 30 days hot + 60 days Glacier IR per ADR-04 retention
    }
  }
}

# DR bucket — different region per ADR-04.
# Replication policy + IAM role for the replication operator are stubbed below;
# wire them up via aws_s3_bucket_replication_configuration before go-live.
# Note: cross-region replication adds ~$200/month (per ADR-04 cost discussion).
provider "aws" {
  alias  = "dr_region"
  region = var.dr_region
}

resource "aws_s3_bucket" "backup_dr" {
  provider = aws.dr_region

  bucket = "aegis-statefulset-backup-dr-${var.environment}-${data.aws_caller_identity.current.account_id}"

  tags = merge(local.common_tags, { Purpose = "DR" })
}

resource "aws_s3_bucket_versioning" "backup_dr" {
  provider = aws.dr_region

  bucket = aws_s3_bucket.backup_dr.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "backup_dr" {
  provider = aws.dr_region

  bucket                  = aws_s3_bucket.backup_dr.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backup_dr" {
  provider = aws.dr_region

  bucket = aws_s3_bucket.backup_dr.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # SSE-S3 — DR-region KMS key complexity skipped for POC. Production upgrade trigger: provision a DR-region KMS key per ADR-07.
    }
  }
}

# TODO: aws_s3_bucket_replication_configuration on the source bucket pointing at DR
#       + IAM role for the replication operator.
