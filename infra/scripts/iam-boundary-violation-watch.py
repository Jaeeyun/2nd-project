
import boto3
import json
import os
import time
import urllib.request

logs_client = boto3.client("logs", region_name="ap-northeast-2")
secrets_client = boto3.client("secretsmanager", region_name="ap-northeast-2")

LOG_GROUP_NAME = os.environ["LOG_GROUP_NAME"]
SLACK_SECRET_ARN = os.environ["SLACK_SECRET_ARN"]
SLACK_CHANNEL = os.environ.get("SLACK_CHANNEL", "#cspm-findings")
NAME_PREFIX = os.environ["NAME_PREFIX"]
EXPECTED_MANAGED_POLICY_ARNS = set(filter(None, os.environ.get("EXPECTED_MANAGED_POLICY_ARNS", "").split(",")))

def _get_slack_bot_token() -> str:
    secret = secrets_client.get_secret_value(SecretId=SLACK_SECRET_ARN)
    return json.loads(secret["SecretString"])["bot_token"]

def _extract_username(user_identity: dict) -> str:

    arn = user_identity.get("arn", "")
    if "assumed-role" in arn:
        return arn.rsplit("/", 1)[-1]
    return user_identity.get("principalId", "unknown")

def _role_owner_username(role_name: str) -> str:

    suffix = role_name[len(NAME_PREFIX) + 1:] if role_name.startswith(f"{NAME_PREFIX}-") else role_name
    return f"test-{suffix}"

def _log_unresolved(event_id: str, target_role: str, violation_policy: str, attached_by: str, target_username: str):

    now_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    summary = (
        f"UNRESOLVED | Role: {target_role} | Policy: {violation_policy.rsplit('/', 1)[-1]} "
        f"| AttachedBy: {attached_by} | LockTarget: {target_username} | At: {now_iso}"
    )
    log_stream = time.strftime("%Y-%m-%d", time.gmtime())
    try:
        logs_client.create_log_stream(logGroupName=LOG_GROUP_NAME, logStreamName=log_stream)
    except logs_client.exceptions.ResourceAlreadyExistsException:
        pass
    logs_client.put_log_events(
        logGroupName=LOG_GROUP_NAME,
        logStreamName=log_stream,
        logEvents=[{
            "timestamp": int(time.time() * 1000),
            "message": json.dumps({"event_id": event_id, "summary": summary}),
        }],
    )

def _post_slack_alert(token: str, event_id: str, role_name: str, policy_arn: str, attached_by: str, target_username: str):
    policy_name = policy_arn.rsplit("/", 1)[-1]
    button_value = json.dumps({
        "event_id": event_id,
        "username": target_username,
        "role_name": role_name,
        "policy_arn": policy_arn,
    })
    payload = {
        "channel": SLACK_CHANNEL,
        "text": f"🚨 [SECURITY ALERT] Unauthorized IAM Policy Attached - {role_name}",
        "blocks": [
            {
                "type": "section",
                "text": {
                    "type": "mrkdwn",
                    "text": (
                        f"*🚨 [SECURITY ALERT] Unauthorized IAM Policy Attached*\n\n"
                        f"• 대상 Role: `{role_name}`\n"
                        f"• 위반 Policy: `{policy_name}`\n"
                        f"• 정책을 붙인 계정: `{attached_by}`\n"
                        f"• 잠금 대상(이 Role의 정상 사용자): `{target_username}`\n"
                        f"• 상태: 🔴 미해결 (Unresolved)\n\n"
                        f"이 Role은 원래 인라인 정책 하나만 쓰도록 설계돼 있어서, "
                        f"관리형 정책이 붙는 것 자체가 정상 범위를 벗어난 상태입니다.\n"
                        f"아래 조치 버튼 중 하나를 선택하세요:"
                    ),
                },
            },
            {
                "type": "actions",
                "elements": [
                    {
                        "type": "button",
                        "text": {"type": "plain_text", "text": "🔒 세션 잠금 & 권한 회수 (Lock & Revoke)"},
                        "style": "danger",
                        "action_id": "lock_account_risk",
                        "value": button_value,
                        "confirm": {
                            "title": {"type": "plain_text", "text": "정말 잠글까요?"},
                            "text": {"type": "plain_text", "text": f"{target_username}의 AWS 세션 전체와 Keycloak SSO 세션을 즉시 강제 종료합니다."},
                            "confirm": {"type": "plain_text", "text": "잠금"},
                            "deny": {"type": "plain_text", "text": "취소"},
                        },
                    },
                    {
                        "type": "button",
                        "text": {"type": "plain_text", "text": "⚠️ 예외 승인 (Approve)"},
                        "action_id": "approve_exception_risk",
                        "value": button_value,
                    },
                ],
            },
        ],
    }
    req = urllib.request.Request(
        "https://slack.com/api/chat.postMessage",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json; charset=utf-8"},
        method="POST",
    )
    with urllib.request.urlopen(req) as resp:
        result = json.loads(resp.read())
        if not result.get("ok"):
            raise RuntimeError(f"Slack API 실패: {result}")

def handler(event, context):

    detail = event["detail"]
    event_id = detail["eventID"]
    request_params = detail["requestParameters"]
    role_name = request_params["roleName"]
    policy_arn = request_params["policyArn"]
    attached_by = _extract_username(detail.get("userIdentity", {}))
    target_username = _role_owner_username(role_name)

    if policy_arn in EXPECTED_MANAGED_POLICY_ARNS:
        return {"statusCode": 200, "result": "in_boundary", "role": role_name}

    _log_unresolved(event_id, role_name, policy_arn, attached_by, target_username)
    token = _get_slack_bot_token()
    _post_slack_alert(token, event_id, role_name, policy_arn, attached_by, target_username)
    return {
        "statusCode": 200, "result": "violation_alerted", "event_id": event_id,
        "role": role_name, "attached_by": attached_by, "target_username": target_username,
    }
