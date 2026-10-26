
import json
import os

import boto3
import redis

MOCK_VENDOR_FUNCTION_NAME = os.environ["MOCK_VENDOR_FUNCTION_NAME"]
_lambda_client = boto3.client("lambda")
REDIS_HOST = os.environ["REDIS_HOST"]
REDIS_PORT = int(os.environ.get("REDIS_PORT", "6379"))
REDIS_AUTH_TOKEN = os.environ["REDIS_AUTH_TOKEN"]

CACHE_TTL_SECONDS = int(os.environ.get("CACHE_TTL_SECONDS", "900"))

def handler(event, context):
    resp = _lambda_client.invoke(FunctionName=MOCK_VENDOR_FUNCTION_NAME, InvocationType="RequestResponse")
    outer = json.loads(resp["Payload"].read())
    payload = json.loads(outer["body"])

    devices = payload.get("devices", {})

    client = redis.Redis(
        host=REDIS_HOST,
        port=REDIS_PORT,
        password=REDIS_AUTH_TOKEN,
        ssl=True,
        socket_timeout=5,
    )
    pipe = client.pipeline()
    for device_cn, trusted in devices.items():
        pipe.set(f"device:{device_cn}", "1" if trusted else "0", ex=CACHE_TTL_SECONDS)
    pipe.execute()

    return {"synced": len(devices)}
