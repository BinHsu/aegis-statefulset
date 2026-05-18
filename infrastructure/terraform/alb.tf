# Single-layer ALB across the three AZs (per ADR-03), TLS terminated at the edge
# with ACM-issued certificate (per ADR-07).

# ACM certificate disabled while route53.tf is also disabled (no DNS
# zone in this account → DNS-01 validation can't complete, terraform
# resource times out after 5min waiting for ISSUED state). Re-enable
# in lockstep with route53.tf + a delegated hosted zone. The cert was
# orphaned anyway — no aws_lb_listener references it (HTTPS listener
# is wired up in production via a separate manifest, not in this POC).
#
# resource "aws_acm_certificate" "main" {
#   domain_name       = var.domain_name
#   validation_method = "DNS"
#
#   subject_alternative_names = ["*.${var.domain_name}"]
#
#   lifecycle {
#     create_before_destroy = true
#   }
#
#   tags = local.common_tags
# }

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
  description = "ALB north-south ingress (HTTPS from internet, egress to backend) per ADR-03"
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

# Bucket policy granting Elastic Load Balancing permission to deliver
# access logs. Without this the aws_lb access_logs block fails at apply
# with "Access Denied for bucket". Two grant paths for robustness:
#   1. logdelivery.elasticloadbalancing.amazonaws.com — the modern
#      service principal (AWS-recommended, all commercial regions).
#   2. The eu-central-1 regional ELB service account (054676820928) —
#      the pre-2022-Region log-delivery path; harmless belt-and-suspenders.
# block_public_policy stays true: an AWS-service-principal grant is not
# a "public" grant, so the public-access-block does not reject it.
resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "ALBLogDeliveryWriteServicePrincipal"
        Effect    = "Allow"
        Principal = { Service = "logdelivery.elasticloadbalancing.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.alb_logs.arn}/*"
      },
      {
        Sid       = "ALBLogDeliveryWriteRegionalAccount"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::054676820928:root" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.alb_logs.arn}/*"
      },
      {
        Sid       = "ALBLogDeliveryAclCheck"
        Effect    = "Allow"
        Principal = { Service = "logdelivery.elasticloadbalancing.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.alb_logs.arn
      },
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.alb_logs]
}
