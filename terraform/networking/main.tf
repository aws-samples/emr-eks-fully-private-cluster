provider "aws" {
  region = local.region
}

data "aws_availability_zones" "available" {
  # Do not include local zones
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  name   = var.name
  region = var.region

  vpc_cidr = var.vpc_cidr
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  endpoints_list = [
    "autoscaling", "ecr.api", "ecr.dkr", "ec2", "ec2messages", "elasticloadbalancing", "emr-containers", "kms", "logs", "ssm", "ssmmessages", "sts",
    "sqs", "eks",     # Karpenter specific: https://karpenter.sh/docs/getting-started/getting-started-with-karpenter/#private-clusters
    "eks-auth",       # This is required if using EKS Pod Identity
    "aps-workspaces", # This is required if using AWS Managed Prometheus Workspace
  ]

  tags = {
    Blueprint  = local.name
    GithubRepo = "github.com/aws-ia/terraform-aws-eks-blueprints"
  }
}


################################################################################
# Supporting Resources
################################################################################

# Assume the workstation is in default VPC, and should have peering connection to
# the EKS VPC.
data "aws_vpc" "default" {
  default = true
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  manage_default_vpc = true

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]

  # Secondary CIDR block attached to VPC for EKS Control Plane ENI + Nodes + Pods
  secondary_cidr_blocks = var.secondary_cidr_blocks

  enable_nat_gateway = false


  # public_subnet_tags = {
  #   "kubernetes.io/role/elb" = 1
  # }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    "karpenter.sh/discovery"          = local.name
  }

  tags = local.tags
}

resource "aws_vpc_peering_connection" "peer" {
  vpc_id      = module.vpc.vpc_id
  peer_vpc_id = data.aws_vpc.default.id
  auto_accept = true

  tags = merge(local.tags, {
    Name = "${local.name}-to-default-vpc-peering"
  })
}

# Route table entry for the created VPC
resource "aws_route" "created_vpc_to_default" {
  count                     = length(module.vpc.private_route_table_ids)
  route_table_id            = module.vpc.private_route_table_ids[count.index]
  destination_cidr_block    = data.aws_vpc.default.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.peer.id
}

# Route table entry for the default VPC
resource "aws_route" "default_vpc_to_created" {
  route_table_id            = data.aws_vpc.default.main_route_table_id
  destination_cidr_block    = module.vpc.vpc_cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.peer.id
}

module "vpc_endpoints" {
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "~> 5.1"

  vpc_id = module.vpc.vpc_id

  # Security group
  create_security_group      = true
  security_group_name_prefix = "${local.name}-vpc-endpoints-"
  security_group_description = "VPC endpoint security group"
  security_group_rules = {
    ingress_https = {
      description = "HTTPS from VPC"
      cidr_blocks = [module.vpc.vpc_cidr_block]
    }
  }

  endpoints = merge({
    s3 = {
      service         = "s3"
      service_type    = "Gateway"
      route_table_ids = module.vpc.private_route_table_ids
      tags = {
        Name = "${local.name}-s3"
      }
    }
    },
    { for service in toset(local.endpoints_list) :
      replace(service, ".", "_") =>
      {
        service             = service
        subnet_ids          = module.vpc.private_subnets
        private_dns_enabled = true
        tags                = { Name = "${local.name}-${service}" }
      }
  })

  tags = local.tags
}
