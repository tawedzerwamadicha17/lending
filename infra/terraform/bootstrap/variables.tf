variable "project" {
  description = "Name prefix for every resource. Also the ECR repository name."
  type        = string
  default     = "corebyte"
}

variable "aws_region" {
  description = "Region for all resources. Keep instances and ECR in the same region -- cross-region image pulls are billed."
  type        = string
  default     = "af-south-1"
}

variable "github_repository" {
  description = "owner/repo allowed to assume the CI role via OIDC."
  type        = string
  default     = "tawedzerwamadicha17/lending"
}

variable "github_immutable_subject_prefix" {
  description = "GitHub's immutable OIDC subject prefix, e.g. repo:owner@129616106/repo@1308916498. Read it from GET /repos/{owner}/{repo}/actions/oidc/customization/sub. Empty trusts only the legacy form."
  type        = string
  default     = ""
}

variable "environments" {
  description = "Environment names the CI role may publish stack config for. Must match the env stack's `environment` values."
  type        = list(string)
  default     = ["staging"]
}

variable "ecr_keep_images" {
  description = "How many images to retain before the lifecycle rule expires them."
  type        = number
  default     = 10
}
