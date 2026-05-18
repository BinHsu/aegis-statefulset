# Velero Backup Storage Location (BSL) bucket + cross-region replication.
# Per ADR-07 (Velero IAM) + ADR-04 (DR strategy).
#
# In-region: standard versioned + KMS-encrypted bucket for Velero metadata.
# DR-region: replica with Glacier Instant Retrieval lifecycle (cost-aware
# tail; restore latency in tens of ms vs. Deep Archive).
#
# IRSA: Velero ServiceAccount uses the role defined here; trust policy
# pins to system:serviceaccount:velero:velero so a compromised SA in
# another namespace cannot assume it.

# --------------------------------------------------------------------
# DR-tier BSL bucket — replicated cross-region.
# Used by Schedule B (DR cadence, e.g., 4h) with snapshotMoveData=true
# for the CSI path; FSB chunks for FSB path also land here.
# Per ADR-04 § "dual-cadence pattern" + ADR-04 § "FSB dual-bucket pattern".
# --------------------------------------------------------------------
resource "aws_s3_bucket" "velero_bsl" {
  bucket = "aegis-velero-bsl-${var.environment}-${data.aws_caller_identity.current.account_id}"

  tags = {
    Component = "dr"
    Tier      = "dr-replicated"
    DataClass = "operational"
  }
}

# --------------------------------------------------------------------
# Operational-tier BSL bucket — NOT replicated cross-region.
# Used by Schedule A (operational cadence, e.g., 5 min) for fast roll-back
# scenarios where cross-region copy is unnecessary cost. Source-region
# only; deleted when source region lost.
# Per ADR-04 § "dual-cadence pattern" + ADR-04 § "FSB dual-bucket pattern".
# --------------------------------------------------------------------
resource "aws_s3_bucket" "velero_bsl_operational" {
  bucket = "aegis-velero-bsl-operational-${var.environment}-${data.aws_caller_identity.current.account_id}"

  tags = {
    Component = "dr"
    Tier      = "operational-source-only"
    DataClass = "operational"
  }
}

resource "aws_s3_bucket_versioning" "velero_bsl_operational" {
  bucket = aws_s3_bucket.velero_bsl_operational.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "velero_bsl_operational" {
  bucket = aws_s3_bucket.velero_bsl_operational.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.logs.arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "velero_bsl_operational" {
  bucket                  = aws_s3_bucket.velero_bsl_operational.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_logging" "velero_bsl_operational" {
  bucket        = aws_s3_bucket.velero_bsl_operational.id
  target_bucket = aws_s3_bucket.access_logs.id
  target_prefix = "velero-bsl-operational/"
}

resource "aws_s3_bucket_lifecycle_configuration" "velero_bsl_operational" {
  bucket = aws_s3_bucket.velero_bsl_operational.id
  rule {
    id     = "expire-old-operational"
    status = "Enabled"
    filter {}
    expiration {
      days = 7 # operational tier: 7-day retention; matches Schedule A ttl
    }
  }
}

resource "aws_s3_bucket_versioning" "velero_bsl" {
  bucket = aws_s3_bucket.velero_bsl.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "velero_bsl" {
  bucket = aws_s3_bucket.velero_bsl.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.logs.arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "velero_bsl" {
  bucket                  = aws_s3_bucket.velero_bsl.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_logging" "velero_bsl" {
  bucket = aws_s3_bucket.velero_bsl.id

  target_bucket = aws_s3_bucket.access_logs.id
  target_prefix = "velero-bsl/"
}

# --------------------------------------------------------------------
# DR-region replica bucket (Glacier Instant Retrieval)
# --------------------------------------------------------------------
resource "aws_s3_bucket" "velero_bsl_dr" {
  provider = aws.dr_region

  bucket = "aegis-velero-bsl-dr-${var.environment}-${data.aws_caller_identity.current.account_id}"

  tags = {
    Component = "dr"
    Tier      = "shared"
    Purpose   = "DR"
  }
}

resource "aws_s3_bucket_versioning" "velero_bsl_dr" {
  provider = aws.dr_region

  bucket = aws_s3_bucket.velero_bsl_dr.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "velero_bsl_dr" {
  provider = aws.dr_region

  bucket = aws_s3_bucket.velero_bsl_dr.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # SSE-S3 — DR-region KMS key complexity skipped for POC. Production upgrade trigger: provision a DR-region KMS key per ADR-07.
    }
  }
}

resource "aws_s3_bucket_public_access_block" "velero_bsl_dr" {
  provider = aws.dr_region

  bucket                  = aws_s3_bucket.velero_bsl_dr.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "velero_bsl_dr" {
  provider = aws.dr_region
  bucket   = aws_s3_bucket.velero_bsl_dr.id

  rule {
    id     = "transition-to-glacier-ir"
    status = "Enabled"

    transition {
      days          = 1
      storage_class = "GLACIER_IR"
    }
  }
}

resource "aws_s3_bucket_logging" "velero_bsl_dr" {
  provider = aws.dr_region

  bucket = aws_s3_bucket.velero_bsl_dr.id

  # Logs to the DR-region access-log bucket — server-access logging
  # requires the target in the same region as the source.
  target_bucket = aws_s3_bucket.access_logs_dr.id
  target_prefix = "velero-bsl-dr/"
}

# --------------------------------------------------------------------
# Cross-region replication (source -> DR)
# --------------------------------------------------------------------
resource "aws_iam_role" "velero_replication" {
  name = "aegis-velero-replication-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "velero_replication" {
  name = "velero-replication-policy"
  role = aws_iam_role.velero_replication.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetReplicationConfiguration",
          "s3:ListBucket",
          "s3:GetObjectVersionForReplication",
          "s3:GetObjectVersionAcl",
          "s3:GetObjectVersionTagging",
          "s3:ReplicateObject",
          "s3:ReplicateDelete",
          "s3:ReplicateTags"
        ]
        Resource = [
          aws_s3_bucket.velero_bsl.arn,
          "${aws_s3_bucket.velero_bsl.arn}/*",
          aws_s3_bucket.velero_bsl_dr.arn,
          "${aws_s3_bucket.velero_bsl_dr.arn}/*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_s3_bucket_replication_configuration" "velero_bsl" {
  # Replication requires versioning on the source bucket.
  depends_on = [aws_s3_bucket_versioning.velero_bsl]

  bucket = aws_s3_bucket.velero_bsl.id
  role   = aws_iam_role.velero_replication.arn

  rule {
    id       = "velero-cross-region-replicate"
    status   = "Enabled"
    priority = 0

    filter {}

    delete_marker_replication {
      status = "Disabled"
    }

    destination {
      bucket        = aws_s3_bucket.velero_bsl_dr.arn
      storage_class = "GLACIER_IR"
    }
  }
}

# --------------------------------------------------------------------
# Velero IRSA role (per ADR-07)
# --------------------------------------------------------------------
resource "aws_iam_role" "velero" {
  name = "aegis-velero-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:velero:velero"
        }
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "velero" {
  name = "velero-permissions"
  role = aws_iam_role.velero.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateSnapshot",
          "ec2:CreateSnapshots",
          "ec2:CopySnapshot",
          "ec2:CreateTags",
          "ec2:DeleteSnapshot",
          "ec2:DescribeSnapshots",
          "ec2:DescribeVolumes",
          "ec2:DescribeAvailabilityZones",
          "ec2:CreateVolume",
          "ec2:AttachVolume",
          "ec2:DetachVolume",
          "ec2:DeleteVolume"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.velero_bsl.arn,
          "${aws_s3_bucket.velero_bsl.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
        Resource = [
          aws_kms_key.logs.arn,
          aws_kms_key.stateful_data.arn,
          aws_kms_key.backup.arn
        ]
      }
    ]
  })
}

output "velero_role_arn" {
  value       = aws_iam_role.velero.arn
  description = "IAM role ARN for Velero IRSA (per ADR-07)"
}

output "velero_bsl_bucket" {
  value       = aws_s3_bucket.velero_bsl.id
  description = "Velero Backup Storage Location bucket name"
}
