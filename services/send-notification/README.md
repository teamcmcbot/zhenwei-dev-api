# send-notification

Lambda service for sending push notifications via Pushover.

## Overview

`send-notification` is the default notification channel for automation events:
- GitHub workflow completion notifications
- Terraform apply completion alerts
- CloudFront invalidation completion alerts
- Any automation pipeline that needs push notifications

## Endpoint

- **Method**: POST
- **URL**: `https://api.zhenwei.dev/send-notification`
- **Authentication**: API key via `x-api-key` header (required)

## Quick Start

### Development

```bash
# Install dependencies
pip install -r requirements.txt
pip install -r requirements-dev.txt

# Run tests
python -m pytest tests/ -v

# Invoke locally (requires AWS credentials for SSM)
python -c "from src.handler import lambda_handler; print(lambda_handler({'body': '...', 'httpMethod': 'POST'}, None))"
```

### Deployment

The Lambda function is built and packaged by `scripts/package_lambda.sh send-notification`, which:
1. Creates `build/send-notification/package/` directory
2. Copies handler and dependencies
3. Zips for AWS Lambda upload

### First-time Terraform deployment

Use the bootstrap-first sequence so the SSM artifact parameter exists before the service module reads it:

Dev:

```bash
terraform -chdir=terraform/envs/dev apply -target=module.bootstrap
scripts/publish_lambda_artifact.sh dev zhenwei-dev-api-artifacts send-notification
terraform -chdir=terraform/envs/dev apply
```

Prod (after dev is verified):

```bash
terraform -chdir=terraform/envs/prod apply -target=module.bootstrap
scripts/publish_lambda_artifact.sh prod zhenwei-dev-api-artifacts send-notification
terraform -chdir=terraform/envs/prod apply
```

For repeat deployments after the parameter exists, publish the new artifact and apply Terraform again.

## Input Contract

### Mandatory fields

| Field | Type | Example |
|-------|------|---------|
| `source` | string | `"github-actions"` |
| `eventType` | string | `"workflow.completed"` |
| `message` | string | `"Deployment succeeded"` |

### Optional fields

| Field | Type | Notes |
|-------|------|-------|
| `title` | string | Auto-generated from `eventType` if omitted |
| `priority` | integer | `-2, -1, 0, 1, 2` (default: 0) |
| `sound` | string | Pushover sound name |
| `device` | string | Restrict to specific device |
| `url` | string | Context link (max 512 chars) |
| `urlTitle` | string | Label for `url` (max 100 chars) |
| `ttl` | integer | Pushover TTL |
| `timestamp` | integer | Unix timestamp |
| `html` | boolean | Enable HTML formatting |
| `monospace` | boolean | Enable monospace font (incompatible with html) |
| `metadata` | object | Structured logging context (no secrets) |
| `dedupeKey` | string | Idempotency key for retry-safe calls |
| `retry` | integer | Emergency only (priority=2) |
| `expire` | integer | Emergency only (priority=2) |
| `callback` | string | Emergency callback URL |
| `applicationToken` | string | Override SSM `PushoverToken` (max 100 chars) |

## Request Example

```json
{
  "source": "github-actions",
  "eventType": "workflow.completed",
  "title": "deploy-prod succeeded",
  "message": "zhenwei-dev-site deploy-prod completed for commit 9f3a7c1",
  "priority": 0,
  "url": "https://github.com/teamcmcbot/zhenwei-dev-site/actions/runs/123456789",
  "urlTitle": "View workflow run",
  "metadata": {
    "repo": "teamcmcbot/zhenwei-dev-site",
    "workflow": "deploy-prod",
    "environment": "prod"
  },
  "dedupeKey": "gha-123456789-workflow.completed"
}
```

## Response Schema

### Success

```json
{
  "accepted": true,
  "provider": "pushover",
  "providerRequestId": "123e4567-e89b-12d3-a456-426614174000",
  "providerReceipt": null,
  "requestId": "aws-request-id"
}
```

### Error

```json
{
  "accepted": false,
  "error": {
    "code": "validation_error",
    "message": "Invalid notification request."
  },
  "requestId": "aws-request-id"
}
```

## Validation Rules

- `source` and `eventType` must match allow-listed values (env vars)
- `message`: 1–1024 characters
- `title`: 1–250 characters (if provided)
- `url`: max 512 characters
- `urlTitle`: max 100 characters
- `applicationToken`: max 100 characters, alphanumeric + `_-.` only
- No control characters in string fields
- Cannot use `html=true` and `monospace=true` together
- If `priority=2` (emergency), `retry` and `expire` are required
- `metadata` cannot contain credentials, tokens, or secrets

## Environment Variables

- `ALLOWED_SOURCES`: Comma-delimited list of valid `source` values (e.g., `"github-actions,terraform,cloudfront"`)
- `ALLOWED_EVENT_TYPES`: Comma-delimited list of valid `eventType` values (e.g., `"workflow.completed,apply.success,apply.failed"`)

## SSM Parameters

The Lambda function reads these SSM parameters at runtime:
- `PushoverToken`: Pushover app token (cached for 60 seconds)
- `PushoverUser`: Pushover user ID (cached for 60 seconds)

Cache is refreshed on:
- Cold start
- TTL expiry
- Auth failure from Pushover

## Security

**Mandatory controls**:
- API key required by API Gateway method
- Very low usage plan quotas (1 req/sec, 400/month for automation, 100/month for website)
- Strict payload validation with allow-lists
- Lambda IAM role limited to SSM read on two parameters only
- Secrets never logged or stored in environment variables
- `applicationToken` usage logged for audit trail

**Recommended (Phase 2)**:
- Add HMAC request signature validation in Lambda

## Errors

| Code | Status | Meaning |
|------|--------|---------|
| `validation_error` | 400 | Invalid payload (e.g., missing required field, invalid length) |
| `auth_error` | 401 | Pushover authentication failed (invalid token/user) |
| `provider_error` | 502 | Pushover service error (after retries) |
| `internal_error` | 500 | Unexpected Lambda error |

## Rate Limiting & Quotas

### Automation Plan (GitHub Actions)
- Throttle: 1 request/second
- Burst: 1
- Monthly quota: 400 requests

### Website Plan (zhenwei.dev)
- Throttle: 1 request/second
- Burst: 1
- Monthly quota: 100 requests

Exceeding throttle returns HTTP 429. Exceeding quota resets on the first of each month.

## Architecture

```
API Gateway (REST API)
  ↓ (with API key + usage plan enforcement)
Lambda Handler
  ├─ Step 1: Parse proxy event
  ├─ Step 2: Validate API key context
  ├─ Step 3: (Reserved) Validate signature header (Phase 2)
  ├─ Step 4: Validate payload
  ├─ Step 5: Resolve Pushover token (SSM or request override)
  ├─ Step 6: Resolve Pushover user (SSM)
  ├─ Step 7: Build Pushover request
  ├─ Step 8: Send to Pushover (4s timeout)
  ├─ Step 9: Retry on transient failures (exponential backoff)
  └─ Step 10: Return normalized response
      ↓
      SSM Parameter Store (PushoverToken, PushoverUser)
      ↓
      Pushover API (https://api.pushover.net/1/messages.json)
      ↓
      CloudWatch Logs (structured JSON, no secrets)
```

## Testing

Run unit tests:

```bash
python -m pytest tests/test_handler.py -v
```

Test coverage:
- Valid requests (all field combinations)
- Missing mandatory fields
- Invalid field lengths
- Invalid field values
- Token override scenarios
- SSM parameter failures
- Pushover API failures and retries
- Network timeouts

## Integration Testing

Run these commands from the repository root after deployment.

Dev:

```bash
API_ENDPOINT="$(terraform -chdir=terraform/envs/dev output -raw send_notification_api_endpoint)"
AUTOMATION_API_KEY="$(terraform -chdir=terraform/envs/dev output -raw send_notification_automation_api_key_value)"
NOW_TS="$(date +%s)"

curl -i -X POST "${API_ENDPOINT%/}/send-notification" \
  -H "x-api-key: ${AUTOMATION_API_KEY}" \
  -H "Content-Type: application/json" \
  -d "{
    \"source\": \"github-actions\",
    \"eventType\": \"workflow.completed\",
    \"message\": \"send-notification full payload smoke test\",
    \"title\": \"deploy-dev succeeded\",
    \"priority\": 0,
    \"sound\": \"pushover\",
    \"device\": \"iphone\",
    \"url\": \"https://github.com/teamcmcbot/zhenwei-dev-api/actions/runs/123456789\",
    \"urlTitle\": \"View workflow run\",
    \"ttl\": 300,
    \"timestamp\": ${NOW_TS},
    \"html\": false,
    \"monospace\": false,
    \"applicationToken\": \"[PUSHOVER_APPLICATION_TOKEN]\",
    \"metadata\": {
      \"repo\": \"teamcmcbot/zhenwei-dev-api\",
      \"workflow\": \"deploy-dev\",
      \"runId\": \"123456789\",
      \"environment\": \"dev\"
    },
    \"dedupeKey\": \"gha-123456789-workflow.completed\"
  }"
```

Prod:

```bash
API_ENDPOINT="$(terraform -chdir=terraform/envs/prod output -raw send_notification_api_endpoint)"
AUTOMATION_API_KEY="$(terraform -chdir=terraform/envs/prod output -raw send_notification_automation_api_key_value)"
NOW_TS="$(date +%s)"

curl -i -X POST "${API_ENDPOINT%/}/send-notification" \
  -H "x-api-key: ${AUTOMATION_API_KEY}" \
  -H "Content-Type: application/json" \
  -d "{
    \"source\": \"github-actions\",
    \"eventType\": \"workflow.completed\",
    \"message\": \"send-notification prod smoke test\",
    \"title\": \"deploy-prod succeeded\",
    \"priority\": 0,
    \"sound\": \"pushover\",
    \"url\": \"https://github.com/teamcmcbot/zhenwei-dev-api/actions/runs/123456789\",
    \"urlTitle\": \"View workflow run\",
    \"ttl\": 300,
    \"timestamp\": ${NOW_TS},
    \"html\": false,
    \"monospace\": false,
    \"metadata\": {
      \"repo\": \"teamcmcbot/zhenwei-dev-api\",
      \"workflow\": \"deploy-prod\",
      \"runId\": \"123456789\",
      \"environment\": \"prod\"
    },
    \"dedupeKey\": \"gha-123456789-workflow.completed\"
  }"
```

Expected result:

- HTTP `200`
- JSON includes `accepted: true`, `provider: "pushover"`, and non-empty `providerRequestId`

Note:

- `applicationToken` is optional. Remove it to use SSM `PushoverToken`. Keep it only when you intentionally want request-level token override.

Optional negative checks:

```bash
# Missing API key should fail at API Gateway.
curl -i -X POST "${API_ENDPOINT%/}/send-notification" \
  -H "Content-Type: application/json" \
  -d '{"source":"github-actions","eventType":"workflow.completed","message":"missing key"}'

# Invalid source should fail Lambda validation.
curl -i -X POST "${API_ENDPOINT%/}/send-notification" \
  -H "x-api-key: ${AUTOMATION_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"source":"invalid-source","eventType":"workflow.completed","message":"invalid source"}'

# html=true and monospace=true together should fail validation.
curl -i -X POST "${API_ENDPOINT%/}/send-notification" \
  -H "x-api-key: ${AUTOMATION_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"source":"github-actions","eventType":"workflow.completed","message":"invalid format","html":true,"monospace":true}'

# Emergency priority without retry/expire should fail validation.
curl -i -X POST "${API_ENDPOINT%/}/send-notification" \
  -H "x-api-key: ${AUTOMATION_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"source":"github-actions","eventType":"workflow.completed","message":"emergency missing fields","priority":2}'
```
