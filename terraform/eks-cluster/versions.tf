terraform {
  required_version = ">= 1.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.34"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.10"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.4"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.3"
    }

  }

  ##  Used for end-to-end testing on project; update to suit your needs
  backend "s3" {
    bucket = "tf-eks-remote-states" # change to your bucket name
    region = "ap-southeast-1"       # change to your desired aws region
    key    = "e2e/fully-private-cluster/eks-cluster/terraform.tfstate"
  }
}
