# parameter-store.tf
#
# AWS SSM Parameter Store SecureString surfaces consumed by ESO (External
# Secrets Operator) inside the cluster. Implements ADR-07.
#
# Why Parameter Store SecureString instead of Secrets Manager:
#   - Both secrets here are write-once. Restic password CANNOT rotate
#     without orphaning existing backups. Grafana Cloud token is rotated
#     manually via Grafana UI — no Lambda rotation hook is meaningful.
#   - Secrets Manager's rotation primitive is the main thing it charges
#     for ($0.40/secret/mo). Without that benefit, Parameter Store
#     SecureString is the right fit.
#   - Same KMS CMK for at-rest encryption (`aws_kms_key.secrets`), same
#     IAM scoping model, same audit-trail surface — only the rotation
#     primitive and the price tag differ.
#
# Pattern:
#   - Each parameter is SecureString, encrypted with the dedicated KMS
#     CMK (same key as backup/data — see kms.tf).
#   - First value is a placeholder; operators set the real value via
#     `aws ssm put-parameter --overwrite` or the AWS console.
#   - lifecycle.ignore_changes on value keeps Terraform from overwriting
#     the operator-set value on subsequent applies.
#   - ESO's IRSA role (defined in iam.tf) needs ssm:GetParameter +
#     kms:Decrypt on these parameter ARNs to reconcile into a K8s Secret.

# Restic password — used by backup CronJob and DR restore Jobs.
# Compromise lets an attacker decrypt all backups; rotation orphans them.
# Never auto-rotate; manual rotation only on personnel departure (with a
# corresponding key-rolling backup migration plan).
resource "aws_ssm_parameter" "restic_password" {
  name        = "/aegis-statefulset/${var.environment}/restic-password"
  description = "Restic encryption password for backup pipeline (ADR-04)"
  type        = "SecureString"
  key_id      = aws_kms_key.secrets.arn
  value       = "PLACEHOLDER-REPLACE-VIA-CONSOLE"

  tags = merge(local.common_tags, { SecretClass = "backup" })

  lifecycle {
    ignore_changes = [value]
  }
}

# Grafana Cloud API token — read by ESO at runtime for in-cluster stack
# interactions. The Terraform-time consumption (during apply, by the
# grafana provider) uses TF_VAR_grafana_cloud_token from the operator's
# shell env, NOT this parameter — terraform can't read its own output.
resource "aws_ssm_parameter" "grafana_cloud_token" {
  name        = "/aegis-statefulset/${var.environment}/grafana-cloud-token"
  description = "Grafana Cloud API token (ADR-06)"
  type        = "SecureString"
  key_id      = aws_kms_key.secrets.arn
  value       = "PLACEHOLDER-REPLACE-VIA-CONSOLE"

  tags = merge(local.common_tags, { SecretClass = "observability" })

  lifecycle {
    ignore_changes = [value]
  }
}

# Application database / cache / external-API tokens go here as additional
# resources following the same pattern. Each one:
#   1. aws_ssm_parameter with type=SecureString + KMS encryption.
#   2. Placeholder value with lifecycle.ignore_changes.
#   3. ExternalSecret CR in helm/aegis-statefulset/templates/ that ESO
#      reconciles into a K8s Secret.

# Output preserved as `secret_arns` to keep downstream consumers
# (CI workflows / runbooks that call `terraform output secret_arns`)
# working without churn. Values are SSM parameter ARNs which fulfill
# the same semantic role.
output "secret_arns" {
  description = "ARNs of SSM SecureString parameters ESO needs ssm:GetParameter on"
  value = {
    restic_password     = aws_ssm_parameter.restic_password.arn
    grafana_cloud_token = aws_ssm_parameter.grafana_cloud_token.arn
  }
}
