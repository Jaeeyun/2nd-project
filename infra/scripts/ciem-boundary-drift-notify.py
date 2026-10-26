
import boto3
import json
import os
import time
import urllib.request
from datetime import datetime, timedelta, timezone

iam = boto3.client("iam")
access_analyzer = boto3.client("accessanalyzer")
secrets_client = boto3.client("secretsmanager")
sts = boto3.client("sts")

REGION = os.environ["AWS_REGION"]
NAME_PREFIX = os.environ["NAME_PREFIX"]
CLOUDTRAIL_ARN = os.environ["CLOUDTRAIL_ARN"]
LOOKBACK_HOURS = int(os.environ.get("LOOKBACK_HOURS", "3"))
SLACK_SECRET_ARN = os.environ["SLACK_SECRET_ARN"]
SLACK_CHANNEL = os.environ.get("SLACK_CHANNEL", "#cspm-findings")
ACCESS_ANALYZER_ROLE_ARN = os.environ["ACCESS_ANALYZER_ROLE_ARN"]
POLICY_GENERATION_TIMEOUT_SECONDS = 420

def _get_slack_bot_token() -> str:
    secret = secrets_client.get_secret_value(SecretId=SLACK_SECRET_ARN)
    return json.loads(secret["SecretString"])["bot_token"]

def _current_role_actions(role_name: str) -> set:

    actions = set()
    for policy_name in iam.list_role_policies(RoleName=role_name).get("PolicyNames", []):
        doc = iam.get_role_policy(RoleName=role_name, PolicyName=policy_name)["PolicyDocument"]
        for stmt in doc.get("Statement", []):
            if stmt.get("Effect") != "Allow":
                continue
            action = stmt.get("Action", [])
            actions.update([action] if isinstance(action, str) else action)
    return actions

def _generated_policy_actions(job_id: str):
    resp = access_analyzer.get_generated_policy(jobId=job_id)
    policies = resp.get("generatedPolicyResult", {}).get("generatedPolicies", [])
    if not policies:
        return set(), None
    policy = json.loads(policies[0]["policy"])
    actions = set()
    for stmt in policy.get("Statement", []):
        action = stmt.get("Action", [])
        actions.update([action] if isinstance(action, str) else action)
    return actions, policy

def _start_policy_generation(role_arn: str, start_time: str, end_time: str) -> str:
    resp = access_analyzer.start_policy_generation(
        policyGenerationDetails={"principalArn": role_arn},
        cloudTrailDetails={
            "trails": [{"cloudTrailArn": CLOUDTRAIL_ARN, "allRegions": True}],
            "startTime": start_time,
            "endTime": end_time,
            "accessRole": ACCESS_ANALYZER_ROLE_ARN,
        },
    )
    return resp["jobId"]

def _wait_for_job(job_id: str) -> str:
    deadline = time.time() + POLICY_GENERATION_TIMEOUT_SECONDS
    while time.time() < deadline:
        status = access_analyzer.get_generated_policy(jobId=job_id)["jobDetails"]["status"]
        if status != "IN_PROGRESS":
            return status
        time.sleep(10)
    return "TIMED_OUT"

def _post_slack_interactive(token: str, role_name: str, role_arn: str, job_id: str, unused_actions: set, start_str: str, end_str: str):
    sorted_actions = sorted(unused_actions)
    unused_list = "\n".join(f"• `{a}`" for a in sorted_actions[:30])
    if len(sorted_actions) > 30:
        unused_list += f"\n... 외 {len(sorted_actions) - 30}건"

    payload = {
        "channel": SLACK_CHANNEL,
        "text": f"권한 드리프트 발견: {role_name}",
        "blocks": [
            {
                "type": "section",
                "text": {
                    "type": "mrkdwn",
                    "text": (
                        f"*🔍 최근 {LOOKBACK_HOURS}시간 미사용 권한 발견*\n"
                        f"Role: `{role_name}`\n"
                        f"분석 대상 기간: `{start_str}` ~ `{end_str}`\n"
                        f"(⚠️ 이 구간 이후의 활동은 이번 결과에 반영되지 않습니다 - 지금 막 쓴 권한이라도 "
                        f"버튼을 누르면 이 시점 기준 정책이 그대로 적용됩니다)\n"
                        f"이 구간 동안 CloudTrail에서 관찰되지 않은 권한:\n"
                        f"{unused_list}\n\n"
                        f"⚠️ 짧은 관찰 기간(데모/테스트용)이라 저빈도 정당 업무가 여기 섞여 "
                        f"있을 수 있습니다. 자동으로 빼지 않습니다 - 아래에서 선택해주세요."
                    ),
                },
            },
            {
                "type": "actions",
                "elements": [
                    {
                        "type": "button",
                        "text": {"type": "plain_text", "text": "✅ 이 권한들 제거 (최소화 적용)"},
                        "style": "primary",
                        "action_id": "apply_reduced_policy",
                        "value": json.dumps({"role_name": role_name, "role_arn": role_arn, "job_id": job_id}),
                        "confirm": {
                            "title": {"type": "plain_text", "text": "정말 적용할까요?"},
                            "text": {"type": "plain_text", "text": f"{role_name}의 정책을 위 목록만큼 줄인 정책으로 즉시 교체합니다."},
                            "confirm": {"type": "plain_text", "text": "적용"},
                            "deny": {"type": "plain_text", "text": "취소"},
                        },
                    },
                    {
                        "type": "button",
                        "text": {"type": "plain_text", "text": "🔒 그대로 유지 (오탐/저빈도 업무)"},
                        "action_id": "keep_current_policy",
                        "value": json.dumps({"role_name": role_name}),
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

    role_suffix = event["role_suffix"]
    role_name = f"{NAME_PREFIX}-{role_suffix}"
    account_id = sts.get_caller_identity()["Account"]
    role_arn = f"arn:aws:iam::{account_id}:role/{role_name}"

    token = _get_slack_bot_token()
    end_time = datetime.now(timezone.utc)
    start_time = end_time - timedelta(hours=LOOKBACK_HOURS)
    end_str = end_time.strftime("%Y-%m-%dT%H:%M:%SZ")
    start_str = start_time.strftime("%Y-%m-%dT%H:%M:%SZ")

    print(f"[{role_name}] 분석 대상 기간: {start_str} ~ {end_str} (최근 {LOOKBACK_HOURS}시간, 이 구간 이후의 활동은 이번 결과에 반영되지 않음)")

    current_actions = _current_role_actions(role_name)
    job_id = _start_policy_generation(role_arn, start_str, end_str)
    status = _wait_for_job(job_id)

    if status != "SUCCEEDED":
        print(f"[{role_name}] Policy Generation 실패/타임아웃: {status}")
        return {"statusCode": 200, "role": role_name, "result": f"job_{status.lower()}"}

    generated_actions, generated_policy = _generated_policy_actions(job_id)
    if generated_policy is None:
        print(f"[{role_name}] 관찰된 활동 없음 - 최근 {LOOKBACK_HOURS}시간 동안 이 Role이 전혀 사용되지 않음")
        return {"statusCode": 200, "role": role_name, "result": "no_activity_observed"}

    unused_actions = current_actions - generated_actions
    if not unused_actions:
        print(f"[{role_name}] 미사용 권한 없음")
        return {"statusCode": 200, "role": role_name, "result": "no_drift"}

    _post_slack_interactive(token, role_name, role_arn, job_id, unused_actions, start_str, end_str)
    return {"statusCode": 200, "role": role_name, "result": "flagged", "unused_count": len(unused_actions)}
