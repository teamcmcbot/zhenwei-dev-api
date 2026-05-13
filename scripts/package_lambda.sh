#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="${1:-get-presigned-url}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE_DIR="${ROOT_DIR}/services/${SERVICE_NAME}"
SRC_DIR="${SERVICE_DIR}/src"
REQUIREMENTS_FILE="${SERVICE_DIR}/requirements.txt"
BUILD_DIR="${ROOT_DIR}/build/${SERVICE_NAME}"
PACKAGE_DIR="${BUILD_DIR}/package"
DIST_DIR="${ROOT_DIR}/dist"
ZIP_PATH="${DIST_DIR}/${SERVICE_NAME}.zip"
MANIFEST_PATH="${DIST_DIR}/${SERVICE_NAME}.manifest.json"

if [[ ! -d "${SRC_DIR}" ]]; then
  echo "Missing service source directory: ${SRC_DIR}" >&2
  exit 1
fi

rm -rf "${BUILD_DIR}"
mkdir -p "${PACKAGE_DIR}" "${DIST_DIR}"
cp -R "${SRC_DIR}/." "${PACKAGE_DIR}/"

if [[ -f "${REQUIREMENTS_FILE}" ]] && grep -Eq '^[[:space:]]*[^#[:space:]]' "${REQUIREMENTS_FILE}"; then
  python3 -m pip install \
    --requirement "${REQUIREMENTS_FILE}" \
    --target "${PACKAGE_DIR}" \
    --upgrade
fi

export PACKAGE_DIR ZIP_PATH MANIFEST_PATH SERVICE_NAME
python3 <<'PY'
import base64
import hashlib
import json
import os
import zipfile
from pathlib import Path

package_dir = Path(os.environ["PACKAGE_DIR"])
zip_path = Path(os.environ["ZIP_PATH"])
manifest_path = Path(os.environ["MANIFEST_PATH"])
service_name = os.environ["SERVICE_NAME"]
fixed_timestamp = (2026, 1, 1, 0, 0, 0)

with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(package_dir.rglob("*")):
        if path.is_dir():
            continue
        relative_path = path.relative_to(package_dir).as_posix()
        info = zipfile.ZipInfo(relative_path, fixed_timestamp)
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o644 << 16
        archive.writestr(info, path.read_bytes())

zip_bytes = zip_path.read_bytes()
source_code_hash = base64.b64encode(hashlib.sha256(zip_bytes).digest()).decode("ascii")
manifest = {
    "service": service_name,
    "zip_path": str(zip_path),
    "source_code_hash": source_code_hash,
    "size_bytes": len(zip_bytes),
}
manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(json.dumps(manifest, indent=2, sort_keys=True))
PY
