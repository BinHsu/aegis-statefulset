output "tfstate_bucket" {
  description = "S3 bucket name for the main composition's terraform state backend"
  value       = aws_s3_bucket.tfstate.id
}

output "region" {
  description = "AWS region of the backend"
  value       = var.aws_region
}

# Convenience: emit a ready-to-use backend.hcl content block.
# Copy the value into infrastructure/terraform/backend.hcl after bootstrap apply.
# Uses terraform 1.10+ S3 native locking (`use_lockfile = true`) — no
# separate DynamoDB table required.
output "backend_hcl_template" {
  description = "Drop-in content for backend.hcl — use with: terraform init -backend-config=backend.hcl"
  value       = <<-EOT
    bucket       = "${aws_s3_bucket.tfstate.id}"
    key          = "main/terraform.tfstate"
    region       = "${var.aws_region}"
    encrypt      = true
    use_lockfile = true
  EOT
}
