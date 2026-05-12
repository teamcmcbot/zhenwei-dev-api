# zhenwei-dev-api Agent Context

## Repository Purpose

This repository, `github.com/teamcmcbot/zhenwei-dev-api`, is the API extension layer for the portfolio site repository:

- Site repo: `github.com/teamcmcbot/zhenwei-dev-site`
- API repo: `github.com/teamcmcbot/zhenwei-dev-api`

The site repo hosts the React/Vite static portfolio and Terraform-managed static hosting infrastructure.

This API repo will host reusable AWS serverless APIs that support the portfolio and future automation workflows. It should demonstrate production-like DevOps practices: API Gateway, Lambda, IAM least privilege, Terraform, CI/CD, testing, artifact packaging, environment separation, observability, and secure operational integrations.

## High-Level Goals

The API repo should:

- Keep Lambda source code separate from Terraform infrastructure code.
- Treat Lambda services as independently testable application units.
- Package Lambda artifacts in CI/CD before Terraform deployment.
- Use Terraform to provision infrastructure and deploy immutable artifacts.
- Support separate `dev` and `prod` environments.
- Provide reusable modules for future APIs.
- Integrate with `zhenwei-dev-site` where needed, especially for cv download and deployment notifications.

## Initial APIs

### 1. get-presigned-url

Purpose:

Generate short-lived S3 presigned URLs when a request passes policy checks.

Initial use case:

The portfolio site’s “Download CV” flow should no longer serve the PDF directly from the frontend repo. Instead:

1. Browser calls `POST /get-presigned-url` through API Gateway with an approved `objectKey` and optional `versionId`.
2. Lambda validates the request.
3. Lambda generates a short-lived S3 presigned URL.
4. Lambda returns `200` JSON with `{ url, fileName, expiresIn }`.
5. Browser starts download using the returned URL.
6. CV PDF lives in a private S3 bucket and is not committed to git.

Important design notes:

- Prefer `200` JSON over `302` redirect for better frontend control and error handling.
- Do not allow arbitrary bucket access unless explicitly building an internal utility API.
- Accept caller-provided object keys only when they match allow-listed exact keys or prefixes.
- Support optional S3 `versionId`; default to the latest object version when omitted.
- Enforce max TTL, for example 300-900 seconds.
- The Lambda IAM role should only allow `s3:GetObject` for approved bucket/key resources.

### 2. send-notification

Purpose:

Send operational alerts to the owner’s device using the Pushover API.

Initial use cases:

- Notify when GitHub Actions deployment succeeds or fails.
- Notify when CloudFront invalidation completes.
- Notify when future automation workflows finish.

Important design notes:

- Pushover app token and user key should be stored in AWS Secrets Manager or encrypted SSM Parameter Store.
- Lambda should read secrets securely at runtime.
- API should validate incoming requests.
- Consider restricting caller identity using API key, Lambda authorizer, JWT authorizer, or GitHub OIDC-driven workflow authentication pattern.

### 3. update-invalidation-status

Purpose:

Check CloudFront invalidation status and notify when invalidation is complete.

Initial behavior:

- Accept `distributionId` and `invalidationId`.
- Poll CloudFront invalidation status every 30 seconds for up to 3 minutes.
- When completed, call or reuse notification logic to send a Pushover alert.

Recommended implementation phases:

- Phase 1: Simple Lambda with bounded polling loop.
- Phase 2: Step Functions orchestration using Wait + Check loop.

Step Functions is preferred long-term because it avoids paying for Lambda idle wait time and gives clearer orchestration, retries, and observability.

## Recommended Repository Structure

```text
zhenwei-dev-api/
  terraform/
    modules/
      lambda_service/
      http_api/
      notification_channel/
    envs/
      dev/
        main.tf
        variables.tf
        outputs.tf
        terraform.tfvars.example
      prod/
        main.tf
        variables.tf
        outputs.tf
        terraform.tfvars.example

  services/
    get-presigned-url/
      src/
        handler.py
      tests/
      requirements.txt
      README.md

    send-notification/
      src/
        handler.py
      tests/
      requirements.txt
      README.md

    update-invalidation-status/
      src/
        handler.py
      tests/
      requirements.txt
      README.md

  shared/
    python/
      utils/
        response.py
        validation.py
        logging.py
        aws_clients.py

  scripts/
    package_lambda.sh
    run_tests.sh

  .github/
    workflows/
      ci.yml
      deploy-dev.yml
      deploy-prod.yml

  README.md
  AGENTS.md
```

## Infrastructure Direction

Terraform should manage:

- API Gateway HTTP APIs
- Lambda functions
- Lambda execution roles
- IAM least-privilege policies
- Lambda permissions for API Gateway invocation
- CloudWatch log groups
- Route53 records
- API Gateway custom domains
- ACM certificates for API custom domains
- Optional WAF association
- Optional Step Functions for long-running workflows
- Optional artifact bucket for Lambda zip packages

Environment model:

- `dev` environment:
  - API domain: `api-dev.zhenwei.dev`
  - Auto deploy from `dev` branch or workflow dispatch
- `prod` environment:
  - API domain: `api.zhenwei.dev`
  - Manual deploy from `main`
  - Protected GitHub Environment approval

State model:

- Use separate Terraform state per stack.
- Example state keys:
  - `zhenwei-dev-api/shared/terraform.tfstate`
  - `zhenwei-dev-api/dev/terraform.tfstate`
  - `zhenwei-dev-api/prod/terraform.tfstate`

Ownership model:

- `terraform/envs/shared` owns shared resources (artifact bucket and optional shared deploy role).
- `terraform/envs/dev` and `terraform/envs/prod` own environment resources and consume shared outputs via remote state.
- Service artifact SSM parameters remain environment-specific.

## Lambda Development Model

Do not place Lambda source code inside Terraform directories.

Production-like flow:

1. Code Lambda under `services/<service-name>/src`.
2. Write unit tests under `services/<service-name>/tests`.
3. Run lint/tests in CI.
4. Package Lambda zip artifact in CI.
5. Upload artifact to an S3 artifact bucket using commit SHA/versioned path.
6. Terraform deploys Lambda using artifact bucket/key/hash.
7. Run smoke tests against deployed dev API.
8. Promote the same artifact to prod where possible.

Terraform should deploy artifacts, not build them.

## GitHub Actions Notes

GitHub workflow files must live under:

```text
.github/workflows/
```

Workflows cannot be placed inside service subdirectories as active workflow definitions.

However, workflows can target subdirectories using:

- `paths` filters
- changed-file detection
- reusable scripts
- composite actions under `.github/actions`

Recommended workflows:

### ci.yml

Runs on pull requests.

Responsibilities:

- Detect changed services.
- Run Python tests for changed services.
- Run formatting/linting.
- Run Terraform fmt/validate.
- Optionally run Terraform plan for affected env.

### deploy-dev.yml

Runs on merge/push to `dev` or manual dispatch.

Responsibilities:

- Package changed Lambda services.
- Upload artifacts to S3 artifact bucket.
- Run Terraform apply for `terraform/envs/dev`.
- Run smoke tests.
- Optionally call `send-notification`.

### deploy-prod.yml

Runs manually from `main`.

Responsibilities:

- Use protected GitHub Environment approval.
- Deploy prod using artifact references.
- Run smoke tests.
- Send success/failure notification.

## Access Control Options

API Gateway and edge protection can include:

- CORS allow-list
- API Gateway throttling
- API Gateway access logs
- CloudWatch alarms for 4xx/5xx/throttle/error spikes
- WAF rate-based rules
- WAF IP allow/deny lists
- WAF Geo match, including Singapore-only restriction if desired
- JWT authorizer
- Lambda authorizer
- API keys where suitable
- IAM auth for machine-to-machine/internal calls

For public portfolio use, recommended baseline:

- Throttling
- CloudWatch alarms
- Structured logs
- Strict IAM roles
- No broad arbitrary S3 object access

Singapore-only restriction is feasible with WAF Geo match, but Geo-IP is approximate and can block legitimate users using VPNs or mobile networks.

## Relationship With zhenwei-dev-site

The site repo should remain frontend/static-hosting focused.

The API repo should expose environment-specific API URLs:

- `https://api-dev.zhenwei.dev`
- `https://api.zhenwei.dev`

The site can consume these through Vite environment variables:

```bash
VITE_APP_ENV=dev
VITE_CV_MODE=api
VITE_CV_API_URL=https://api-dev.zhenwei.dev/get-presigned-url
```

For local site development, the site can use a static fallback:

```bash
VITE_APP_ENV=local
VITE_CV_MODE=local-static
```

Local fallback can use:

```text
/assets/resume/zhenwei-seo-cv.pdf
```

## Initial Implementation Priority

Recommended first milestone:

1. Scaffold repo structure.
2. Create `get-presigned-url` service.
3. Create basic Terraform for dev API Gateway + Lambda.
4. Add artifact packaging in CI.
5. Deploy dev endpoint.
6. Integrate `zhenwei-dev-site` cv download with dev API.
7. Add `send-notification`.
8. Add `update-invalidation-status`.

## Engineering Principles

When working in this repo:

- Keep changes small and environment-aware.
- Prefer least-privilege IAM.
- Do not hard-code secrets.
- Do not commit private cv PDFs or secret tokens.
- Use structured logs.
- Keep Terraform reusable through modules.
- Keep service logic testable without AWS where possible.
- Use AWS mocks/stubs for unit tests.
- Use deployed dev environment for integration tests.
- Avoid mixing application code into Terraform directories.
