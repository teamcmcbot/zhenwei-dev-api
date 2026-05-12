output "artifact_bucket_name" {
  value       = local.artifact_bucket_name
  description = "Artifact bucket used by packaging and Lambda deployment."
}

output "get_presigned_url_artifact_parameter_name" {
  value       = var.create_artifact_parameter ? aws_ssm_parameter.get_presigned_url_artifact[0].name : null
  description = "SSM parameter name storing get-presigned-url artifact metadata."
}

output "github_api_deploy_role_arn" {
  value       = var.create_github_deploy_role ? aws_iam_role.github_api_deploy[0].arn : null
  description = "Optional GitHub OIDC deploy role ARN."
}
