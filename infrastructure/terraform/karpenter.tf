# Karpenter for the stateless tier (per ADR-02: mode-aware horizontal scaling).
# Stateful tier uses fixed per-AZ MNGs (see node-groups-stateful.tf).
#
# TODO production: per ADR-09, replace tag pin with git SHA pin:
#   source = "git::https://github.com/terraform-aws-modules/terraform-aws-eks.git//modules/karpenter?ref=<sha>"

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.8"

  cluster_name = aws_eks_cluster.main.name

  # Karpenter NodePool config inline (or via Helm post-cluster-bootstrap)
  irsa_oidc_provider_arn          = aws_iam_openid_connect_provider.eks.arn
  irsa_namespace_service_accounts = ["karpenter:karpenter"]

  tags = local.common_tags
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}
