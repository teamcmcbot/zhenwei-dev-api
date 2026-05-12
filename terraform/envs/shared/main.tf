locals {
  default_tags = merge(
    var.tags,
    {
      Environment = var.environment
      ManagedBy   = "terraform"
      Project     = var.project_name
    }
  )
}

# Bootstraps the shared stack so dev and prod can consume common outputs.
module "bootstrap" {
  source = "../../modules/bootstrap"

  project_name              = var.project_name
  environment               = var.environment
  artifact_bucket_name      = var.artifact_bucket_name
  create_artifact_bucket    = var.create_artifact_bucket
  create_artifact_parameter = false
  create_github_deploy_role = var.create_github_deploy_role
  github_repo               = var.github_repo
  github_allowed_branches   = var.github_allowed_branches
  github_deploy_environments = var.github_deploy_environments
  artifact_prefix           = var.artifact_prefix
  tags                      = local.default_tags
}
