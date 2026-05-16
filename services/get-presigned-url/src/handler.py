import base64
import json
import logging
import os
import re
from datetime import datetime
from pathlib import PurePosixPath
from typing import Any

LOGGER = logging.getLogger(__name__)
S3_CLIENT = None


class RequestError(Exception):
    def __init__(self, status_code: int, code: str, message: str) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.code = code
        self.message = message


def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    configure_logging()
    request_id = getattr(context, "aws_request_id", None) or event.get("requestContext", {}).get("requestId", "")
    headers = normalize_headers(event.get("headers") or {})
    origin = headers.get("origin")
    allowed_origins = parse_csv_env("ALLOWED_ORIGINS")

    try:
        method = event.get("requestContext", {}).get("http", {}).get("method") or event.get("httpMethod", "")

        if method == "OPTIONS":
            validate_origin(origin, allowed_origins)
            return response(204, None, origin, allowed_origins)

        if method != "POST":
            raise RequestError(405, "method_not_allowed", "Method not allowed.")

        validate_origin(origin, allowed_origins)
        body = parse_body(event)
        config = load_config()
        request = validate_request(body, config)

        signing_params = {
            "Bucket": config["bucket_name"],
            "Key": request["object_key"],
            "ResponseContentDisposition": f'attachment; filename="{request["file_name"]}"',
        }
        if request.get("version_id"):
            signing_params["VersionId"] = request["version_id"]

        object_metadata = get_object_metadata(
            get_s3_client(),
            config["bucket_name"],
            request["object_key"],
            request.get("version_id"),
        )

        url = get_s3_client().generate_presigned_url(
            ClientMethod="get_object",
            Params=signing_params,
            ExpiresIn=request["expires_in_seconds"],
        )

        LOGGER.info(
            "generated_presigned_url",
            extra={
                "request_id": request_id,
                "object_key": request["object_key"],
                "expires_in_seconds": request["expires_in_seconds"],
                "app_env": os.getenv("APP_ENV", ""),
            },
        )

        payload = {
            "url": url,
            "bucketName": config["bucket_name"],
            "objectKey": request["object_key"],
            "versionId": object_metadata.get("versionId") or request.get("version_id"),
            "fileName": request["file_name"],
            "expiresIn": request["expires_in_seconds"],
            "eTag": object_metadata.get("eTag"),
            "lastModified": object_metadata.get("lastModified"),
            "contentLength": object_metadata.get("contentLength"),
            "contentType": object_metadata.get("contentType"),
        }
        return response(200, payload, origin, allowed_origins)
    except RequestError as exc:
        LOGGER.info("request_rejected", extra={"request_id": request_id, "code": exc.code})
        return error_response(exc.status_code, exc.code, exc.message, request_id, origin, allowed_origins)
    except Exception:
        LOGGER.exception("unexpected_error", extra={"request_id": request_id})
        return error_response(500, "internal_error", "Unexpected error.", request_id, origin, allowed_origins)


def configure_logging() -> None:
    level_name = os.getenv("LOG_LEVEL", "INFO").upper()
    level = getattr(logging, level_name, logging.INFO)
    logging.getLogger().setLevel(level)


def get_s3_client() -> Any:
    global S3_CLIENT
    if S3_CLIENT is None:
        import boto3

        S3_CLIENT = boto3.client("s3")
    return S3_CLIENT


def get_object_metadata(s3_client: Any, bucket_name: str, object_key: str, version_id: str | None) -> dict[str, Any]:
    head_params: dict[str, Any] = {"Bucket": bucket_name, "Key": object_key}
    if version_id:
        head_params["VersionId"] = version_id

    try:
        head = s3_client.head_object(**head_params)
    except Exception as exc:
        error_code = get_aws_error_code(exc)
        if error_code in {"404", "NoSuchKey", "NotFound", "NoSuchVersion"}:
            raise RequestError(404, "not_found", "The requested file does not exist.") from exc
        raise

    return {
        "versionId": head.get("VersionId"),
        "eTag": normalize_etag(head.get("ETag")),
        "lastModified": to_iso8601(head.get("LastModified")),
        "contentLength": head.get("ContentLength"),
        "contentType": head.get("ContentType"),
    }


def get_aws_error_code(exc: Exception) -> str:
    response = getattr(exc, "response", None)
    if not isinstance(response, dict):
        return ""
    error = response.get("Error")
    if not isinstance(error, dict):
        return ""
    return str(error.get("Code", ""))


def normalize_etag(value: Any) -> str | None:
    if not isinstance(value, str) or not value:
        return None
    return value.strip('"')


def to_iso8601(value: Any) -> str | None:
    if not isinstance(value, datetime):
        return None
    return value.isoformat()


def load_config() -> dict[str, Any]:
    bucket_name = os.getenv("PRIVATE_BUCKET_NAME", "").strip()
    if not bucket_name:
        raise RuntimeError("PRIVATE_BUCKET_NAME is required")

    default_expires = parse_positive_int_env("DEFAULT_PRESIGNED_URL_EXPIRES_SECONDS", 300)
    max_expires = parse_positive_int_env("MAX_PRESIGNED_URL_EXPIRES_SECONDS", 900)
    if default_expires > max_expires:
        default_expires = max_expires

    return {
        "bucket_name": bucket_name,
        "allowed_object_keys": parse_csv_env("ALLOWED_OBJECT_KEYS"),
        "allowed_object_prefixes": parse_csv_env("ALLOWED_OBJECT_PREFIXES"),
        "default_expires_seconds": default_expires,
        "max_expires_seconds": max_expires,
    }


def parse_positive_int_env(name: str, default: int) -> int:
    value = os.getenv(name, "").strip()
    if not value:
        return default
    try:
        parsed = int(value)
    except ValueError as exc:
        raise RuntimeError(f"{name} must be an integer") from exc
    if parsed <= 0:
        raise RuntimeError(f"{name} must be positive")
    return parsed


def parse_csv_env(name: str) -> list[str]:
    value = os.getenv(name, "")
    return [item.strip() for item in value.split(",") if item.strip()]


def normalize_headers(headers: dict[str, Any]) -> dict[str, str]:
    return {str(key).lower(): str(value) for key, value in headers.items() if value is not None}


def validate_origin(origin: str | None, allowed_origins: list[str]) -> None:
    if origin and origin not in allowed_origins:
        raise RequestError(403, "forbidden", "The request origin is not allowed.")


def parse_body(event: dict[str, Any]) -> dict[str, Any]:
    raw_body = event.get("body")
    if raw_body is None or raw_body == "":
        raise RequestError(400, "invalid_request", "Request body is required.")

    if event.get("isBase64Encoded"):
        raw_body = base64.b64decode(raw_body).decode("utf-8")

    try:
        body = json.loads(raw_body)
    except (TypeError, ValueError) as exc:
        raise RequestError(400, "invalid_json", "Request body must be valid JSON.") from exc

    if not isinstance(body, dict):
        raise RequestError(400, "invalid_request", "Request body must be a JSON object.")
    return body


def validate_request(body: dict[str, Any], config: dict[str, Any]) -> dict[str, Any]:
    object_key = body.get("objectKey")
    if not isinstance(object_key, str):
        raise RequestError(400, "invalid_request", "objectKey is required.")

    object_key = object_key.strip()
    validate_object_key(object_key)
    if not is_allowed_object_key(object_key, config["allowed_object_keys"], config["allowed_object_prefixes"]):
        raise RequestError(403, "forbidden", "The requested file is not available.")

    version_id = body.get("versionId")
    if version_id is not None:
        if not isinstance(version_id, str) or not 1 <= len(version_id) <= 1024 or has_control_chars(version_id):
            raise RequestError(400, "invalid_request", "versionId is invalid.")

    expires_in_seconds = resolve_expires_in_seconds(
        body.get("expiresInSeconds"),
        config["default_expires_seconds"],
        config["max_expires_seconds"],
    )

    requested_file_name = body.get("contentDispositionFileName")
    if requested_file_name is not None and not isinstance(requested_file_name, str):
        raise RequestError(400, "invalid_request", "contentDispositionFileName is invalid.")

    file_name = sanitize_file_name(requested_file_name or PurePosixPath(object_key).name)

    return {
        "object_key": object_key,
        "version_id": version_id,
        "expires_in_seconds": expires_in_seconds,
        "file_name": file_name,
    }


def validate_object_key(object_key: str) -> None:
    if not object_key:
        raise RequestError(400, "invalid_request", "objectKey is required.")
    if len(object_key) > 1024:
        raise RequestError(400, "invalid_request", "objectKey is too long.")
    if object_key.startswith(("/", "http://", "https://", "s3://")):
        raise RequestError(400, "invalid_request", "objectKey is invalid.")
    if "\\" in object_key or has_control_chars(object_key):
        raise RequestError(400, "invalid_request", "objectKey is invalid.")
    if any(part in ("", ".", "..") for part in object_key.split("/")):
        raise RequestError(400, "invalid_request", "objectKey is invalid.")


def has_control_chars(value: str) -> bool:
    return any(ord(char) < 32 or ord(char) == 127 for char in value)


def is_allowed_object_key(object_key: str, allowed_keys: list[str], allowed_prefixes: list[str]) -> bool:
    return object_key in allowed_keys or any(object_key.startswith(prefix) for prefix in allowed_prefixes)


def resolve_expires_in_seconds(value: Any, default: int, maximum: int) -> int:
    if value is None:
        return default
    if isinstance(value, bool):
        raise RequestError(400, "invalid_request", "expiresInSeconds is invalid.")
    try:
        parsed = int(value)
    except (TypeError, ValueError) as exc:
        raise RequestError(400, "invalid_request", "expiresInSeconds is invalid.") from exc
    if parsed <= 0:
        raise RequestError(400, "invalid_request", "expiresInSeconds must be positive.")
    return min(parsed, maximum)


def sanitize_file_name(value: str) -> str:
    file_name = PurePosixPath(value.replace("\\", "/")).name.strip()
    file_name = re.sub(r"[^A-Za-z0-9._ -]", "_", file_name)
    file_name = re.sub(r"\s+", " ", file_name).strip(" .")
    return file_name[:128] or "download"


def response(status_code: int, payload: dict[str, Any] | None, origin: str | None, allowed_origins: list[str]) -> dict[str, Any]:
    headers = response_headers(origin, allowed_origins)
    if status_code == 204:
        return {"statusCode": status_code, "headers": headers, "body": ""}
    return {"statusCode": status_code, "headers": headers, "body": json.dumps(payload or {}, separators=(",", ":"))}


def error_response(
    status_code: int,
    code: str,
    message: str,
    request_id: str,
    origin: str | None,
    allowed_origins: list[str],
) -> dict[str, Any]:
    return response(status_code, {"error": {"code": code, "message": message}, "requestId": request_id}, origin, allowed_origins)


def response_headers(origin: str | None, allowed_origins: list[str]) -> dict[str, str]:
    headers = {
        "Content-Type": "application/json",
        "Vary": "Origin",
        "Access-Control-Allow-Methods": "OPTIONS,POST",
        "Access-Control-Allow-Headers": "content-type,authorization,x-requested-with",
        "Access-Control-Max-Age": "300",
    }
    if origin and origin in allowed_origins:
        headers["Access-Control-Allow-Origin"] = origin
    return headers
