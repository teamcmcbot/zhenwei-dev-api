# send-notification API Design (v3)

## Goal

`send-notification` is the second API in this repository and becomes the default notification channel for automation events.

Immediate use case:

- GitHub workflow completion notifications (success/failure/cancelled).

Future use cases:

- Terraform apply completion alerts.
- CloudFront invalidation completion alerts.
- Any future automation pipeline that needs push notifications.

## Architecture Choice From Discussion

For this hobby project, use **API Gateway REST API** for this endpoint so you can demonstrate:

- REST API resources/methods.
- API keys.
- Usage plans.

Rationale:

- Traffic is expected to be low (about 300 calls/month).
- Cost difference vs HTTP API is acceptable for this volume.
- API key workflow is simple for GitHub Actions (`x-api-key` header from GitHub environment secrets).

## Endpoint Shape

Primary endpoint:

- `POST /send-notification`

Expected URL with custom domain:

- `https://api.zhenwei.dev/send-notification`

Notes:

- Endpoint is intended for machine-to-machine calls.
- No browser CORS support is required.

## Provider Assumptions (Pushover, checked via Context7)

Based on latest Pushover docs (`/websites/pushover_net_api`):

- Send endpoint: `POST https://api.pushover.net/1/messages.json`
- Required provider fields: `token`, `user`, `message`
- Common optional fields: `title`, `priority`, `sound`, `device`, `url`, `url_title`, `ttl`, `timestamp`, `html`, `monospace`
- Response format includes `status`, `request`, and for emergency messages, `receipt`
- Error responses include `status=0` and `errors[]`
- Message limits: message 1024 chars, title 250, URL 512, URL title 100

## Secrets Source (Existing SSM Parameters)

Reuse existing parameters by name:

- Parameter name: `PushoverToken`
- Parameter name: `PushoverUser`

Lambda behavior:

- Use Terraform data source `data.aws_ssm_parameter` to look up parameter values at deploy time for caching/documentation.
- At runtime, read values with `ssm:GetParameter` call.
- Cache in memory for warm invocations.
- Never log secret values.
- Refresh secret cache on cold start and when provider returns auth-related failures.

## Access Control Strategy

### Primary control

- API key required at API Gateway method level.

### Usage plan controls (demo-friendly, abuse-limiting)

Provision two usage plans for different caller groups:

**Plan 1: Automation (GitHub Actions + future automation pipelines)**

- Throttle rate: `1` request/second
- Throttle burst: `1`
- Quota: `400` requests/month

**Plan 2: Website (zhenwei.dev direct calls)**

- Throttle rate: `1` request/second
- Throttle burst: `1`
- Quota: `100` requests/month

Each plan has its own API key, allowing independent quota management and selective revocation per caller group.

### Defense in depth (recommended)

API key alone is not strong auth. Add one additional control:

- Shared signature header validation in Lambda (for example HMAC using a second secret in GitHub environment secrets), or
- Strict source allow-list plus very low quotas if you want lighter setup first.

## Input Contract

### Mandatory fields

| Field       | Type   | Why mandatory                              |
| ----------- | ------ | ------------------------------------------ |
| `source`    | string | Audit and policy control (who is sending). |
| `eventType` | string | Routing/alert classification.              |
| `message`   | string | Core Pushover content.                     |

### Optional fields

| Field              | Type    | Notes                                                                                                              |
| ------------------ | ------- | ------------------------------------------------------------------------------------------------------------------ |
| `title`            | string  | If omitted, service generates from `eventType`.                                                                    |
| `priority`         | integer | Allowed `-2,-1,0,1,2`; default `0`.                                                                                |
| `sound`            | string  | Pushover sound name.                                                                                               |
| `device`           | string  | Restrict to a specific device.                                                                                     |
| `url`              | string  | Context link (for example GitHub run URL).                                                                         |
| `urlTitle`         | string  | Label for `url`.                                                                                                   |
| `ttl`              | integer | Optional Pushover TTL.                                                                                             |
| `timestamp`        | integer | Unix timestamp for original event time.                                                                            |
| `html`             | boolean | Map `true` to `html=1`.                                                                                            |
| `monospace`        | boolean | Map `true` to `monospace=1`; reject if `html=true`.                                                                |
| `metadata`         | object  | Non-secret logging context.                                                                                        |
| `dedupeKey`        | string  | Optional idempotency key for retry-safe calls.                                                                     |
| `retry`            | integer | Emergency only (`priority=2`).                                                                                     |
| `expire`           | integer | Emergency only (`priority=2`).                                                                                     |
| `callback`         | string  | Emergency callback URL if needed later.                                                                            |
| `applicationToken` | string  | Optional Pushover app token to override SSM `PushoverToken` value. If omitted or empty, defaults to SSM parameter. |

### Validation rules

- `source` and `eventType` must be allow-listed by env vars.
- `message` length: `1..1024`.
- `title` length: `1..250` if provided.
- `url` max length: `512` if provided.
- `urlTitle` max length: `100` if provided.
- `applicationToken` if provided: max length 100, alphanumeric + common symbols only, no spaces or control chars.
- Reject control characters in all string fields.
- Reject `html=true` and `monospace=true` together.
- If `priority=2`, require `retry` and `expire`.
- `metadata` must not include credentials, tokens, headers, or secrets.
- If `applicationToken` is provided and non-empty, use it; otherwise fall back to SSM `PushoverToken` parameter.

## Request and Response Examples

### GitHub workflow completion request

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
    "runId": "123456789",
    "environment": "prod"
  },
  "dedupeKey": "gha-123456789-workflow.completed"
}
```

### Success response

```json
{
  "accepted": true,
  "provider": "pushover",
  "providerRequestId": "647d2300-702c-4b38-8b2f-d56326ae460b",
  "providerReceipt": null,
  "requestId": "aws-request-id"
}
```

### Error response

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

## Lambda Handler Design

Handler steps:

1. Parse REST API proxy event.
2. Validate API key context from API Gateway usage plan enforcement.
3. Optionally validate request signature header if enabled.
4. Validate payload and apply defaults.
5. Determine Pushover app token:
   - If `applicationToken` in request is non-empty, use it.
   - Otherwise, read `PushoverToken` from SSM.
6. Resolve `PushoverUser` from SSM.
7. Build `application/x-www-form-urlencoded` payload for Pushover.
8. Send request with low timeout (3-5 seconds).
9. Retry transient failures (`429`, `5xx`, network timeout) with bounded backoff.
10. Return normalized response and structured logs.

## Security Model

Mandatory controls:

- No anonymous calls.
- API key required by method.
- Very low usage plan limits.
- Strict payload schema and allow-lists.
- Lambda role limited to the two SSM parameter ARNs.
- Do not store provider secrets in environment variables or code.
- Caller-provided `applicationToken` is accepted as convenience for multi-tenant or multi-token scenarios; validate strictly and log token usage for audit.

Strongly recommended additional control:

- Add request signature validation in Lambda (shared secret in GitHub environment secret).

IAM scope recommendation for SSM read:

- `ssm:GetParameter` on SSM parameters:
  - `PushoverToken`
  - `PushoverUser`

## Reusability Strategy

- Keep `send-notification` as a central service so other workflows call one endpoint.
- This centralizes provider integration, policy checks, and observability.
- Lambda layer is optional later for shared helper code, but provider calls should remain centralized in this service for governance.

## Terraform Impact (REST API version)

Create `terraform/modules/send_notification` with REST API resources:

- `aws_api_gateway_rest_api`
- Root API resource (`/`) + custom-domain base path mapping (`send-notification`)
- `aws_api_gateway_method` (`POST`, `api_key_required=true`)
- `aws_api_gateway_integration` (Lambda proxy)
- `aws_api_gateway_deployment`
- `aws_api_gateway_stage`
- `aws_api_gateway_api_key` (automation key for GitHub Actions + future automation)
- `aws_api_gateway_api_key` (website key for zhenwei.dev direct calls)
- `aws_api_gateway_usage_plan` (automation plan: 400/month)
- `aws_api_gateway_usage_plan` (website plan: 100/month)
- `aws_api_gateway_usage_plan_key` (associate automation key to automation plan)
- `aws_api_gateway_usage_plan_key` (associate website key to website plan)
- Lambda + IAM + CloudWatch resources
- Optional WAF association for extra abuse controls

## Operational Notes

**API Keys and Usage Plans:**

- Automation key (400/month): Store in GitHub Environment Secrets for workflow calls.
- Website key (100/month): Store in zhenwei.dev frontend environment secrets for future direct calls.
- Rotate keys periodically and on suspicion of exposure.
- Use separate keys per caller group for independent tracking and selective revocation.

**Monitoring and Alarms:**

- Alarm on usage spikes, 4xx/5xx spikes, and Lambda errors.
- Track per-key quota consumption to monitor usage patterns.

## Rollout Plan

1. Implement `services/send-notification` Lambda skeleton.
2. Implement request validation and Pushover adapter.
3. Implement REST API + two usage plans + API keys Terraform module.
4. Set usage plan limits:
   - Automation plan: rate 1, burst 1, monthly quota 400
   - Website plan: rate 1, burst 1, monthly quota 100
5. Add unit tests and integration test in `dev`.
6. Add GitHub workflow step that calls `https://api.zhenwei.dev/send-notification` with automation `x-api-key`.
7. Document website API key location for future frontend integration.
8. Optionally add Lambda signature verification as phase 2 hardening.
