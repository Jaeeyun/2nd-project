
import base64
import boto3
import hashlib
import hmac
import json
import os
import time
import urllib.parse
import urllib.request

iam = boto3.client("iam")
access_analyzer = boto3.client("accessanalyzer")
securityhub = boto3.client("securityhub")
secrets_client = boto3.client("secretsmanager")
lambda_client = boto3.client("lambda")
logs_client = boto3.client("logs")

SLACK_SECRET_ARN = os.environ["SLACK_SECRET_ARN"]
SESSION_REVOKE_FUNCTION_NAME = os.environ["SESSION_REVOKE_FUNCTION_NAME"]
BOUNDARY_VIOLATION_LOG_GROUP = os.environ["BOUNDARY_VIOLATION_LOG_GROUP"]
CSPM_EXCEPTION_LOG_GROUP = os.environ["CSPM_EXCEPTION_LOG_GROUP"]

_REASON_TYPE_LABELS = {
    "risk_accepted": "Risk Accepted",
    "compensating_control": "Compensating Control",
    "false_positive": "False Positive",
    "business_requirement": "Business Requirement",
}

def _get_signing_secret() -> str:
    secret = secrets_client.get_secret_value(SecretId=SLACK_SECRET_ARN)
    return json.loads(secret["SecretString"])["signing_secret"]

def _get_bot_token() -> str:
    secret = secrets_client.get_secret_value(SecretId=SLACK_SECRET_ARN)
    return json.loads(secret["SecretString"])["bot_token"]

def _slack_api_call(method: str, bot_token: str, payload: dict) -> dict:
    req = urllib.request.Request(
        f"https://slack.com/api/{method}",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Content-Type": "application/json; charset=utf-8",
            "Authorization": f"Bearer {bot_token}",
        },
        method="POST",
    )
    with urllib.request.urlopen(req) as resp:
        result = json.loads(resp.read().decode("utf-8"))

    if not result.get("ok"):
        print(json.dumps({"warning": f"slack api {method} failed", "error": result.get("error"), "response": result}))
    return result

def _verify_slack_signature(headers: dict, body: str) -> bool:
    timestamp = headers.get("x-slack-request-timestamp", "")
    slack_signature = headers.get("x-slack-signature", "")

    if abs(time.time() - int(timestamp)) > 60 * 5:
        return False

    signing_secret = _get_signing_secret()
    sig_basestring = f"v0:{timestamp}:{body}"
    computed = "v0=" + hmac.new(
        signing_secret.encode(), sig_basestring.encode(), hashlib.sha256
    ).hexdigest()
    return hmac.compare_digest(computed, slack_signature)

def _respond_to_slack(response_url: str, text: str):
    payload = {"replace_original": "true", "text": text}
    req = urllib.request.Request(
        response_url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    urllib.request.urlopen(req)

def _open_suppress_modal(bot_token: str, trigger_id: str, value: dict, channel_id: str, message_ts: str):

    review_date_default = time.strftime("%Y-%m-%d", time.gmtime(time.time() + 90 * 24 * 3600))
    private_metadata = json.dumps({
        "finding_id": value.get("finding_id", ""),
        "product_arn": value.get("product_arn", ""),
        "resource_id": value.get("resource_id", ""),
        "channel_id": channel_id,
        "message_ts": message_ts,
    })

    view = {
        "type": "modal",
        "callback_id": "cspm_suppress_submit",
        "private_metadata": private_metadata,
        "title": {"type": "plain_text", "text": "위험 수용 / 예외 등록"},
        "submit": {"type": "plain_text", "text": "제출"},
        "close": {"type": "plain_text", "text": "취소"},
        "blocks": [
            {
                "type": "input",
                "block_id": "ticket_ref_block",
                "label": {"type": "plain_text", "text": "Ticket Ref"},
                "element": {
                    "type": "plain_text_input",
                    "action_id": "ticket_ref_input",
                    "initial_value": f"SEC-AUTO-{int(time.time())}",
                },
            },
            {
                "type": "section",
                "block_id": "scope_target_block",
                "text": {"type": "mrkdwn", "text": f"*Scope/Target:*\n`{value.get('resource_id', '?')}`"},
            },
            {
                "type": "input",
                "block_id": "reason_type_block",
                "label": {"type": "plain_text", "text": "Reason Type"},
                "element": {
                    "type": "static_select",
                    "action_id": "reason_type_select",
                    "placeholder": {"type": "plain_text", "text": "사유를 선택하세요"},
                    "options": [
                        {"text": {"type": "plain_text", "text": label}, "value": key}
                        for key, label in _REASON_TYPE_LABELS.items()
                    ],
                },
            },
            {
                "type": "input",
                "block_id": "rationale_block",
                "label": {"type": "plain_text", "text": "Rationale"},
                "element": {
                    "type": "plain_text_input",
                    "action_id": "rationale_input",
                    "multiline": True,
                },
            },
            {
                "type": "input",
                "block_id": "compensating_block",
                "optional": True,
                "label": {"type": "plain_text", "text": "Compensating Controls"},
                "element": {
                    "type": "plain_text_input",
                    "action_id": "compensating_input",
                    "multiline": True,
                },
            },
            {
                "type": "input",
                "block_id": "review_date_block",
                "label": {"type": "plain_text", "text": "Review Date"},
                "element": {
                    "type": "datepicker",
                    "action_id": "review_date_picker",
                    "initial_date": review_date_default,
                },
            },
        ],
    }
    _slack_api_call("views.open", bot_token, {"trigger_id": trigger_id, "view": view})

def _log_cspm_exception(
    ticket_ref: str, reason_type: str, resource_id: str, rationale: str,
    compensating: str, review_date: str, approved_by: str, finding_id: str,
    product_arn: str,
):

    now_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    record = {
        "eventType": "CSPM_EXCEPTION_RECORDED",
        "timestamp": now_iso,
        "ticketRef": ticket_ref,
        "reasonType": reason_type,
        "resourceId": resource_id,
        "rationale": rationale,
        "compensatingControls": compensating,
        "reviewDate": review_date,
        "approvedBy": approved_by,
        "findingId": finding_id,
        "productArn": product_arn,
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

def _update_slack_message(bot_token: str, channel_id: str, message_ts: str, text: str):

    _slack_api_call("chat.update", bot_token, {
        "channel": channel_id,
        "ts": message_ts,
        "text": text,
        "blocks": [{"type": "section", "text": {"type": "mrkdwn", "text": text}}],
    })

def _handle_cspm_suppress_submit(view: dict, approver: str):
    metadata = json.loads(view.get("private_metadata", "{}"))
    finding_id = metadata.get("finding_id", "")
    product_arn = metadata.get("product_arn", "")
    resource_id = metadata.get("resource_id", "")
    channel_id = metadata.get("channel_id", "")
    message_ts = metadata.get("message_ts", "")

    values = view["state"]["values"]
    ticket_ref = values["ticket_ref_block"]["ticket_ref_input"]["value"]
    reason_type_key = values["reason_type_block"]["reason_type_select"]["selected_option"]["value"]
    reason_type_label = _REASON_TYPE_LABELS.get(reason_type_key, reason_type_key)
    rationale = values["rationale_block"]["rationale_input"]["value"] or ""
    compensating = (values["compensating_block"]["compensating_input"]["value"] or "").strip()
    review_date = values["review_date_block"]["review_date_picker"]["selected_date"]

    note_text = (
        "[CSPM Exception Record]\n"
        f"- Reason Type: {reason_type_label}\n"
        f"- Ticket Ref: {ticket_ref}\n"
        f"- Rationale: {rationale}\n"
        f"- Compensating Controls: {compensating}\n"
        f"- Scope/Target: {resource_id}\n"
        f"- Review Date: {review_date}\n"
        f"- Approved By: @{approver}"
    )

    securityhub.batch_update_findings(
        FindingIdentifiers=[{"Id": finding_id, "ProductArn": product_arn}],
        Workflow={"Status": "SUPPRESSED"},
        Note={"Text": note_text, "UpdatedBy": approver},
    )

    _log_cspm_exception(
        ticket_ref, reason_type_label, resource_id, rationale,
        compensating, review_date, f"@{approver}", finding_id, product_arn,
    )

    if channel_id and message_ts:
        bot_token = _get_bot_token()
        _update_slack_message(
            bot_token, channel_id, message_ts,
            f"✅ @{approver} 님이 예외(Suppress) 처리 완료함",
        )

def _handle_keep_access_key(value: dict, approver: str, response_url: str):
    username, key_id = value["username"], value["key_id"]
    iam.tag_user(
        UserName=username,
        Tags=[{"Key": "CIEMExceptionReviewedBy", "Value": approver},
              {"Key": "CIEMExceptionReviewedAt", "Value": str(int(time.time()))}],
    )
    _respond_to_slack(response_url, f"✅ {username}/{key_id} — {approver}님이 예외로 확인, 유지합니다.")

def _handle_revoke_access_key(value: dict, approver: str, response_url: str):
    username, key_id = value["username"], value["key_id"]
    iam.update_access_key(UserName=username, AccessKeyId=key_id, Status="Inactive")
    iam.delete_access_key(UserName=username, AccessKeyId=key_id)
    _respond_to_slack(response_url, f"🗑 {username}/{key_id} — {approver}님의 승인으로 삭제 완료.")

def _handle_apply_reduced_policy(value: dict, approver: str, response_url: str):
    role_name = value["role_name"]
    job_id = value["job_id"]

    generated = access_analyzer.get_generated_policy(jobId=job_id)
    policies = generated.get("generatedPolicyResult", {}).get("generatedPolicies", [])
    if not policies:
        _respond_to_slack(
            response_url,
            f"❌ {role_name} - 생성된 정책을 다시 못 찾았습니다(시간이 지나 만료됐을 수 있음). "
            f"분석을 다시 실행해주세요.",
        )
        return

    reduced_policy = policies[0]["policy"]

    existing_policy_names = iam.list_role_policies(RoleName=role_name).get("PolicyNames", [])
    if not existing_policy_names:
        _respond_to_slack(response_url, f"❌ {role_name} - 기존 인라인 정책을 찾을 수 없습니다.")
        return

    target_policy_name = existing_policy_names[0]

    iam.put_role_policy(RoleName=role_name, PolicyName=target_policy_name, PolicyDocument=reduced_policy)
    iam.tag_role(
        RoleName=role_name,
        Tags=[{"Key": "BoundaryDriftReviewedBy", "Value": approver},
              {"Key": "BoundaryDriftReviewedAt", "Value": str(int(time.time()))}],
    )
    _respond_to_slack(
        response_url,
        f"✅ {role_name} — {approver}님 승인으로 최소권한 정책 적용 완료.\n"
        f"⚠️ 참고: Console/CLI로 직접 바꾼 상태라, 다음 `terraform apply` 때 "
        f"policies/*.json.tpl 파일과 실제 상태가 다르면 되돌아갈 수 있습니다 - "
        f"계속 유지하려면 이 결과를 해당 정책 파일에도 반영해주세요.",
    )

def _handle_keep_current_policy(value: dict, approver: str, response_url: str):
    role_name = value["role_name"]
    _respond_to_slack(
        response_url,
        f"🔒 {role_name} — {approver}님이 현재 정책 유지로 확인함(저빈도 정당 업무로 판단, 자동 회수 안 함).",
    )

def _log_resolved(event_id: str, target_role: str, resolved_by: str, button_clicked: str, action_taken: str):

    now_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    summary = (
        f"RESOLVED | Role: {target_role} | By: {resolved_by} | Action: {button_clicked} "
        f"→ {action_taken} | At: {now_iso}"
    )
    log_stream = time.strftime("%Y-%m-%d", time.gmtime())
    try:
        logs_client.create_log_stream(logGroupName=BOUNDARY_VIOLATION_LOG_GROUP, logStreamName=log_stream)
    except logs_client.exceptions.ResourceAlreadyExistsException:
        pass
    logs_client.put_log_events(
        logGroupName=BOUNDARY_VIOLATION_LOG_GROUP,
        logStreamName=log_stream,
        logEvents=[{
            "timestamp": int(time.time() * 1000),
            "message": json.dumps({"event_id": event_id, "summary": summary}),
        }],
    )

def _handle_lock_account_risk(value: dict, approver: str, response_url: str):
    username = value["username"]
    role_name = value.get("role_name", "?")
    policy_arn = value.get("policy_arn")
    policy_name = policy_arn.rsplit("/", 1)[-1] if policy_arn else "?"

    if policy_arn:
        try:
            iam.detach_role_policy(RoleName=role_name, PolicyArn=policy_arn)
        except iam.exceptions.NoSuchEntityException:
            pass

    lambda_client.invoke(
        FunctionName=SESSION_REVOKE_FUNCTION_NAME,
        InvocationType="Event",
        Payload=json.dumps({"username": username}).encode("utf-8"),
    )
    if "event_id" in value:
        _log_resolved(
            value["event_id"], role_name, f"@{approver}", "Lock & Revoke",
            f"{policy_name} Detached & Session Revoked",
        )
    _respond_to_slack(
        response_url,
        f"✅ @{approver} 님이 [Lock & Revoke] 버튼을 눌러 조치를 완료했습니다.\n"
        f"🔒 {username} — AWS 세션 전체 차단 + Keycloak SSO 로그아웃. "
        f"원인: {role_name}에 Permission Boundary 밖의 정책({policy_name})이 부착됨.",
    )

def _handle_approve_exception_risk(value: dict, approver: str, response_url: str):
    role_name = value.get("role_name", "?")
    policy_name = value.get("policy_arn", "?").rsplit("/", 1)[-1]
    if "event_id" in value:
        _log_resolved(
            value["event_id"], role_name, f"@{approver}", "Approve",
            f"{policy_name} 예외 승인(정책 유지, 회수 안 함)",
        )
    _respond_to_slack(
        response_url,
        f"⚠️ @{approver} 님이 [Approve] 버튼을 눌러 예외로 승인했습니다.\n"
        f"{role_name}의 {policy_name}는 그대로 유지됩니다(자동 회수 없음).",
    )

ACTION_HANDLERS = {
    "keep_access_key": _handle_keep_access_key,
    "revoke_access_key": _handle_revoke_access_key,
    "apply_reduced_policy": _handle_apply_reduced_policy,
    "keep_current_policy": _handle_keep_current_policy,
    "lock_account_risk": _handle_lock_account_risk,
    "approve_exception_risk": _handle_approve_exception_risk,
}

def handler(event, context):
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    body = event.get("body", "")

    if event.get("isBase64Encoded"):
        body = base64.b64decode(body).decode("utf-8")

    if not _verify_slack_signature(headers, body):
        return {"statusCode": 401, "body": "invalid signature"}

    form = urllib.parse.parse_qs(body)
    payload = json.loads(form["payload"][0])
    payload_type = payload.get("type")

    if payload_type == "view_submission":
        view = payload["view"]
        if view.get("callback_id") != "cspm_suppress_submit":
            return {"statusCode": 400, "body": "unknown view"}
        approver = payload["user"]["username"]
        _handle_cspm_suppress_submit(view, approver)
        return {"statusCode": 200, "body": ""}

    actions = payload.get("actions") or []
    if not actions:

        print(json.dumps({"warning": "no actions in block_actions payload", "raw_payload": payload}))
        return {"statusCode": 200, "body": ""}

    action = actions[0]
    action_id = action.get("action_id")
    approver = payload["user"]["username"]
    raw_value = action.get("value")

    if raw_value is None:

        print(json.dumps({"warning": "action has no value field", "action_id": action_id, "raw_payload": payload}))
        return {"statusCode": 200, "body": ""}

    if action_id == "open_suppress_modal":
        value = json.loads(raw_value)
        trigger_id = payload["trigger_id"]
        channel_id = payload["channel"]["id"]
        message_ts = payload["message"]["ts"]
        bot_token = _get_bot_token()
        _open_suppress_modal(bot_token, trigger_id, value, channel_id, message_ts)
        return {"statusCode": 200, "body": ""}

    value = json.loads(raw_value)
    response_url = payload["response_url"]

    handler_fn = ACTION_HANDLERS.get(action_id)
    if handler_fn is None:
        return {"statusCode": 400, "body": "unknown action"}

    handler_fn(value, approver, response_url)
    return {"statusCode": 200, "body": ""}
