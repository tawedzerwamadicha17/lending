variable "project" {
  description = "Name prefix for every resource. Also the ECR repository name."
  type        = string
  default     = "lending"
}

variable "aws_region" {
  description = "Region for all resources. Keep instances and ECR in the same region -- cross-region image pulls are billed."
  type        = string
  default     = "us-east-1"
}

variable "github_repository" {
  description = "owner/repo allowed to assume the CI role via OIDC."
  type        = string
  default     = "tawedzerwamadicha17/lending"
}

variable "environments" {
  description = "Environment names the CI role may publish stack config for. Must match the env stack's `environment` values."
  type        = list(string)
  default     = ["prod", "staging"]
}

variable "ecr_keep_images" {
  description = "How many images to retain before the lifecycle rule expires them."
  type        = number
  default     = 10
}
