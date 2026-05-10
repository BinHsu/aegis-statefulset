# AWS Budgets per ADR-10 — three-threshold ladder (50% forecast / 80% actual /
# 100% forecast) → SNS → on-call channel. Budget alarm sits on the same severity
# ladder as availability alarms; a forecast 100% breach pages on-call the same
# way an SLO breach does (FinOps Foundation Principle 3 — "Everyone takes
# ownership of cloud usage").

resource "aws_sns_topic" "finops_alerts" {
  name              = "aegis-statefulset-finops-${var.environment}"
  kms_master_key_id = aws_kms_key.logs.id

  tags = {
    Component = "finops"
    Tier      = "shared"
    DataClass = "operational"
  }
}

resource "aws_sns_topic_subscription" "finops_email" {
  count = length(var.finops_alert_emails)

  topic_arn = aws_sns_topic.finops_alerts.arn
  protocol  = "email"
  endpoint  = var.finops_alert_emails[count.index]
}

# Allow AWS Budgets service to publish to the SNS topic.
data "aws_iam_policy_document" "finops_alerts_topic_policy" {
  statement {
    sid    = "AllowBudgetsServiceToPublish"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }

    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.finops_alerts.arn]
  }

  statement {
    sid    = "AllowCostAnomalyDetectionToPublish"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["costalerts.amazonaws.com"]
    }

    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.finops_alerts.arn]
  }
}

resource "aws_sns_topic_policy" "finops_alerts" {
  arn    = aws_sns_topic.finops_alerts.arn
  policy = data.aws_iam_policy_document.finops_alerts_topic_policy.json
}

# ====================================================================
# Monthly project-wide budget (env-scoped)
# ====================================================================
resource "aws_budgets_budget" "monthly_total" {
  name         = "aegis-statefulset-${var.environment}-monthly"
  budget_type  = "COST"
  limit_amount = var.monthly_budget_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name = "TagKeyValue"
    values = [
      "aws:Project$aegis-statefulset",
      "aws:Environment$${var.environment}",
    ]
  }

  # 50% forecast — early warning, email-only, no page.
  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 50
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_sns_topic_arns = [aws_sns_topic.finops_alerts.arn]
  }

  # 80% actual — actionable, requires investigation.
  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 80
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.finops_alerts.arn]
  }

  # 100% forecast — page on-call, treated like a Severity 2.
  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_sns_topic_arns = [aws_sns_topic.finops_alerts.arn]
  }
}

# ====================================================================
# Per-tier budget (stateful) — separate alert ladder for stateful overruns.
# Stateful tier is the predictable baseline (per ADR-04, ADR-02); a breach
# here means either tenant growth (expected, plan capacity) or drift
# (unexpected, investigate).
# ====================================================================
resource "aws_budgets_budget" "stateful_monthly" {
  name         = "aegis-statefulset-${var.environment}-stateful"
  budget_type  = "COST"
  limit_amount = var.monthly_budget_stateful_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name = "TagKeyValue"
    values = [
      "aws:Tier$stateful",
      "aws:Environment$${var.environment}",
    ]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 80
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.finops_alerts.arn]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_sns_topic_arns = [aws_sns_topic.finops_alerts.arn]
  }
}
