variable "project_name" {
  type        = string
  description = "Project name prefix."
  default     = "zhenwei-dev-api"
}

variable "environment" {
  type        = string
  description = "Environment identifier."
  default     = "dev"
}

variable "aws_region" {
  type        = string
  description = "AWS region for dev deployment."
}

variable "private_bucket_name" {
  type        = string
  description = "Private content bucket for presigned object downloads."
}

variable "state_bucket_name" {
  type        = string
  description = "Terraform state bucket used for remote-state lookups."
  default     = "zhenwei-terraform-tfstate"
}

variable "state_bucket_region" {
  type        = string
  description = "Region of Terraform state bucket used for remote-state lookups."
  default     = "ap-southeast-1"
}

variable "shared_state_key" {
  type        = string
  description = "State key for shared stack outputs consumed by this environment."
  default     = "zhenwei-dev-api/shared/terraform.tfstate"
}

variable "allowed_origins" {
  type        = list(string)
  description = "CORS allowed origins for frontend callers."
}

variable "allowed_object_keys" {
  type        = list(string)
  description = "Exact allowed object keys for signing."
  default     = []
}

variable "allowed_object_prefixes" {
  type        = list(string)
  description = "Allowed object key prefixes for signing."
  default     = ["resume/"]
}

variable "default_expires_seconds" {
  type        = number
  description = "Default presigned URL expiry."
  default     = 300
}

variable "max_expires_seconds" {
  type        = number
  description = "Maximum presigned URL expiry."
  default     = 900
}

variable "lambda_runtime" {
  type        = string
  description = "Lambda runtime for the service."
  default     = "python3.14"
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

variable "log_retention_days" {
  type        = number
  description = "CloudWatch log retention in days."
  default     = 30
}

variable "send_notification_stage_name" {
  type        = string
  description = "Stage name for the send-notification REST API."
  default     = "dev"
}

variable "throttle_burst_limit" {
  type        = number
  description = "API Gateway burst limit."
  default     = 25
}

variable "throttle_rate_limit" {
  type        = number
  description = "API Gateway steady-state requests per second."
  default     = 10
}

variable "alarm_sns_topic_arn" {
  type        = string
  description = "Optional SNS topic ARN for alarms."
  default     = ""
}

variable "enable_cloudwatch_alarms" {
  type        = bool
  description = "Create CloudWatch metric alarms for service resources."
  default     = false
}

variable "allowed_notification_sources" {
  type        = list(string)
  description = "Allowed source values for send-notification requests."
  default     = ["github-actions", "terraform", "cloudfront"]
}

variable "allowed_notification_event_types" {
  type        = list(string)
  description = "Allowed eventType values for send-notification requests."
  default     = ["workflow.completed", "apply.success", "apply.failed", "invalidation.complete"]
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
  description = "Automation usage plan monthly quota."
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
  description = "Website usage plan monthly quota."
  default     = 100
}

variable "enable_custom_domain" {
  type        = bool
  description = "Enable custom API domain resources."
  default     = false
}

variable "create_api_domain_certificate" {
  type        = bool
  description = "Create ACM certificate in this environment for api_domain_name."
  default     = false
}

variable "api_domain_name" {
  type        = string
  description = "Custom API domain name."
  default     = ""
}

variable "hosted_zone_name" {
  type        = string
  description = "Route53 hosted zone name used for domain wiring, e.g. example.com."
  default     = ""
}

variable "api_domain_certificate_arn" {
  type        = string
  description = "ACM certificate ARN for API custom domain."
  default     = ""
}

variable "tags" {
  type        = map(string)
  description = "Common tags for environment resources."
  default = {
    ManagedBy = "terraform"
    Project   = "zhenwei-dev-api"
  }
}
