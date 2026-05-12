data "aws_partition" "current" {}

data "aws_caller_identity" "current" {}

// Reads the existing GitHub Actions OIDC provider for deploy role trust.
data "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
}

locals {
  artifact_parameter_name = "/${var.project_name}/${var.environment}/get-presigned-url/artifact"
  github_deploy_artifact_parameter_arns = [
    for environment in var.github_deploy_environments :
    "arn:${data.aws_partition.current.partition}:ssm:*:${data.aws_caller_identity.current.account_id}:parameter/${var.project_name}/${environment}/get-presigned-url/artifact"
  ]

  github_subjects = [
    for branch in var.github_allowed_branches :
    "repo:${var.github_repo}:ref:refs/heads/${branch}"
  ]

  artifact_bucket_name = var.create_artifact_bucket ? aws_s3_bucket.artifacts[0].bucket : data.aws_s3_bucket.artifacts[0].bucket
}

# Creates the shared or environment-specific artifact bucket when requested.
resource "aws_s3_bucket" "artifacts" {
  count         = var.create_artifact_bucket ? 1 : 0
  bucket        = var.artifact_bucket_name
  force_destroy = var.artifact_bucket_force_destroy

  tags = var.tags
}

# Enables versioning for the artifact bucket.
resource "aws_s3_bucket_versioning" "artifacts" {
  count  = var.create_artifact_bucket ? 1 : 0
  bucket = aws_s3_bucket.artifacts[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

# Enforces server-side encryption on the artifact bucket.
resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  count  = var.create_artifact_bucket ? 1 : 0
  bucket = aws_s3_bucket.artifacts[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Blocks public access on the artifact bucket.
resource "aws_s3_bucket_public_access_block" "artifacts" {
  count  = var.create_artifact_bucket ? 1 : 0
  bucket = aws_s3_bucket.artifacts[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Reads an existing artifact bucket when this stack does not create one.
data "aws_s3_bucket" "artifacts" {
  count  = var.create_artifact_bucket ? 0 : 1
  bucket = var.artifact_bucket_name
}

# Creates the SSM parameter that stores artifact metadata for deployments.
resource "aws_ssm_parameter" "get_presigned_url_artifact" {
  count = var.create_artifact_parameter ? 1 : 0

  name = local.artifact_parameter_name
  type = "String"
  # Builds the GitHub OIDC trust policy when a dedicated deploy role is enabled.

  value = jsonencode({
    bucket           = local.artifact_bucket_name
    key              = "placeholder"
    source_code_hash = "placeholder"
    build_id         = "placeholder"
    commit_sha       = "placeholder"
    created_at       = "placeholder"
  })

  lifecycle {
    ignore_changes = [value]
  }

  tags = var.tags
}

data "aws_iam_policy_document" "github_assume_role" {
  count = var.create_github_deploy_role ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.github_subjects
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

# Creates the optional GitHub deploy role for CI/CD.
resource "aws_iam_role" "github_api_deploy" {
  count = var.create_github_deploy_role ? 1 : 0

  name               = "${var.project_name}-${var.environment}-github-api-deploy"
  assume_role_policy = data.aws_iam_policy_document.github_assume_role[0].json
  tags               = var.tags
}

# Grants the deploy role access to artifact uploads and the SSM parameter.
resource "aws_iam_role_policy" "github_api_deploy" {
  count = var.create_github_deploy_role ? 1 : 0

  name = "${var.project_name}-${var.environment}-api-deploy-policy"
  role = aws_iam_role.github_api_deploy[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:s3:::${local.artifact_bucket_name}/${var.artifact_prefix}*"
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:PutParameter"
        ]
        Resource = local.github_deploy_artifact_parameter_arns
      }
    ]
  })
}
