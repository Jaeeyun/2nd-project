import json
import time

import boto3

import config

_logs_client = boto3.client("logs", region_name=config.AWS_REGION)
_current_stream = None

def _ensure_stream() -> str:
    global _current_stream
    stream = time.strftime("%Y-%m-%d", time.gmtime())
    if stream != _current_stream:
        try:
            _logs_client.create_log_stream(logGroupName=config.DB_ACCESS_LOG_GROUP, logStreamName=stream)
        except _logs_client.exceptions.ResourceAlreadyExistsException:
            pass
        _current_stream = stream
    return stream

def record_db_access(account: str, action: str, subject: str, access_ip: str) -> None:

    if not config.DB_ACCESS_LOG_GROUP:
        return
    try:
        stream = _ensure_stream()
        record = {
            "log_type": "db_access",
            "account": account,
            "access_time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "access_ip": access_ip or "unknown",
            "subject_processed": subject,
            "action": action,
            "source": "employee-service-direct",
        }
        _logs_client.put_log_events(
            logGroupName=config.DB_ACCESS_LOG_GROUP,
            logStreamName=stream,
            logEvents=[
                {"timestamp": int(time.time() * 1000), "message": json.dumps(record, ensure_ascii=False)}
            ],
        )
    except Exception as exc:
        print(f"record_db_access 실패(요청은 계속 처리됨): {exc}")
