variable "aws_region" {
  description = "AWS region for the cluster"
  type        = string
  default     = "eu-central-1"
}

variable "dr_region" {
  description = "AWS region for cross-region DR backup bucket (per ADR-04)"
  type        = string
  default     = "eu-west-1"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "prod"
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging, or prod"
  }
}

variable "az_count" {
  description = "Number of AZs to use (matches helm values cells.per_az_count)"
  type        = number
  default     = 3
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "kubernetes_version" {
  description = "EKS cluster Kubernetes version"
  type        = string
  # EKS only allows sequential minor upgrades (1.29→1.30, then 1.30→1.31).
  # When bumping from a cluster that's already created, step one version
  # at a time to keep the upgrade in-place. Fresh clusters can start at
  # the latest supported version directly.
  default     = "1.30"
}

variable "stateful_node_instance_types" {
  description = "Instance types for the stateful pool (per ADR-02)"
  type        = list(string)
  default     = ["r6id.2xlarge"]
}

variable "stateful_pool_per_az_size" {
  description = "Number of nodes per AZ for stateful pool (1:1 with primary pods per ADR-02)"
  type        = number
  default     = 3
}

variable "domain_name" {
  description = "Domain for ALB / Route 53 (anonymised in POC)"
  type        = string
  default     = "aegis.example.com"
}

# ====================================================================
# FinOps variables (per ADR-10)
# ====================================================================

variable "cost_center" {
  description = "FinOps cost center identifier (per ADR-10)"
  type        = string
  default     = "aegis-statefulset-platform"
}

variable "owner_email" {
  description = "Resource owner email for FinOps + accountability (per ADR-10)"
  type        = string
  default     = "platform-team@example.com"
}

variable "monthly_budget_usd" {
  description = "Monthly project budget ceiling in USD — drives Budgets thresholds (per ADR-10)"
  type        = number
  default     = 10000
}

variable "monthly_budget_stateful_usd" {
  description = "Monthly stateful-tier budget ceiling in USD — separate alert ladder (per ADR-10)"
  type        = number
  default     = 7000
}

variable "finops_alert_emails" {
  description = "Email subscribers for FinOps SNS topic (budgets + anomaly detector) (per ADR-10)"
  type        = list(string)
  default     = []
}

# ====================================================================
# Warm-standby + DR cutover variables (per ADR-04)
# ====================================================================

variable "master_az" {
  description = "Master AZ for stateful + stateless workloads (per ADR-04 single-master-AZ + warm-standby pattern)"
  type        = string
  default     = "eu-central-1a"
}

variable "stateless_node_instance_types" {
  description = "Instance types for the stateless tier"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "stateless_pool_size" {
  description = "Number of stateless tier nodes in master AZ"
  type        = number
  default     = 3
}

variable "primary_traffic_weight" {
  description = "Route 53 weight for primary region (set 0 to drain) (per ADR-04)"
  type        = number
  default     = 100
}

variable "dr_traffic_weight" {
  description = "Route 53 weight for DR region (set 100 for cutover) (per ADR-04)"
  type        = number
  default     = 0
}

variable "dr_region_alb_dns" {
  description = "DR region ALB DNS (cross-region output, empty disables DR record) (per ADR-04)"
  type        = string
  default     = ""
}

variable "dr_region_alb_zone_id" {
  description = "DR region ALB Route 53 zone ID (cross-region output) (per ADR-04)"
  type        = string
  default     = ""
}

variable "enable_argocd" {
  description = "Whether to deploy ArgoCD via terraform helm_release (else manage out-of-band)"
  type        = bool
  default     = true
}
