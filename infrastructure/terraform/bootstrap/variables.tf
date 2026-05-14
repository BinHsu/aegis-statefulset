variable "aws_region" {
  description = "AWS region for the state backend (typically matches main composition's region)"
  type        = string
  default     = "eu-central-1"
}

variable "environment" {
  description = "Environment name — included in state bucket + lock-table names to isolate per environment"
  type        = string
  default     = "staging"
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging, or prod"
  }
}
