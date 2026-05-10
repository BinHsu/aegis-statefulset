provider "aws" {
  region = var.aws_region

  # Day-1 FinOps tagging per ADR-10.
  # Cost Allocation Tag activation in AWS Billing Console enables Cost Explorer
  # and CUR drilldown by these dimensions. Per-resource overrides where the
  # default doesn't fit (e.g., stateful EBS overrides Component/Tier/DataClass).
  default_tags {
    tags = {
      Project     = "aegis-statefulset"
      Environment = var.environment
      ManagedBy   = "terraform"

      # FinOps tags (per ADR-10)
      CostCenter   = var.cost_center
      Owner        = var.owner_email
      Component    = "platform"    # override per resource: stateful / stateless / observability / backup / network / finops
      Tier         = "shared"      # override per resource: stateful / stateless / shared
      DataClass    = "operational" # override per resource: tenant-data / operational / logs
      BackupPolicy = "n/a"         # override per resource: 1h / 6h / n/a
    }
  }
}

# Get current AWS account info
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  cluster_name = "aegis-statefulset-${var.environment}"
  azs          = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  common_tags = {
    Project     = "aegis-statefulset"
    Environment = var.environment
  }
}
