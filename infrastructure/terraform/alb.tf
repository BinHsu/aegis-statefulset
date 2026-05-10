# Single-layer ALB across the three AZs (per ADR-03), TLS terminated at the edge
# with ACM-issued certificate (per ADR-07).

resource "aws_acm_certificate" "main" {
  domain_name       = var.domain_name
  validation_method = "DNS"

  subject_alternative_names = ["*.${var.domain_name}"]

  lifecycle {
    create_before_destroy = true
  }

  tags = local.common_tags
}

# DNS validation record creation depends on Route 53 zone — see route53.tf when added.

resource "aws_lb" "main" {
  name               = "aegis-statefulset-${var.environment}"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = module.vpc.public_subnets

  enable_deletion_protection = var.environment == "prod" ? true : false
  enable_http2               = true
  drop_invalid_header_fields = true

  access_logs {
    bucket  = aws_s3_bucket.alb_logs.id
    prefix  = "alb"
    enabled = true
  }

  tags = local.common_tags
}

resource "aws_security_group" "alb" {
  name_prefix = "aegis-statefulset-alb-"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "HTTPS from public internet - ALB north-south ingress per ADR-03. WAF + NetworkPolicy do application-layer filtering."
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "ALB egress to backend pods + AWS APIs - restricted at cluster boundary by NetworkPolicy per ADR-07."
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.common_tags
}

resource "aws_s3_bucket" "alb_logs" {
  bucket = "aegis-statefulset-alb-logs-${var.environment}-${data.aws_caller_identity.current.account_id}"

  tags = local.common_tags
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # SSE-S3 — ALB log delivery principal cannot use SSE-KMS without elaborate IAM dance.
    }
  }
}

resource "aws_s3_bucket_versioning" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_logging" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  target_bucket = aws_s3_bucket.access_logs.id
  target_prefix = "alb-logs/"
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket                  = aws_s3_bucket.alb_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
