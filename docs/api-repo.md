# API Repository Initial Plan

## Summary

Yes, these three APIs are all feasible and a good next step for building a reusable API platform repo.

Proposed new repository name: zhenwei-dev-api

Primary goals:
- Separate application code from infrastructure code
- Make Lambda development/test workflows production-like
- Reuse common Terraform modules and CI/CD workflows
- Support future APIs without repo redesign

## Recommended Repository Structure

```text
zhenwei-dev-api/
  terraform/
    modules/
      lambda_service/
      http_api/
      notification_channel/
    envs/
      shared/
        main.tf
        variables.tf
        terraform.tfvars
      dev/
        main.tf
        variables.tf
        terraform.tfvars
      prod/
        main.tf
        variables.tf
        terraform.tfvars
  services/
    get-presigned-url/
      src/
        handler.py
      tests/
      requirements.txt
    send-notification/
      src/
        handler.py
      tests/
      requirements.txt
    update-invalidation-status/
      src/
        handler.py
      tests/
      requirements.txt
  shared/
    python/
      utils/
        aws_clients.py
        response.py
  .github/
    workflows/
      ci.yml
      deploy-dev.yml
      deploy-prod.yml
  README.md
```

Design principle:
- services/: Lambda code and tests
- terraform/: Terraform only (no business logic code)
- CI builds artifacts first, then Terraform deploys those artifacts

## API 1: get-presigned-url

Purpose:
- Return short-lived S3 presigned URL when request passes policy checks

Input (example JSON):
```json
{
  "objectKey": "private-downloads/resume/zhenwei-seo-cv.pdf",
  "versionId": "3HL4kqtJlcpXroDTDmJ+rmSpXd3dIbrH",
  "expiresInSeconds": 300,
  "contentDispositionFileName": "zhenwei-seo-cv.pdf"
}
```

Response (success):
```json
{
  "url": "https://...",
  "objectKey": "private-downloads/resume/zhenwei-seo-cv.pdf",
  "versionId": "3HL4kqtJlcpXroDTDmJ+rmSpXd3dIbrH",
  "expiresIn": 300,
  "fileName": "zhenwei-seo-cv.pdf"
}
```

Policy checks recommended:
- Configure bucket name by environment; do not accept arbitrary bucket names from callers
- Allow-list object key prefixes or exact keys
- Support optional S3 object `versionId`, defaulting to latest version when omitted
- Enforce max TTL (for example <= 900 seconds)
- Optional origin/API key/JWT checks
- Rate limit at API Gateway

Security notes:
- Do not allow arbitrary bucket names from callers unless intentionally designing as an internal utility API.
- Keep the bucket configured by environment.
- Allow caller-provided object keys only when they match exact-key or prefix allow-lists.
- Keep prefix allow-lists narrow so the reusable endpoint cannot sign unrelated private objects.

## API 2: send-notification

Purpose:
- Send operational notifications to your device through Pushover

Input (example JSON):
```json
{
  "title": "Workflow Complete",
  "message": "deploy-prod succeeded for commit abc123",
  "priority": 0,
  "source": "github-actions"
}
```

Response:
```json
{
  "accepted": true,
  "provider": "pushover",
  "requestId": "..."
}
```

Implementation notes:
- Store Pushover app token and user key in AWS Secrets Manager or SSM Parameter Store (encrypted)
- Lambda reads secret at runtime (with caching)
- Add retry with backoff for transient provider failures

GitHub integration:
- Future workflows can call this API at final step to notify success/failure

## API 3: update-invalidation-status

Purpose:
- Track CloudFront invalidation status and notify when completed

Your proposed behavior:
- Input distribution ID + invalidation ID
- Poll every 30s for up to 3 minutes
- On completion, call send-notification

This is feasible.

Input (example JSON):
```json
{
  "distributionId": "E123456789",
  "invalidationId": "I123456789",
  "notifyOnComplete": true,
  "timeoutSeconds": 180,
  "pollIntervalSeconds": 30
}
```

Response options:
- synchronous mode: returns final status if completed before timeout
- async mode: returns accepted=true and continues tracking in background

Recommended implementation approach:
- Phase 1 (simple): single Lambda with bounded polling loop
- Phase 2 (better): Step Functions (Wait + Check loop) for cleaner orchestration and long-running tracking

Why Phase 2 is better:
- Avoids long Lambda runtime for wait periods
- Cleaner retries and observability
- Easier future extensions (multi-step workflows)

## API Gateway Access Control Options

You can combine multiple controls:
- CORS allow-list
- Throttling (rate + burst)
- WAF rate-based rules
- WAF IP allow/deny list
- WAF Geo restriction (for example Singapore only)
- JWT authorizer (Cognito/OIDC)
- Lambda authorizer (custom logic)
- API keys + usage plans (if needed)

Singapore-only access:
- Feasible via WAF Geo match on SG
- Caveat: Geo-IP is approximate; use with operational fallback process

Recommended baseline:
- Public API + strict throttling + CloudWatch alarms + logging
- Add SG geofence only if you explicitly want regional lock-down

## Terraform Scope for Initial Version

Core resources likely needed:
- API Gateway HTTP API, routes, integrations, stages
- Lambda functions and permissions
- IAM roles and least-privilege policies
- CloudWatch log groups and alarms
- Optional WAF association (if throttling and alarms are not sufficient)
- Route53 records for api-dev.zhenwei.dev and api.zhenwei.dev
- ACM certificates (regional for API Gateway custom domain)

State strategy:
- Separate state per stack
- terraform/envs/shared, terraform/envs/dev, and terraform/envs/prod each have isolated backend keys
- Shared stack owns global resources, env stacks consume shared outputs via remote state

## CI/CD Pipeline Plan

Yes, this structure supports clean CI/CD.

Workflows in .github/workflows (required by GitHub):

1. ci.yml (pull requests)
- Lint and test changed services
- Terraform fmt + validate
- Optional terraform plan for changed environment

2. deploy-dev.yml (merge to dev)
- Package changed Lambdas
- Upload artifacts to S3 artifact bucket with commit SHA path
- Terraform apply for dev using artifact references
- Smoke tests on dev endpoints
- Optional send-notification on completion

3. deploy-prod.yml (manual approval)
- Same pattern as dev but prod env
- Protected GitHub Environment approvals
- Notifications on success/failure

Artifact strategy:
- Build zip per service
- Store object key by commit SHA
- Terraform consumes bucket + key + hash for deterministic deployment

## Development and Testing Process

Suggested per-Lambda workflow:
- Write handler and unit tests
- Local test with sample API Gateway event payloads
- Mock AWS SDK calls for unit tests
- Run integration test in dev after deployment
- Promote same artifact version to prod

Do not package Lambda code under Terraform directories.

## Phased Delivery

Phase 1:
- Repo scaffold
- get-presigned-url API (dev only)
- Basic CI and deploy-dev workflow

Phase 2:
- send-notification API
- Wire notifications from deploy workflows

Phase 3:
- update-invalidation-status API (simple bounded polling)

Phase 4:
- Migrate invalidation tracker to Step Functions orchestration
- Add stronger edge filtering (for example WAF) and dashboards if needed

## Direct Answer to Your Question

Does this structure make sense?
- Yes, it is a strong and realistic structure.

Can these three APIs be done?
- Yes. All are implementable with your current AWS stack direction.

Can GitHub workflows exist in subdirectories?
- Workflow definition files must live in .github/workflows.
- You can still target subdirectories with path filters and reusable scripts/actions.
