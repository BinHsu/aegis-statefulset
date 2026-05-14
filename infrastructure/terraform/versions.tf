terraform {
  # 1.10+ required for native S3 backend locking (`use_lockfile = true`
  # in backend config) — replaces the older dynamodb_table approach.
  # See infrastructure/terraform/bootstrap/README.md for rationale.
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }
    grafana = {
      source  = "grafana/grafana"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # S3 remote backend. Values supplied via `-backend-config=backend.hcl`
  # so the bucket/table names (which include the account ID) don't get
  # baked into the source tree. See:
  #   - infrastructure/terraform/bootstrap/README.md   (one-time setup)
  #   - infrastructure/terraform/backend.hcl.example   (template)
  backend "s3" {}
}
