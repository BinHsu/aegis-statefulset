# lifecycle-hooks.tf
#
# ASG lifecycle hook + drain Lambda for the stateful pool (ADR-04).
#
# Why this exists:
#   Stateful pods (StatefulSet primary/standby) hold EBS-locality and
#   in-memory LevelDB state. A node terminating without an orderly drain
#   causes pod restart with cold cache and brief unavailability — bad
#   experience even when EBS data is intact.
#
# How it works:
#   1. Each stateful node group has an ASG with a TERMINATING lifecycle hook.
#   2. The hook publishes to an SNS topic.
#   3. SNS triggers a Lambda that:
#        a) cordons the node (kubectl cordon)
#        b) drains the node (kubectl drain --delete-emptydir-data=false)
#        c) calls complete_lifecycle_action so the ASG can proceed
#   4. The pod is evicted gracefully via kubectl drain. K8s sends SIGTERM
#      to the container; the app's signal handler runs http.Server.Shutdown
#      + LevelDB Close() + fsync /data; the preStop hook (templated in
#      helm/.../templates/statefulset-primary.yaml) sleeps 10s first so
#      the service-level load-balancer drains before the process exits.
#      `terminationGracePeriodSeconds: 60` bounds the whole window
#      (per ADR-02 § Graceful shutdown).
#
# Out of scope here:
#   The Lambda's Python source lives in infrastructure/lambda/asg-drain/.
#   This file wires up the AWS surface (IAM, hook, topic, function shell)
#   and references the source as a local archive.

resource "aws_iam_role" "asg_drain_lambda" {
  name = "aegis-statefulset-${var.environment}-asg-drain"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "asg_drain_basic" {
  role       = aws_iam_role.asg_drain_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "asg_drain_inline" {
  name = "asg-drain-inline"
  role = aws_iam_role.asg_drain_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Complete the lifecycle action so the ASG can proceed once the
        # drain succeeds (or after a timeout).
        Effect   = "Allow"
        Action   = ["autoscaling:CompleteLifecycleAction"]
        Resource = "*"
      },
      {
        # Lambda needs to call EKS describe to discover the cluster
        # endpoint + CA, plus eks:AccessKubernetesApi via the aws-auth
        # ConfigMap (the Lambda role is mapped to a K8s RBAC group).
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "ec2:DescribeInstances",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_sns_topic" "asg_drain" {
  name              = "aegis-statefulset-${var.environment}-asg-drain"
  kms_master_key_id = aws_kms_key.secrets.key_id

  tags = local.common_tags
}

# Lifecycle hook on the master AZ stateful ASG. The hook fires on
# instance termination and pauses the ASG until the Lambda completes
# the drain (or until the heartbeat timeout, whichever first).
#
# Per ADR-04: stateful_master is the only stateful node group running
# real pods; stateful_standby is at desired=0 by default. The standby
# hooks are still wired so a post-rotation standby (now active) inherits
# the same drain semantics on the next termination.
resource "aws_autoscaling_lifecycle_hook" "stateful_master_terminating" {
  name                   = "aegis-statefulset-stateful-master-${var.master_az}-drain"
  autoscaling_group_name = aws_eks_node_group.stateful_master.resources[0].autoscaling_groups[0].name

  lifecycle_transition = "autoscaling:EC2_INSTANCE_TERMINATING"
  default_result       = "ABANDON"
  heartbeat_timeout    = 600 # 10 min — drain must complete in this window

  notification_target_arn = aws_sns_topic.asg_drain.arn
  role_arn                = aws_iam_role.asg_lifecycle.arn
}

resource "aws_autoscaling_lifecycle_hook" "stateful_standby_terminating" {
  for_each = aws_eks_node_group.stateful_standby

  name                   = "aegis-statefulset-${each.key}-drain"
  autoscaling_group_name = each.value.resources[0].autoscaling_groups[0].name

  lifecycle_transition = "autoscaling:EC2_INSTANCE_TERMINATING"
  default_result       = "ABANDON"
  heartbeat_timeout    = 600

  notification_target_arn = aws_sns_topic.asg_drain.arn
  role_arn                = aws_iam_role.asg_lifecycle.arn
}

# IAM role allowing ASG to publish lifecycle notifications to SNS.
resource "aws_iam_role" "asg_lifecycle" {
  name = "aegis-statefulset-${var.environment}-asg-lifecycle"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "autoscaling.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "asg_lifecycle_publish" {
  name = "asg-lifecycle-publish"
  role = aws_iam_role.asg_lifecycle.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.asg_drain.arn
      },
      {
        # The asg_drain SNS topic is SSE-encrypted with aws_kms_key.secrets.
        # Publishing to an encrypted topic — including the test message AWS
        # sends when the lifecycle hook is created — requires the publisher
        # to generate a data key under that CMK.
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = aws_kms_key.secrets.arn
      },
    ]
  })
}

# Lambda deployment package — zipped from infrastructure/lambda/asg-drain/
# at plan time. The handler is pure stdlib + boto3 (both in the python3.11
# runtime), so the archive is a single source file with no vendored deps.
data "archive_file" "asg_drain" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/asg-drain"
  output_path = "${path.module}/.build/asg-drain.zip"
}

# Upload the package to the artefacts bucket. terraform manages the object
# so a cold `terraform apply` is self-contained — no out-of-band CI step.
resource "aws_s3_object" "asg_drain" {
  bucket = aws_s3_bucket.lambda_artifacts.id
  key    = "asg-drain/asg-drain.zip"
  source = data.archive_file.asg_drain.output_path
  etag   = data.archive_file.asg_drain.output_md5

  depends_on = [
    aws_s3_bucket_versioning.lambda_artifacts,
    aws_s3_bucket_server_side_encryption_configuration.lambda_artifacts,
  ]
}

resource "aws_lambda_function" "asg_drain" {
  function_name = "aegis-statefulset-${var.environment}-asg-drain"
  role          = aws_iam_role.asg_drain_lambda.arn
  runtime       = "python3.11"
  handler       = "asg_drain.handler"
  timeout       = 540 # 9 min — must be < heartbeat_timeout

  s3_bucket        = aws_s3_bucket.lambda_artifacts.id
  s3_key           = aws_s3_object.asg_drain.key
  source_code_hash = data.archive_file.asg_drain.output_base64sha256

  environment {
    variables = {
      CLUSTER_NAME = local.cluster_name
      LOG_LEVEL    = "INFO"
    }
  }

  tags = local.common_tags
}

resource "aws_s3_bucket" "lambda_artifacts" {
  bucket = "aegis-statefulset-${var.environment}-lambda-artifacts"
  tags   = local.common_tags
}

resource "aws_s3_bucket_versioning" "lambda_artifacts" {
  bucket = aws_s3_bucket.lambda_artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_logging" "lambda_artifacts" {
  bucket = aws_s3_bucket.lambda_artifacts.id

  target_bucket = aws_s3_bucket.access_logs.id
  target_prefix = "lambda-artifacts/"
}

resource "aws_s3_bucket_server_side_encryption_configuration" "lambda_artifacts" {
  bucket = aws_s3_bucket.lambda_artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.secrets.arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "lambda_artifacts" {
  bucket                  = aws_s3_bucket.lambda_artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Wire SNS topic -> Lambda
resource "aws_sns_topic_subscription" "asg_drain" {
  topic_arn = aws_sns_topic.asg_drain.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.asg_drain.arn
}

resource "aws_lambda_permission" "asg_drain_sns" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.asg_drain.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.asg_drain.arn
}
