# Terraform

This directory contains the infrastructure for `zhenwei-dev-api`.

## Design

The Terraform layout is split into three stacks so shared resources and environment-specific resources stay isolated:

- `envs/shared` owns shared infrastructure that both environments consume.
- `envs/dev` owns the development deployment.
- `envs/prod` owns the production deployment.

The current shared module provisions the common artifact bucket and, optionally, a GitHub OIDC deploy role. The dev and prod stacks consume shared outputs through remote state and create their own environment-specific resources, including the SSM parameter that points to the packaged Lambda artifact.

API Gateway REST account logging settings are also owned by `envs/shared` (`aws_api_gateway_account` + CloudWatch role) because they are account-level singletons per region.

## Region Rules

- All stacks run in `ap-southeast-1`.
- API Gateway HTTP API custom domains require a regional ACM certificate in the same AWS region as the API (`ap-southeast-1` in this repo).

## Tagging Rules

Baseline tags come from Terraform variable defaults:

- `ManagedBy = "terraform"`
- `Project = "zhenwei-dev-api"`

Environment stacks merge in:

- `Environment = "shared"`, `"dev"`, or `"prod"`

Do not add personal tags or owner tags in `terraform.tfvars` files unless you intentionally need extra metadata.

## Stack Responsibilities

### `envs/shared`

Creates shared infrastructure used by all environments:

- Lambda artifact bucket
- Optional GitHub deploy role
- API Gateway account-level CloudWatch logging role/configuration
- Shared outputs consumed by dev/prod via remote state

### `envs/dev`

Creates the development environment resources:

- Environment-specific artifact SSM parameter
- `get-presigned-url` API and Lambda resources
- Optional custom domain resources

### `envs/prod`

Creates the production environment resources:

- Environment-specific artifact SSM parameter
- `get-presigned-url` API and Lambda resources
- Optional custom domain resources

## Flag Matrix

This matrix shows where each toggle is intended to be turned on or off.

| Flag | Shared | Dev | Prod | Notes |
| --- | --- | --- | --- | --- |
| `create_artifact_bucket` | `true` | `false` | `false` | Shared owns the artifact bucket once. |
| `create_artifact_parameter` | `false` | `true` | `true` | Dev/prod each own their own artifact pointer parameter. |
| `create_github_deploy_role` | `true` | `false` | `false` | Shared owns CI deploy identity once. |
| `enable_custom_domain` | n/a | `false` | `true` | Dev usually uses execute-api URL; prod uses custom domain. |
| `create_api_domain_certificate` | n/a | `false` | `false` or `true` | Set `true` only if Terraform should create the regional ACM certificate in the API region (`ap-southeast-1`). |

Notes:

- `dev` and `prod` hardcode `create_artifact_bucket=false`, `create_artifact_parameter=true`, and `create_github_deploy_role=false` in their `main.tf` files.
- In `shared`, the bootstrap module looks up the existing GitHub Actions OIDC provider (`token.actions.githubusercontent.com`) automatically.
- In `shared`, the GitHub deploy role should be allowed to update the artifact parameters for the target environments, controlled by `github_deploy_environments` (default: `dev`, `prod`).

## Why `enable_custom_domain` Is `false` In Dev

`enable_custom_domain` is `false` in dev by default to keep dev setup simpler and cheaper while still allowing full API testing.

- Dev can use the default API Gateway execute-api endpoint without Route53/domain wiring.
- This avoids unnecessary DNS changes and certificate/domain dependencies in day-to-day development.
- Prod sets it to `true` because public stable hostname routing is needed there.

If you want dev to use `api-dev.<domain>` as well, set `enable_custom_domain = true` in `envs/dev/terraform.tfvars` and provide the required hosted zone and certificate inputs.

For this HTTP API setup, that certificate must be regional in `ap-southeast-1`.

## Apply Sequence

Run the stacks in this order:

1. `shared`
2. `dev`
3. `prod`

The reason for this order is that dev and prod read shared outputs from remote state. If shared does not exist first, the environment stacks cannot resolve the artifact bucket output.

## Migration Note: API Gateway Account Ownership

If you previously managed `aws_api_gateway_account` from `envs/dev` and/or `envs/prod`, migrate state ownership before applying environment stacks to avoid singleton flip-flop:

```bash
# 1) Apply shared first so shared owns the API Gateway account singleton.
terraform -chdir=terraform/envs/shared apply

# 2) Remove old singleton ownership from env states without touching real infra.
terraform -chdir=terraform/envs/dev state rm module.send_notification.aws_api_gateway_account.this
terraform -chdir=terraform/envs/prod state rm module.send_notification.aws_api_gateway_account.this

# 3) Remove legacy env-specific API Gateway CloudWatch roles from env states.
terraform -chdir=terraform/envs/dev state rm module.send_notification.aws_iam_role_policy_attachment.apigw_cloudwatch
terraform -chdir=terraform/envs/dev state rm module.send_notification.aws_iam_role.apigw_cloudwatch
terraform -chdir=terraform/envs/prod state rm module.send_notification.aws_iam_role_policy_attachment.apigw_cloudwatch
terraform -chdir=terraform/envs/prod state rm module.send_notification.aws_iam_role.apigw_cloudwatch

# 4) Plan/apply dev and prod normally.
terraform -chdir=terraform/envs/dev plan
terraform -chdir=terraform/envs/prod plan
```

After migration, apply in dev should no longer create drift in prod (and vice versa).

## Recommended Workflow

### 1. Review or create tfvars

Use the example files as a starting point:

- `envs/shared/terraform.tfvars.example`
- `envs/dev/terraform.tfvars.example`
- `envs/prod/terraform.tfvars.example`

Copy them to `terraform.tfvars` in each stack directory and fill in the values needed for your account.

### 2. Initialize and validate

Run validation from each stack directory:

```bash
terraform -chdir=terraform/envs/shared init -backend=false
terraform -chdir=terraform/envs/shared validate

terraform -chdir=terraform/envs/dev init -backend=false
terraform -chdir=terraform/envs/dev validate

terraform -chdir=terraform/envs/prod init -backend=false
terraform -chdir=terraform/envs/prod validate
```

### 3. Apply shared first

```bash
terraform -chdir=terraform/envs/shared apply
```

### 4. Apply dev

```bash
terraform -chdir=terraform/envs/dev apply
```

### 5. Apply prod

```bash
terraform -chdir=terraform/envs/prod apply
```

## Notes

- `shared` is the only stack that should own cross-environment primitives.
- `dev` and `prod` should not create duplicate shared resources.
- Terraform manages infrastructure only; Lambda package build and upload should happen in CI or a separate packaging step.
- The artifact metadata stored in SSM is expected to be updated by the packaging/deploy pipeline before Terraform consumes it.
