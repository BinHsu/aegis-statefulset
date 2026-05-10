output "cluster_name" {
  value = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.main.endpoint
}

output "cluster_oidc_issuer" {
  value = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

output "alb_dns_name" {
  value = aws_lb.main.dns_name
}

output "backup_bucket_source" {
  value = aws_s3_bucket.backup_source.id
}

output "backup_bucket_dr" {
  value = aws_s3_bucket.backup_dr.id
}

output "kms_key_data" {
  value = aws_kms_key.stateful_data.id
}

output "irsa_role_arn" {
  value = aws_iam_role.aegis_statefulset.arn
}
