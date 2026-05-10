# Stateful + stateless node groups — per-AZ pre-provisioned warm-standby pattern.
# Per ADR-01 (multi-AZ placement) + ADR-01 (one MNG per AZ) + ADR-02 (1:1
# pod-to-node ratio) + ADR-04 (single-master-AZ + warm-standby DR).
#
# Architecture (per ADR-04, supersedes earlier all-AZs-active model):
#   - master_az is the active AZ; carries `desired_size = N` for both stateful
#     and stateless tiers.
#   - Other AZs hold mirror node groups with `desired_size = 0`. Subnets,
#     IAM, KMS, taints, labels are pre-baked.
#   - AZ rotation: `aws eks update-nodegroup-config` to scale a standby up
#     and the current master down — no `terraform apply` needed in the rotation
#     path. Lifecycle ignore_changes on desired_size lets the live operator
#     drive scaling without drift.
#
# Why pre-provisioned warm standby:
#   - Cold standby (no MNG until DR) = ~10-15 min provisioning latency on
#     incident path. Warm standby = scale-up only (~2-3 min for r6id.2xlarge
#     image pull + node-ready).
#   - Cost: standby MNGs at desired=0 incur no EC2 charge — only the (free)
#     control-plane MNG metadata.
#
# capacity_type = ON_DEMAND for both tiers per ADR-04 (no spot for stateful;
# stateless tier in this take-home keeps ON_DEMAND for predictable capacity
# during demo — production would mix in spot via Karpenter NodePool, not the
# managed node group).

# --------------------------------------------------------------------
# Stateful tier — master AZ (active)
# --------------------------------------------------------------------
resource "aws_eks_node_group" "stateful_master" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "stateful-master-${var.master_az}"
  node_role_arn   = aws_iam_role.node_group.arn

  # CRITICAL: only the master AZ subnet — single failure domain per ADR-01.
  subnet_ids = [
    for s in module.vpc.private_subnets :
    s if data.aws_subnet.private[s].availability_zone == var.master_az
  ]

  instance_types = var.stateful_node_instance_types
  capacity_type  = "ON_DEMAND"

  scaling_config {
    desired_size = var.stateful_pool_per_az_size
    min_size     = var.stateful_pool_per_az_size     # Cannot scale below per ADR-04
    max_size     = var.stateful_pool_per_az_size + 1 # +1 surge for rolling update
  }

  update_config {
    max_unavailable_percentage = 33
  }

  labels = {
    "aegis.io/pool"               = "stateful"
    "topology.kubernetes.io/zone" = var.master_az
  }

  taint {
    key    = "aegis.io/stateful"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  tags = merge(local.common_tags, {
    "k8s.io/cluster-autoscaler/${local.cluster_name}" = "owned"
    "k8s.io/cluster-autoscaler/enabled"               = "true"
  })

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [scaling_config[0].desired_size]
  }
}

# --------------------------------------------------------------------
# Stateful tier — warm-standby AZs (desired=0; scale up via API on rotation)
# --------------------------------------------------------------------
resource "aws_eks_node_group" "stateful_standby" {
  for_each = toset([
    for az in local.azs : az if az != var.master_az
  ])

  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "stateful-standby-${each.value}"
  node_role_arn   = aws_iam_role.node_group.arn

  subnet_ids = [
    for s in module.vpc.private_subnets :
    s if data.aws_subnet.private[s].availability_zone == each.value
  ]

  instance_types = var.stateful_node_instance_types
  capacity_type  = "ON_DEMAND"

  scaling_config {
    desired_size = 0 # Warm standby; scale up via aws eks update-nodegroup-config
    min_size     = 0
    max_size     = var.stateful_pool_per_az_size + 1
  }

  update_config {
    max_unavailable_percentage = 33
  }

  labels = {
    "aegis.io/pool"               = "stateful"
    "topology.kubernetes.io/zone" = each.value
    "aegis.io/role"               = "standby"
  }

  taint {
    key    = "aegis.io/stateful"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  tags = merge(local.common_tags, {
    "k8s.io/cluster-autoscaler/${local.cluster_name}" = "owned"
    "k8s.io/cluster-autoscaler/enabled"               = "true"
  })

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [scaling_config[0].desired_size]
  }
}

# --------------------------------------------------------------------
# Stateless tier — master AZ (active)
# Karpenter handles burst capacity via NodePool; this MNG provides the
# baseline floor (system pods, ingress controller, default scheduling).
# --------------------------------------------------------------------
resource "aws_eks_node_group" "stateless_master" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "stateless-master-${var.master_az}"
  node_role_arn   = aws_iam_role.node_group.arn

  subnet_ids = [
    for s in module.vpc.private_subnets :
    s if data.aws_subnet.private[s].availability_zone == var.master_az
  ]

  instance_types = var.stateless_node_instance_types
  capacity_type  = "ON_DEMAND"

  scaling_config {
    desired_size = var.stateless_pool_size
    min_size     = 1
    max_size     = var.stateless_pool_size + 2
  }

  labels = {
    "aegis.io/pool"               = "stateless"
    "topology.kubernetes.io/zone" = var.master_az
  }

  tags = local.common_tags

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [scaling_config[0].desired_size]
  }
}

# --------------------------------------------------------------------
# Stateless tier — warm-standby AZs
# --------------------------------------------------------------------
resource "aws_eks_node_group" "stateless_standby" {
  for_each = toset([
    for az in local.azs : az if az != var.master_az
  ])

  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "stateless-standby-${each.value}"
  node_role_arn   = aws_iam_role.node_group.arn

  subnet_ids = [
    for s in module.vpc.private_subnets :
    s if data.aws_subnet.private[s].availability_zone == each.value
  ]

  instance_types = var.stateless_node_instance_types
  capacity_type  = "ON_DEMAND"

  scaling_config {
    desired_size = 0
    min_size     = 0
    max_size     = var.stateless_pool_size
  }

  labels = {
    "aegis.io/pool"               = "stateless"
    "topology.kubernetes.io/zone" = each.value
    "aegis.io/role"               = "standby"
  }

  tags = local.common_tags

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [scaling_config[0].desired_size]
  }
}

# --------------------------------------------------------------------
# Shared subnet metadata + node IAM role
# --------------------------------------------------------------------
data "aws_subnet" "private" {
  for_each = toset(module.vpc.private_subnets)
  id       = each.value
}

resource "aws_iam_role" "node_group" {
  name = "${local.cluster_name}-node-group-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Standard EKS node group policies
resource "aws_iam_role_policy_attachment" "node_AmazonEKSWorkerNodePolicy" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKS_CNI_Policy" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_AmazonEC2ContainerRegistryReadOnly" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}
