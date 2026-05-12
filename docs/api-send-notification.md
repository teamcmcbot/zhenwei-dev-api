# send-notification Implementation Plan

## Purpose

`send-notification` sends operational push notifications to the owner's device. The first provider is expected to be Pushover. This service is intended for trusted automation, especially GitHub Actions workflows and internal Lambda or Step Functions workflows.

This endpoint must not be publicly callable. If public users can trigger it, they can spam notifications and waste API Gateway, Lambda, and provider quota.

## Public Contract

Recommended route if exposed through API Gateway:

```text
POST /internal/notifications
```

Recommended preferred invocation for GitHub Actions:

```text
aws lambda invoke --function-name <send-notification-function> ...
```

Direct Lambda invocation through an AWS role assumed with GitHub OIDC avoids exposing an HTTP endpoint when a public URL is not needed.

### Request

```json
{
  "source": "github-actions",
  "eventType": "deploy.completed",
  "title": "Deployment completed",
  "message": "zhenwei-dev-site deploy-prod completed for commit abc1234",
  "priority": 0,
  "metadata": {
    "repository": "teamcmcbot/zhenwei-dev-site",
    "workflow": "deploy-prod",
    "runId": "123456789",
    "commitSha": "abc1234",
    "environment": "prod"
  }
}
```

Required fields:

| Name | Type | Description |
| --- | --- | --- |
| `source` | string | Trusted source identifier, for example `github-actions` or `invalidation-status`. |
| `eventType` | string | Allow-listed event type. |
| `title` | string | Short notification title. |
| `message` | string | Notification body. |

Optional fields:

| Name | Type | Description |
| --- | --- | --- |
| `priority` | integer | Provider priority, constrained to approved values such as `-1`, `0`, or `1`. |
| `metadata` | object | Non-secret operational context for logs and troubleshooting. |

Validation limits:

- `title` maximum length: 100 characters.
- `message` maximum length: 512 characters.
- `eventType` must be allow-listed.
- `priority` must be allow-listed.
- `metadata` must not include secrets or full tokens.

### Response

Successful response:

```json
{
  "accepted": true,
  "provider": "pushover",
  "requestId": "..."
}
```

Rejected response:

```json
{
  "accepted": false,
  "error": {
    "code": "validation_error",
    "message": "The notification request is invalid."
  },
  "requestId": "..."
}
```

## Lambda Logic

Recommended runtime: Python 3.14.

Handler steps:

1. Read request ID, caller identity, and environment.
2. Parse JSON input from API Gateway event or direct Lambda event.
3. Validate authentication context when invoked through API Gateway.
4. Validate `source`, `eventType`, `title`, `message`, `priority`, and `metadata`.
5. Load Pushover secret from AWS Secrets Manager or encrypted SSM Parameter Store.
6. Call the Pushover API with a short timeout.
7. Retry transient provider failures with bounded exponential backoff.
8. Return `accepted: true` only after provider acceptance.
9. Log structured outcome without logging secret values.

Suggested environment variables:

| Name | Example | Description |
| --- | --- | --- |
| `APP_ENV` | `prod` | Environment name. |
| `LOG_LEVEL` | `INFO` | Runtime log level. |
| `NOTIFICATION_PROVIDER` | `pushover` | Provider implementation. |
| `PUSHOVER_SECRET_ID` | `/zhenwei-dev-api/prod/pushover` | Secret ID or parameter name. |
| `ALLOWED_SOURCES` | `github-actions,invalidation-status` | Allowed source values. |
| `ALLOWED_EVENT_TYPES` | `deploy.completed,deploy.failed,invalidation.completed,invalidation.timeout` | Allowed event types. |
| `HTTP_TIMEOUT_SECONDS` | `5` | Provider request timeout. |

Secret shape in Secrets Manager:

```json
{
  "appToken": "...",
  "userKey": "..."
}
```

## Terraform Configuration

Required resources:

| Resource | Purpose |
| --- | --- |
| `aws_lambda_function` | Runs the notification handler. |
| `aws_iam_role` | Lambda execution role. |
| `aws_iam_role_policy` | Allows read access to the notification secret. |
| `aws_cloudwatch_log_group` | Stores Lambda logs with explicit retention. |
| `aws_secretsmanager_secret` or data source | Stores or references provider credentials. |
| `aws_apigatewayv2_route` | Optional `POST /internal/notifications` route. |
| `aws_apigatewayv2_authorizer` or IAM auth config | Protects the route if API Gateway is used. |
| `aws_lambda_permission` | Allows API Gateway to invoke Lambda if route is used. |
| `aws_iam_role` for GitHub OIDC | Allows trusted GitHub workflows to invoke the Lambda or API route. |

Preferred initial design:

- Do not expose an HTTP route unless it is needed.
- Create a GitHub Actions IAM role trusted through GitHub OIDC.
- Allow that role to call `lambda:InvokeFunction` on this Lambda.
- Allow internal AWS services, such as the invalidation tracker Lambda or Step Functions state machine, to invoke it through IAM.

If API Gateway is used:

- Use `AWS_IAM` authorization for `POST /internal/notifications`.
- Grant `execute-api:Invoke` only to the GitHub OIDC role and approved internal roles.
- Do not enable CORS for browser use.

GitHub OIDC trust should restrict:

- Repository owner and repository names.
- Branch or environment where possible.
- Workflow audience and subject claims.

Suggested module inputs:

| Name | Description |
| --- | --- |
| `environment` | `dev` or `prod`. |
| `artifact_bucket` | Lambda artifact S3 bucket. |
| `artifact_key` | Versioned Lambda zip key. |
| `artifact_hash` | Source code hash. |
| `pushover_secret_id` | Secret ID containing provider credentials. |
| `allowed_sources` | Valid request sources. |
| `allowed_event_types` | Valid event types. |
| `github_oidc_subjects` | Trusted GitHub workflow subjects. |
| `log_retention_days` | CloudWatch log retention. |

## Access Control

This service should use private machine-to-machine access.

Recommended controls:

- Prefer direct Lambda invoke from GitHub Actions using AWS credentials from GitHub OIDC.
- Restrict the GitHub OIDC trust policy to specific repositories and protected environments.
- If HTTP is required, require `AWS_IAM` auth on the API Gateway route.
- Do not configure permissive CORS for this route.
- Do not accept anonymous requests, API-key-only requests, or unsigned webhook calls.
- Validate request source and event type even after IAM authorization.
- Use low reserved concurrency if needed to cap cost and provider spam during failures.

Why not API key only:

- API keys can leak.
- API keys identify a caller but are weak authorization by themselves.
- API Gateway usage plans help throttle, but they do not provide strong workload identity.

## Logging And Observability

Lambda structured log fields:

| Field | Description |
| --- | --- |
| `service` | `send-notification`. |
| `environment` | `dev` or `prod`. |
| `requestId` | Lambda or API Gateway request ID. |
| `callerArn` | IAM caller when available. |
| `source` | Request source. |
| `eventType` | Notification event type. |
| `provider` | `pushover`. |
| `providerStatus` | Provider response status code or provider result. |
| `outcome` | `accepted`, `validation_error`, `unauthorized`, `provider_error`, `internal_error`. |
| `durationMs` | Handler duration. |

Do not log:

- Pushover app token.
- Pushover user key.
- Full request headers.
- Any GitHub tokens or AWS temporary credentials.

Recommended metrics and alarms:

- Lambda errors greater than 0.
- Provider failures greater than 0.
- Unexpected invocation count spike.
- Unauthorized or validation failures greater than a small threshold.
- Throttles or reserved concurrency saturation.

## Tests

Unit tests:

- Accepts valid GitHub Actions deployment notification.
- Rejects missing required fields.
- Rejects unsupported `source` and `eventType`.
- Rejects oversized `title` or `message`.
- Does not log secret fields.
- Handles provider timeout and transient errors.
- Maps provider rejection to a safe error response.

Integration tests in dev:

- Invoke Lambda using the GitHub OIDC deployment role.
- Verify successful Pushover delivery for a test event.
- Verify unauthorized API Gateway call is denied if route exists.

## Implementation Order

1. Create service skeleton under `services/send-notification/`.
2. Implement request validation and provider abstraction.
3. Add Pushover client with timeout and bounded retry.
4. Add Terraform for Lambda, secret access, logs, and GitHub OIDC invocation role.
5. Add optional IAM-protected API Gateway route only if needed.
6. Add workflow examples that assume the role and invoke the service.
7. Add alarms for failures and unexpected invocation volume.