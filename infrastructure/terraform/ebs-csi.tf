# ebs-csi.tf
#
# AWS EBS CSI driver — installed as an EKS managed addon.
#
# Why this exists as IaC:
#   The stateful tier's whole premise is EBS-backed StatefulSets (ADR-02
#   multi-PVC: data + wal volumes). Without the EBS CSI driver the chart's
#   `ebs.csi.aws.com` StorageClass has no provisioner and every
#   volumeClaimTemplate stays Pending. The driver was previously installed
#   by hand (it surfaced as an untracked orphan during teardown); this
#   file brings it under terraform so a cold apply yields a cluster that
#   can actually run the stateful workload.
#
# IRSA: the addon's controller ServiceAccount (kube-system/
# ebs-csi-controller-sa) assumes this role to call the EC2 volume APIs.

data "aws_iam_policy_document" "ebs_csi_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "aegis-statefulset-${var.environment}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "aws-ebs-csi-driver"
  service_account_role_arn    = aws_iam_role.ebs_csi.arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_node_group.stateful_master,
    aws_eks_node_group.stateless_master,
    aws_iam_role_policy_attachment.ebs_csi,
  ]

  tags = local.common_tags
}
