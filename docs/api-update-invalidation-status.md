# update-invalidation-status Implementation Plan

## Purpose

`update-invalidation-status` tracks a CloudFront invalidation until it completes, then sends an operational notification. The first consumer is the `zhenwei-dev-site` deployment workflow, which creates a CloudFront invalidation and needs a reliable completion signal.

The service should be internal automation only. Public callers should not be able to submit arbitrary distribution IDs or trigger notification flows.

## Public Contract

Recommended route if exposed through API Gateway:

```text
POST /internal/cloudfront/invalidation-status
```

Recommended long-term invocation:

```text
aws stepfunctions start-execution --state-machine-arn <arn> --input file://payload.json
```

Step Functions is the better long-term fit because waiting is part of the business process. Lambda can work for the first phase, but it pays for idle wait time during polling.

### Request

```json
{
  "source": "github-actions",
  "distributionId": "E1234567890ABC",
  "invalidationId": "I1234567890ABC",
  "environment": "prod",
  "pollIntervalSeconds": 30,
  "timeoutSeconds": 300,
  "notifyOnComplete": true,
  "metadata": {
    "repository": "teamcmcbot/zhenwei-dev-site",
    "workflow": "deploy-prod",
    "runId": "123456789",
    "commitSha": "abc1234"
  }
}
```

Required fields:

| Name | Type | Description |
| --- | --- | --- |
| `source` | string | Trusted source, normally `github-actions`. |
| `distributionId` | string | CloudFront distribution ID returned by the site deployment workflow. |
| `invalidationId` | string | CloudFront invalidation ID returned by the invalidation create step. |
| `environment` | string | `dev` or `prod`. |

Optional fields:

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `pollIntervalSeconds` | integer | `30` | Poll interval. Must stay within configured limits. |
| `timeoutSeconds` | integer | `300` | Maximum tracking time. Must stay within configured limits. |
| `notifyOnComplete` | boolean | `true` | Whether to send a notification when completed. |
| `metadata` | object | `{}` | Non-secret workflow context. |

Validation limits:

- `distributionId` must be in an environment-specific allow-list.
- `invalidationId` must match the expected CloudFront invalidation ID format.
- `pollIntervalSeconds` should be fixed at 30 seconds or constrained to 15-60 seconds.
- `timeoutSeconds` should be capped at 300 seconds for Phase 1.
- `source` must be allow-listed.
- Metadata must not contain secrets or tokens.

### Response

Phase 1 Lambda synchronous response when completed:

```json
{
  "status": "Completed",
  "completed": true,
  "checks": 4,
  "elapsedSeconds": 90,
  "notificationSent": true,
  "requestId": "..."
}
```

Phase 1 Lambda response when timeout is reached:

```json
{
  "status": "InProgress",
  "completed": false,
  "checks": 10,
  "elapsedSeconds": 300,
  "notificationSent": true,
  "requestId": "..."
}
```

Step Functions start response:

```json
{
  "accepted": true,
  "executionArn": "arn:aws:states:...",
  "requestId": "..."
}
```

## Phase 1 Lambda Logic

Recommended runtime: Python 3.14.

Handler steps:

1. Read request ID, caller identity, and environment.
2. Parse and validate the input payload.
3. Verify the distribution ID is allow-listed for the environment.
4. Call `cloudfront.get_invalidation`.
5. If status is `Completed`, send a completion notification and return success.
6. If status is not complete, wait for `pollIntervalSeconds`.
7. Repeat until completed or `timeoutSeconds` is reached.
8. If timeout is reached, send a timeout notification with the last known status.
9. Return final status, check count, elapsed time, and notification result.

Suggested environment variables:

| Name | Example | Description |
| --- | --- | --- |
| `APP_ENV` | `prod` | Environment name. |
| `LOG_LEVEL` | `INFO` | Runtime log level. |
| `ALLOWED_DISTRIBUTION_IDS` | `E1234567890ABC` | Comma-separated approved distribution IDs. |
| `DEFAULT_POLL_INTERVAL_SECONDS` | `30` | Default poll interval. |
| `MAX_TIMEOUT_SECONDS` | `300` | Maximum tracking time. |
| `SEND_NOTIFICATION_FUNCTION_NAME` | `zhenwei-dev-api-prod-send-notification` | Internal notification Lambda name. |
| `ALLOWED_SOURCES` | `github-actions` | Allowed source values. |

## Phase 2 Step Functions Logic

Recommended state machine flow:

```text
Validate Input -> Check Invalidation -> Is Completed?
  -> yes: Send Completion Notification -> Done
  -> no: Is Timeout Reached?
    -> yes: Send Timeout Notification -> Done
    -> no: Wait 30 Seconds -> Check Invalidation
```

Recommended implementation details:

- Use a small validation Lambda at the start, or validate before `StartExecution` in the API wrapper Lambda.
- Use a check-status Lambda for `cloudfront:GetInvalidation`.
- Use Step Functions `Wait` state for the 30-second interval.
- Use a notification Lambda task to call `send-notification` internally.
- Store execution history in Step Functions for operational traceability.

## Terraform Configuration

Phase 1 required resources:

| Resource | Purpose |
| --- | --- |
| `aws_lambda_function` | Runs bounded polling logic. |
| `aws_iam_role` | Lambda execution role. |
| `aws_iam_role_policy` | Allows `cloudfront:GetInvalidation` and notification invocation. |
| `aws_cloudwatch_log_group` | Stores Lambda logs with explicit retention. |
| `aws_apigatewayv2_route` | Optional IAM-protected internal HTTP route. |
| `aws_lambda_permission` | Allows API Gateway invocation if route is used. |
| `aws_iam_role` for GitHub OIDC | Allows trusted GitHub workflows to invoke Lambda or API route. |

Phase 2 additional resources:

| Resource | Purpose |
| --- | --- |
| `aws_sfn_state_machine` | Orchestrates wait/check/notify workflow. |
| `aws_iam_role` for Step Functions | Allows state machine to invoke task Lambdas. |
| `aws_cloudwatch_log_group` for Step Functions | Stores execution logs. |
| `aws_lambda_function` check-status task | Calls CloudFront and returns status. |
| `aws_apigatewayv2_route` or direct IAM | Starts state machine execution. |

IAM policy scope:

```json
{
  "Action": "cloudfront:GetInvalidation",
  "Effect": "Allow",
  "Resource": "*"
}
```

CloudFront IAM resource scoping is limited for some actions. Because of that, the application must enforce an explicit allow-list of distribution IDs even if IAM cannot fully scope the resource.

Additional permissions:

- `lambda:InvokeFunction` for `send-notification`, if Lambda calls notification directly.
- `states:StartExecution` for the Step Functions state machine, if GitHub Actions starts the workflow.
- `execute-api:Invoke` only if an IAM-protected API Gateway route is used.

Suggested module inputs:

| Name | Description |
| --- | --- |
| `environment` | `dev` or `prod`. |
| `artifact_bucket` | Lambda artifact S3 bucket. |
| `artifact_key` | Versioned Lambda zip key. |
| `artifact_hash` | Source code hash. |
| `allowed_distribution_ids` | Approved CloudFront distributions. |
| `notification_function_name` | Internal notification Lambda. |
| `github_oidc_subjects` | Trusted GitHub workflow subjects. |
| `max_timeout_seconds` | Maximum tracking duration. |
| `log_retention_days` | CloudWatch log retention. |

## Access Control

Recommended controls:

- Treat this as an internal endpoint.
- Prefer GitHub OIDC to assume an AWS role and directly invoke Lambda or Step Functions.
- If API Gateway is used, require `AWS_IAM` authorization.
- Do not enable browser CORS for this route.
- Restrict the GitHub OIDC trust policy to the deployment workflows that create invalidations.
- Validate distribution IDs against environment-specific allow-lists.
- Cap timeout and poll interval in code.
- Use reserved concurrency if necessary to prevent runaway workflow failures from starting too many pollers.

Abuse scenarios to prevent:

- Anonymous callers checking arbitrary distribution IDs.
- Attackers triggering notification spam through fake invalidation IDs.
- Workflow bugs starting many long-running polling Lambdas.
- Excessive CloudFront API calls caused by unbounded polling.

## Logging And Observability

Lambda structured log fields:

| Field | Description |
| --- | --- |
| `service` | `update-invalidation-status`. |
| `environment` | `dev` or `prod`. |
| `requestId` | Lambda, API Gateway, or Step Functions execution ID. |
| `callerArn` | IAM caller when available. |
| `source` | Request source. |
| `distributionId` | Approved distribution ID. |
| `invalidationId` | Invalidation ID. |
| `cloudFrontStatus` | `InProgress` or `Completed`. |
| `checks` | Number of status checks performed. |
| `elapsedSeconds` | Total elapsed tracking time. |
| `notificationSent` | Whether notification was attempted. |
| `outcome` | `completed`, `timeout`, `validation_error`, `unauthorized`, `cloudfront_error`, `notification_error`, `internal_error`. |

Recommended metrics and alarms:

- Lambda or Step Functions execution failures.
- Timeout outcomes greater than expected.
- Invocation count spike.
- CloudFront API errors.
- Notification failures.
- Step Functions executions running longer than expected.

For Step Functions:

- Enable execution logging.
- Enable X-Ray if deeper tracing is useful.
- Use execution names that include environment, workflow run ID, and invalidation ID when possible.

## Tests

Unit tests:

- Accepts valid request for an allow-listed distribution.
- Rejects unknown distribution IDs.
- Rejects invalid invalidation IDs.
- Caps timeout and poll interval.
- Returns completed when CloudFront reports `Completed`.
- Returns timeout when CloudFront remains `InProgress`.
- Invokes notification service with expected payload.
- Handles CloudFront API errors safely.

Integration tests in dev:

- Start an invalidation from the site workflow and pass IDs to this service.
- Verify the service observes `Completed`.
- Verify completion notification is sent.
- Verify unauthorized direct API calls are denied if an HTTP route exists.

## Implementation Order

1. Implement Phase 1 Lambda with bounded polling and tests.
2. Add Terraform for Lambda, IAM, logs, GitHub OIDC invocation, and optional IAM-protected route.
3. Wire deployment workflow to invoke this service after creating a CloudFront invalidation.
4. Add alarms for errors, timeouts, and invocation spikes.
5. Replace bounded polling Lambda with Step Functions orchestration once the initial flow is proven.