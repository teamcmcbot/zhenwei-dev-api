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

variable "private_bucket_name" {
  type        = string
  description = "Approved private bucket for object signing."
}

variable "allowed_object_keys" {
  type        = list(string)
  description = "Exact object keys allowed for signing."
  default     = []
}

variable "allowed_object_prefixes" {
  type        = list(string)
  description = "Allowed key prefixes for signing."
  default     = []
}

variable "default_expires_seconds" {
  type        = number
  description = "Default presigned URL TTL."
  default     = 300
}

variable "max_expires_seconds" {
  type        = number
  description = "Maximum presigned URL TTL."
  default     = 900
}

variable "allowed_origins" {
  type        = list(string)
  description = "CORS allow-list for browser callers."
}

variable "api_name" {
  type        = string
  description = "HTTP API name."
  default     = ""
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch log retention days."
  default     = 30
}

variable "stage_name" {
  type        = string
  description = "API Gateway stage name."
  default     = "$default"
}

variable "throttle_burst_limit" {
  type        = number
  description = "API Gateway burst limit for route throttling."
  default     = 25
}

variable "throttle_rate_limit" {
  type        = number
  description = "API Gateway steady-state rate limit for route throttling."
  default     = 10
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
  description = "Create API custom domain resources when true."
  default     = false
}

variable "create_api_domain_certificate" {
  type        = bool
  description = "Create and validate ACM certificate for API domain when true."
  default     = false
}

variable "api_domain_name" {
  type        = string
  description = "Custom API domain name, for example api-dev.zhenwei.dev."
  default     = ""
}

variable "hosted_zone_name" {
  type        = string
  description = "Route53 hosted zone name used for ACM validation and domain alias records, e.g. example.com."
  default     = ""
}

variable "api_domain_certificate_arn" {
  type        = string
  description = "ACM certificate ARN for the custom API domain."
  default     = ""
}

variable "tags" {
  type        = map(string)
  description = "Common tags for resources."
  default     = {}
}
