terraform {
  required_version = ">= 1.6"

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

  # Backend config — set in environment-specific .tfvars or env vars
  # backend "s3" {
  #   bucket         = "aegis-statefulset-tfstate"
  #   key            = "infrastructure/terraform.tfstate"
  #   region         = "eu-central-1"
  #   dynamodb_table = "aegis-statefulset-tfstate-lock"
  #   encrypt        = true
  # }
}
