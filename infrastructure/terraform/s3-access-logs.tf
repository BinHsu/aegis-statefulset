# Shared S3 access-log bucket — destination for every other bucket's
# server-access logs. Satisfies tfsec aws-s3-enable-bucket-logging
# (every bucket needs a logging target) without each bucket needing its
# own dedicated log destination.
#
# Per ADR-07 § audit pipeline: bucket-level access logs are an
# orthogonal data source to CloudTrail data-events; CloudTrail is the
# API-call audit; this is the object-access audit. Both feed the
# tamper-protected audit log pipeline (object-lock retained 7 years).
#
# Why a separate file: keeps the dependency direction clean — every
# other bucket can `references` this resource without circular tf
# state coupling.

resource "aws_s3_bucket" "access_logs" {
  bucket = "aegis-statefulset-s3-access-logs-${var.environment}-${data.aws_caller_identity.current.account_id}"

  tags = merge(local.common_tags, { Purpose = "S3-access-log-target" })
}

resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # SSE-S3 — log destination buckets cannot use SSE-KMS without IAM dance for log delivery principal.
    }
  }
}

resource "aws_s3_bucket_versioning" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    id     = "expire-old-logs"
    status = "Enabled"

    filter {}

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    expiration {
      days = 365 # one year of access logs; cheaper than CloudTrail retention since it's higher volume
    }
  }
}

# Allow the S3 log-delivery principal to write to this bucket.
# This is the canonical pattern; without the policy, target-bucket
# logs are silently dropped.
resource "aws_s3_bucket_policy" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowS3LogDelivery"
      Effect = "Allow"
      Principal = {
        Service = "logging.s3.amazonaws.com"
      }
      Action   = "s3:PutObject"
      Resource = "${aws_s3_bucket.access_logs.arn}/*"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
      }
    }]
  })
}
