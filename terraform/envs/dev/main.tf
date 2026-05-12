locals {
  default_tags = merge(
    var.tags,
    {
      Environment = var.environment
      ManagedBy   = "terraform"
      Project     = var.project_name
    }
  )

  shared_artifact_bucket_name = data.terraform_remote_state.shared.outputs.artifact_bucket_name
}

# Reads the shared artifact bucket output from the shared stack state.
data "terraform_remote_state" "shared" {
  backend = "s3"

  config = {
    bucket = var.state_bucket_name
    key    = var.shared_state_key
    region = var.state_bucket_region
  }
}

# Creates the dev artifact parameter and prepares deployment metadata.
module "bootstrap" {
  source = "../../modules/bootstrap"

  project_name              = var.project_name
  environment               = var.environment
  artifact_bucket_name      = local.shared_artifact_bucket_name
  create_artifact_bucket    = false
  create_artifact_parameter = true
  create_github_deploy_role = false
  github_repo               = ""
  github_allowed_branches   = []
  artifact_prefix           = "lambdas/get-presigned-url/"
  tags                      = local.default_tags
}

# Deploys the dev get-presigned-url API and Lambda resources.
module "get_presigned_url" {
  source = "../../modules/get_presigned_url"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  project_name                  = var.project_name
  environment                   = var.environment
  aws_region                    = var.aws_region
  artifact_parameter_name       = module.bootstrap.get_presigned_url_artifact_parameter_name
  lambda_runtime                = var.lambda_runtime
  lambda_memory_size            = var.lambda_memory_size
  lambda_timeout_seconds        = var.lambda_timeout_seconds
  private_bucket_name           = var.private_bucket_name
  allowed_object_keys           = var.allowed_object_keys
  allowed_object_prefixes       = var.allowed_object_prefixes
  default_expires_seconds       = var.default_expires_seconds
  max_expires_seconds           = var.max_expires_seconds
  allowed_origins               = var.allowed_origins
  log_retention_days            = var.log_retention_days
  throttle_burst_limit          = var.throttle_burst_limit
  throttle_rate_limit           = var.throttle_rate_limit
  alarm_sns_topic_arn           = var.alarm_sns_topic_arn
  enable_custom_domain          = var.enable_custom_domain
  create_api_domain_certificate = var.create_api_domain_certificate
  api_domain_name               = var.api_domain_name
  hosted_zone_name              = var.hosted_zone_name
  api_domain_certificate_arn    = var.api_domain_certificate_arn
  tags                          = local.default_tags
}
