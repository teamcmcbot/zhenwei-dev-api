locals {
  default_tags = merge(
    var.tags,
    {
      Environment = var.environment
      ManagedBy   = "terraform"
      Project     = var.project_name
    }
  )
}

data "aws_iam_policy_document" "apigw_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["apigateway.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "apigw_cloudwatch" {
  name               = "${var.project_name}-${var.environment}-apigw-cloudwatch"
  assume_role_policy = data.aws_iam_policy_document.apigw_assume_role.json
  tags               = local.default_tags
}

resource "aws_iam_role_policy_attachment" "apigw_cloudwatch" {
  role       = aws_iam_role.apigw_cloudwatch.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

# API Gateway account settings are account-level singletons per region.
# Keep ownership in shared to avoid dev/prod drift.
resource "aws_api_gateway_account" "this" {
  cloudwatch_role_arn = aws_iam_role.apigw_cloudwatch.arn
}

# Bootstraps the shared stack so dev and prod can consume common outputs.
module "bootstrap" {
  source = "../../modules/bootstrap"

  project_name              = var.project_name
  environment               = var.environment
  artifact_bucket_name      = var.artifact_bucket_name
  create_artifact_bucket    = var.create_artifact_bucket
  create_artifact_parameter = false
  create_github_deploy_role = var.create_github_deploy_role
  github_repo               = var.github_repo
  github_allowed_branches   = var.github_allowed_branches
  github_deploy_environments = var.github_deploy_environments
  artifact_prefix           = var.artifact_prefix
  tags                      = local.default_tags
}
