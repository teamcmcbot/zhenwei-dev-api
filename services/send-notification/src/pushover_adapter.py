import json
import logging
import time
from typing import Any, Optional
from urllib.parse import urlencode

import requests
from requests.exceptions import RequestException, Timeout

LOGGER = logging.getLogger(__name__)

PUSHOVER_API_ENDPOINT = "https://api.pushover.net/1/messages.json"
PUSHOVER_TIMEOUT_SECONDS = 4
MAX_RETRIES = 4
RETRY_BACKOFF_MS = [100, 200, 400, 800]  # Exponential backoff in milliseconds


class PushoverError(Exception):
    """Raised when Pushover integration fails."""
    def __init__(self, code: str, message: str, retry_attempt: int = 0, provider_status: Optional[int] = None) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.retry_attempt = retry_attempt
        self.provider_status = provider_status


def is_retryable_error(status_code: int) -> bool:
    """Determine if HTTP error is retryable."""
    return status_code in (429, 500, 502, 503, 504)


def build_pushover_payload(validated_payload: dict, pushover_token: str, pushover_user: str) -> dict[str, Any]:
    """
    Build application/x-www-form-urlencoded payload for Pushover.
    
    Converts internal payload format to Pushover API format.
    See: https://pushover.net/api
    
    Args:
        validated_payload: Normalized payload from validators
        pushover_token: Pushover app token
        pushover_user: Pushover user ID
    
    Returns:
        Dictionary ready for urlencode to send to Pushover
    """
    pushover_payload = {
        "token": pushover_token,
        "user": pushover_user,
        "message": validated_payload["message"],
    }
    
    # Optional fields (only include if not None)
    if validated_payload.get("title"):
        pushover_payload["title"] = validated_payload["title"]
    
    if validated_payload["priority"] != 0:
        pushover_payload["priority"] = validated_payload["priority"]
    
    if validated_payload.get("sound"):
        pushover_payload["sound"] = validated_payload["sound"]
    
    if validated_payload.get("device"):
        pushover_payload["device"] = validated_payload["device"]
    
    if validated_payload.get("url"):
        pushover_payload["url"] = validated_payload["url"]
    
    if validated_payload.get("urlTitle"):
        pushover_payload["url_title"] = validated_payload["urlTitle"]
    
    if validated_payload.get("ttl"):
        pushover_payload["ttl"] = validated_payload["ttl"]
    
    if validated_payload.get("timestamp"):
        pushover_payload["timestamp"] = validated_payload["timestamp"]
    
    if validated_payload["html"]:
        pushover_payload["html"] = 1
    
    if validated_payload["monospace"]:
        pushover_payload["monospace"] = 1
    
    if validated_payload.get("dedupeKey"):
        pushover_payload["expire"] = validated_payload["dedupeKey"]
    
    # Emergency (priority=2) fields
    if validated_payload["priority"] == 2:
        if validated_payload.get("retry"):
            pushover_payload["retry"] = validated_payload["retry"]
        if validated_payload.get("expire"):
            pushover_payload["expire"] = validated_payload["expire"]
        if validated_payload.get("callback"):
            pushover_payload["callback"] = validated_payload["callback"]
    
    return pushover_payload


def send_notification(pushover_payload: dict[str, Any], metadata: Optional[dict] = None) -> dict[str, Any]:
    """
    Send notification to Pushover with retry logic.
    
    Behavior:
    - Sends HTTP POST to Pushover API with 4-second timeout
    - Retries on transient errors (429, 5xx) with exponential backoff
    - Returns normalized response with providerRequestId
    - For emergency messages, includes providerReceipt if available
    
    Args:
        pushover_payload: Payload ready to send to Pushover (from build_pushover_payload)
        metadata: Optional metadata for logging (not sent to Pushover)
    
    Returns:
        Normalized response dictionary:
        {
            'accepted': True,
            'provider': 'pushover',
            'providerRequestId': '<uuid>',
            'providerReceipt': '<receipt>' or None,
        }
    
    Raises:
        PushoverError: If send fails after retries
    """
    body = urlencode(pushover_payload)
    LOGGER.debug(f"Sending notification to Pushover (retry attempt 0 of {MAX_RETRIES})")
    
    for attempt in range(MAX_RETRIES):
        try:
            response = requests.post(
                PUSHOVER_API_ENDPOINT,
                data=body,
                headers={"Content-Type": "application/x-www-form-urlencoded"},
                timeout=PUSHOVER_TIMEOUT_SECONDS,
            )
            
            LOGGER.debug(f"Pushover response status: {response.status_code}")
            
            # Success: 200 OK
            if response.status_code == 200:
                try:
                    response_data = response.json()
                except json.JSONDecodeError as e:
                    msg = f"Pushover returned invalid JSON: {str(e)}"
                    LOGGER.error(msg)
                    raise PushoverError("provider_error", msg, retry_attempt=attempt, provider_status=200) from e
                
                # Extract response fields
                request_id = response_data.get("request", "")
                receipt = response_data.get("receipt")  # Present only for emergency messages
                
                LOGGER.info(f"Pushover notification sent (requestId: {request_id}, receipt: {receipt})")
                
                return {
                    "accepted": True,
                    "provider": "pushover",
                    "providerRequestId": request_id,
                    "providerReceipt": receipt,
                }
            
            # Check if error is retryable
            if not is_retryable_error(response.status_code):
                # Non-retryable error: auth failure, validation error, etc.
                try:
                    response_data = response.json()
                    error_messages = response_data.get("errors", [])
                    error_text = "; ".join(error_messages) if error_messages else "Unknown error"
                except json.JSONDecodeError:
                    error_text = response.text or "Unknown error"
                
                msg = f"Pushover error (HTTP {response.status_code}): {error_text}"
                LOGGER.error(msg)
                
                # Determine error code based on status
                if response.status_code == 401:
                    error_code = "auth_error"
                elif response.status_code == 400:
                    error_code = "validation_error"
                else:
                    error_code = "provider_error"
                
                raise PushoverError(error_code, msg, retry_attempt=attempt, provider_status=response.status_code)
            
            # Retryable error: sleep and retry
            if attempt < MAX_RETRIES - 1:
                backoff_ms = RETRY_BACKOFF_MS[attempt]
                LOGGER.warning(f"Pushover error (HTTP {response.status_code}, retryable); backing off {backoff_ms}ms before retry {attempt + 1} of {MAX_RETRIES}")
                time.sleep(backoff_ms / 1000.0)
            else:
                msg = f"Pushover error (HTTP {response.status_code}) after {MAX_RETRIES} retries"
                LOGGER.error(msg)
                raise PushoverError("provider_error", msg, retry_attempt=attempt, provider_status=response.status_code)
        
        except Timeout as e:
            msg = f"Pushover request timeout after {PUSHOVER_TIMEOUT_SECONDS}s"
            LOGGER.warning(msg)
            
            if attempt < MAX_RETRIES - 1:
                backoff_ms = RETRY_BACKOFF_MS[attempt]
                LOGGER.warning(f"Timeout (retryable); backing off {backoff_ms}ms before retry {attempt + 1} of {MAX_RETRIES}")
                time.sleep(backoff_ms / 1000.0)
            else:
                LOGGER.error(f"{msg} after {MAX_RETRIES} retries")
                raise PushoverError("provider_error", msg, retry_attempt=attempt) from e
        
        except RequestException as e:
            msg = f"Pushover request failed: {str(e)}"
            LOGGER.warning(msg)
            
            if attempt < MAX_RETRIES - 1:
                backoff_ms = RETRY_BACKOFF_MS[attempt]
                LOGGER.warning(f"Request failed (retryable); backing off {backoff_ms}ms before retry {attempt + 1} of {MAX_RETRIES}")
                time.sleep(backoff_ms / 1000.0)
            else:
                LOGGER.error(f"{msg} after {MAX_RETRIES} retries")
                raise PushoverError("provider_error", msg, retry_attempt=attempt) from e
    
    # Should not reach here, but add safeguard
    msg = f"Unexpected exit from retry loop"
    LOGGER.error(msg)
    raise PushoverError("provider_error", msg)
