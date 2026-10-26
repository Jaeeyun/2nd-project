
import boto3
import json
from typing import Optional
import os
import time

logs_client = boto3.client("logs", region_name=os.environ.get("AWS_REGION", "ap-northeast-2"))

LOG_FILE = os.environ.get("OPA_LOG_FILE", "/var/log/opa/opa.log")
STATE_FILE = os.environ.get("OPA_SHIPPER_STATE_FILE", "/var/lib/opa-shipper/offset")
LOG_GROUP_NAME = os.environ["LOG_GROUP_NAME"]

def _read_offset() -> int:
    try:
        with open(STATE_FILE) as f:
            return int(f.read().strip())
    except (FileNotFoundError, ValueError):
        return 0

def _write_offset(offset: int):
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    with open(STATE_FILE, "w") as f:
        f.write(str(offset))

def _is_decision_log(entry: dict) -> bool:

    return "decision_id" in entry

def _to_cwl_event(entry: dict) -> Optional[dict]:

    result = entry.get("result")
    ip = entry.get("input", {}).get("source_ip", "unknown")
    username = entry.get("input", {}).get("username", "unknown")
    mfa = entry.get("input", {}).get("mfa_configured")
    decision = "ALLOW" if result is True else "DENY"
    summary = (
        f"{decision} | User: {username} | IP: {ip} | MFA: {mfa} "
        f"| DecisionID: {entry.get('decision_id')} | At: {entry.get('timestamp', '')}"
    )
    ts_ms = int(time.time() * 1000)
    return {"timestamp": ts_ms, "message": json.dumps({"decision_id": entry.get("decision_id"), "summary": summary})}

def main():
    if not os.path.exists(LOG_FILE):
        print(f"{LOG_FILE} 없음 - OPA가 아직 결정 로그를 안 남겼을 수 있음, 이번 실행은 건너뜀")
        return

    offset = _read_offset()
    events = []
    with open(LOG_FILE) as f:
        f.seek(offset)
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            if _is_decision_log(entry):
                event = _to_cwl_event(entry)
                if event:
                    events.append(event)
        new_offset = f.tell()

    if not events:
        _write_offset(new_offset)
        return

    log_stream = time.strftime("%Y-%m-%d", time.gmtime())
    try:
        logs_client.create_log_stream(logGroupName=LOG_GROUP_NAME, logStreamName=log_stream)
    except logs_client.exceptions.ResourceAlreadyExistsException:
        pass

    events.sort(key=lambda e: e["timestamp"])
    logs_client.put_log_events(logGroupName=LOG_GROUP_NAME, logStreamName=log_stream, logEvents=events)
    _write_offset(new_offset)
    print(f"{len(events)}건 전송 완료 (offset {offset} -> {new_offset})")

if __name__ == "__main__":
    main()
