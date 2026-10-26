
import json
import os
import logging
from datetime import datetime, timezone
from typing import TypedDict, Optional

logger = logging.getLogger()
logger.setLevel(logging.INFO)

BEDROCK_MODEL_ID = os.environ.get(
    "BEDROCK_MODEL_ID", "anthropic.claude-3-5-haiku-20241022-v1:0"
)
BEDROCK_REGION = os.environ.get("BEDROCK_REGION", "ap-northeast-2")
MAX_TOKENS = int(os.environ.get("BEDROCK_MAX_TOKENS", "300"))
DAILY_INVOCATION_CAP = int(os.environ.get("BEDROCK_DAILY_CAP", "50"))
COST_GUARD_TABLE = os.environ.get("COST_GUARD_TABLE", "cspm-bedrock-usage")

class Finding(TypedDict, total=False):
    Title: str
    Severity: str
    ResourceArn: str
    ResourceType: str
    EventName: str
    AccountId: str
    Region: str

class QueryResult(TypedDict):
    query: str
    source: str
    reason: Optional[str]

FALLBACK_QUERY_TEMPLATE = """fields @timestamp, eventName, userIdentity.arn, sourceIPAddress
| filter resources.0.ARN = "{resource_arn}"
| sort @timestamp desc
| limit 50"""

def _build_prompt(finding: Finding) -> str:

    return f"""당신은 AWS 보안 담당자를 돕는 조사 보조 도구입니다.
아래 Security Hub finding에 대해, 해당 리소스의 최근 API 호출 이력을 조사할 수 있는
CloudWatch Logs Insights 쿼리 한 개만 작성하세요.

- Finding 제목: {finding.get('Title', 'N/A')}
- 심각도: {finding.get('Severity', 'N/A')}
- 리소스 ARN: {finding.get('ResourceArn', 'N/A')}
- 리소스 타입: {finding.get('ResourceType', 'N/A')}
- 관련 API 이벤트명: {finding.get('EventName', 'N/A')}
- 계정/리전: {finding.get('AccountId', 'N/A')} / {finding.get('Region', 'N/A')}

규칙:
1. 로그 소스는 CloudTrail 로그 그룹을 조회한다고 가정합니다 (필드: eventName, userIdentity.arn, sourceIPAddress, requestParameters 등).
2. 이 리소스와 직접 관련된 이벤트만 걸러지도록 filter 조건에 리소스 ARN 또는 리소스 식별자를 반드시 포함하세요.
3. 심각도가 HIGH/CRITICAL이면 조회 범위를 넓혀도 되지만, 쿼리 자체에 시간 범위(bin/sort)를 넣어 최근순 정렬하세요.
4. 설명 문장 없이 CWLI 쿼리 구문만 출력하세요. 코드블록(```)도 붙이지 마세요.
"""

def _check_and_increment_daily_cap(dynamodb_resource=None) -> bool:

    if dynamodb_resource is None:
        logger.warning("cost-guard skipped: no dynamodb resource injected (test mode)")
        return True

    table = dynamodb_resource.Table(COST_GUARD_TABLE)
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")

    try:
        resp = table.update_item(
            Key={"date": today},
            UpdateExpression="ADD invocation_count :inc",
            ExpressionAttributeValues={":inc": 1},
            ReturnValues="UPDATED_NEW",
        )
        count = int(resp["Attributes"]["invocation_count"])
    except Exception:
        logger.exception("cost-guard table update failed, treating as cap-exceeded (fail safe)")
        return False

    if count > DAILY_INVOCATION_CAP:
        logger.warning(f"daily Bedrock invocation cap exceeded: {count}/{DAILY_INVOCATION_CAP}")
        return False
    return True

def generate_cwli_query(
    finding: Finding,
    bedrock_client=None,
    dynamodb_resource=None,
) -> QueryResult:

    resource_arn = finding.get("ResourceArn", "UNKNOWN")
    fallback = FALLBACK_QUERY_TEMPLATE.format(resource_arn=resource_arn)

    if bedrock_client is None:
        return QueryResult(query=fallback, source="fallback", reason="no_bedrock_client")

    if not _check_and_increment_daily_cap(dynamodb_resource):
        return QueryResult(query=fallback, source="fallback", reason="daily_cap_exceeded")

    prompt = _build_prompt(finding)

    try:
        response = bedrock_client.invoke_model(
            modelId=BEDROCK_MODEL_ID,
            body=json.dumps(
                {
                    "anthropic_version": "bedrock-2023-05-31",
                    "max_tokens": MAX_TOKENS,
                    "messages": [{"role": "user", "content": prompt}],
                }
            ),
        )
        result = json.loads(response["body"].read())
        query_text = result["content"][0]["text"].strip()

        if not query_text:
            raise ValueError("empty response from Bedrock")

        return QueryResult(query=query_text, source="bedrock", reason=None)

    except Exception as e:
        logger.exception("Bedrock invocation failed, falling back to static template")
        return QueryResult(query=fallback, source="fallback", reason=f"bedrock_error:{type(e).__name__}")

def format_slack_query_block(result: QueryResult, finding: Finding) -> str:

    label = "🤖 Bedrock 생성 쿼리" if result["source"] == "bedrock" else "📋 기본 템플릿 쿼리 (fallback)"
    note = f"\n_fallback 사유: {result['reason']}_" if result["source"] == "fallback" else ""
    return f"*{label}*{note}\n```\n{result['query']}\n```\n(CWLI 콘솔에 붙여넣어 직접 실행하세요)"
