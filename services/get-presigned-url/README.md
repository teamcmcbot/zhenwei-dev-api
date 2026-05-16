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
  "versionId": "3HL4kqtJlcpXroDTDmJ-rmSpXd3dIbrH",
  "fileName": "zhenwei-seo-cv.pdf",
  "expiresIn": 300,
  "eTag": "abc123etag",
  "lastModified": "2026-05-16T10:30:00+00:00",
  "contentLength": 2048,
  "contentType": "application/pdf"
}
```

`versionId` is resolved from S3 object metadata when available. The service also returns file metadata from `HeadObject` (`eTag`, `lastModified`, `contentLength`, `contentType`).

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

Use explicit `service-name` in publish commands so the workflow stays clear as more Lambda services are added.

For a first environment deployment, create the environment artifact parameter first, then publish the zip metadata, then run the full Terraform apply.

Dev:

```bash
terraform -chdir=terraform/envs/dev apply -target=module.bootstrap
scripts/publish_lambda_artifact.sh dev zhenwei-dev-api-artifacts get-presigned-url
terraform -chdir=terraform/envs/dev apply
```

Prod (after dev is verified):

```bash
terraform -chdir=terraform/envs/prod apply -target=module.bootstrap
scripts/publish_lambda_artifact.sh prod zhenwei-dev-api-artifacts get-presigned-url
terraform -chdir=terraform/envs/prod apply
```

After bootstrap resources already exist, the repeat deploy flow is usually just publish + full apply.

## Smoke Test After Deploy

Run these commands from the repository root. They read the API endpoint from Terraform outputs and then call `POST /get-presigned-url`.

Dev:

```bash
DEV_API_ENDPOINT="$(terraform -chdir=terraform/envs/dev output -raw get_presigned_url_api_endpoint)"

curl -i -X POST "${DEV_API_ENDPOINT%/}/get-presigned-url" \
  -H "Origin: https://zhenwei.dev" \
  -H "Content-Type: application/json" \
  -d '{
    "objectKey": "private-downloads/resume/zhenwei-seo-cv.pdf",
    "expiresInSeconds": 300
  }'
```

Prod:

```bash
PROD_API_ENDPOINT="$(terraform -chdir=terraform/envs/prod output -raw get_presigned_url_api_endpoint)"

curl -i -X POST "${PROD_API_ENDPOINT%/}/get-presigned-url" \
  -H "Origin: https://zhenwei.dev" \
  -H "Content-Type: application/json" \
  -d '{
    "objectKey": "private-downloads/resume/zhenwei-seo-cv.pdf",
    "expiresInSeconds": 300
  }'
```

Expected result:

- HTTP `200`
- JSON response includes `url`, `versionId`, `eTag`, `lastModified`, `contentLength`, and `contentType`
- `access-control-allow-origin` matches the supplied origin
