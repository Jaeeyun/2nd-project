
import json

def handler(event, context):
    headers = event.get("headers", {})

    pomerium_headers = {k: v for k, v in headers.items() if k.lower().startswith("x-pomerium")}

    body = {
        "message": "mTLS ALB 뒤 echo 백엔드에 도달했습니다.",
        "pomerium_headers": pomerium_headers,
        "all_headers": headers,
        "path": event.get("path", "/"),
        "method": event.get("httpMethod", "GET"),
    }

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body, ensure_ascii=False, indent=2),
    }
