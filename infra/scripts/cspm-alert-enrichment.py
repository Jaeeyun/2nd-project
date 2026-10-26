
import json
import os
import time
import urllib.parse
import urllib.request
import boto3

cloudtrail = boto3.client("cloudtrail")
dynamodb = boto3.client("dynamodb")
secrets_client = boto3.client("secretsmanager")
logs_client = boto3.client("logs")
bedrock = boto3.client("bedrock-runtime")

DEDUP_TABLE_NAME = os.environ["DEDUP_TABLE_NAME"]
SLACK_SECRET_ARN = os.environ["SLACK_SECRET_ARN"]
SLACK_CHANNEL = os.environ["SLACK_CHANNEL"]
AWS_ACCOUNT_ID = os.environ["AWS_ACCOUNT_ID"]
AWS_REGION = os.environ["AWS_REGION"]
DEDUP_TTL_HOURS = int(os.environ.get("DEDUP_TTL_HOURS", "24"))
CLOUDTRAIL_LOOKBACK_HOURS = int(os.environ.get("CLOUDTRAIL_LOOKBACK_HOURS", "48"))
CSPM_EXCEPTION_LOG_GROUP = os.environ["CSPM_EXCEPTION_LOG_GROUP"]

BEDROCK_MODEL_ID = os.environ.get("BEDROCK_MODEL_ID", "anthropic.claude-3-haiku-20240307-v1:0")
BEDROCK_MAX_TOKENS = int(os.environ.get("BEDROCK_MAX_TOKENS", "300"))
BEDROCK_DAILY_CAP = int(os.environ.get("BEDROCK_DAILY_CAP", "50"))

_SEVERITY_EMOJI = {"CRITICAL": "🔴", "HIGH": "🟠"}

def _get_bot_token() -> str:
    secret = secrets_client.get_secret_value(SecretId=SLACK_SECRET_ARN)
    return json.loads(secret["SecretString"])["bot_token"]

def _is_duplicate(finding_id: str) -> bool:
    now = int(time.time())
    resp = dynamodb.get_item(
        TableName=DEDUP_TABLE_NAME,
        Key={"finding_id": {"S": finding_id}},
    )
    item = resp.get("Item")
    if item and int(item["expires_at"]["N"]) > now:
        return True

    dynamodb.put_item(
        TableName=DEDUP_TABLE_NAME,
        Item={
            "finding_id": {"S": finding_id},
            "expires_at": {"N": str(now + DEDUP_TTL_HOURS * 3600)},
            "sent_at": {"N": str(now)},
        },
    )
    return False

def _bedrock_cap_exceeded() -> bool:
    usage_key = f"BEDROCK_USAGE#{time.strftime('%Y-%m-%d', time.gmtime())}"
    try:
        resp = dynamodb.update_item(
            TableName=DEDUP_TABLE_NAME,
            Key={"finding_id": {"S": usage_key}},
            UpdateExpression="ADD invocation_count :inc",
            ExpressionAttributeValues={":inc": {"N": "1"}},
            ReturnValues="UPDATED_NEW",
        )
        count = int(resp["Attributes"]["invocation_count"]["N"])
    except Exception as exc:
        print(json.dumps({"warning": "bedrock cap check failed, treating as exceeded", "error": str(exc)}))
        return True

    return count > BEDROCK_DAILY_CAP

def _extract_resource_name(resource: dict) -> str:
    resource_id = resource.get("Id", "")
    if resource_id.startswith("arn:"):
        return resource_id.rsplit(":", 1)[-1].rsplit("/", 1)[-1]
    return resource_id

def _lookup_actor(resource_name: str) -> dict | None:
    if not resource_name:
        return None
    end_time = time.time()
    start_time = end_time - CLOUDTRAIL_LOOKBACK_HOURS * 3600
    try:
        resp = cloudtrail.lookup_events(
            LookupAttributes=[{"AttributeKey": "ResourceName", "AttributeValue": resource_name}],
            StartTime=start_time,
            EndTime=end_time,
            MaxResults=1,
        )
    except Exception as exc:
        return {"error": str(exc)}

    events = resp.get("Events", [])
    if not events:
        return None

    event = events[0]
    raw = json.loads(event.get("CloudTrailEvent", "{}"))
    user_identity = raw.get("userIdentity", {})
    actor = user_identity.get("arn") or user_identity.get("principalId") or user_identity.get("type", "unknown")
    return {
        "actor": actor,
        "source_ip": raw.get("sourceIPAddress", "unknown"),
        "event_name": event.get("EventName", "unknown"),
        "event_time": event.get("EventTime").isoformat() if hasattr(event.get("EventTime"), "isoformat") else str(event.get("EventTime")),
    }

def _build_logs_insights_query(resource_name: str) -> str:
    return (
        "fields @timestamp, userIdentity.arn, sourceIPAddress, eventName, requestParameters\n"
        f"| filter @message like /{resource_name}/\n"
        "| sort @timestamp desc\n"
        "| limit 20"
    )

CLOUDTRAIL_LOG_SCHEMA_FIELDS = [
    "@timestamp", "@message",
    "eventName", "eventTime", "eventSource", "awsRegion",
    "userIdentity.arn", "userIdentity.principalId", "userIdentity.type",
    "sourceIPAddress", "requestParameters", "responseElements",
]

def _build_bedrock_prompt(resource_name: str, finding: dict) -> str:
    title = finding.get("Title", "")
    severity = finding.get("Severity", {}).get("Label", "")
    resource_type = finding.get("Resources", [{}])[0].get("Type", "unknown")
    schema_list = ", ".join(CLOUDTRAIL_LOG_SCHEMA_FIELDS)
    example = _build_logs_insights_query(resource_name)
    return (
        "당신은 AWS 보안 담당자를 돕는 조사 보조 도구입니다.\n"
        "아래 Security Hub finding에 대해 CloudWatch Logs Insights 쿼리를 작성하세요.\n\n"
        f"- Finding 제목: {title}\n"
        f"- 심각도: {severity}\n"
        f"- 리소스 이름: {resource_name}\n"
        f"- 리소스 타입: {resource_type}\n\n"
        "중요 — 대상 로그 그룹:\n"
        "이 쿼리는 VPC Flow Logs가 아니라 **AWS CloudTrail 관리 이벤트**가 적재된\n"
        "로그 그룹을 대상으로 합니다. 로그 한 건은 '누가(userIdentity) 언제(eventTime)\n"
        "어떤 API를(eventName) 어디서(sourceIPAddress) 호출했는가'를 기록한 것이지,\n"
        "네트워크 트래픽 허용/차단(ALLOW/REJECT) 기록이 아닙니다.\n"
        f"사용 가능한 필드는 다음뿐입니다: {schema_list}\n"
        "이 목록에 없는 필드(예: resourceId)는 존재하지 않습니다. 만들어내지 마세요.\n\n"
        "예시 A (기본형 - 리소스 이름만으로 필터):\n"
        f"{example}\n\n"
        "예시 B (조건을 좁힌 경우 - 리소스 이름/이벤트명은 예시용이며 실제 값이 아닙니다):\n"
        "fields @timestamp, eventName, userIdentity.arn\n"
        "| filter @message like /i-0123456789abcdef0/ and @message like /RunInstances/\n"
        "| sort @timestamp desc\n"
        "| limit 15\n\n"
        "위 두 예시는 형식과 필터링 패턴(항상 @message 기준)을 보여주는 참고용일 뿐입니다.\n"
        "그대로 베끼지 말고, 이번 finding의 실제 내용(Finding 제목에 나온 구체적 조건 -\n"
        "예: 포트 번호, CIDR, 프로토콜 등)을 반영해 예시 B처럼 조건을 좁혀서 쓰세요.\n\n"
        "규칙:\n"
        "1. 위 필드 목록에 있는 필드만 사용하세요.\n"
        "2. filter 조건에 리소스 이름을 반드시 포함하세요.\n"
        "3. filter 조건은 반드시 @message 기준으로 like 매칭하세요 (예: filter @message like\n"
        "   /패턴/). requestParameters처럼 중첩된 JSON 필드는 CWLI가 filter 대상으로 제대로\n"
        "   추출하지 못해 항상 0건이 됩니다 - fields에 표시용으로 넣는 건 괜찮지만 filter\n"
        "   조건에는 절대 쓰지 마세요.\n"
        "4. 조사 목적이므로 limit은 10~30 사이로 하세요.\n"
        "5. 설명 문장 없이 CWLI 쿼리 구문만 출력하세요. 코드블록(```)도 붙이지 마세요.\n"
        "6. 조건을 좁힐 때 JSON 키 이름을 추측해서 key:value 형태(예: /\"FromPort\":22/,\n"
        "   /CIDR='0.0.0.0\\/0'/)로 만들지 마세요. 실제 키 철자/케이싱을 모르면 틀린\n"
        "   추측이 되어 0건이 됩니다. 대신 값 자체만 단독으로 @message like /값/ 형태로\n"
        "   검색하세요 (예: @message like /0.0.0.0\\/0/, @message like /22/)."
    )

import re as _re

_CWLI_KEYWORDS = {
    "fields", "filter", "sort", "limit", "stats", "by", "desc", "asc",
    "and", "or", "not", "like", "in", "as", "dedup", "parse",

    "count", "sum", "avg", "min", "max", "distinct_count",
    "earliest", "latest", "ispresent", "isblank", "isempty",
    "abs", "ceil", "floor", "sqrt", "log", "log10", "greatest", "least",
    "coalesce", "concat", "strlen", "substr", "replace", "strcontains",
    "toupper", "tolower", "trim", "ltrim", "rtrim",
    "bin", "datefloor", "fromMillis", "toMillis", "todynamic",
}

def _query_uses_unknown_fields(query_text: str) -> bool:
    cleaned = _re.sub(r"'[^']*'", " ", query_text)
    cleaned = _re.sub(r'"[^"]*"', " ", cleaned)
    cleaned = _re.sub(r"/[^/\n]*/", " ", cleaned)

    tokens = _re.findall(r"[@a-zA-Z_][a-zA-Z0-9_.]*", cleaned)
    for token in tokens:
        if token.lower() in _CWLI_KEYWORDS:
            continue
        base = token.split(".")[0]
        if any(base == f.split(".")[0] for f in CLOUDTRAIL_LOG_SCHEMA_FIELDS):
            continue
        return True
    return False

def _generate_logs_query(resource_name: str, finding: dict) -> tuple[str, str]:
    fallback_query = _build_logs_insights_query(resource_name)

    if _bedrock_cap_exceeded():
        return fallback_query, "fallback_cap_exceeded"

    try:
        response = bedrock.invoke_model(
            modelId=BEDROCK_MODEL_ID,
            body=json.dumps({
                "anthropic_version": "bedrock-2023-05-31",
                "max_tokens": BEDROCK_MAX_TOKENS,
                "messages": [{"role": "user", "content": _build_bedrock_prompt(resource_name, finding)}],
            }),
        )
        result = json.loads(response["body"].read())
        query_text = result["content"][0]["text"].strip()
        if not query_text:
            raise ValueError("empty response from bedrock")
        if _query_uses_unknown_fields(query_text):
            print(json.dumps({"warning": "bedrock query references unknown fields, falling back", "query": query_text}))
            return fallback_query, "fallback_unknown_fields"
        return query_text, "bedrock"
    except Exception as exc:
        print(json.dumps({"warning": "bedrock query generation failed, falling back", "error": str(exc)}))
        return fallback_query, f"fallback_error:{type(exc).__name__}"

def _security_hub_deep_link(finding_id: str, product_arn: str) -> str:
    selected = f"{product_arn}/{finding_id}"
    encoded = urllib.parse.quote(selected, safe="")
    return (
        f"https://{AWS_REGION}.console.aws.amazon.com/securityhub/home?region={AWS_REGION}"
        f"#/findings?selectedFindingId={encoded}"
    )

def _post_to_slack(bot_token: str, finding: dict, actor: dict | None, logs_query: str, deep_link: str, resource_name: str, query_source: str = "fallback"):
    severity_label = finding.get("Severity", {}).get("Label", "UNKNOWN")
    emoji = _SEVERITY_EMOJI.get(severity_label, "⚪")
    title = finding.get("Title", "(제목 없음)")
    resources = finding.get("Resources", [{}])
    resource_type = resources[0].get("Type", "unknown") if resources else "unknown"
    account_id = finding.get("AwsAccountId", AWS_ACCOUNT_ID)
    region = finding.get("Region", AWS_REGION)
    compliance_status = finding.get("Compliance", {}).get("Status", "unknown")

    if actor and "error" not in actor:
        actor_text = (
            f"*변경자:* `{actor['actor']}`\n"
            f"*발신 IP:* `{actor['source_ip']}`\n"
            f"*조치:* `{actor['event_name']}` (`{actor['event_time']}`)"
        )
    elif actor and "error" in actor:
        actor_text = f"CloudTrail 조회 실패: {actor['error']}"
    else:
        actor_text = f"최근 {CLOUDTRAIL_LOOKBACK_HOURS}시간 내 CloudTrail 이벤트 없음 (오래된 리소스이거나 이름 매칭 실패)"

    payload = {
        "blocks": [
            {
                "type": "header",
                "text": {"type": "plain_text", "text": f"{emoji} [{severity_label}] {title}"},
            },
            {
                "type": "section",
                "fields": [
                    {"type": "mrkdwn", "text": f"*리소스 타입:*\n{resource_type}"},
                    {"type": "mrkdwn", "text": f"*리소스 이름:*\n`{resource_name}`"},
                    {"type": "mrkdwn", "text": f"*계정:*\n{account_id}"},
                    {"type": "mrkdwn", "text": f"*리전:*\n{region}"},
                    {"type": "mrkdwn", "text": f"*컴플라이언스:*\n{compliance_status}"},
                ],
            },
            {"type": "section", "text": {"type": "mrkdwn", "text": actor_text}},
            {
                "type": "section",
                "text": {
                    "type": "mrkdwn",
                    "text": (
                        f"*CloudWatch Logs Insights 쿼리 "
                        f"({'🤖 Bedrock 생성' if query_source == 'bedrock' else '📋 기본 템플릿'}, 복사해서 붙여넣기):*\n"
                        f"```{logs_query}```"
                    ),
                },
            },
            {
                "type": "actions",
                "elements": [
                    {
                        "type": "button",
                        "text": {"type": "plain_text", "text": "Security Hub에서 보기"},
                        "url": deep_link,
                    },
                    {
                        "type": "button",
                        "text": {"type": "plain_text", "text": "🛑 위험 수용 / 예외 등록"},
                        "style": "danger",
                        "action_id": "open_suppress_modal",
                        "value": json.dumps({
                            "finding_id": finding.get("Id", ""),
                            "product_arn": finding.get("ProductArn", ""),
                            "resource_id": resource_name,
                        }),
                    },
                ],
            },
        ]
    }

    payload["channel"] = SLACK_CHANNEL
    req = urllib.request.Request(
        "https://slack.com/api/chat.postMessage",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Content-Type": "application/json; charset=utf-8",
            "Authorization": f"Bearer {bot_token}",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        result = json.loads(resp.read().decode("utf-8"))
    if not result.get("ok"):
        print(json.dumps({"warning": "slack chat.postMessage failed", "error": result.get("error"), "response": result}))

def _log_alert_sent(finding_id: str, resource_name: str, severity: str, title: str, actor: str, query_source: str = "fallback"):
    record = {
        "eventType": "CSPM_ALERT_SENT",
        "findingId": finding_id,
        "resourceId": resource_name,
        "severity": severity,
        "title": title,
        "actor": actor,
        "queryGeneratedBy": query_source,
    }
    log_stream = time.strftime("%Y-%m-%d", time.gmtime())
    try:
        logs_client.create_log_stream(logGroupName=CSPM_EXCEPTION_LOG_GROUP, logStreamName=log_stream)
    except logs_client.exceptions.ResourceAlreadyExistsException:
        pass
    logs_client.put_log_events(
        logGroupName=CSPM_EXCEPTION_LOG_GROUP,
        logStreamName=log_stream,
        logEvents=[{"timestamp": int(time.time() * 1000), "message": json.dumps(record)}],
    )

def handler(event, context):
    findings = event.get("detail", {}).get("findings", [])
    bot_token = None
    processed, skipped_dup = 0, 0

    for finding in findings:
        finding_id = finding.get("Id", "")
        if not finding_id:
            continue
        if _is_duplicate(finding_id):
            skipped_dup += 1
            continue

        resources = finding.get("Resources", [{}])
        resource_name = _extract_resource_name(resources[0]) if resources else ""
        actor_data = _lookup_actor(resource_name)
        actor_str = actor_data.get("actor", "unknown") if actor_data and "error" not in actor_data else "unknown"
        severity = finding.get("Severity", {}).get("Label", "UNKNOWN")
        title = finding.get("Title", "(제목 없음)")

        logs_query, query_source = _generate_logs_query(resource_name, finding)
        deep_link = _security_hub_deep_link(finding_id, finding.get("ProductArn", ""))

        if bot_token is None:
            bot_token = _get_bot_token()
        _post_to_slack(bot_token, finding, actor_data, logs_query, deep_link, resource_name, query_source)

        _log_alert_sent(finding_id, resource_name, severity, title, actor_str, query_source)
        processed += 1

    return {"statusCode": 200, "processed": processed, "skipped_duplicate": skipped_dup}