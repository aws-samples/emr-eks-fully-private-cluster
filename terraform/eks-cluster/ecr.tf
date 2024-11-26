# module "secrets_manager" {
#   source  = "terraform-aws-modules/secrets-manager/aws"
#   version = "~> 1.1"

#   name                    = "ecr-pullthroughcache/docker"
#   secret_string           = jsonencode(var.docker_secret)
#   recovery_window_in_days = 0 # Set to 0 for testing purposes, this will immediately delete the secret. This action is irreversible. https://docs.aws.amazon.com/secretsmanager/latest/apireference/API_DeleteSecret.html
# }

#---------------------------------------------------------------
# The IAM policy for EKS worker node to pull images via ECR
# pull through cache, which need auto create the ECR repo.
#---------------------------------------------------------------
resource "aws_iam_policy" "ecr_repo_write" {
  name_prefix = "${local.name}-ecr-repo-write"
  path        = "/"
  description = "IAM policy for ECR repository write access"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:CreateRepository",
          "ecr:BatchImportUpstreamImage",
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage"
        ]
        Resource = "*"
      }
    ]
  })
}

module "ecr" {
  source  = "terraform-aws-modules/ecr/aws"
  version = "~> 2.2"

  create_repository = false

  registry_pull_through_cache_rules = {
    ecr = {
      ecr_repository_prefix = "ecr-public"
      upstream_registry_url = "public.ecr.aws"
    }
    k8s = {
      ecr_repository_prefix = "k8s"
      upstream_registry_url = "registry.k8s.io"
    }
    quay = {
      ecr_repository_prefix = "quay"
      upstream_registry_url = "quay.io"
    }
    # Refer to below snippet if need the docker hub pull through cache.
    # https://github.com/aws-ia/terraform-aws-eks-blueprints/blob/main/patterns/ecr-pull-through-cache/ecr.tf
    # dockerhub = {
    #   ecr_repository_prefix = "docker-hub"
    #   upstream_registry_url = "registry-1.docker.io"
    #   credential_arn        = module.secrets_manager.secret_arn
    # }
  }

  manage_registry_scanning_configuration = true
  # registry_scan_type                     = "ENHANCED"
  registry_scan_rules = [
    {
      scan_frequency = "SCAN_ON_PUSH"
      filter = [
        {
          filter      = "*"
          filter_type = "WILDCARD"
        },
      ]
    }
  ]
}
