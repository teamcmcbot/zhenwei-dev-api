# get-presigned-url Implementation Plan

## Purpose

`get-presigned-url` returns a short-lived S3 presigned URL for approved private files. The first consumer is the `zhenwei-dev-site` React app, which will call this API to download the resume PDF from the private S3 bucket provisioned by the site infrastructure. The service should stay reusable for future private files stored in the same approved bucket.

This endpoint must not become an unrestricted S3 signing utility. Public callers can provide an `objectKey`, but the Lambda must validate that key against environment-specific allow-lists or allowed prefixes before generating a URL.

## Public Contract

Recommended route:

```text
POST /get-presigned-url
```

Use `POST` because the request includes object details and optional signing options in the JSON body.

### Request

```json
{
  "objectKey": "resume/zhenwei-seo-cv.pdf",
  "versionId": "3HL4kqtJlcpXroDTDmJ+rmSpXd3dIbrH",
  "expiresInSeconds": 300,
  "contentDispositionFileName": "zhenwei-seo-cv.pdf"
}
```

Required fields:

| Name | Type | Description |
| --- | --- | --- |
| `objectKey` | string | S3 object key in the approved private bucket. Must match an allow-listed exact key or prefix. |

Optional fields:

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `versionId` | string | latest version | S3 object version ID. If omitted, S3 returns the latest version. |
| `expiresInSeconds` | integer | `300` | Requested URL TTL. The service must cap this to the configured maximum. |
| `contentDispositionFileName` | string | object file name | Friendly download filename used in `ResponseContentDisposition`. |

Do not accept arbitrary bucket names from public callers. The bucket should be configured by environment, for example `zhenwei-private-bucket`, while the caller provides only the object key and optional version ID.

Example CV request:

```json
{
  "objectKey": "resume/zhenwei-seo-cv.pdf",
  "expiresInSeconds": 300,
  "contentDispositionFileName": "zhenwei-seo-cv.pdf"
}
```

Example request for a specific object version:

```json
{
  "objectKey": "resume/zhenwei-seo-cv.pdf",
  "versionId": "3HL4kqtJlcpXroDTDmJ+rmSpXd3dIbrH"
}
```

### Response

Successful response:

```json
{
  "url": "https://zhenwei-private-bucket.s3...",
  "bucketName": "zhenwei-private-bucket",
  "objectKey": "resume/zhenwei-seo-cv.pdf",
  "versionId": "3HL4kqtJlcpXroDTDmJ+rmSpXd3dIbrH",
  "fileName": "zhenwei-seo-cv.pdf",
  "expiresIn": 300
}
```

If the caller omits `versionId`, the response should either omit `versionId` or return `null`, depending on the final response schema. The generated URL should point to the latest version.

Error response:

```json
{
  "error": {
    "code": "forbidden",
    "message": "The requested file is not available."
  },
  "requestId": "..."
}
```

Use generic error messages for public callers. Do not reveal bucket names, object keys, IAM details, or policy decisions in client-facing errors.

## Lambda Logic

Recommended runtime: the latest Python runtime supported by AWS Lambda at implementation time. Use Python 3.12 or 3.13 if Python 3.14 is not yet available in Lambda for the target AWS region.

Handler steps:

1. Read request context and correlation ID.
2. Validate HTTP method and route.
3. Parse JSON request body.
4. Validate `objectKey`, optional `versionId`, optional `expiresInSeconds`, and optional `contentDispositionFileName`.
5. Resolve the approved bucket from environment configuration.
6. Check `objectKey` against exact-key and prefix allow-lists.
7. Set expiry to the requested value capped by the configured maximum.
8. Build S3 signing parameters with `Bucket`, `Key`, optional `VersionId`, and optional `ResponseContentDisposition`.
9. Generate the presigned URL with `boto3.client("s3").generate_presigned_url`.
10. Return `200` JSON with `url`, `bucketName`, `objectKey`, optional `versionId`, `fileName`, and `expiresIn`.
11. Log a structured success event without logging the full presigned URL.

Suggested environment variables:

| Name | Example | Description |
| --- | --- | --- |
| `APP_ENV` | `dev` | Environment name. |
| `LOG_LEVEL` | `INFO` | Runtime log level. |
| `PRIVATE_BUCKET_NAME` | `zhenwei-private-bucket` | Approved private bucket name. |
| `ALLOWED_OBJECT_KEYS` | `resume/zhenwei-seo-cv.pdf` | Comma-separated exact object keys allowed for signing. |
| `ALLOWED_OBJECT_PREFIXES` | `public-downloads/,resume/` | Comma-separated prefixes allowed for signing. Keep this narrow. |
| `DEFAULT_PRESIGNED_URL_EXPIRES_SECONDS` | `300` | Default URL expiry. |
| `MAX_PRESIGNED_URL_EXPIRES_SECONDS` | `900` | Hard maximum URL expiry. |
| `ALLOWED_ORIGINS` | `https://zhenwei.dev,https://www.zhenwei.dev` | CORS allow-list. |

Validation rules:

- `objectKey` is required and must be a relative S3 key, not a URL.
- `objectKey` must not contain traversal-like segments such as `../`.
- `objectKey` must match `ALLOWED_OBJECT_KEYS` or start with an allowed prefix from `ALLOWED_OBJECT_PREFIXES`.
- `versionId`, when provided, must be treated as an opaque string and passed only as S3 `VersionId` after length and character sanity checks.
- Expiry must be greater than 0 and less than or equal to the configured maximum, such as 900 seconds.
- Bucket must come from service configuration, not caller input.
- `contentDispositionFileName` must be sanitized so it cannot inject response headers.
- `Origin` must match the configured allow-list when present.
- `OPTIONS` requests should return CORS preflight responses without signing a URL.

## Terraform Configuration

Terraform should live under `infra/modules/` and `infra/envs/<env>/`.

Terraform should own the Lambda function, API Gateway wiring, IAM, logs, and the SSM parameter resources used to track deployable Lambda artifacts. The package/upload step should update the SSM parameter value; Terraform should read that value during plan/apply.

Required resources:

| Resource | Purpose |
| --- | --- |
| `aws_s3_bucket` or existing artifact bucket data source | Stores immutable Lambda zip artifacts. |
| `aws_ssm_parameter` | Defines the per-environment artifact metadata parameter for this service. Ignore value drift because packaging automation updates it. |
| `data.aws_ssm_parameter` | Reads the current artifact metadata used by `aws_lambda_function`. |
| `aws_lambda_function` | Runs the handler. |
| `aws_iam_role` | Lambda execution role. |
| `aws_iam_role_policy` | Grants least-privilege S3 read access to the approved object only. |
| `aws_cloudwatch_log_group` | Stores Lambda logs with explicit retention. |
| `aws_cloudwatch_metric_alarm` | Alerts on API and Lambda error or throttle spikes. |
| `aws_apigatewayv2_api` | HTTP API, likely shared across services per environment. |
| `aws_apigatewayv2_integration` | Lambda proxy integration. |
| `aws_apigatewayv2_route` | `POST /get-presigned-url` and `OPTIONS /get-presigned-url`. |
| `aws_lambda_permission` | Allows API Gateway to invoke this Lambda. |
| `aws_apigatewayv2_stage` | Environment stage with access logs enabled. |
| `aws_wafv2_web_acl` | Optional for additional edge filtering if needed later. |
| `aws_apigatewayv2_domain_name` | Custom API domain. |
| `aws_route53_record` | DNS alias for the API domain. |

### Artifact Metadata Parameter

Use one SSM parameter per service per environment:

```text
/zhenwei-dev-api/dev/get-presigned-url/artifact
/zhenwei-dev-api/prod/get-presigned-url/artifact
```

Recommended parameter type: `String`. The artifact bucket, key, hash, and build metadata are not secrets.

Recommended parameter value:

```json
{
  "bucket": "zhenwei-dev-api-artifacts",
  "key": "lambdas/get-presigned-url/abc123.zip",
  "source_code_hash": "base64sha256...",
  "build_id": "abc123",
  "commit_sha": "abc123def456",
  "created_at": "2026-05-12T10:00:00Z"
}
```

Terraform should create the parameter name but ignore changes to the value:

```hcl
resource "aws_ssm_parameter" "get_presigned_url_artifact" {
  name = "/zhenwei-dev-api/${var.environment}/get-presigned-url/artifact"
  type = "String"

  value = jsonencode({
    bucket           = "placeholder"
    key              = "placeholder"
    source_code_hash = "placeholder"
    build_id         = "placeholder"
    commit_sha       = "placeholder"
    created_at       = "placeholder"
  })

  lifecycle {
    ignore_changes = [value]
  }
}

data "aws_ssm_parameter" "get_presigned_url_artifact" {
  name       = aws_ssm_parameter.get_presigned_url_artifact.name
  depends_on = [aws_ssm_parameter.get_presigned_url_artifact]
}

locals {
  get_presigned_url_artifact = jsondecode(data.aws_ssm_parameter.get_presigned_url_artifact.value)
}
```

The Lambda should then use the decoded artifact metadata:

```hcl
resource "aws_lambda_function" "get_presigned_url" {
  function_name = "zhenwei-dev-api-${var.environment}-get-presigned-url"
  role          = aws_iam_role.get_presigned_url.arn
  runtime       = var.lambda_runtime
  handler       = "handler.lambda_handler"

  s3_bucket        = local.get_presigned_url_artifact.bucket
  s3_key           = local.get_presigned_url_artifact.key
  source_code_hash = local.get_presigned_url_artifact.source_code_hash
}
```

Use immutable artifact keys. Do not upload new builds to a mutable key such as `latest.zip`.

IAM policy scope:

```json
{
  "Action": "s3:GetObject",
  "Effect": "Allow",
  "Resource": [
    "arn:aws:s3:::zhenwei-private-bucket/resume/*",
    "arn:aws:s3:::zhenwei-private-bucket/public-downloads/*"
  ]
}
```

If only exact files should be signed, prefer exact object ARNs instead of prefixes. If prefixes are needed for reusability, keep them narrow and mirror the same prefixes in Lambda validation.

Suggested module inputs:

| Name | Description |
| --- | --- |
| `environment` | `dev` or `prod`. |
| `api_id` | Shared HTTP API ID. |
| `artifact_parameter_name` | SSM parameter name containing the current deployable artifact metadata. |
| `lambda_runtime` | AWS Lambda Python runtime to use. |
| `private_bucket_name` | Approved private bucket name. |
| `allowed_object_keys` | Exact object keys allowed for signing. |
| `allowed_object_prefixes` | Object key prefixes allowed for signing. |
| `default_expires_seconds` | Default URL TTL. |
| `max_expires_seconds` | Maximum URL TTL. |
| `allowed_origins` | CORS origins for the site. |
| `log_retention_days` | CloudWatch log retention. |

## Deployment Model

The production-ready deployment model should use immutable S3 artifacts and SSM artifact pointers.

### Local-First Sequence

This repository can start with local Terraform applies, similar to `zhenwei-dev-site`:

1. Run service tests locally.
2. Package `services/get-presigned-url/src` plus required `shared/python` code into a zip.
3. Upload the zip to the artifact S3 bucket with an immutable key, for example `lambdas/get-presigned-url/<build-id>.zip`.
4. Calculate the base64 SHA-256 hash of the zip.
5. Update `/zhenwei-dev-api/dev/get-presigned-url/artifact` in SSM with bucket, key, hash, and build metadata.
6. Run `terraform plan` from `infra/envs/dev`.
7. Run `terraform apply` from `infra/envs/dev`.
8. Terraform reads the SSM parameter and updates `aws_lambda_function` to the referenced artifact.
9. Run a smoke test against `https://api-dev.zhenwei.dev/get-presigned-url`.

### GitHub Actions Sequence

When CI/CD is added, GitHub Actions should perform the same sequence:

1. Detect whether `services/get-presigned-url/**` or relevant `shared/python/**` files changed.
2. Run tests.
3. Package and upload a new immutable zip only when code changed.
4. Update the service artifact SSM parameter only when a new zip is produced.
5. Run Terraform plan/apply when Lambda code or Terraform configuration changed.
6. Terraform reads SSM rather than receiving artifact bucket/key/hash directly through command-line variables.

If only Terraform changes, skip packaging and use the artifact metadata already stored in SSM.

For prod, do not blindly deploy the latest dev artifact. Promote an explicitly approved build by copying the tested artifact metadata into `/zhenwei-dev-api/prod/get-presigned-url/artifact`, then run prod Terraform apply with protected approval.

### GitHub OIDC Role Permissions

The GitHub Actions role, once introduced, needs artifact and parameter permissions for this service.

Packaging/upload permissions:

```json
{
  "Effect": "Allow",
  "Action": [
    "s3:PutObject",
    "s3:GetObject"
  ],
  "Resource": "arn:aws:s3:::zhenwei-dev-api-artifacts/lambdas/get-presigned-url/*"
}
```

SSM artifact pointer permissions:

```json
{
  "Effect": "Allow",
  "Action": [
    "ssm:GetParameter",
    "ssm:PutParameter"
  ],
  "Resource": "arn:aws:ssm:<region>:<account-id>:parameter/zhenwei-dev-api/dev/get-presigned-url/artifact"
}
```

Terraform plan/apply permissions also need `ssm:GetParameter` for the artifact parameter because Terraform reads the current artifact metadata during plan and apply.

For prod, scope the role separately to the prod parameter and require a protected GitHub Environment approval before updating it.

## Access Control

This is the only initial endpoint expected to be callable from a browser, so it needs layered public-route protections.

Controls:

- Do not expose raw S3 bucket selection to callers.
- Allow caller-provided `objectKey` only after exact-key or prefix validation.
- Support caller-provided `versionId` only as an optional S3 object version selector for approved keys.
- Use CORS allow-list for `https://zhenwei.dev`, `https://www.zhenwei.dev`, and the dev site origin.
- Use API Gateway route throttling.
- Add CloudWatch alarms for API Gateway 4xx/5xx/throttle spikes and Lambda errors.
- Keep presigned URL TTL short.
- Scope Lambda IAM to the exact object or approved prefix.
- Return generic errors for denied or invalid requests.

CORS is not an authentication mechanism. It helps browser behavior, but API Gateway throttling, alarms, and strict backend validation are what prevent misuse.

## Logging And Observability

Lambda structured log fields:

| Field | Description |
| --- | --- |
| `service` | `get-presigned-url`. |
| `environment` | `dev` or `prod`. |
| `requestId` | API Gateway or Lambda request ID. |
| `origin` | Request origin if present. |
| `route` | Matched route. |
| `objectKey` | Requested object key, or a hashed/redacted form if paths become sensitive. |
| `versionIdProvided` | Whether the caller requested a specific object version. |
| `outcome` | `success`, `validation_error`, `forbidden`, `s3_error`, `internal_error`. |
| `statusCode` | HTTP response status. |
| `durationMs` | Handler duration. |

Do not log:

- Full presigned URLs.
- AWS credentials.
- Secret values.
- Excessive request headers.

Recommended metrics and alarms:

- Lambda errors greater than 0 for a short window.
- API Gateway 4xx spike, which may indicate scanning or misuse.
- API Gateway 5xx greater than 0.
- API Gateway throttled requests spike.
- Lambda duration approaching timeout.

## Tests

Unit tests:

- Returns `200` and expected JSON shape for valid request.
- Rejects unsupported methods.
- Handles CORS preflight.
- Rejects caller-supplied bucket names.
- Rejects object keys outside exact-key and prefix allow-lists.
- Allows an optional version ID for an approved object key.
- Enforces max TTL.
- Sanitizes `contentDispositionFileName`.
- Converts S3 signing failures to safe error responses.

Integration tests in dev:

- Call `POST /get-presigned-url` from an allowed origin and verify JSON shape.
- Request a known object key without `versionId` and confirm the URL signs the latest version.
- Request a known object key with `versionId` and confirm the URL includes version-specific access.
- Confirm the returned URL expires according to configured TTL.
- Confirm disallowed origins do not receive permissive CORS headers.

## Implementation Order

1. Confirm the approved private bucket name and initial allowed object keys or prefixes.
2. Create service skeleton under `services/get-presigned-url/`.
3. Implement handler with reusable `objectKey` validation, optional `versionId`, and tests.
4. Add shared response, validation, logging, and AWS client helpers if they are not already present.
5. Add local package script that builds an immutable Lambda zip from service code plus `shared/python`.
6. Add local upload script that uploads the zip to the artifact bucket and updates the dev SSM artifact parameter.
7. Add Terraform for the artifact SSM parameter, Lambda, IAM, route, logs, CORS config, and dev custom domain wiring.
8. Run local `terraform plan` and `terraform apply` for `infra/envs/dev`.
9. Add API Gateway rate limits and CloudWatch alarms for the public route.
10. Run dev smoke tests against `https://api-dev.zhenwei.dev/get-presigned-url`.
11. Integrate the CV download flow in `zhenwei-dev-site`.
12. Add GitHub Actions packaging and Terraform deployment after the local flow is proven.
13. Promote to prod with an explicitly approved artifact after dev smoke testing.

## Readiness And Open Decisions

The service design is ready to implement locally once these values are confirmed:

| Decision | Needed value |
| --- | --- |
| Private bucket name | Confirm whether `zhenwei-private-bucket` is the final bucket name for dev and prod. |
| Initial object allow-list | Confirm exact keys or prefixes, for example `resume/zhenwei-seo-cv.pdf` or `resume/`. |
| Artifact bucket | Confirm whether this repo creates a new artifact bucket or reuses an existing deployment artifact bucket. |
| Terraform backend | Confirm where `infra/envs/dev` and `infra/envs/prod` state will live. |
| Lambda runtime | Confirm the AWS-supported Python runtime to use in the target region. |
| API domain ownership | Confirm Route53 hosted zone and ACM certificate strategy for `api-dev.zhenwei.dev` and `api.zhenwei.dev`. |
| CORS origins | Confirm dev and prod frontend origins. |

No additional API behavior clarification is required for the first implementation. The main remaining choices are deployment/environment values, not handler behavior.