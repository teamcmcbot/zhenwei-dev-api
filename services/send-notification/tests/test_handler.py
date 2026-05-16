import json
import os
import sys
from pathlib import Path
from unittest.mock import Mock, patch, MagicMock

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from handler import lambda_handler
from secrets import clear_cache
from validators import ValidationError


# Mock context object
class MockContext:
    aws_request_id = "test-request-id-123"


@pytest.fixture
def mock_context():
    return MockContext()


@pytest.fixture
def mock_ssm():
    """Mock boto3 SSM client with default credentials."""
    with patch("secrets.get_ssm_client") as mock_client_getter:
        mock_client = MagicMock()
        mock_client_getter.return_value = mock_client
        
        def mock_get_parameter(Name, WithDecryption=True):
            if Name == "PushoverToken":
                return {"Parameter": {"Value": "user_token_123"}}
            elif Name == "PushoverUser":
                return {"Parameter": {"Value": "user_id_456"}}
            else:
                raise Exception(f"Unknown parameter: {Name}")
        
        mock_client.get_parameter.side_effect = mock_get_parameter
        mock_client.exceptions.ParameterNotFound = Exception
        yield mock_client


@pytest.fixture
def mock_requests():
    """Mock requests library for Pushover calls."""
    with patch("pushover_adapter.requests") as mock_req:
        yield mock_req


@pytest.fixture(autouse=True)
def setup_env():
    """Set up environment variables for each test."""
    clear_cache()
    os.environ["ALLOWED_SOURCES"] = "github-actions,terraform,cloudfront"
    os.environ["ALLOWED_EVENT_TYPES"] = "workflow.completed,apply.success,apply.failed,invalidation.complete"
    yield
    # Clean up
    clear_cache()
    os.environ.pop("ALLOWED_SOURCES", None)
    os.environ.pop("ALLOWED_EVENT_TYPES", None)


# Test 1: Valid request with mandatory fields only
def test_valid_request_mandatory_only(mock_context, mock_ssm, mock_requests):
    """Test valid request with all mandatory fields, no optional fields."""
    mock_response = MagicMock()
    mock_response.status_code = 200
    mock_response.json.return_value = {"status": 1, "request": "req-id-123"}
    mock_requests.post.return_value = mock_response
    
    event = {
        "httpMethod": "POST",
        "requestContext": {"http": {"method": "POST"}},
        "body": json.dumps({
            "source": "github-actions",
            "eventType": "workflow.completed",
            "message": "Deployment succeeded",
        }),
    }
    
    response = lambda_handler(event, mock_context)
    
    assert response["statusCode"] == 200
    body = json.loads(response["body"])
    assert body["accepted"] is True
    assert body["provider"] == "pushover"
    assert body["providerRequestId"] == "req-id-123"
    assert body["requestId"] == "test-request-id-123"


# Test 2: Valid request with optional fields
def test_valid_request_with_optional_fields(mock_context, mock_ssm, mock_requests):
    """Test valid request with optional fields included."""
    mock_response = MagicMock()
    mock_response.status_code = 200
    mock_response.json.return_value = {"status": 1, "request": "req-id-456"}
    mock_requests.post.return_value = mock_response
    
    event = {
        "httpMethod": "POST",
        "requestContext": {"http": {"method": "POST"}},
        "body": json.dumps({
            "source": "github-actions",
            "eventType": "workflow.completed",
            "message": "Deployment succeeded",
            "title": "GitHub Actions",
            "priority": 1,
            "url": "https://github.com/example/repo/actions/runs/123",
            "urlTitle": "View run",
            "metadata": {"repo": "example/repo", "workflow": "deploy"},
        }),
    }
    
    response = lambda_handler(event, mock_context)
    
    assert response["statusCode"] == 200
    body = json.loads(response["body"])
    assert body["accepted"] is True


# Test 3: Missing mandatory field (source)
def test_missing_mandatory_field_source(mock_context, mock_ssm, mock_requests):
    """Test request with missing 'source' field."""
    event = {
        "httpMethod": "POST",
        "requestContext": {"http": {"method": "POST"}},
        "body": json.dumps({
            "eventType": "workflow.completed",
            "message": "Deployment succeeded",
        }),
    }
    
    response = lambda_handler(event, mock_context)
    
    assert response["statusCode"] == 400
    body = json.loads(response["body"])
    assert body["accepted"] is False
    assert body["error"]["code"] == "validation_error"
    assert "source" in body["error"]["message"].lower()


# Test 4: Missing mandatory field (message)
def test_missing_mandatory_field_message(mock_context, mock_ssm, mock_requests):
    """Test request with missing 'message' field."""
    event = {
        "httpMethod": "POST",
        "requestContext": {"http": {"method": "POST"}},
        "body": json.dumps({
            "source": "github-actions",
            "eventType": "workflow.completed",
        }),
    }
    
    response = lambda_handler(event, mock_context)
    
    assert response["statusCode"] == 400
    body = json.loads(response["body"])
    assert body["accepted"] is False
    assert body["error"]["code"] == "validation_error"


# Test 5: Message too long (exceeds 1024 chars)
def test_message_exceeds_max_length(mock_context, mock_ssm, mock_requests):
    """Test request with message longer than 1024 characters."""
    event = {
        "httpMethod": "POST",
        "requestContext": {"http": {"method": "POST"}},
        "body": json.dumps({
            "source": "github-actions",
            "eventType": "workflow.completed",
            "message": "x" * 1025,
        }),
    }
    
    response = lambda_handler(event, mock_context)
    
    assert response["statusCode"] == 400
    body = json.loads(response["body"])
    assert body["error"]["code"] == "validation_error"
    assert "1024" in body["error"]["message"]


# Test 6: Title exceeds max length (250 chars)
def test_title_exceeds_max_length(mock_context, mock_ssm, mock_requests):
    """Test request with title longer than 250 characters."""
    event = {
        "httpMethod": "POST",
        "requestContext": {"http": {"method": "POST"}},
        "body": json.dumps({
            "source": "github-actions",
            "eventType": "workflow.completed",
            "message": "Test",
            "title": "x" * 251,
        }),
    }
    
    response = lambda_handler(event, mock_context)
    
    assert response["statusCode"] == 400
    body = json.loads(response["body"])
    assert body["error"]["code"] == "validation_error"


# Test 7: Invalid source (not in allow-list)
def test_invalid_source(mock_context, mock_ssm, mock_requests):
    """Test request with source not in allow-list."""
    event = {
        "httpMethod": "POST",
        "requestContext": {"http": {"method": "POST"}},
        "body": json.dumps({
            "source": "invalid-source",
            "eventType": "workflow.completed",
            "message": "Test",
        }),
    }
    
    response = lambda_handler(event, mock_context)
    
    assert response["statusCode"] == 400
    body = json.loads(response["body"])
    assert "allowed" in body["error"]["message"].lower()


# Test 8: HTML and monospace conflict
def test_html_and_monospace_conflict(mock_context, mock_ssm, mock_requests):
    """Test request with both html=true and monospace=true."""
    event = {
        "httpMethod": "POST",
        "requestContext": {"http": {"method": "POST"}},
        "body": json.dumps({
            "source": "github-actions",
            "eventType": "workflow.completed",
            "message": "Test",
            "html": True,
            "monospace": True,
        }),
    }
    
    response = lambda_handler(event, mock_context)
    
    assert response["statusCode"] == 400
    body = json.loads(response["body"])
    assert "both html and monospace" in body["error"]["message"].lower()


# Test 9: Priority 2 (emergency) without retry/expire
def test_priority_2_missing_retry(mock_context, mock_ssm, mock_requests):
    """Test emergency priority without required retry field."""
    event = {
        "httpMethod": "POST",
        "requestContext": {"http": {"method": "POST"}},
        "body": json.dumps({
            "source": "github-actions",
            "eventType": "workflow.completed",
            "message": "Test",
            "priority": 2,
            "expire": 3600,
        }),
    }
    
    response = lambda_handler(event, mock_context)
    
    assert response["statusCode"] == 400
    body = json.loads(response["body"])
    assert "retry" in body["error"]["message"].lower()


# Test 10: Priority 2 valid with retry and expire
def test_priority_2_valid(mock_context, mock_ssm, mock_requests):
    """Test emergency priority with required retry and expire fields."""
    mock_response = MagicMock()
    mock_response.status_code = 200
    mock_response.json.return_value = {"status": 1, "request": "req-id-789", "receipt": "receipt-123"}
    mock_requests.post.return_value = mock_response
    
    event = {
        "httpMethod": "POST",
        "requestContext": {"http": {"method": "POST"}},
        "body": json.dumps({
            "source": "github-actions",
            "eventType": "workflow.completed",
            "message": "Emergency",
            "priority": 2,
            "retry": 60,
            "expire": 3600,
        }),
    }
    
    response = lambda_handler(event, mock_context)
    
    assert response["statusCode"] == 200
    body = json.loads(response["body"])
    assert body["accepted"] is True
    assert body["providerReceipt"] == "receipt-123"


# Test 11: applicationToken override (valid token format)
def test_application_token_override(mock_context, mock_ssm, mock_requests):
    """Test request with valid applicationToken override."""
    mock_response = MagicMock()
    mock_response.status_code = 200
    mock_response.json.return_value = {"status": 1, "request": "req-id-override"}
    mock_requests.post.return_value = mock_response
    
    event = {
        "httpMethod": "POST",
        "requestContext": {"http": {"method": "POST"}},
        "body": json.dumps({
            "source": "github-actions",
            "eventType": "workflow.completed",
            "message": "Test",
            "applicationToken": "custom_token_abc123",
        }),
    }
    
    response = lambda_handler(event, mock_context)
    
    assert response["statusCode"] == 200
    body = json.loads(response["body"])
    assert body["accepted"] is True


# Test 12: applicationToken with invalid characters
def test_application_token_invalid_chars(mock_context, mock_ssm, mock_requests):
    """Test request with applicationToken containing invalid characters."""
    event = {
        "httpMethod": "POST",
        "requestContext": {"http": {"method": "POST"}},
        "body": json.dumps({
            "source": "github-actions",
            "eventType": "workflow.completed",
            "message": "Test",
            "applicationToken": "invalid token!@#",
        }),
    }
    
    response = lambda_handler(event, mock_context)
    
    assert response["statusCode"] == 400
    body = json.loads(response["body"])
    assert "applicationToken" in body["error"]["message"]


# Test 13: applicationToken too long
def test_application_token_too_long(mock_context, mock_ssm, mock_requests):
    """Test request with applicationToken longer than 100 characters."""
    event = {
        "httpMethod": "POST",
        "requestContext": {"http": {"method": "POST"}},
        "body": json.dumps({
            "source": "github-actions",
            "eventType": "workflow.completed",
            "message": "Test",
            "applicationToken": "x" * 101,
        }),
    }
    
    response = lambda_handler(event, mock_context)
    
    assert response["statusCode"] == 400
    body = json.loads(response["body"])
    assert "applicationToken" in body["error"]["message"]


# Test 14: Metadata with sensitive key (should reject)
def test_metadata_with_sensitive_key(mock_context, mock_ssm, mock_requests):
    """Test request with sensitive keys in metadata."""
    event = {
        "httpMethod": "POST",
        "requestContext": {"http": {"method": "POST"}},
        "body": json.dumps({
            "source": "github-actions",
            "eventType": "workflow.completed",
            "message": "Test",
            "metadata": {"password": "secret123"},
        }),
    }
    
    response = lambda_handler(event, mock_context)
    
    assert response["statusCode"] == 400
    body = json.loads(response["body"])
    assert "password" in body["error"]["message"].lower()


# Test 15: SSM parameter read failure
def test_ssm_parameter_not_found(mock_context, mock_requests):
    """Test request when SSM parameter is not found."""
    with patch("secrets.get_ssm_client") as mock_client_getter:
        mock_client = MagicMock()
        mock_client_getter.return_value = mock_client
        mock_client.get_parameter.side_effect = Exception("ParameterNotFound")
        mock_client.exceptions.ParameterNotFound = Exception
        
        event = {
            "httpMethod": "POST",
            "requestContext": {"http": {"method": "POST"}},
            "body": json.dumps({
                "source": "github-actions",
                "eventType": "workflow.completed",
                "message": "Test",
            }),
        }
        
        response = lambda_handler(event, mock_context)
        
        assert response["statusCode"] == 502
        body = json.loads(response["body"])
        assert body["error"]["code"] == "provider_error"


# Test 16: Pushover 400 error (validation error)
def test_pushover_400_validation_error(mock_context, mock_ssm, mock_requests):
    """Test response when Pushover returns 400 validation error."""
    mock_response = MagicMock()
    mock_response.status_code = 400
    mock_response.json.return_value = {"status": 0, "errors": ["invalid message"]}
    mock_requests.post.return_value = mock_response
    
    event = {
        "httpMethod": "POST",
        "requestContext": {"http": {"method": "POST"}},
        "body": json.dumps({
            "source": "github-actions",
            "eventType": "workflow.completed",
            "message": "Test",
        }),
    }
    
    response = lambda_handler(event, mock_context)
    
    assert response["statusCode"] == 400
    body = json.loads(response["body"])
    assert body["error"]["code"] == "validation_error"


# Test 17: Pushover 401 error (auth error)
def test_pushover_401_auth_error(mock_context, mock_ssm, mock_requests):
    """Test response when Pushover returns 401 auth error."""
    mock_response = MagicMock()
    mock_response.status_code = 401
    mock_response.json.return_value = {"status": 0, "errors": ["invalid token"]}
    mock_requests.post.return_value = mock_response
    
    event = {
        "httpMethod": "POST",
        "requestContext": {"http": {"method": "POST"}},
        "body": json.dumps({
            "source": "github-actions",
            "eventType": "workflow.completed",
            "message": "Test",
        }),
    }
    
    response = lambda_handler(event, mock_context)
    
    assert response["statusCode"] == 401
    body = json.loads(response["body"])
    assert body["error"]["code"] == "auth_error"


# Test 18: Pushover 429 (throttled) with retry
def test_pushover_429_with_retry(mock_context, mock_ssm, mock_requests):
    """Test Pushover 429 error with retry logic (first fails, second succeeds)."""
    # First call returns 429, second returns 200
    mock_response_429 = MagicMock()
    mock_response_429.status_code = 429
    
    mock_response_200 = MagicMock()
    mock_response_200.status_code = 200
    mock_response_200.json.return_value = {"status": 1, "request": "req-id-retry"}
    
    mock_requests.post.side_effect = [mock_response_429, mock_response_200]
    
    event = {
        "httpMethod": "POST",
        "requestContext": {"http": {"method": "POST"}},
        "body": json.dumps({
            "source": "github-actions",
            "eventType": "workflow.completed",
            "message": "Test",
        }),
    }
    
    response = lambda_handler(event, mock_context)
    
    assert response["statusCode"] == 200
    body = json.loads(response["body"])
    assert body["accepted"] is True
    assert mock_requests.post.call_count == 2


# Test 19: Pushover 500 error with retry
def test_pushover_500_with_retry(mock_context, mock_ssm, mock_requests):
    """Test Pushover 500 error with retry logic."""
    mock_response_500 = MagicMock()
    mock_response_500.status_code = 500
    
    mock_response_200 = MagicMock()
    mock_response_200.status_code = 200
    mock_response_200.json.return_value = {"status": 1, "request": "req-id-500"}
    
    mock_requests.post.side_effect = [mock_response_500, mock_response_200]
    
    event = {
        "httpMethod": "POST",
        "requestContext": {"http": {"method": "POST"}},
        "body": json.dumps({
            "source": "github-actions",
            "eventType": "workflow.completed",
            "message": "Test",
        }),
    }
    
    response = lambda_handler(event, mock_context)
    
    assert response["statusCode"] == 200
    body = json.loads(response["body"])
    assert body["accepted"] is True


# Test 20: Network timeout with retry
def test_pushover_timeout_with_retry(mock_context, mock_ssm, mock_requests):
    """Test Pushover timeout with retry logic."""
    import requests as requests_module
    
    mock_requests.post.side_effect = [
        requests_module.exceptions.Timeout(),
        MagicMock(status_code=200, json=MagicMock(return_value={"status": 1, "request": "req-id-timeout"}))
    ]
    
    event = {
        "httpMethod": "POST",
        "requestContext": {"http": {"method": "POST"}},
        "body": json.dumps({
            "source": "github-actions",
            "eventType": "workflow.completed",
            "message": "Test",
        }),
    }
    
    response = lambda_handler(event, mock_context)
    
    assert response["statusCode"] == 200
    body = json.loads(response["body"])
    assert body["accepted"] is True


# Test 21: Invalid HTTP method (GET)
def test_invalid_http_method(mock_context, mock_ssm, mock_requests):
    """Test request with invalid HTTP method."""
    event = {
        "httpMethod": "GET",
        "requestContext": {"http": {"method": "GET"}},
        "body": json.dumps({
            "source": "github-actions",
            "eventType": "workflow.completed",
            "message": "Test",
        }),
    }
    
    response = lambda_handler(event, mock_context)
    
    assert response["statusCode"] == 405
    body = json.loads(response["body"])
    assert body["error"]["code"] == "method_not_allowed"


# Test 22: Invalid JSON in body
def test_invalid_json_in_body(mock_context, mock_ssm, mock_requests):
    """Test request with malformed JSON."""
    event = {
        "httpMethod": "POST",
        "requestContext": {"http": {"method": "POST"}},
        "body": "{invalid json",
    }
    
    response = lambda_handler(event, mock_context)
    
    assert response["statusCode"] == 400
    body = json.loads(response["body"])
    assert body["error"]["code"] == "validation_error"


# Test 23: Request with dedupeKey
def test_request_with_dedupe_key(mock_context, mock_ssm, mock_requests):
    """Test request with dedupeKey for idempotency."""
    mock_response = MagicMock()
    mock_response.status_code = 200
    mock_response.json.return_value = {"status": 1, "request": "req-id-dedupe"}
    mock_requests.post.return_value = mock_response
    
    event = {
        "httpMethod": "POST",
        "requestContext": {"http": {"method": "POST"}},
        "body": json.dumps({
            "source": "github-actions",
            "eventType": "workflow.completed",
            "message": "Test",
            "dedupeKey": "unique-key-123",
        }),
    }
    
    response = lambda_handler(event, mock_context)
    
    assert response["statusCode"] == 200
    body = json.loads(response["body"])
    assert body["accepted"] is True


# Test 24: Request with timestamp field
def test_request_with_timestamp(mock_context, mock_ssm, mock_requests):
    """Test request with Unix timestamp."""
    mock_response = MagicMock()
    mock_response.status_code = 200
    mock_response.json.return_value = {"status": 1, "request": "req-id-timestamp"}
    mock_requests.post.return_value = mock_response
    
    event = {
        "httpMethod": "POST",
        "requestContext": {"http": {"method": "POST"}},
        "body": json.dumps({
            "source": "github-actions",
            "eventType": "workflow.completed",
            "message": "Test",
            "timestamp": 1609459200,
        }),
    }
    
    response = lambda_handler(event, mock_context)
    
    assert response["statusCode"] == 200
    body = json.loads(response["body"])
    assert body["accepted"] is True


# Test 25: Response includes requestId
def test_response_includes_request_id(mock_context, mock_ssm, mock_requests):
    """Test that response includes the AWS request ID."""
    mock_response = MagicMock()
    mock_response.status_code = 200
    mock_response.json.return_value = {"status": 1, "request": "req-id-final"}
    mock_requests.post.return_value = mock_response
    
    event = {
        "httpMethod": "POST",
        "requestContext": {"http": {"method": "POST"}},
        "body": json.dumps({
            "source": "github-actions",
            "eventType": "workflow.completed",
            "message": "Test",
        }),
    }
    
    response = lambda_handler(event, mock_context)
    
    body = json.loads(response["body"])
    assert body["requestId"] == "test-request-id-123"
