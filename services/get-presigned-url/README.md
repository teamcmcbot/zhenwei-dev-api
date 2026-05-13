# get-presigned-url

Lambda service for generating short-lived S3 presigned URLs for approved private objects.

## Request

```json
{
  "objectKey": "private-downloads/resume/zhenwei-seo-cv.pdf",
  "expiresInSeconds": 300,
  "contentDispositionFileName": "zhenwei-seo-cv.pdf"
}
```

`objectKey` is required. `versionId`, `expiresInSeconds`, and `contentDispositionFileName` are optional.

## Response

```json
{
  "url": "https://...",
  "bucketName": "zhenwei-private-bucket",
  "objectKey": "private-downloads/resume/zhenwei-seo-cv.pdf",
  "versionId": null,
  "fileName": "zhenwei-seo-cv.pdf",
  "expiresIn": 300
}
```

## Runtime Configuration

The Terraform module provides these environment variables:

| Variable | Purpose |
| --- | --- |
| `PRIVATE_BUCKET_NAME` | S3 bucket that contains approved private objects. |
| `ALLOWED_OBJECT_KEYS` | Comma-separated exact object keys allowed for signing. |
| `ALLOWED_OBJECT_PREFIXES` | Comma-separated object key prefixes allowed for signing. |
| `DEFAULT_PRESIGNED_URL_EXPIRES_SECONDS` | Default URL TTL when the request omits `expiresInSeconds`. |
| `MAX_PRESIGNED_URL_EXPIRES_SECONDS` | Maximum URL TTL. Higher requested values are capped. |
| `ALLOWED_ORIGINS` | Comma-separated browser origins allowed by the Lambda response. |
| `LOG_LEVEL` | Python logging level. |

## Local Tests

```bash
python3 -m unittest discover -s services/get-presigned-url/tests
```

## Package

```bash
scripts/package_lambda.sh get-presigned-url
```

The package artifact is written to `dist/get-presigned-url.zip` with a metadata file at `dist/get-presigned-url.manifest.json`.

## Publish Artifact

For a first environment deployment, create the environment artifact parameter first, then publish the zip metadata, then run the full Terraform apply:

```bash
terraform -chdir=terraform/envs/dev apply -target=module.bootstrap
scripts/publish_lambda_artifact.sh dev zhenwei-dev-api-artifacts
terraform -chdir=terraform/envs/dev apply
```

Repeat the same pattern for `prod` after the dev deployment is verified.
