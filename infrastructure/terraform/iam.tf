# IRSA role for the application service account.
# Per ADR-07 (zero-trust network policies) the application's blast radius
# is also constrained at the IAM layer — only the buckets/keys it needs.

data "aws_iam_policy_document" "irsa_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:aegis-app:aegis-statefulset"]
    }
  }
}

resource "aws_iam_role" "aegis_statefulset" {
  name               = "aegis-statefulset-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.irsa_assume.json

  tags = local.common_tags
}

# Permissions: read/write backup bucket, use the relevant per-tier KMS keys.
resource "aws_iam_role_policy" "aegis_statefulset" {
  name = "aegis-statefulset-permissions"
  role = aws_iam_role.aegis_statefulset.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3BackupAccess"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:DeleteObject"
        ]
        Resource = [
          aws_s3_bucket.backup_source.arn,
          "${aws_s3_bucket.backup_source.arn}/*"
        ]
      },
      {
        Sid    = "KMSDataKey"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey"
        ]
        Resource = [
          aws_kms_key.backup.arn,
          aws_kms_key.stateful_data.arn,
          aws_kms_key.secrets.arn
        ]
      },
      {
        Sid    = "DynamoDBPlacementTable"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem",
          "dynamodb:Query",
          "dynamodb:DescribeTable"
        ]
        Resource = [
          aws_dynamodb_table.placement.arn
        ]
      },
      {
        Sid    = "DynamoDBStreamForLambda"
        Effect = "Allow"
        Action = [
          "dynamodb:DescribeStream",
          "dynamodb:GetShardIterator",
          "dynamodb:GetRecords",
          "dynamodb:ListStreams"
        ]
        Resource = [
          aws_dynamodb_table.placement.stream_arn
        ]
      },
      {
        Sid    = "KMSPlacementTable"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey"
        ]
        Resource = [
          aws_kms_key.placement_table.arn
        ]
      }
    ]
  })
}

# Cache invalidation Lambda role — subscribes to placement table Stream,
# calls Envoy admin API to invalidate cache entries (per ADR-03 4-layer protection)
resource "aws_iam_role" "cache_invalidator" {
  name = "aegis-statefulset-cache-invalidator-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "cache_invalidator" {
  name = "cache-invalidator-permissions"
  role = aws_iam_role.cache_invalidator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:DescribeStream",
          "dynamodb:GetShardIterator",
          "dynamodb:GetRecords",
          "dynamodb:ListStreams"
        ]
        Resource = aws_dynamodb_table.placement.stream_arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = aws_kms_key.placement_table.arn
      }
    ]
  })
}

output "cache_invalidator_role_arn" {
  value       = aws_iam_role.cache_invalidator.arn
  description = "IAM role ARN for cache invalidation Lambda (subscribes to placement table Stream)"
}

# --------------------------------------------------------------------
# AWS Load Balancer Controller IRSA
# --------------------------------------------------------------------
# Used by the helm_release in cluster-controllers.tf. Trust pinned to
# kube-system:aws-load-balancer-controller.
resource "aws_iam_role" "alb_controller" {
  # Full project prefix `aegis-statefulset-` rather than short `aegis-` —
  # `aegis-` collides with sibling repos in shared accounts (LDZ owns
  # its own aegis-* resources). See aegis-aws-landing-zone issue #54
  # for the platform-side naming conventions this aligns with.
  name = "aegis-statefulset-alb-controller-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
        }
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "alb_controller" {
  name = "alb-controller-permissions"
  role = aws_iam_role.alb_controller.id

  # Standard AWS Load Balancer Controller permissions (subset).
  # TODO production: replace with the upstream IAM policy JSON published in
  # kubernetes-sigs/aws-load-balancer-controller (the upstream policy
  # includes WAF + Shield + cognito-idp permissions we don't need today).
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeAccountAttributes",
          "ec2:DescribeAddresses",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeInternetGateways",
          "ec2:DescribeVpcs",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeInstances",
          "elasticloadbalancing:Describe*",
          "elasticloadbalancing:CreateTargetGroup",
          "elasticloadbalancing:DeleteTargetGroup",
          "elasticloadbalancing:RegisterTargets",
          "elasticloadbalancing:DeregisterTargets",
          "elasticloadbalancing:CreateLoadBalancer",
          "elasticloadbalancing:DeleteLoadBalancer"
        ]
        Resource = "*"
      }
    ]
  })
}

# --------------------------------------------------------------------
# Karpenter IRSA (for the helm_release controller annotation)
# --------------------------------------------------------------------
# The terraform-aws-modules/eks//karpenter module in karpenter.tf wires
# instance-profile + node IAM. This role is the *controller* SA role,
# annotated on the karpenter:karpenter ServiceAccount in cluster-controllers.tf.
resource "aws_iam_role" "karpenter" {
  # Two naming requirements stack here:
  # (1) Full project prefix `aegis-statefulset-` (avoid LDZ collision —
  #     see aegis-aws-landing-zone issue #54)
  # (2) Suffix `-karpenter-controller` — matches the org's SCP
  #     `DenyIamPrivilegeEscalation` exemption pattern
  #     `arn:aws:iam::*:role/*-karpenter-controller` so this role can
  #     be CREATED by any principal (not just ControlTowerExecution /
  #     gh-tf-*). Standard convention from terraform-aws-modules/eks.
  name = "aegis-statefulset-karpenter-controller-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:karpenter:karpenter"
        }
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "karpenter" {
  name = "karpenter-permissions"
  role = aws_iam_role.karpenter.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:RunInstances",
          "ec2:CreateTags",
          "ec2:DescribeInstances",
          "ec2:TerminateInstances",
          "iam:PassRole",
          "eks:DescribeCluster"
        ]
        Resource = "*"
      }
    ]
  })
}
