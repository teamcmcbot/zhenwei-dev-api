variable "project_name" {
  type        = string
  description = "Project name used for resource naming."
}

variable "environment" {
  type        = string
  description = "Environment name (dev or prod)."
}

variable "aws_region" {
  type        = string
  description = "AWS region for deployment."
}

variable "artifact_parameter_name" {
  type        = string
  description = "SSM parameter containing artifact bucket/key/hash metadata JSON."
}

variable "lambda_runtime" {
  type        = string
  description = "Lambda runtime to use."
  default     = "python3.14"
}

variable "lambda_handler" {
  type        = string
  description = "Lambda handler path."
  default     = "handler.lambda_handler"
}

variable "lambda_memory_size" {
  type        = number
  description = "Lambda memory size in MB."
  default     = 512
}

variable "lambda_timeout_seconds" {
  type        = number
  description = "Lambda timeout in seconds."
  default     = 15
}

variable "allowed_sources" {
  type        = list(string)
  description = "Allowed source values for send-notification requests."
}

variable "allowed_event_types" {
  type        = list(string)
  description = "Allowed eventType values for send-notification requests."
}

variable "api_name" {
  type        = string
  description = "REST API name."
  default     = ""
}

variable "stage_name" {
  type        = string
  description = "API Gateway stage name."
  default     = "v1"
}

variable "pushover_token_parameter_name" {
  type        = string
  description = "SSM parameter name for the default Pushover application token."
  default     = "PushoverToken"
}

variable "pushover_user_parameter_name" {
  type        = string
  description = "SSM parameter name for the Pushover user key."
  default     = "PushoverUser"
}

variable "automation_api_key_parameter_name" {
  type        = string
  description = "Optional SSM parameter name override for automation API key storage."
  default     = ""
}

variable "website_api_key_parameter_name" {
  type        = string
  description = "Optional SSM parameter name override for website API key storage."
  default     = ""
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch log retention days."
  default     = 30
}

variable "automation_rate_limit" {
  type        = number
  description = "Automation usage plan steady-state requests per second."
  default     = 1
}

variable "automation_burst_limit" {
  type        = number
  description = "Automation usage plan burst limit."
  default     = 1
}

variable "automation_monthly_quota" {
  type        = number
  description = "Monthly quota for the automation API key."
  default     = 400
}

variable "website_rate_limit" {
  type        = number
  description = "Website usage plan steady-state requests per second."
  default     = 1
}

variable "website_burst_limit" {
  type        = number
  description = "Website usage plan burst limit."
  default     = 1
}

variable "website_monthly_quota" {
  type        = number
  description = "Monthly quota for the website API key."
  default     = 100
}

variable "enable_cloudwatch_alarms" {
  type        = bool
  description = "Create CloudWatch metric alarms for this service."
  default     = true
}

variable "alarm_sns_topic_arn" {
  type        = string
  description = "Optional SNS topic for CloudWatch alarm actions."
  default     = ""
}

variable "enable_custom_domain" {
  type        = bool
  description = "Attach this REST API stage to an existing custom API Gateway domain."
  default     = false
}

variable "api_domain_name" {
  type        = string
  description = "Existing API Gateway custom domain name (for example api.zhenwei.dev)."
  default     = ""
}

variable "custom_domain_base_path" {
  type        = string
  description = "Base path mapping under the custom domain (for example send-notification)."
  default     = "send-notification"
}

variable "tags" {
  type        = map(string)
  description = "Common tags for resources."
  default     = {}
}
