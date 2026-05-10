# AWS Cost Anomaly Detector per ADR-10.
# Catches drift the budget ladder misses — a rogue m6i.32xlarge spinning up
# because someone forgot to set instance_types on a node group, an accidental
# dev cluster left running over a long weekend. Free service; daily cadence.

resource "aws_ce_anomaly_monitor" "project" {
  name              = "aegis-statefulset-${var.environment}"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"

  tags = {
    Component = "finops"
    Tier      = "shared"
    DataClass = "operational"
  }
}

resource "aws_ce_anomaly_subscription" "project" {
  name      = "aegis-statefulset-${var.environment}-anomaly-sub"
  frequency = "DAILY"

  monitor_arn_list = [aws_ce_anomaly_monitor.project.arn]

  subscriber {
    type    = "SNS"
    address = aws_sns_topic.finops_alerts.arn
  }

  # Alert on anomalies whose absolute impact crosses $100. Tuned to suppress
  # the long tail of $5-20 noise events; raise to $250 if alert fatigue sets in
  # during the first month of operation.
  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      values        = ["100"]
      match_options = ["GREATER_THAN_OR_EQUAL"]
    }
  }

  tags = {
    Component = "finops"
    Tier      = "shared"
    DataClass = "operational"
  }
}
