#!/usr/bin/env bash
set -euo pipefail

ENVIRONMENT="${1:?Usage: scripts/publish_lambda_artifact.sh <environment> <artifact-bucket> [service-name] [artifact-prefix]}"
ARTIFACT_BUCKET="${2:?Usage: scripts/publish_lambda_artifact.sh <environment> <artifact-bucket> [service-name] [artifact-prefix]}"
SERVICE_NAME="${3:-get-presigned-url}"
ARTIFACT_PREFIX="${4:-lambdas/${SERVICE_NAME}}"
PROJECT_NAME="${PROJECT_NAME:-zhenwei-dev-api}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZIP_PATH="${ROOT_DIR}/dist/${SERVICE_NAME}.zip"
MANIFEST_PATH="${ROOT_DIR}/dist/${SERVICE_NAME}.manifest.json"
COMMIT_SHA="${GITHUB_SHA:-$(git -C "${ROOT_DIR}" rev-parse --short=12 HEAD 2>/dev/null || echo local)}"
BUILD_ID="${GITHUB_RUN_ID:-local-${COMMIT_SHA}}"
CREATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ARTIFACT_KEY="${ARTIFACT_PREFIX%/}/${COMMIT_SHA}.zip"
PARAMETER_NAME="/${PROJECT_NAME}/${ENVIRONMENT}/${SERVICE_NAME}/artifact"

"${ROOT_DIR}/scripts/package_lambda.sh" "${SERVICE_NAME}" >/dev/null

aws s3 cp "${ZIP_PATH}" "s3://${ARTIFACT_BUCKET}/${ARTIFACT_KEY}"

export ARTIFACT_BUCKET ARTIFACT_KEY BUILD_ID COMMIT_SHA CREATED_AT MANIFEST_PATH PARAMETER_NAME
PARAMETER_VALUE="$(python3 <<'PY'
import json
import os
from pathlib import Path

manifest = json.loads(Path(os.environ["MANIFEST_PATH"]).read_text(encoding="utf-8"))
value = {
    "bucket": os.environ["ARTIFACT_BUCKET"],
    "key": os.environ["ARTIFACT_KEY"],
    "source_code_hash": manifest["source_code_hash"],
    "build_id": os.environ["BUILD_ID"],
    "commit_sha": os.environ["COMMIT_SHA"],
    "created_at": os.environ["CREATED_AT"],
}
print(json.dumps(value, separators=(",", ":")))
PY
)"

aws ssm put-parameter \
  --name "${PARAMETER_NAME}" \
  --type String \
  --value "${PARAMETER_VALUE}" \
  --overwrite >/dev/null

printf '%s\n' "Published ${SERVICE_NAME} artifact:"
printf '  s3://%s/%s\n' "${ARTIFACT_BUCKET}" "${ARTIFACT_KEY}"
printf '  %s\n' "${PARAMETER_NAME}"
