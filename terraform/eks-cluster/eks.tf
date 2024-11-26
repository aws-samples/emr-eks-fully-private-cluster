locals {
  name   = var.name
  region = var.region

  vpc_cidr = "10.8.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  vpc = data.terraform_remote_state.network_state.outputs.vpc

  additional_policies = {
    ssm_managed_instance_core = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    ecr_repo_write            = aws_iam_policy.ecr_repo_write.arn
  }

  tags = {
    Blueprint  = local.name
    GithubRepo = "github.com/awslabs/data-on-eks"
  }
}


# Get the state with data resources from s3 bucket tf-eks-remote-states 
data "terraform_remote_state" "network_state" {
  backend = "s3"
  config = {
    bucket = "tf-eks-remote-states"
    key    = "e2e/fully-private-cluster/networking/terraform.tfstate"
    region = "ap-southeast-1"
  }
}


data "aws_vpc" "default" {
  default = true
}

# ################################################################################
# # Cluster
# ################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.11"

  cluster_name    = local.name
  cluster_version = "1.30"

  vpc_id     = local.vpc.vpc_id
  subnet_ids = local.vpc.private_subnets

  # Automatically add the workstation IAM identity for cluster access
  enable_cluster_creator_admin_permissions = true



  access_entries = {
    karpenter_nodes = {
      principal_arn = aws_iam_role.karpenter.arn
      type          = "EC2_LINUX"
      username      = "system:node:{{EC2PrivateDNSName}}"
    }
  }

  #---------------------------------------
  # Note: This can further restricted to specific required for each Add-on and your application
  #---------------------------------------
  # Extend cluster security group rules
  cluster_security_group_additional_rules = {
    default_vpc = {
      description = "Allow ingress from default vpc"
      type        = "ingress"
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = [data.aws_vpc.default.cidr_block]
    }
    ingress_nodes_ephemeral_ports_tcp = {
      description                = "Nodes on ephemeral ports"
      protocol                   = "tcp"
      from_port                  = 1025
      to_port                    = 65535
      type                       = "ingress"
      source_node_security_group = true
    }
  }
  # Extend node-to-node security group rules
  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
    ingress_fsx1 = {
      description = "Allows Lustre traffic between Lustre clients"
      cidr_blocks = local.vpc.private_subnets_cidr_blocks
      from_port   = 1021
      to_port     = 1023
      protocol    = "tcp"
      type        = "ingress"
    }
    ingress_fsx2 = {
      description = "Allows Lustre traffic between Lustre clients"
      cidr_blocks = local.vpc.private_subnets_cidr_blocks
      from_port   = 988
      to_port     = 988
      protocol    = "tcp"
      type        = "ingress"
    }
  }

  eks_managed_node_group_defaults = {
    iam_role_additional_policies = {
      # Not required, but used in the example to access the nodes to inspect mounted volumes
      AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      ECR                          = aws_iam_policy.ecr_repo_write.arn
    }
  }

  eks_managed_node_groups = {
    #  We recommend to have a MNG to place your critical workloads and add-ons
    #  Then rely on Karpenter to scale your workloads
    #  You can also make uses on nodeSelector and Taints/tolerations to spread workloads on MNG or Karpenter provisioners
    core_node_group = {
      name        = "core-node-group"
      description = "EKS managed node group example launch template"

      min_size     = 1
      max_size     = 9
      desired_size = 3

      instance_types = ["m5.xlarge"]

      ebs_optimized = true
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size = 100
            volume_type = "gp3"
          }
        }
      }

      labels = {
        WorkerType    = "ON_DEMAND"
        NodeGroupType = "core"
      }

      tags = {
        Name                     = "core-node-grp",
        "karpenter.sh/discovery" = local.name
      }
    }
  }

  tags = merge(local.tags, {
    "karpenter.sh/discovery" = local.name
  })
}
