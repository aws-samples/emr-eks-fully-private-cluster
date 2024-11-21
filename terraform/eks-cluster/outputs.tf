output "configure_kubectl" {
  description = "Configure kubectl: make sure you're logged in with the correct AWS profile and run the following command to update your kubeconfig"
  value       = "aws eks --region ${local.region} update-kubeconfig --name ${module.eks.cluster_name}"
}

# output "vpc_module" {
#   value = data.terraform_remote_state.tf-eks-remote-states
# }

output "vpc_id" {
  value = local.vpc.vpc_id
}

output "emr_containers" {
  value = module.emr_containers
}