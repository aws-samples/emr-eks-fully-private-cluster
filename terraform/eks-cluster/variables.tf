variable "name" {
  description = "Name of the project and cluster"
  type        = string
  default     = "fully-private-cluster"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-1"
}

# variable "docker_secret" {
#   description = "Inform your docker username and accessToken to allow pullTroughCache to get images from Docker.io. E.g. `{username='user',accessToken='pass'}`"
#   type = object({
#     username    = string
#     accessToken = string
#   })
#   sensitive = true
# }
