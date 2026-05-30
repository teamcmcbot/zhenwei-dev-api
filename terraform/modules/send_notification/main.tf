data "aws_partition" "current" {}

data "aws_caller_identity" "current" {}

// Reads the packaged Lambda artifact metadata from SSM.
data "aws_ssm_parameter" "artifact" {
  name = var.artifact_parameter_name
}

data "aws_ssm_parameter" "pushover_token" {
  name = var.pushover_token_parameter_name
}

data "aws_ssm_parameter" "pushover_user" {
  name = var.pushover_user_parameter_name
}

locals {
  service_name                      = "send-notification"
  lambda_name                       = "${var.project_name}-${var.environment}-${local.service_name}"
  api_name                          = var.api_name != "" ? var.api_name : "${var.project_name}-${var.environment}-send-notification-rest-api"
  automation_api_key_parameter_name = var.automation_api_key_parameter_name != "" ? var.automation_api_key_parameter_name : "/${var.project_name}/${var.environment}/send-notification/api-key/automation"
  website_api_key_parameter_name    = var.website_api_key_parameter_name != "" ? var.website_api_key_parameter_name : "/${var.project_name}/${var.environment}/send-notification/api-key/website"

  artifact      = jsondecode(data.aws_ssm_parameter.artifact.value)
  alarm_actions = var.alarm_sns_topic_arn == "" ? [] : [var.alarm_sns_topic_arn]
}

resource "aws_iam_role" "lambda" {
  name = "${local.lambda_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "lambda" {
  name = "${local.lambda_name}-policy"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.lambda_name}",
          "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.lambda_name}:*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter"
        ]
        Resource = [
          data.aws_ssm_parameter.pushover_token.arn,
          data.aws_ssm_parameter.pushover_user.arn
        ]
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.lambda_name}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_lambda_function" "this" {
  function_name = local.lambda_name
  role          = aws_iam_role.lambda.arn
  runtime       = var.lambda_runtime
  handler       = var.lambda_handler

  s3_bucket        = local.artifact.bucket
  s3_key           = local.artifact.key
  source_code_hash = local.artifact.source_code_hash

  memory_size = var.lambda_memory_size
  timeout     = var.lambda_timeout_seconds

  environment {
    variables = {
      APP_ENV             = var.environment
      ALLOWED_SOURCES     = join(",", var.allowed_sources)
      ALLOWED_EVENT_TYPES = join(",", var.allowed_event_types)
      LOG_LEVEL           = "INFO"
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda]

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "api_access" {
  name              = "/aws/apigateway/${local.api_name}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_api_gateway_rest_api" "this" {
  name = local.api_name

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = var.tags
}

resource "aws_api_gateway_resource" "send_notification" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "send-notification"
}

resource "aws_api_gateway_method" "post" {
  rest_api_id      = aws_api_gateway_rest_api.this.id
  resource_id      = aws_api_gateway_resource.send_notification.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = true
}

resource "aws_api_gateway_integration" "lambda" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.send_notification.id
  http_method             = aws_api_gateway_method.post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.this.invoke_arn
}

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.send_notification.id,
      aws_api_gateway_method.post.id,
      aws_api_gateway_integration.lambda.id,
      aws_lambda_function.this.qualified_arn
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [aws_api_gateway_integration.lambda]
}

resource "aws_api_gateway_stage" "this" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  deployment_id = aws_api_gateway_deployment.this.id
  stage_name    = var.stage_name

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      resourcePath   = "$context.resourcePath"
      status         = "$context.status"
      protocol       = "$context.protocol"
      responseLength = "$context.responseLength"
      integrationErr = "$context.integration.error"
      apiKeyId       = "$context.identity.apiKeyId"
    })
  }

  tags = var.tags
}

resource "aws_api_gateway_method_settings" "all" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.this.stage_name
  method_path = "*/*"

  settings {
    metrics_enabled    = true
    logging_level      = "INFO"
    data_trace_enabled = false
  }
}

resource "aws_lambda_permission" "allow_api_gateway" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.this.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/*"
}

resource "aws_api_gateway_base_path_mapping" "custom_domain" {
  count = var.enable_custom_domain ? 1 : 0

  api_id      = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.this.stage_name
  domain_name = var.api_domain_name
  base_path   = var.custom_domain_base_path
}

resource "aws_api_gateway_api_key" "automation" {
  name    = "${local.lambda_name}-automation"
  enabled = true

  tags = merge(var.tags, {
    CallerGroup = "automation"
  })
}

resource "aws_api_gateway_api_key" "website" {
  name    = "${local.lambda_name}-website"
  enabled = true

  tags = merge(var.tags, {
    CallerGroup = "website"
  })
}

resource "aws_ssm_parameter" "automation_api_key" {
  name      = local.automation_api_key_parameter_name
  type      = "SecureString"
  value     = aws_api_gateway_api_key.automation.value
  overwrite = true

  tags = merge(var.tags, {
    CallerGroup = "automation"
    Purpose     = "send-notification-api-key"
  })
}

resource "aws_ssm_parameter" "website_api_key" {
  name      = local.website_api_key_parameter_name
  type      = "SecureString"
  value     = aws_api_gateway_api_key.website.value
  overwrite = true

  tags = merge(var.tags, {
    CallerGroup = "website"
    Purpose     = "send-notification-api-key"
  })
}

resource "aws_api_gateway_usage_plan" "automation" {
  name = "${local.lambda_name}-automation"

  api_stages {
    api_id = aws_api_gateway_rest_api.this.id
    stage  = aws_api_gateway_stage.this.stage_name
  }

  throttle_settings {
    burst_limit = var.automation_burst_limit
    rate_limit  = var.automation_rate_limit
  }

  quota_settings {
    limit  = var.automation_monthly_quota
    offset = 0
    period = "MONTH"
  }

  tags = merge(var.tags, {
    CallerGroup = "automation"
  })
}

resource "aws_api_gateway_usage_plan" "website" {
  name = "${local.lambda_name}-website"

  api_stages {
    api_id = aws_api_gateway_rest_api.this.id
    stage  = aws_api_gateway_stage.this.stage_name
  }

  throttle_settings {
    burst_limit = var.website_burst_limit
    rate_limit  = var.website_rate_limit
  }

  quota_settings {
    limit  = var.website_monthly_quota
    offset = 0
    period = "MONTH"
  }

  tags = merge(var.tags, {
    CallerGroup = "website"
  })
}

resource "aws_api_gateway_usage_plan_key" "automation" {
  key_id        = aws_api_gateway_api_key.automation.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.automation.id
}

resource "aws_api_gateway_usage_plan_key" "website" {
  key_id        = aws_api_gateway_api_key.website.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.website.id
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  count = var.enable_cloudwatch_alarms ? 1 : 0

  alarm_name          = "${local.lambda_name}-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Lambda errors detected for send-notification"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    FunctionName = aws_lambda_function.this.function_name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "lambda_throttles" {
  count = var.enable_cloudwatch_alarms ? 1 : 0

  alarm_name          = "${local.lambda_name}-throttles"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Throttles"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Lambda throttles detected for send-notification"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    FunctionName = aws_lambda_function.this.function_name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "api_4xx" {
  count = var.enable_cloudwatch_alarms ? 1 : 0

  alarm_name          = "${local.api_name}-4xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "4XXError"
  namespace           = "AWS/ApiGateway"
  period              = 300
  statistic           = "Sum"
  threshold           = 10
  alarm_description   = "REST API 4xx spike detected"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    ApiName = aws_api_gateway_rest_api.this.name
    Stage   = aws_api_gateway_stage.this.stage_name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  count = var.enable_cloudwatch_alarms ? 1 : 0

  alarm_name          = "${local.api_name}-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "5XXError"
  namespace           = "AWS/ApiGateway"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "REST API 5xx detected"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    ApiName = aws_api_gateway_rest_api.this.name
    Stage   = aws_api_gateway_stage.this.stage_name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "api_throttled" {
  count = var.enable_cloudwatch_alarms ? 1 : 0

  alarm_name          = "${local.api_name}-throttled-requests"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Throttle"
  namespace           = "AWS/ApiGateway"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "REST API throttled requests detected"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    ApiName = aws_api_gateway_rest_api.this.name
    Stage   = aws_api_gateway_stage.this.stage_name
  }

  tags = var.tags
}
