# secrets-manager.tf
#
# AWS Secrets Manager surfaces consumed by ESO (External Secrets Operator)
# inside the cluster. Implements ADR-07.
#
# Pattern:
#   - Each secret is created here as a named resource with KMS encryption.
#   - The first version is a placeholder; operators rotate the real value
#     through the AWS console or a separate rotation Lambda.
#   - lifecycle.ignore_changes on secret_string keeps Terraform from
#     overwriting the operator-set value on subsequent applies.
#   - ESO's IRSA role (defined in iam.tf, not here) has GetSecretValue
#     scoped to these secret ARNs; that's the bridge that gets the secret
#     into a K8s Secret object inside the cluster.

# Restic password — used by backup CronJob and DR restore Jobs.
# Compromise would let an attacker decrypt all backups; rotation is
# annual or on personnel departure.
resource "aws_secretsmanager_secret" "restic_password" {
  name                    = "aegis-statefulset-${var.environment}/restic-password"
  description             = "Restic encryption password for backup pipeline (ADR-04)"
  kms_key_id              = aws_kms_key.secrets.arn
  recovery_window_in_days = 30

  tags = merge(local.common_tags, { SecretClass = "backup" })
}

resource "aws_secretsmanager_secret_version" "restic_password" {
  secret_id     = aws_secretsmanager_secret.restic_password.id
  secret_string = "PLACEHOLDER-REPLACE-VIA-CONSOLE"

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# Grafana Cloud API token — read by terraform-grafana provider during apply
# and by ESO at runtime for stack-scoped resources that need rotation.
resource "aws_secretsmanager_secret" "grafana_cloud_token" {
  name                    = "aegis-statefulset-${var.environment}/grafana-cloud-token"
  description             = "Grafana Cloud API token (ADR-06)"
  kms_key_id              = aws_kms_key.secrets.arn
  recovery_window_in_days = 30

  tags = merge(local.common_tags, { SecretClass = "observability" })
}

resource "aws_secretsmanager_secret_version" "grafana_cloud_token" {
  secret_id     = aws_secretsmanager_secret.grafana_cloud_token.id
  secret_string = "PLACEHOLDER-REPLACE-VIA-CONSOLE"

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# Application database / cache / external-API tokens go here as additional
# resources following the same pattern. Each one:
#   1. aws_secretsmanager_secret with KMS encryption + recovery window.
#   2. aws_secretsmanager_secret_version with placeholder + ignore_changes.
#   3. ExternalSecret CR in helm/aegis-statefulset/templates/ that ESO
#      reconciles into a K8s Secret.

# Outputs for IAM policy generation in iam.tf (least-privilege scope).
output "secret_arns" {
  description = "ARNs of secrets ESO needs GetSecretValue on"
  value = {
    restic_password     = aws_secretsmanager_secret.restic_password.arn
    grafana_cloud_token = aws_secretsmanager_secret.grafana_cloud_token.arn
  }
}
