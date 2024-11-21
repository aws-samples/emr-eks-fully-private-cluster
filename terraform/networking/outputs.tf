output "vpc_endpoints" {
  description = "VPC Endpoint Names"
  value       = [for endpoint in module.vpc_endpoints.endpoints : endpoint.service_name]
}
# Expected Output
# vpc_endpoints = [
#   "com.amazonaws.ap-southeast-1.aps-workspaces",
#   "com.amazonaws.ap-southeast-1.autoscaling",
#   "com.amazonaws.ap-southeast-1.ec2",
#   "com.amazonaws.ap-southeast-1.ec2messages",
#   "com.amazonaws.ap-southeast-1.ecr.api",
#   "com.amazonaws.ap-southeast-1.ecr.dkr",
#   "com.amazonaws.ap-southeast-1.eks",
#   "com.amazonaws.ap-southeast-1.eks-auth",
#   "com.amazonaws.ap-southeast-1.elasticloadbalancing",
#   "com.amazonaws.ap-southeast-1.emr-containers",
#   "com.amazonaws.ap-southeast-1.kms",
#   "com.amazonaws.ap-southeast-1.logs",
#   "com.amazonaws.ap-southeast-1.s3",
#   "com.amazonaws.ap-southeast-1.sqs",
#   "com.amazonaws.ap-southeast-1.ssm",
#   "com.amazonaws.ap-southeast-1.ssmmessages",
#   "com.amazonaws.ap-southeast-1.sts",
# ]


output "vpc" {
  value = {
    vpc_id                      = module.vpc.vpc_id
    vpc_cidr_block              = module.vpc.vpc_cidr_block
    vpc_secondary_cidr_blocks   = module.vpc.vpc_secondary_cidr_blocks
    private_subnets             = module.vpc.private_subnets
    private_subnets_cidr_blocks = module.vpc.private_subnets_cidr_blocks
  }
}
