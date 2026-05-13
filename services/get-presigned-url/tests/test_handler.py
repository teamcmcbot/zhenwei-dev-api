import importlib.util
import json
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

HANDLER_PATH = Path(__file__).resolve().parents[1] / "src" / "handler.py"
spec = importlib.util.spec_from_file_location("get_presigned_url_handler", HANDLER_PATH)
handler = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = handler
spec.loader.exec_module(handler)


class FakeContext:
    aws_request_id = "test-request-id"


class FakeS3Client:
    def __init__(self):
        self.calls = []

    def generate_presigned_url(self, **kwargs):
        self.calls.append(kwargs)
        return "https://signed.example.test/object"


class HandlerTests(unittest.TestCase):
    def setUp(self):
        self.fake_s3 = FakeS3Client()
        handler.S3_CLIENT = self.fake_s3
        self.env = {
            "PRIVATE_BUCKET_NAME": "private-bucket",
            "ALLOWED_OBJECT_KEYS": "exact/zhenwei-seo-cv.pdf",
            "ALLOWED_OBJECT_PREFIXES": "private-downloads/",
            "DEFAULT_PRESIGNED_URL_EXPIRES_SECONDS": "300",
            "MAX_PRESIGNED_URL_EXPIRES_SECONDS": "900",
            "ALLOWED_ORIGINS": "https://zhenwei.dev,https://www.zhenwei.dev",
            "LOG_LEVEL": "CRITICAL",
        }
        self.env_patcher = patch.dict(os.environ, self.env, clear=False)
        self.env_patcher.start()

    def tearDown(self):
        self.env_patcher.stop()
        handler.S3_CLIENT = None

    def event(self, body, method="POST", origin="https://zhenwei.dev"):
        return {
            "requestContext": {
                "requestId": "api-request-id",
                "http": {"method": method},
            },
            "headers": {"origin": origin} if origin else {},
            "body": json.dumps(body) if body is not None else None,
            "isBase64Encoded": False,
        }

    def test_generates_presigned_url_for_exact_allowed_key(self):
        response = handler.lambda_handler(
            self.event(
                {
                    "objectKey": "exact/zhenwei-seo-cv.pdf",
                    "expiresInSeconds": 600,
                    "contentDispositionFileName": "zhenwei-seo-cv.pdf",
                }
            ),
            FakeContext(),
        )

        payload = json.loads(response["body"])
        self.assertEqual(response["statusCode"], 200)
        self.assertEqual(response["headers"]["Access-Control-Allow-Origin"], "https://zhenwei.dev")
        self.assertEqual(payload["url"], "https://signed.example.test/object")
        self.assertEqual(payload["bucketName"], "private-bucket")
        self.assertEqual(payload["objectKey"], "exact/zhenwei-seo-cv.pdf")
        self.assertEqual(payload["fileName"], "zhenwei-seo-cv.pdf")
        self.assertEqual(payload["expiresIn"], 600)
        self.assertEqual(self.fake_s3.calls[0]["ExpiresIn"], 600)
        self.assertEqual(
            self.fake_s3.calls[0]["Params"],
            {
                "Bucket": "private-bucket",
                "Key": "exact/zhenwei-seo-cv.pdf",
                "ResponseContentDisposition": 'attachment; filename="zhenwei-seo-cv.pdf"',
            },
        )

    def test_caps_expiry_to_configured_maximum(self):
        response = handler.lambda_handler(
            self.event({"objectKey": "private-downloads/resume/zhenwei-seo-cv.pdf", "expiresInSeconds": 9999}),
            FakeContext(),
        )

        payload = json.loads(response["body"])
        self.assertEqual(response["statusCode"], 200)
        self.assertEqual(payload["expiresIn"], 900)
        self.assertEqual(self.fake_s3.calls[0]["ExpiresIn"], 900)

    def test_allows_configured_prefix(self):
        response = handler.lambda_handler(
            self.event({"objectKey": "private-downloads/example.pdf"}),
            FakeContext(),
        )

        self.assertEqual(response["statusCode"], 200)
        self.assertEqual(self.fake_s3.calls[0]["Params"]["Key"], "private-downloads/example.pdf")

    def test_rejects_unapproved_key(self):
        response = handler.lambda_handler(
            self.event({"objectKey": "secrets/private.pdf"}),
            FakeContext(),
        )

        payload = json.loads(response["body"])
        self.assertEqual(response["statusCode"], 403)
        self.assertEqual(payload["error"]["code"], "forbidden")
        self.assertEqual(self.fake_s3.calls, [])

    def test_rejects_path_traversal_key(self):
        response = handler.lambda_handler(
            self.event({"objectKey": "resume/../secret.pdf"}),
            FakeContext(),
        )

        payload = json.loads(response["body"])
        self.assertEqual(response["statusCode"], 400)
        self.assertEqual(payload["error"]["code"], "invalid_request")
        self.assertEqual(self.fake_s3.calls, [])

    def test_rejects_disallowed_origin(self):
        response = handler.lambda_handler(
            self.event({"objectKey": "private-downloads/resume/zhenwei-seo-cv.pdf"}, origin="https://evil.example"),
            FakeContext(),
        )

        self.assertEqual(response["statusCode"], 403)
        self.assertNotIn("Access-Control-Allow-Origin", response["headers"])
        self.assertEqual(self.fake_s3.calls, [])

    def test_handles_cors_preflight(self):
        response = handler.lambda_handler(self.event(None, method="OPTIONS"), FakeContext())

        self.assertEqual(response["statusCode"], 204)
        self.assertEqual(response["body"], "")
        self.assertEqual(response["headers"]["Access-Control-Allow-Origin"], "https://zhenwei.dev")
        self.assertEqual(self.fake_s3.calls, [])


if __name__ == "__main__":
    unittest.main()
