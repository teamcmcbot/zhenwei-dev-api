# zhenwei-dev-api

`zhenwei-dev-api` is the AWS serverless API layer for `zhenwei.dev`.

The main website repository, `zhenwei-dev-site`, owns the React/Vite frontend and the static hosting infrastructure such as S3, CloudFront, Route53, and ACM. This repository owns API Gateway, Lambda services, API-specific IAM, observability, and CI/CD workflows for reusable backend capabilities that support the site and future automation workflows.

API endpoint targets:

- Dev: execute-api endpoint by default (custom domain optional: `https://api-dev.zhenwei.dev`)
- Prod: `https://api.zhenwei.dev`

## Goals

- Keep API application code separate from Terraform infrastructure code.
- Treat every Lambda service as an independently testable application unit.
- Package Lambda artifacts in CI before Terraform deployment.
- Deploy immutable Lambda artifacts through Terraform.
- Support separate `dev` and `prod` environments.
- Use least-privilege IAM for every service.
- Avoid committing private files, tokens, API keys, or secrets.
- Provide reusable modules and scripts for future APIs.

## Initial APIs

### `get-presigned-url`

Generates a short-lived S3 presigned URL for approved private files.

Initial use case: the portfolio site's CV download flow should call this API instead of serving the PDF directly from the frontend repository. The CV PDF remains in the private S3 bucket that is provisioned outside this repo, currently planned as `zhenwei-private-bucket`. The endpoint stays reusable for future private files by using an approved namespace such as `private-downloads/` rather than a resume-specific bucket path.

Expected flow:

1. Browser calls `POST /get-presigned-url` with an approved `objectKey` and optional `versionId`.
2. Lambda validates the request and policy rules.
3. Lambda generates a short-lived S3 presigned URL.
4. Lambda returns `200` JSON with the URL, file name, and expiry.
5. Browser starts the download using the returned URL.

Security model:

- Do not accept arbitrary bucket names from public callers.
- Accept caller-provided `objectKey` only when it matches exact-key or prefix allow-lists.
- Support optional `versionId` for S3 object versioning; omit it to sign the latest object version.
- Enforce a maximum TTL, for example 300 to 900 seconds.
- Scope the Lambda role to `s3:GetObject` only for approved object ARNs or narrow prefixes.
- Use strict CORS for the portfolio site origins.
- Add API Gateway throttling and CloudWatch alarms for abuse and error spikes.

### `send-notification`

Sends operational push notifications to the owner's device, likely through Pushover.

Initial use cases:

- Notify when GitHub Actions deployments succeed or fail.
- Notify when CloudFront invalidation completes.
- Notify when future automation workflows need owner attention.

Security model:

- This endpoint should not be publicly callable from browsers.
- Prefer machine-to-machine access from GitHub Actions using GitHub OIDC to assume an AWS IAM role, then invoke Lambda directly or call an IAM-protected API Gateway route.
- Store Pushover credentials in AWS Secrets Manager or encrypted SSM Parameter Store.
- Never store notification provider tokens in GitHub, Terraform variables, or Lambda environment variables as plaintext.
- Validate source, event type, message length, and allowed priority values.
- Apply low throttling limits, structured logging, and alarms for unexpected call volume.

### `update-invalidation-status`

Tracks a CloudFront invalidation until it completes, then sends a notification.

Initial behavior:

- Accept `distributionId` and `invalidationId`.
- Check CloudFront invalidation status every 30 seconds.
- Stop after a bounded timeout, currently planned as up to 5 minutes.
- Send a notification when the invalidation reaches `Completed`.

Implementation phases:

- Phase 1: Lambda with a bounded polling loop.
- Phase 2: Step Functions with Wait and Check states.

Step Functions is preferred long-term because it avoids paying for Lambda idle wait time and gives clearer retries, history, and observability.

Security model:

- This endpoint should be treated as an internal automation endpoint, not a public browser API.
- Prefer GitHub OIDC plus IAM authorization for workflow-triggered calls.
- Validate that the requested distribution ID is in an allow-list for this account and environment.
- Scope the Lambda role to `cloudfront:GetInvalidation` only for approved distributions where practical.
- Reuse the notification service internally rather than exposing notification details to callers.

## Access Control Strategy

Because this repository is public, endpoint safety must not depend on hiding route names, payload shapes, or implementation details. The design should assume public users can read the code and discover URLs. Protection should come from authentication, authorization, validation, throttling, and least privilege.

Recommended baseline:

| Endpoint | Caller | Recommended access control | Notes |
| --- | --- | --- | --- |
| `get-presigned-url` | Portfolio site browser | Public route with strict validation, CORS allow-list, API Gateway throttling, and CloudWatch alarms | Safe only if caller-provided `objectKey` values are constrained to approved exact keys or prefixes. |
| `send-notification` | GitHub Actions and internal services | Private machine-to-machine route using IAM auth through GitHub OIDC, or direct Lambda invoke by an assumed role | Do not rely on an API key alone for this endpoint. |
| `update-invalidation-status` | GitHub Actions deployment workflow | Private machine-to-machine route using IAM auth through GitHub OIDC, or direct Step Functions execution by an assumed role | Validate distribution IDs and cap runtime. |

Optional controls:

- WAF rate-based rules for public routes if baseline throttling is insufficient.
- WAF geo rules if a regional access restriction is intentionally desired.
- JWT or Lambda authorizer for future authenticated user-facing APIs.
- API keys only as a secondary control, not as the main protection for sensitive automation endpoints.

## Repository Layout

Planned structure:

```text
zhenwei-dev-api/
  terraform/
    modules/
      http_api/
      lambda_service/
      notification_channel/
      step_function/
    envs/
      shared/
        main.tf
        variables.tf
        outputs.tf
        terraform.tfvars.example
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
        aws_clients.py
        logging.py
        response.py
        validation.py

  scripts/
    package_lambda.sh
    run_tests.sh

  .github/
    workflows/
      ci.yml
      deploy-dev.yml
      deploy-prod.yml

  docs/
  README.md
  AGENTS.md
```

Layout principles:

- `services/` contains Lambda application code and tests.
- `shared/` contains reusable Python utilities shared by services.
- `terraform/` contains Terraform only.
- `terraform/modules/` contains reusable infrastructure modules.
- `terraform/envs/shared` owns shared resources consumed by env stacks.
- `terraform/envs/dev` and `terraform/envs/prod` contain environment-specific composition and variables.
- `.github/workflows/` contains active GitHub Actions workflow definitions. GitHub workflow files cannot be activated from service subdirectories.

## Terraform Model

Terraform should manage API infrastructure, not build Lambda packages.

Expected Terraform responsibilities:

- API Gateway HTTP APIs, routes, integrations, stages, and custom domains.
- Lambda functions and versions or aliases.
- Lambda execution roles and least-privilege policies.
- Lambda permissions for API Gateway invocation.
- CloudWatch log groups, metrics, and alarms.
- Route53 records for `api-dev.zhenwei.dev` and `api.zhenwei.dev`.
- Regional ACM certificates for API Gateway custom domains if needed.
- Optional WAF associations if needed later.
- Optional Step Functions for invalidation tracking.
- Optional artifact bucket for Lambda zip packages.

State should be separated by stack. Example backend keys:

- `zhenwei-dev-api/shared/terraform.tfstate`
- `zhenwei-dev-api/dev/terraform.tfstate`
- `zhenwei-dev-api/prod/terraform.tfstate`

Ownership model:

- `shared` owns shared resources such as artifact bucket and optional shared GitHub deploy role.
- `dev` and `prod` own environment resources and consume shared outputs via remote state.
- `dev` and `prod` each manage their own service artifact SSM parameter paths.

Environment-specific values should live in Terraform variables or external secret/config stores, not hard-coded in modules.

## Lambda Development Model

Each service should be developed and tested independently:

1. Write service code under `services/<service-name>/src`.
2. Write unit tests under `services/<service-name>/tests`.
3. Use local mocks or stubs for AWS SDK calls.
4. Run formatting, linting, and tests in CI.
5. Package the service into a zip artifact in CI.
6. Upload the artifact to an S3 artifact bucket using a commit SHA or versioned path.
7. Update the service SSM artifact parameter with artifact metadata (`bucket`, `key`, `source_code_hash`, build metadata).
8. Let Terraform read the SSM artifact parameter and deploy the already-built artifact.

## Bootstrap Sequence (Local First)

To avoid a chicken-and-egg cycle, bootstrap infrastructure in three stacks:

1. Apply `terraform/envs/shared` first to create shared primitives (artifact bucket and optional shared deploy role).
2. Apply `terraform/envs/dev` and `terraform/envs/prod` to create environment-specific SSM artifact parameters and API resources.
3. Implement service code and package scripts.
4. Build and upload Lambda zip artifacts to the shared artifact bucket.
5. Update each environment service artifact SSM parameter with uploaded artifact metadata.
6. Re-apply `terraform/envs/dev` or `terraform/envs/prod` to deploy the referenced artifact.
7. Run smoke tests from curl/Postman and site integration tests.
8. Add GitHub workflows to automate steps 4 through 7.

## CI/CD Plan

Recommended workflows:

### `ci.yml`

Runs on pull requests.

Responsibilities:

- Detect changed services.
- Run Python formatting, linting, and unit tests.
- Run Terraform `fmt` and `validate`.
- Optionally run Terraform plan for changed environments.

### `deploy-dev.yml`

Runs on pushes to the `dev` branch and by manual dispatch.

Responsibilities:

- Package changed Lambda services.
- Upload artifacts to the artifact bucket.
- Run Terraform apply for `terraform/envs/dev`.
- Run smoke tests against the dev execute-api endpoint (or `api-dev.zhenwei.dev` if custom domain is enabled).
- Send deployment notifications through the internal notification path.

### `deploy-prod.yml`

Runs manually from `main` with a protected GitHub Environment approval.

Responsibilities:

- Deploy the approved artifact versions to prod.
- Run Terraform apply for `terraform/envs/prod`.
- Run smoke tests against `api.zhenwei.dev`.
- Send success or failure notifications.

## Environment Model

| Environment | Domain | Deployment trigger | Purpose |
| --- | --- | --- | --- |
| `dev` | execute-api endpoint by default (`api-dev.zhenwei.dev` optional) | Push to `dev` or manual dispatch | Integration testing and site development. |
| `prod` | `api.zhenwei.dev` | Manual workflow from `main` with approval | Production portfolio and automation APIs. |

The portfolio site can point to different API URLs with environment variables, for example:

```bash
VITE_APP_ENV=dev
VITE_CV_MODE=api
VITE_CV_API_URL=https://<dev-execute-api-id>.execute-api.ap-southeast-1.amazonaws.com/get-presigned-url
```

## Delivery Phases

1. Scaffold the repository structure.
2. Implement `get-presigned-url` for dev.
3. Add shared-stack Terraform for artifact bucket and optional shared IAM roles.
4. Add env-stack Terraform for environment SSM parameter names and API resources.
5. Add CI tests and Lambda artifact packaging.
6. Deploy the dev endpoint and integrate the site CV download flow.
7. Implement `send-notification` with secure secret retrieval and internal access control.
8. Implement `update-invalidation-status` with bounded polling.
9. Migrate invalidation tracking to Step Functions if the workflow becomes long-running or needs richer orchestration.

## Related Docs

- [docs/api-repo-context.md](docs/api-repo-context.md)
- [docs/api-repo.md](docs/api-repo.md)
