variable "project_name" {
  type        = string
  description = "Project name used in resource names and SSM paths."
}

variable "environment" {
  type        = string
  description = "Environment name (dev or prod)."
}

variable "artifact_bucket_name" {
  type        = string
  description = "Name of the Lambda artifact bucket."
}

variable "create_artifact_bucket" {
  type        = bool
  description = "Create artifact bucket in this stack when true."
  default     = true
}

variable "artifact_bucket_force_destroy" {
  type        = bool
  description = "Allow destroying non-empty artifact bucket. Keep false in normal use."
  default     = false
}

variable "create_github_deploy_role" {
  type        = bool
  description = "Create a separate GitHub OIDC deploy role for this repo when true."
  default     = false
}

variable "create_artifact_parameter" {
  type        = bool
  description = "Create environment artifact SSM parameter when true."
  default     = true
}

variable "github_repo" {
  type        = string
  description = "GitHub repo in owner/name format for this API repository."
  default     = ""
}

variable "github_allowed_branches" {
  type        = list(string)
  description = "Allowed branches for role assumption, for example [\"dev\", \"main\"]."
  default     = ["dev", "main"]
}

variable "github_deploy_environments" {
  type        = list(string)
  description = "Environment names whose artifact parameters the shared GitHub deploy role may update."
  default     = []
}

variable "artifact_prefix" {
  type        = string
  description = "Artifact key prefix used by packaging workflows."
  default     = "lambdas/get-presigned-url/"
}

variable "tags" {
  type        = map(string)
  description = "Common tags applied to resources."
  default     = {}
}
