
import json
import os

import redis

REDIS_HOST = os.environ["REDIS_HOST"]
REDIS_PORT = int(os.environ.get("REDIS_PORT", "6379"))
REDIS_AUTH_TOKEN = os.environ["REDIS_AUTH_TOKEN"]
API_KEY = os.environ["API_KEY"]

_client = redis.Redis(
    host=REDIS_HOST,
    port=REDIS_PORT,
    password=REDIS_AUTH_TOKEN,
    ssl=True,
    socket_timeout=3,
)

def handler(event, context):

    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    if headers.get("x-api-key") != API_KEY:
        return {
            "statusCode": 403,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": "invalid or missing x-api-key"}),
        }

    device_cn = (event.get("queryStringParameters") or {}).get("device_cn", "")
    if not device_cn:
        return {
            "statusCode": 400,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": "device_cn query parameter required"}),
        }

    value = _client.get(f"device:{device_cn}")

    trusted = value is not None and value == b"1"

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"device_cn": device_cn, "trusted": trusted, "known": value is not None}),
    }
