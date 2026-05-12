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
