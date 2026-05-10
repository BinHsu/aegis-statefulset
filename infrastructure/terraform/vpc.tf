# VPC + per-AZ public/private subnets backing the EKS cluster.
# Per ADR-01: multi-AZ placement is foundational for stateful HA.
#
# Module pinning: version constraint via Terraform Registry semver.
# TODO production: per ADR-09 (SHA pinning supply chain), switch to git SHA pin:
#   source = "git::https://github.com/terraform-aws-modules/terraform-aws-vpc.git?ref=<full-40-char-sha>"
# Tag-based pins (~> 5.5) are convenient but tag-mutable; SHA pins are immutable.

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.5"

  name = "aegis-statefulset-${var.environment}"
  cidr = var.vpc_cidr

  azs             = local.azs
  private_subnets = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 4, i + 1)]
  public_subnets  = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 4, i + 11)]

  enable_nat_gateway = true
  single_nat_gateway = false # NAT per AZ for HA — survives single-AZ NAT outage

  enable_dns_hostnames = true
  enable_dns_support   = true

  # Tag subnets for EKS LB ingress controller discovery
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = local.common_tags
}

# S3 Gateway Endpoint — free, keeps Velero backup metadata + EBS Snapshot
# Lambda payload traffic off the NAT path. The vpc module v5+ removed the
# convenience flag `enable_s3_endpoint`; an explicit resource is now the
# canonical pattern (matches the DynamoDB endpoint below).
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  tags = {
    Name = "aegis-statefulset-${var.environment}-s3-endpoint"
  }
}

# DynamoDB Gateway Endpoint — free, keeps placement-table traffic off the
# NAT path (which is metered). Per ADR-03 the placement table is on the
# read path of every request, so taking it off NAT is both a cost and
# latency win.
resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  tags = {
    Name = "aegis-statefulset-${var.environment}-dynamodb-endpoint"
  }
}
