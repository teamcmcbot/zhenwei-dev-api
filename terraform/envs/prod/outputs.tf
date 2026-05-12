output "artifact_bucket_name" {
  value       = module.bootstrap.artifact_bucket_name
  description = "Artifact bucket for Lambda zip uploads."
}

output "artifact_parameter_name" {
  value       = module.bootstrap.get_presigned_url_artifact_parameter_name
  description = "SSM parameter storing active artifact metadata."
}

output "github_api_deploy_role_arn" {
  value       = module.bootstrap.github_api_deploy_role_arn
  description = "Optional dedicated GitHub OIDC deploy role ARN."
}

output "get_presigned_url_api_endpoint" {
  value       = module.get_presigned_url.api_endpoint
  description = "Invoke URL for get-presigned-url API."
}

output "get_presigned_url_lambda_name" {
  value       = module.get_presigned_url.lambda_function_name
  description = "Lambda name for get-presigned-url."
}
