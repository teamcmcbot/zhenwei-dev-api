output "artifact_bucket_name" {
  value       = module.bootstrap.artifact_bucket_name
  description = "Shared artifact bucket name consumed by dev and prod stacks."
}

output "github_api_deploy_role_arn" {
  value       = module.bootstrap.github_api_deploy_role_arn
  description = "Optional shared GitHub OIDC deploy role ARN."
}
