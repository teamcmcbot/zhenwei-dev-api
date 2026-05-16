import re
import string
from typing import Any, Optional


class ValidationError(Exception):
    """Raised when request validation fails."""
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def parse_csv_env(env_value: str) -> set[str]:
    """Parse comma-delimited string into a set of lowercase values."""
    if not env_value:
        return set()
    return {v.strip().lower() for v in env_value.split(",") if v.strip()}


def validate_string_field(value: Any, field_name: str, min_len: int = 1, max_len: int = None, 
                         allow_empty: bool = False) -> str:
    """Validate string field: type, length, control characters."""
    if value is None:
        if allow_empty:
            return ""
        raise ValidationError("validation_error", f"Missing required field: {field_name}")
    
    if not isinstance(value, str):
        raise ValidationError("validation_error", f"Field {field_name} must be a string, got {type(value).__name__}")
    
    if not allow_empty and len(value) < min_len:
        raise ValidationError("validation_error", f"Field {field_name} must be at least {min_len} character(s)")
    
    if max_len and len(value) > max_len:
        raise ValidationError("validation_error", f"Field {field_name} must be at most {max_len} character(s)")
    
    # Reject control characters (except newline which we allow in message for formatting)
    if field_name != "message":
        if any(ord(c) < 32 and c != '\n' for c in value):
            raise ValidationError("validation_error", f"Field {field_name} contains control characters")
    
    return value


def validate_priority(value: Any) -> int:
    """Validate priority field: must be -2, -1, 0, 1, or 2."""
    if value is None:
        return 0
    
    if not isinstance(value, int):
        raise ValidationError("validation_error", "Field priority must be an integer")
    
    if value not in (-2, -1, 0, 1, 2):
        raise ValidationError("validation_error", "Field priority must be one of: -2, -1, 0, 1, 2")
    
    return value


def validate_integer_field(value: Any, field_name: str, min_val: int = None, max_val: int = None) -> int:
    """Validate integer field."""
    if value is None:
        raise ValidationError("validation_error", f"Missing required field: {field_name}")
    
    if not isinstance(value, int):
        raise ValidationError("validation_error", f"Field {field_name} must be an integer")
    
    if min_val is not None and value < min_val:
        raise ValidationError("validation_error", f"Field {field_name} must be at least {min_val}")
    
    if max_val is not None and value > max_val:
        raise ValidationError("validation_error", f"Field {field_name} must be at most {max_val}")
    
    return value


def validate_boolean_field(value: Any, field_name: str) -> bool:
    """Validate boolean field."""
    if value is None:
        return False
    
    if not isinstance(value, bool):
        raise ValidationError("validation_error", f"Field {field_name} must be a boolean")
    
    return value


def validate_application_token(value: Optional[str]) -> Optional[str]:
    """Validate applicationToken field: max 100 chars, alphanumeric + common symbols only."""
    if value is None or value == "":
        return None
    
    if not isinstance(value, str):
        raise ValidationError("validation_error", "Field applicationToken must be a string")
    
    if len(value) > 100:
        raise ValidationError("validation_error", "Field applicationToken must be at most 100 characters")
    
    # Allow alphanumeric, underscore, dash, dot (Pushover token format)
    if not re.match(r"^[a-zA-Z0-9_\-.]+$", value):
        raise ValidationError("validation_error", "Field applicationToken contains invalid characters (only alphanumeric, _, -, . allowed)")
    
    return value


def validate_metadata(value: Optional[dict]) -> Optional[dict]:
    """Validate metadata field: must not contain sensitive keys."""
    if value is None:
        return None
    
    if not isinstance(value, dict):
        raise ValidationError("validation_error", "Field metadata must be an object")
    
    # List of keys that should not be in metadata (to prevent accidental secret leakage)
    sensitive_keys = {"password", "token", "secret", "key", "credential", "auth", "apikey", "api_key", "authorization"}
    
    for key in value.keys():
        if key.lower() in sensitive_keys:
            raise ValidationError("validation_error", f"Field metadata contains sensitive key: {key}")
    
    return value


def validate_payload(payload: dict, allowed_sources: set[str], allowed_event_types: set[str]) -> dict:
    """Validate entire request payload and return normalized payload."""
    
    # Mandatory fields
    source = validate_string_field(payload.get("source"), "source", max_len=100)
    event_type = validate_string_field(payload.get("eventType"), "eventType", max_len=100)
    message = validate_string_field(payload.get("message"), "message", min_len=1, max_len=1024)
    
    # Validate source and eventType are in allow-list
    if source.lower() not in allowed_sources:
        raise ValidationError("validation_error", f"Field source '{source}' is not allowed")
    
    if event_type.lower() not in allowed_event_types:
        raise ValidationError("validation_error", f"Field eventType '{event_type}' is not allowed")
    
    # Optional fields
    title = validate_string_field(payload.get("title"), "title", min_len=1, max_len=250, allow_empty=True)
    if not title:
        title = None
    
    priority = validate_priority(payload.get("priority"))
    
    sound = validate_string_field(payload.get("sound"), "sound", max_len=100, allow_empty=True)
    if not sound:
        sound = None
    
    device = validate_string_field(payload.get("device"), "device", max_len=100, allow_empty=True)
    if not device:
        device = None
    
    url = validate_string_field(payload.get("url"), "url", max_len=512, allow_empty=True)
    if not url:
        url = None
    
    url_title = validate_string_field(payload.get("urlTitle"), "urlTitle", max_len=100, allow_empty=True)
    if not url_title:
        url_title = None
    
    ttl = payload.get("ttl")
    if ttl is not None:
        ttl = validate_integer_field(ttl, "ttl", min_val=0)
    
    timestamp = payload.get("timestamp")
    if timestamp is not None:
        timestamp = validate_integer_field(timestamp, "timestamp", min_val=0)
    
    html = validate_boolean_field(payload.get("html"), "html")
    monospace = validate_boolean_field(payload.get("monospace"), "monospace")
    
    # Cannot use both html and monospace
    if html and monospace:
        raise ValidationError("validation_error", "Cannot use both html and monospace")
    
    metadata = validate_metadata(payload.get("metadata"))
    
    dedupe_key = validate_string_field(payload.get("dedupeKey"), "dedupeKey", max_len=100, allow_empty=True)
    if not dedupe_key:
        dedupe_key = None
    
    retry = payload.get("retry")
    if retry is not None:
        retry = validate_integer_field(retry, "retry", min_val=0)
    
    expire = payload.get("expire")
    if expire is not None:
        expire = validate_integer_field(expire, "expire", min_val=0)
    
    callback = validate_string_field(payload.get("callback"), "callback", max_len=512, allow_empty=True)
    if not callback:
        callback = None
    
    # If priority is 2 (emergency), retry and expire are required
    if priority == 2:
        if retry is None:
            raise ValidationError("validation_error", "Field retry is required when priority=2 (emergency)")
        if expire is None:
            raise ValidationError("validation_error", "Field expire is required when priority=2 (emergency)")
    
    # Validate applicationToken
    application_token = validate_application_token(payload.get("applicationToken"))
    
    # Build normalized payload
    normalized = {
        "source": source,
        "eventType": event_type,
        "message": message,
        "title": title,
        "priority": priority,
        "sound": sound,
        "device": device,
        "url": url,
        "urlTitle": url_title,
        "ttl": ttl,
        "timestamp": timestamp,
        "html": html,
        "monospace": monospace,
        "metadata": metadata,
        "dedupeKey": dedupe_key,
        "retry": retry,
        "expire": expire,
        "callback": callback,
        "applicationToken": application_token,
    }
    
    return normalized
