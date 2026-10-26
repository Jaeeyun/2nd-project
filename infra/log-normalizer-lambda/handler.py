
import base64
import csv
import gzip
import io
import json
import os
import re
import time

import boto3

REGION = os.environ.get("AWS_REGION", "ap-northeast-2")
MODE = os.environ["MODE"]
DEST_LOG_GROUP = os.environ["DEST_LOG_GROUP"]

logs_client = boto3.client("logs", region_name=REGION)
ssm_client = boto3.client("ssm", region_name=REGION)

PGAUDIT_PREFIX_RE = re.compile(
    r"^(?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} UTC):"
    r"(?P<ip>[\d.]+)?\(\d+\):"
    r"(?P<account>[^@]+)@(?P<database>[^:]+):"
    r"\[\d+\]:LOG:\s+AUDIT: (?P<rest>.*)$",
    re.DOTALL,
)

def _write_dest(records_with_ts):
    if not records_with_ts:
        return 0
    stream_name = time.strftime("%Y-%m-%d", time.gmtime())
    try:
        logs_client.create_log_stream(logGroupName=DEST_LOG_GROUP, logStreamName=stream_name)
    except logs_client.exceptions.ResourceAlreadyExistsException:
        pass

    events = [
        {"timestamp": ts, "message": json.dumps(rec, ensure_ascii=False)}
        for ts, rec in sorted(records_with_ts, key=lambda x: x[0])
    ]

    logs_client.put_log_events(logGroupName=DEST_LOG_GROUP, logStreamName=stream_name, logEvents=events)
    return len(events)

QUERY_LITERAL_RE = re.compile(r"'(?:[^']|'')*'")

def _mask_query_literals(query: str) -> str:
    return QUERY_LITERAL_RE.sub("'***'", query)

def _pgaudit_to_record(line: str):
    m = PGAUDIT_PREFIX_RE.match(line)
    if not m:
        return None
    reader = csv.reader(io.StringIO(m.group("rest")))
    try:
        fields = next(reader)
    except StopIteration:
        return None
    if len(fields) < 9:
        return None
    _audit_type, _stmt_id, _substmt_id, _class, command, _object_type, object_name, query, _param = fields[:9]

    ts = m.group("ts").replace(" UTC", "")
    access_time = ts.replace(" ", "T") + "Z"
    clean_query = _mask_query_literals(" ".join(query.split()))

    db_role = m.group("account")

    return {
        "log_type": "db_access",
        "account": db_role,
        "db_role": db_role,
        "access_time": access_time,
        "access_ip": m.group("ip") or "unknown",
        "subject_processed": f"table:{object_name}",
        "action": command,
        "query": clean_query,
        "database": m.group("database"),
        "source": "rds-pgaudit",
    }

def handle_rds_pgaudit(event):
    payload = json.loads(gzip.decompress(base64.b64decode(event["awslogs"]["data"])))
    if payload.get("messageType") != "DATA":
        return {"written": 0}

    records = []
    for log_event in payload["logEvents"]:
        rec = _pgaudit_to_record(log_event["message"])
        if rec:
            records.append((log_event["timestamp"], rec))

    written = _write_dest(records)
    return {"written": written}

LAST_TS_PARAM = f"/{os.environ.get('PROJECT_PREFIX', 'ztna')}/eks-audit-normalizer/last-processed-ts"
SRC_EKS_LOG_GROUP = os.environ.get("SRC_EKS_LOG_GROUP", "")

def _get_last_ts(default_lookback_sec=600):
    try:
        resp = ssm_client.get_parameter(Name=LAST_TS_PARAM)
        return int(resp["Parameter"]["Value"])
    except ssm_client.exceptions.ParameterNotFound:
        return int(time.time() * 1000) - default_lookback_sec * 1000

def _set_last_ts(ts_ms: int):
    ssm_client.put_parameter(Name=LAST_TS_PARAM, Value=str(ts_ms), Type="String", Overwrite=True)

def _run_insights_query(log_group, query, start_ms, end_ms):
    query_id = logs_client.start_query(
        logGroupName=log_group,
        startTime=start_ms // 1000,
        endTime=end_ms // 1000,
        queryString=query,
    )["queryId"]

    for _ in range(25):
        time.sleep(2)
        result = logs_client.get_query_results(queryId=query_id)
        if result["status"] == "Complete":
            return result["results"]
        if result["status"] in ("Failed", "Cancelled", "Timeout"):
            raise RuntimeError(f"Logs Insights query {result['status']}: {query_id}")
    raise TimeoutError(f"Logs Insights query did not complete in time: {query_id}")

def _eks_audit_to_record(message: str, insights_ts_ms: int):
    audit = json.loads(message)
    user = audit.get("user", {})
    extra = user.get("extra", {})
    session_names = extra.get("sessionName", [])

    if not session_names or re.fullmatch(r"i-[0-9a-f]{8,}", session_names[0]):
        return None

    account = session_names[0]
    ref = audit.get("objectRef", {})
    status = audit.get("responseStatus", {})
    resource_desc = ref.get("resource", "unknown")
    if ref.get("name"):
        resource_desc += f"/{ref['name']}"

    received = audit.get("requestReceivedTimestamp")
    source_ips = audit.get("sourceIPs", [])

    return {
        "log_type": "operator_access",
        "account": account,
        "access_time": received or "unknown",
        "access_ip": source_ips[0] if source_ips else "unknown",
        "subject_processed": f"{resource_desc}" + (f" (ns:{ref['namespace']})" if ref.get("namespace") else ""),
        "action": audit.get("verb", "unknown"),
        "result": "ALLOW" if status.get("code", 0) < 400 else "DENY",
        "result_code": status.get("code"),
        "source": "eks-audit-log",
    }

def handle_eks_audit(_event):
    now_ms = int(time.time() * 1000)
    start_ms = _get_last_ts()
    if start_ms >= now_ms:
        return {"written": 0}

    rows = _run_insights_query(
        SRC_EKS_LOG_GROUP,
        'fields @timestamp, @message | filter ispresent(user.extra.sessionName.0) | sort @timestamp asc | limit 1000',
        start_ms, now_ms,
    )

    records = []
    max_ts_seen = start_ms
    for row in rows:
        fields = {f["field"]: f["value"] for f in row}
        rec = _eks_audit_to_record(fields["@message"], now_ms)
        if not rec:
            continue

        ts_struct = time.strptime(fields["@timestamp"].split(".")[0], "%Y-%m-%d %H:%M:%S")
        ts_ms = int(time.mktime(ts_struct)) * 1000
        records.append((ts_ms, rec))
        max_ts_seen = max(max_ts_seen, ts_ms + 1)

    written = _write_dest(records)
    _set_last_ts(max_ts_seen)
    return {"written": written, "window_start": start_ms, "window_end": now_ms}

def lambda_handler(event, context):
    if MODE == "rds_pgaudit":
        return handle_rds_pgaudit(event)
    elif MODE == "eks_audit":
        return handle_eks_audit(event)
    raise ValueError(f"unknown MODE={MODE}")
