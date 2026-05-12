variable "project_name" {
  type        = string
  description = "Project name prefix."
  default     = "zhenwei-dev-api"
}

variable "environment" {
  type        = string
  description = "Shared environment identifier."
  default     = "shared"
}

variable "aws_region" {
  type        = string
  description = "AWS region for shared resources."
}

variable "artifact_bucket_name" {
  type        = string
  description = "Shared artifact bucket name used by all environments."
  default     = "zhenwei-dev-api-artifacts"
}

variable "create_artifact_bucket" {
  type        = bool
  description = "Create shared artifact bucket in this stack."
  default     = true
}

variable "create_github_deploy_role" {
  type        = bool
  description = "Create dedicated GitHub OIDC deploy role for this repo in shared stack."
  default     = false
}

variable "github_repo" {
  type        = string
  description = "GitHub repo in owner/name format for trust policy subject checks."
  default     = ""
}

variable "github_allowed_branches" {
  type        = list(string)
  description = "Allowed branches for role assumption."
  default     = ["dev", "main"]
}

variable "github_deploy_environments" {
  type        = list(string)
  description = "Environment names whose artifact parameters can be updated by the shared GitHub deploy role."
  default     = ["dev", "prod"]
}

variable "artifact_prefix" {
  type        = string
  description = "Allowed artifact key prefix for upload permissions."
  default     = "lambdas/get-presigned-url/"
}

variable "tags" {
  type        = map(string)
  description = "Common tags for shared resources."
  default = {
    ManagedBy = "terraform"
    Project   = "zhenwei-dev-api"
  }
}
