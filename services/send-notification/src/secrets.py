import json
import logging
import time
from typing import Optional

import boto3

LOGGER = logging.getLogger(__name__)

# SSM parameter cache: {param_name: (value, timestamp)}
_PARAMETER_CACHE: dict[str, tuple[str, float]] = {}
_CACHE_TTL_SECONDS = 60

SSM_CLIENT = None


def get_ssm_client():
    """Get or initialize SSM client."""
    global SSM_CLIENT
    if SSM_CLIENT is None:
        SSM_CLIENT = boto3.client("ssm")
    return SSM_CLIENT


class SecretCacheError(Exception):
    """Raised when secret retrieval fails."""
    pass


def clear_cache(param_name: Optional[str] = None) -> None:
    """Clear cache entry for a parameter, or all cache if param_name is None."""
    global _PARAMETER_CACHE
    if param_name:
        if param_name in _PARAMETER_CACHE:
            LOGGER.info(f"Clearing cache for parameter: {param_name}")
            del _PARAMETER_CACHE[param_name]
    else:
        LOGGER.info("Clearing entire parameter cache")
        _PARAMETER_CACHE.clear()


def get_parameter(param_name: str, with_decryption: bool = True) -> str:
    """
    Get SSM parameter value with in-memory caching.
    
    Cache behavior:
    - Returns cached value if available and not expired (TTL 60 seconds)
    - On cache miss, fetches from SSM
    - On fetch failure, raises SecretCacheError
    - Cache is cleared on cold start (Lambda invocation resets module state)
    
    Args:
        param_name: SSM parameter name (e.g., 'PushoverToken')
        with_decryption: Whether to decrypt SecureString parameters
    
    Returns:
        Parameter value (string)
    
    Raises:
        SecretCacheError: If parameter cannot be retrieved from SSM
    """
    global _PARAMETER_CACHE
    
    current_time = time.time()
    
    # Check cache
    if param_name in _PARAMETER_CACHE:
        value, timestamp = _PARAMETER_CACHE[param_name]
        age_seconds = current_time - timestamp
        if age_seconds < _CACHE_TTL_SECONDS:
            LOGGER.debug(f"Cache hit for parameter {param_name} (age: {age_seconds:.1f}s)")
            return value
        else:
            LOGGER.debug(f"Cache expired for parameter {param_name} (age: {age_seconds:.1f}s > {_CACHE_TTL_SECONDS}s)")
            del _PARAMETER_CACHE[param_name]
    
    # Cache miss; fetch from SSM
    LOGGER.debug(f"Fetching parameter from SSM: {param_name}")
    try:
        client = get_ssm_client()
        response = client.get_parameter(Name=param_name, WithDecryption=with_decryption)
        value = response["Parameter"]["Value"]
        
        # Cache the value
        _PARAMETER_CACHE[param_name] = (value, current_time)
        LOGGER.info(f"Retrieved and cached parameter: {param_name}")
        return value
    
    except client.exceptions.ParameterNotFound as e:
        msg = f"SSM parameter not found: {param_name}"
        LOGGER.error(msg)
        raise SecretCacheError(msg) from e
    
    except Exception as e:
        msg = f"Failed to retrieve SSM parameter {param_name}: {str(e)}"
        LOGGER.error(msg)
        raise SecretCacheError(msg) from e


def get_pushover_credentials() -> tuple[str, str]:
    """
    Get Pushover app token and user ID from SSM parameters.
    
    Returns:
        Tuple of (pushover_token, pushover_user)
    
    Raises:
        SecretCacheError: If either parameter cannot be retrieved
    """
    try:
        token = get_parameter("PushoverToken")
        user = get_parameter("PushoverUser")
        return token, user
    except SecretCacheError as e:
        LOGGER.error(f"Failed to retrieve Pushover credentials: {str(e)}")
        raise
