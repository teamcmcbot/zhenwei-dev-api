import json
import logging
import os
from typing import Any

from validators import ValidationError, parse_csv_env, validate_payload
from secrets import SecretCacheError, get_parameter
from pushover_adapter import PushoverError, build_pushover_payload, send_notification

LOGGER = logging.getLogger(__name__)


def configure_logging() -> None:
    """Configure structured logging for Lambda."""
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    )


def parse_body(event: dict) -> dict:
    """Parse request body from Lambda proxy event."""
    body = event.get("body", "{}")
    if isinstance(body, str):
        try:
            return json.loads(body)
        except json.JSONDecodeError as e:
            raise ValidationError("validation_error", f"Invalid JSON in request body: {str(e)}")
    else:
        return body if isinstance(body, dict) else {}


def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """
    Lambda handler for send-notification API.
    
    10-step process:
    1. Parse REST API proxy event
    2. Validate API key context from API Gateway usage plan enforcement
    3. (Reserved) Validate request signature header if enabled (Phase 2)
    4. Validate payload and apply defaults
    5. Determine Pushover app token (applicationToken override or SSM)
    6. Resolve PushoverUser from SSM
    7. Build application/x-www-form-urlencoded payload for Pushover
    8. Send request with 4-second timeout
    9. Retry transient failures with exponential backoff
    10. Return normalized response and structured logs
    
    Args:
        event: Lambda proxy integration event
        context: Lambda context object
    
    Returns:
        API response dict with statusCode, headers, body
    """
    configure_logging()
    
    # Get AWS request ID for tracing
    request_id = getattr(context, "aws_request_id", "unknown")
    LOGGER.info(f"Processing request {request_id}")
    
    try:
        # Step 1: Parse REST API proxy event
        LOGGER.debug("Step 1: Parsing proxy event")
        http_method = event.get("requestContext", {}).get("http", {}).get("method") or event.get("httpMethod", "")
        if http_method != "POST":
            LOGGER.warning(f"Invalid HTTP method: {http_method}")
            return error_response(405, "method_not_allowed", "Method not allowed", request_id)
        
        # Step 2: Validate API key context from API Gateway
        # (API Gateway method has api_key_required=true, so if we reach here, key is valid)
        LOGGER.debug("Step 2: API key validated by API Gateway")
        
        # Step 3: Reserved for request signature validation (Phase 2)
        LOGGER.debug("Step 3: Request signature validation (reserved for Phase 2)")
        # TODO: Add HMAC signature validation in Phase 2
        
        # Step 4: Validate payload and apply defaults
        LOGGER.debug("Step 4: Validating payload")
        body = parse_body(event)
        
        allowed_sources = parse_csv_env(os.getenv("ALLOWED_SOURCES", "github-actions,terraform,cloudfront"))
        allowed_event_types = parse_csv_env(os.getenv("ALLOWED_EVENT_TYPES", "workflow.completed,apply.success,apply.failed,invalidation.complete"))
        
        validated_payload = validate_payload(body, allowed_sources, allowed_event_types)
        LOGGER.info(f"Payload validated: source={validated_payload['source']}, eventType={validated_payload['eventType']}")
        
        # Step 5: Determine Pushover app token
        LOGGER.debug("Step 5: Resolving Pushover app token")
        if validated_payload.get("applicationToken"):
            pushover_token = validated_payload["applicationToken"]
            LOGGER.info("Using caller-provided applicationToken (audit trail: applicationToken used)")
        else:
            try:
                pushover_token = get_parameter("PushoverToken")
                LOGGER.info("Using SSM PushoverToken")
            except SecretCacheError as e:
                LOGGER.error(f"Failed to retrieve PushoverToken from SSM: {str(e)}")
                return error_response(502, "provider_error", "Failed to retrieve secrets", request_id)
        
        # Step 6: Resolve PushoverUser from SSM
        LOGGER.debug("Step 6: Resolving PushoverUser from SSM")
        try:
            pushover_user = get_parameter("PushoverUser")
            LOGGER.info("Retrieved PushoverUser from SSM")
        except SecretCacheError as e:
            LOGGER.error(f"Failed to retrieve PushoverUser from SSM: {str(e)}")
            return error_response(502, "provider_error", "Failed to retrieve secrets", request_id)
        
        # Step 7: Build Pushover payload
        LOGGER.debug("Step 7: Building Pushover request payload")
        pushover_payload = build_pushover_payload(validated_payload, pushover_token, pushover_user)
        LOGGER.debug(f"Pushover payload keys: {list(pushover_payload.keys())}")
        
        # Step 8: Send to Pushover (with timeout)
        # Step 9: Retry on transient failures (handled in pushover_adapter)
        LOGGER.debug("Step 8-9: Sending to Pushover with retry logic")
        try:
            result = send_notification(pushover_payload, metadata=validated_payload.get("metadata"))
            LOGGER.info(f"Notification accepted by Pushover: {result['providerRequestId']}")
        except PushoverError as e:
            LOGGER.error(f"Pushover error: {e.code} - {e.message}")
            if e.code == "auth_error":
                status_code = 401
            elif e.code == "validation_error":
                status_code = 400
            else:
                status_code = 502
            return error_response(status_code, e.code, e.message, request_id)
        
        # Step 10: Return normalized response
        LOGGER.info(f"Request {request_id} completed successfully")
        return success_response(result, request_id)
    
    except ValidationError as e:
        LOGGER.warning(f"Validation error: {e.code} - {e.message}")
        return error_response(400, e.code, e.message, request_id)
    
    except Exception as e:
        LOGGER.exception(f"Unexpected error: {str(e)}")
        return error_response(500, "internal_error", "Unexpected error processing request", request_id)


def success_response(result: dict, request_id: str) -> dict[str, Any]:
    """Build success response."""
    body = {
        "accepted": result.get("accepted", True),
        "provider": result.get("provider", "pushover"),
        "providerRequestId": result.get("providerRequestId"),
        "providerReceipt": result.get("providerReceipt"),
        "requestId": request_id,
    }
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def error_response(status_code: int, error_code: str, error_message: str, request_id: str) -> dict[str, Any]:
    """Build error response."""
    body = {
        "accepted": False,
        "error": {
            "code": error_code,
            "message": error_message,
        },
        "requestId": request_id,
    }
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }
