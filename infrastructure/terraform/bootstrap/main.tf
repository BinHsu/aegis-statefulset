# infrastructure/terraform/bootstrap/main.tf
#
# Stage-0 terraform: provisions the state backend (S3 + DynamoDB) that the
# main composition depends on. Runs with a LOCAL backend — see README for
# the chicken-and-egg explanation.
#
# Idempotent — re-running is safe.

terraform {
  # 1.10+ required for the main composition's S3 backend `use_lockfile`
  # option (native S3-conditional-writes locking, replaces DynamoDB).
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }
  # Local backend by design — see README. The state file lives under
  # this directory and is gitignored.
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "aegis-statefulset"
      Component   = "tfstate-backend"
      ManagedBy   = "terraform"
      Environment = var.environment
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  # S3 bucket names are globally unique — include account ID to namespace.
  state_bucket_name = "aegis-statefulset-tfstate-${var.environment}-${data.aws_caller_identity.current.account_id}"
  # No separate DynamoDB lock table — terraform 1.10+ S3 backend
  # `use_lockfile = true` uses S3 conditional writes (If-None-Match)
  # for native locking. One less service, one less IAM scope.
}

# ============================================================================
# S3 — terraform state bucket
# ============================================================================

resource "aws_s3_bucket" "tfstate" {
  bucket = local.state_bucket_name

  lifecycle {
    prevent_destroy = true # state bucket should NEVER be auto-destroyed
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    id     = "expire-non-current-versions"
    status = "Enabled"
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

# ============================================================================
# State locking — handled by S3 itself via terraform 1.10+ `use_lockfile`
# ============================================================================
# Terraform 1.10 (Nov 2024) added native S3 locking using S3 conditional
# writes (If-None-Match) introduced in AWS S3 the same month. The main
# composition's backend uses `use_lockfile = true` instead of a separate
# DynamoDB table. Benefits:
#   - One less service to provision + monitor
#   - One less IAM scope to manage (no dynamodb:* required)
#   - Zero DynamoDB cost (even PAY_PER_REQUEST has request fees)
#   - Lock granularity per-key (same as DynamoDB pattern)
# See: https://developer.hashicorp.com/terraform/language/backend/s3#use-lockfile
