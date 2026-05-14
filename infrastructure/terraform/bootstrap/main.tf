# infrastructure/terraform/bootstrap/main.tf
#
# Stage-0 terraform: provisions the state backend (S3 + DynamoDB) that the
# main composition depends on. Runs with a LOCAL backend — see README for
# the chicken-and-egg explanation.
#
# Idempotent — re-running is safe.

terraform {
  required_version = ">= 1.6"
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
  state_lock_name   = "aegis-statefulset-tflock-${var.environment}"
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
# DynamoDB — terraform state lock table
# ============================================================================

resource "aws_dynamodb_table" "tflock" {
  name         = local.state_lock_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  lifecycle {
    prevent_destroy = true # losing the lock table = state-race risk
  }
}
