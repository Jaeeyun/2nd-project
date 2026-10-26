
import json

MOCK_DEVICES = {
    "device-uuid-demo-0001": True,

    "chulsoo.kim@company.com": True,
    "younghee.lee@company.com": True,
    "gildong.hong@company.com": True,
    "minsu.park@company.com": True,
}

def handler(event, context):
    body = json.dumps({"devices": MOCK_DEVICES})
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": body,
    }
