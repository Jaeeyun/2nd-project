
import boto3
import json
import os
import re
import time
from glob import glob
from typing import Optional

logs_client = boto3.client("logs", region_name=os.environ.get("AWS_REGION", "ap-northeast-2"))

STATE_FILE = os.environ.get("SHIPPER_STATE_FILE", "/var/lib/keycloak-login-shipper/offset")
LOG_GROUP_NAME = os.environ["LOG_GROUP_NAME"]

EVENT_TYPE_RE = re.compile(r'type="(LOGIN|LOGOUT|LOGIN_ERROR|LOGOUT_ERROR)"')
REALM_RE = re.compile(r'realmName="([^"]*)"')
USERNAME_RE = re.compile(r'username="([^"]*)"')
IP_RE = re.compile(r'ipAddress="([^"]*)"')

def _docker_log_file() -> Optional[str]:
    inspect = os.popen("docker inspect -f '{{.LogPath}}' keycloak 2>/dev/null").read().strip()
    if inspect and os.path.exists(inspect):
        return inspect
    candidates = glob("/var/lib/docker/containers/*/*-json.log")
    return candidates[0] if candidates else None

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

def _to_cwl_event(line: str, received_at_ms: int) -> Optional[dict]:
    type_match = EVENT_TYPE_RE.search(line)
    if not type_match:
        return None
    realm_match = REALM_RE.search(line)
    username_match = USERNAME_RE.search(line)
    ip_match = IP_RE.search(line)

    access_time = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(received_at_ms / 1000))
    record = {
        "log_type": "login_logout",
        "account": username_match.group(1) if username_match else "unknown",
        "access_time": access_time,
        "access_ip": ip_match.group(1) if ip_match else "unknown",
        "subject_processed": "N/A (인증 이벤트, 특정 레코드 접근 아님)",
        "action": type_match.group(1),
        "realm": realm_match.group(1) if realm_match else "unknown",
        "source": "keycloak-event-log",
    }
    return {"timestamp": received_at_ms, "message": json.dumps(record, ensure_ascii=False)}

def main():
    log_file = _docker_log_file()
    if not log_file:
        print("keycloak 컨테이너 로그 파일을 찾을 수 없음 - 이번 실행은 건너뜀")
        return

    offset = _read_offset()
    events = []
    with open(log_file) as f:
        f.seek(offset)
        for raw_line in f:
            raw_line = raw_line.strip()
            if not raw_line:
                continue

            try:
                wrapper = json.loads(raw_line)
                inner = wrapper.get("log", "")
            except json.JSONDecodeError:
                inner = raw_line
            event = _to_cwl_event(inner, int(time.time() * 1000))
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
