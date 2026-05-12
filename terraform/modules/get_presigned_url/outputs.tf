output "lambda_function_name" {
  value       = aws_lambda_function.this.function_name
  description = "Deployed Lambda function name."
}

output "api_id" {
  value       = aws_apigatewayv2_api.this.id
  description = "HTTP API ID."
}

output "api_endpoint" {
  value       = aws_apigatewayv2_api.this.api_endpoint
  description = "Invoke URL for the API."
}

output "stage_name" {
  value       = aws_apigatewayv2_stage.this.name
  description = "API stage name."
}

output "artifact_parameter_name" {
  value       = var.artifact_parameter_name
  description = "Artifact parameter consumed by the Lambda deployment."
}
