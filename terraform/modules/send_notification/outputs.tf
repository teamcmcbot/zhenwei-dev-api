output "lambda_function_name" {
  value       = aws_lambda_function.this.function_name
  description = "Deployed Lambda function name."
}

output "api_id" {
  value       = aws_api_gateway_rest_api.this.id
  description = "REST API ID."
}

output "api_endpoint" {
  value       = "https://${aws_api_gateway_rest_api.this.id}.execute-api.${var.aws_region}.amazonaws.com/${aws_api_gateway_stage.this.stage_name}"
  description = "Invoke URL for the REST API stage."
}

output "stage_name" {
  value       = aws_api_gateway_stage.this.stage_name
  description = "API stage name."
}

output "artifact_parameter_name" {
  value       = var.artifact_parameter_name
  description = "Artifact parameter consumed by the Lambda deployment."
}

output "automation_api_key_id" {
  value       = aws_api_gateway_api_key.automation.id
  description = "Automation API key ID."
}

output "automation_api_key_value" {
  value       = aws_api_gateway_api_key.automation.value
  description = "Automation API key value."
  sensitive   = true
}

output "website_api_key_id" {
  value       = aws_api_gateway_api_key.website.id
  description = "Website API key ID."
}

output "website_api_key_value" {
  value       = aws_api_gateway_api_key.website.value
  description = "Website API key value."
  sensitive   = true
}
