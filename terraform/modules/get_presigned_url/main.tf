data "aws_partition" "current" {}

// Looks up the Route53 hosted zone when custom domain is enabled.
data "aws_route53_zone" "main" {
  count        = var.enable_custom_domain ? 1 : 0
  name         = var.hosted_zone_name
  private_zone = false
}

// Reads the packaged Lambda artifact metadata from SSM.
data "aws_ssm_parameter" "artifact" {
  name = var.artifact_parameter_name
}

locals {
  service_name = "get-presigned-url"
  lambda_name  = "${var.project_name}-${var.environment}-${local.service_name}"
  api_name     = var.api_name != "" ? var.api_name : "${var.project_name}-${var.environment}-http-api"

  artifact = jsondecode(data.aws_ssm_parameter.artifact.value)

  cleaned_allowed_prefixes = [for p in var.allowed_object_prefixes : trimprefix(p, "/")]

  allowed_object_arns = concat(
    [for k in var.allowed_object_keys : "arn:${data.aws_partition.current.partition}:s3:::${var.private_bucket_name}/${k}"],
    [for p in local.cleaned_allowed_prefixes : "arn:${data.aws_partition.current.partition}:s3:::${var.private_bucket_name}/${p}*"]
  )

  alarm_actions = var.alarm_sns_topic_arn == "" ? [] : [var.alarm_sns_topic_arn]

  resolved_api_certificate_arn = var.create_api_domain_certificate ? aws_acm_certificate_validation.api_domain[0].certificate_arn : var.api_domain_certificate_arn
}

// Creates the Lambda execution role for get-presigned-url.
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

// Grants the Lambda permission to write logs and read approved S3 objects.
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
          "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:*:log-group:/aws/lambda/${local.lambda_name}:*",
          "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:*:log-group:/aws/lambda/${local.lambda_name}"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject"
        ]
        Resource = local.allowed_object_arns
      }
    ]
  })
}

// Sets retention for Lambda application logs.
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.lambda_name}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

// Creates the Lambda function for presigned URL generation.
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
      APP_ENV                               = var.environment
      PRIVATE_BUCKET_NAME                   = var.private_bucket_name
      ALLOWED_OBJECT_KEYS                   = join(",", var.allowed_object_keys)
      ALLOWED_OBJECT_PREFIXES               = join(",", var.allowed_object_prefixes)
      DEFAULT_PRESIGNED_URL_EXPIRES_SECONDS = tostring(var.default_expires_seconds)
      MAX_PRESIGNED_URL_EXPIRES_SECONDS     = tostring(var.max_expires_seconds)
      ALLOWED_ORIGINS                       = join(",", var.allowed_origins)
      LOG_LEVEL                             = "INFO"
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda]

  tags = var.tags
}

// Sets retention for API Gateway access logs.
resource "aws_cloudwatch_log_group" "api_access" {
  name              = "/aws/apigateway/${local.api_name}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

// Creates the HTTP API entrypoint for the service.
resource "aws_apigatewayv2_api" "this" {
  name          = local.api_name
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = var.allowed_origins
    allow_methods = ["OPTIONS", "POST"]
    allow_headers = ["content-type", "authorization", "x-requested-with"]
    max_age       = 300
  }

  tags = var.tags
}

// Connects the API route to the Lambda handler.
resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_method     = "POST"
  payload_format_version = "2.0"
  integration_uri        = aws_lambda_function.this.invoke_arn
}

// Exposes the POST route used by the browser client.
resource "aws_apigatewayv2_route" "post_get_presigned_url" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "POST /get-presigned-url"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

// Configures the API stage, throttling, and access logging.
resource "aws_apigatewayv2_stage" "this" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = var.stage_name
  auto_deploy = true

  default_route_settings {
    detailed_metrics_enabled = true
    throttling_burst_limit   = var.throttle_burst_limit
    throttling_rate_limit    = var.throttle_rate_limit
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      protocol       = "$context.protocol"
      responseLength = "$context.responseLength"
      integrationErr = "$context.integration.error"
    })
  }

  tags = var.tags
}

// Allows API Gateway to invoke the Lambda function.
resource "aws_lambda_permission" "allow_api_gateway" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.this.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}

// Alerts when the Lambda function records errors.
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
  alarm_description   = "Lambda errors detected for get-presigned-url"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    FunctionName = aws_lambda_function.this.function_name
  }

  tags = var.tags
}

// Alerts when the API returns elevated 4xx responses.
resource "aws_cloudwatch_metric_alarm" "api_4xx" {
  count = var.enable_cloudwatch_alarms ? 1 : 0

  alarm_name          = "${local.api_name}-4xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "4xx"
  namespace           = "AWS/ApiGateway"
  period              = 300
  statistic           = "Sum"
  threshold           = 50
  alarm_description   = "API 4xx spike detected"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    ApiId = aws_apigatewayv2_api.this.id
    Stage = aws_apigatewayv2_stage.this.name
  }

  tags = var.tags
}

// Alerts when the API returns elevated 5xx responses.
resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  count = var.enable_cloudwatch_alarms ? 1 : 0

  alarm_name          = "${local.api_name}-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "5xx"
  namespace           = "AWS/ApiGateway"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "API 5xx detected"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    ApiId = aws_apigatewayv2_api.this.id
    Stage = aws_apigatewayv2_stage.this.name
  }

  tags = var.tags
}

// Alerts when the API exceeds throttling limits.
resource "aws_cloudwatch_metric_alarm" "api_throttled" {
  count = var.enable_cloudwatch_alarms ? 1 : 0

  alarm_name          = "${local.api_name}-throttled-requests"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ThrottledRequests"
  namespace           = "AWS/ApiGateway"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "API throttled requests detected"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    ApiId = aws_apigatewayv2_api.this.id
    Stage = aws_apigatewayv2_stage.this.name
  }

  tags = var.tags
}

// Creates the custom domain name when API Gateway should use one.
resource "aws_apigatewayv2_domain_name" "this" {
  count = var.enable_custom_domain ? 1 : 0

  domain_name = var.api_domain_name

  domain_name_configuration {
    certificate_arn = local.resolved_api_certificate_arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }

  tags = var.tags
}

// Creates the ACM certificate for the API custom domain when requested.
resource "aws_acm_certificate" "api_domain" {
  count = var.enable_custom_domain && var.create_api_domain_certificate ? 1 : 0

  domain_name       = var.api_domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = var.tags
}

// Publishes DNS validation records for the ACM certificate.
resource "aws_route53_record" "acm_validation" {
  for_each = var.enable_custom_domain && var.create_api_domain_certificate ? {
    for dvo in aws_acm_certificate.api_domain[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 60
  records = [each.value.record]
}

// Waits for ACM validation to complete before using the certificate.
resource "aws_acm_certificate_validation" "api_domain" {
  count = var.enable_custom_domain && var.create_api_domain_certificate ? 1 : 0

  certificate_arn         = aws_acm_certificate.api_domain[0].arn
  validation_record_fqdns = [for record in aws_route53_record.acm_validation : record.fqdn]
}

// Maps the custom domain to the API stage.
resource "aws_apigatewayv2_api_mapping" "this" {
  count = var.enable_custom_domain ? 1 : 0

  api_id      = aws_apigatewayv2_api.this.id
  domain_name = aws_apigatewayv2_domain_name.this[0].id
  stage       = aws_apigatewayv2_stage.this.id
}

// Creates the Route53 alias record for the API custom domain.
resource "aws_route53_record" "api_domain" {
  count = var.enable_custom_domain ? 1 : 0

  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = var.api_domain_name
  type    = "A"

  alias {
    name                   = aws_apigatewayv2_domain_name.this[0].domain_name_configuration[0].target_domain_name
    zone_id                = aws_apigatewayv2_domain_name.this[0].domain_name_configuration[0].hosted_zone_id
    evaluate_target_health = false
  }
}
