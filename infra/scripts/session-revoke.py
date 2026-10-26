
import boto3
import json
import os
import ssl
import time
import urllib.parse
import urllib.request

_INSECURE_SSL_CONTEXT = ssl.create_default_context()
_INSECURE_SSL_CONTEXT.check_hostname = False
_INSECURE_SSL_CONTEXT.verify_mode = ssl.CERT_NONE

iam = boto3.client("iam")
secrets_client = boto3.client("secretsmanager") if os.environ.get("SLACK_SECRET_ARN") else None
ssm = boto3.client("ssm")
sns = boto3.client("sns")

REGION = os.environ["AWS_REGION"]
NAME_PREFIX = os.environ["NAME_PREFIX"]
KEYCLOAK_HOST = os.environ["KEYCLOAK_HOST"]
REALM_NAME = os.environ["REALM_NAME"]
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
ROLE_NAMES = json.loads(os.environ["ROLE_NAMES_JSON"])

def _revoke_aws_sessions(username: str):

    policy_document = json.dumps({
        "Version": "2012-10-17",
        "Statement": [{
            "Sid": "RevokeSpecificUserSession",
            "Effect": "Deny",
            "Action": "*",
            "Resource": "*",
            "Condition": {
                "StringLike": {"aws:userid": f"*:{username}"},
                "DateLessThan": {"aws:TokenIssueTime": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())},
            },
        }],
    })

    revoked_roles = []
    for role_name in ROLE_NAMES:
        try:
            iam.put_role_policy(
                RoleName=role_name,
                PolicyName=f"revoke-session-{username}",
                PolicyDocument=policy_document,
            )
            revoked_roles.append(role_name)
        except iam.exceptions.NoSuchEntityException:
            continue
    return revoked_roles

def _get_keycloak_admin_token() -> str:
    admin_password = ssm.get_parameter(
        Name=f"/keycloak/{NAME_PREFIX}/admin-password", WithDecryption=True
    )["Parameter"]["Value"]

    data = urllib.parse.urlencode({
        "client_id": "admin-cli",
        "grant_type": "password",
        "username": "admin",
        "password": admin_password,
    }).encode()
    req = urllib.request.Request(
        f"https://{KEYCLOAK_HOST}/realms/master/protocol/openid-connect/token",
        data=data, method="POST",
    )
    with urllib.request.urlopen(req, context=_INSECURE_SSL_CONTEXT) as resp:
        return json.loads(resp.read())["access_token"]

def _get_keycloak_user_id(username: str, admin_token: str) -> str | None:
    headers = {"Authorization": f"Bearer {admin_token}"}
    req = urllib.request.Request(
        f"https://{KEYCLOAK_HOST}/admin/realms/{REALM_NAME}/users?username={username}&exact=true",
        headers=headers,
    )
    with urllib.request.urlopen(req, context=_INSECURE_SSL_CONTEXT) as resp:
        users = json.loads(resp.read())
    return users[0]["id"] if users else None

def _logout_keycloak_user(user_id: str, admin_token: str):
    headers = {"Authorization": f"Bearer {admin_token}"}

    req = urllib.request.Request(
        f"https://{KEYCLOAK_HOST}/admin/realms/{REALM_NAME}/users/{user_id}/logout",
        headers=headers, method="POST",
    )
    urllib.request.urlopen(req, context=_INSECURE_SSL_CONTEXT)

def _disable_keycloak_user(user_id: str, admin_token: str):

    headers = {"Authorization": f"Bearer {admin_token}", "Content-Type": "application/json"}
    req = urllib.request.Request(
        f"https://{KEYCLOAK_HOST}/admin/realms/{REALM_NAME}/users/{user_id}",
        data=json.dumps({"enabled": False}).encode("utf-8"),
        headers=headers, method="PUT",
    )
    urllib.request.urlopen(req, context=_INSECURE_SSL_CONTEXT)

def _extract_username(event: dict) -> str:

    if "username" in event:
        return event["username"]

    try:
        finding = event["detail"]["findings"][0]
        return finding["Resources"][0]["Details"]["AwsIamRole"]["RoleSessionName"]
    except (KeyError, IndexError):
        raise ValueError("username을 이벤트에서 추출하지 못했습니다. {'username': '...'} 형태로 수동 재호출하세요.")

def handler(event, context):
    username = _extract_username(event)

    revoked_roles = _revoke_aws_sessions(username)

    keycloak_logged_out = False
    keycloak_disabled = False
    try:
        admin_token = _get_keycloak_admin_token()
        user_id = _get_keycloak_user_id(username, admin_token)
        if user_id:
            _logout_keycloak_user(user_id, admin_token)
            keycloak_logged_out = True
            _disable_keycloak_user(user_id, admin_token)
            keycloak_disabled = True
    except Exception as e:
        keycloak_logged_out = f"실패: {e}"

    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject=f"🚨 세션 강제 종료: {username}",
        Message=(
            f"대상: {username}\n"
            f"AWS 세션 차단 완료 Role: {', '.join(revoked_roles) if revoked_roles else '없음'}\n"
            f"Keycloak 로그아웃: {keycloak_logged_out}\n"
            f"Keycloak 계정 비활성화: {keycloak_disabled} (관리자가 다시 활성화하기 전까지 재로그인 불가)\n"
            f"참고: 정책 반영까지 최대 몇 분 소요될 수 있음(AWS 공식 안내)."
        ),
    )

    return {
        "statusCode": 200,
        "username": username,
        "revoked_roles": revoked_roles,
        "keycloak_logged_out": keycloak_logged_out,
        "keycloak_disabled": keycloak_disabled,
    }
