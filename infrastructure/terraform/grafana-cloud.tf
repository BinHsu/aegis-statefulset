# grafana-cloud.tf
#
# Grafana Cloud stack + dashboards via the Grafana Terraform provider.
# Implements ADR-06 (observability backend as IaC).
#
# Why IaC for dashboards:
#   - Dashboards drift in the UI; without IaC, "the dashboard exists"
#     becomes a discovery problem during incidents.
#   - 7 dashboards per ADR-06 (developer self-service dashboards).
#     Each is a JSON file in dashboards/; this file iterates over them.
#   - The same TF state holds Grafana Cloud stack creation + datasource
#     wiring + dashboard provisioning, so spinning up a new environment
#     gives a fully wired observability surface in one apply.
#
# Token sourcing:
#   The Grafana Cloud API token comes from AWS Secrets Manager
#   (see secrets-manager.tf). For local plan/apply, set
#   TF_VAR_grafana_cloud_token; CI uses the OIDC role to read the secret.

variable "grafana_cloud_token" {
  description = "Grafana Cloud API token (sourced from Secrets Manager in CI)"
  type        = string
  sensitive   = true
  default     = ""
}

provider "grafana" {
  alias = "cloud"

  cloud_access_policy_token = var.grafana_cloud_token
}

resource "grafana_cloud_stack" "main" {
  provider = grafana.cloud

  name        = "aegis-statefulset-${var.environment}"
  slug        = "aegis-statefulset-${var.environment}"
  region_slug = "eu"

  description = "Observability stack for aegis-statefulset (${var.environment})"
}

# Stack-scoped provider. Once the stack exists, datasources + dashboards
# go through the stack's URL with a stack-issued service-account token.
provider "grafana" {
  alias = "stack"

  url  = grafana_cloud_stack.main.url
  auth = grafana_cloud_stack_service_account_token.dashboards.key
}

resource "grafana_cloud_stack_service_account" "dashboards" {
  provider = grafana.cloud

  stack_slug = grafana_cloud_stack.main.slug
  name       = "terraform-dashboards"
  role       = "Admin"
}

resource "grafana_cloud_stack_service_account_token" "dashboards" {
  provider = grafana.cloud

  stack_slug         = grafana_cloud_stack.main.slug
  service_account_id = grafana_cloud_stack_service_account.dashboards.id
  name               = "terraform-dashboards-token"
}

# Datasources — Mimir (metrics), Loki (logs), Tempo (traces).
resource "grafana_data_source" "mimir" {
  provider = grafana.stack

  type = "prometheus"
  name = "Mimir"
  url  = grafana_cloud_stack.main.prometheus_url

  basic_auth_enabled  = true
  basic_auth_username = grafana_cloud_stack.main.prometheus_user_id
}

resource "grafana_data_source" "loki" {
  provider = grafana.stack

  type = "loki"
  name = "Loki"
  url  = grafana_cloud_stack.main.logs_url

  basic_auth_enabled  = true
  basic_auth_username = grafana_cloud_stack.main.logs_user_id
}

resource "grafana_data_source" "tempo" {
  provider = grafana.stack

  type = "tempo"
  name = "Tempo"
  url  = grafana_cloud_stack.main.traces_url

  basic_auth_enabled  = true
  basic_auth_username = grafana_cloud_stack.main.traces_user_id
}

resource "grafana_folder" "main" {
  provider = grafana.stack

  title = "aegis-statefulset"
}

# Seven dashboards per ADR-06. JSON files live next to this file in
# dashboards/. Adding a dashboard is a one-line append to local.dashboards
# plus the JSON file — no extra TF resource required.
locals {
  dashboards = [
    "service-health",
    "customer-drill-down",
    "pod-detail",
    "cell-capacity",
    "backup-pipeline",
    "ha-status",
    "migration-progress",
  ]
}

resource "grafana_dashboard" "default" {
  provider = grafana.stack

  for_each = toset(local.dashboards)

  folder      = grafana_folder.main.id
  config_json = file("${path.module}/dashboards/${each.value}.json")
}

output "grafana_stack_url" {
  value       = grafana_cloud_stack.main.url
  description = "Grafana Cloud stack URL for the environment"
}
