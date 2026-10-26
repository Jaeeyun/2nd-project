#!/usr/bin/env bash
set -euo pipefail

REGION="${REGION:?필요}"
NAME_PREFIX="${NAME_PREFIX:?필요}"
REALM_NAME="${REALM_NAME:?필요}"
DEV_GENERAL_ROLE_ARN="${DEV_GENERAL_ROLE_ARN:?필요}"
DEV_LEAD_ROLE_ARN="${DEV_LEAD_ROLE_ARN:?필요}"
DEV_HR_BACKEND_ROLE_ARN="${DEV_HR_BACKEND_ROLE_ARN:?필요}"
DB_GENERAL_ROLE_ARN="${DB_GENERAL_ROLE_ARN:?필요}"
DB_LEAD_ROLE_ARN="${DB_LEAD_ROLE_ARN:?필요}"
OPS_GENERAL_ROLE_ARN="${OPS_GENERAL_ROLE_ARN:?필요}"
OPS_LEAD_ROLE_ARN="${OPS_LEAD_ROLE_ARN:?필요}"
SECURITY_AUDITOR_ROLE_ARN="${SECURITY_AUDITOR_ROLE_ARN:?필요}"
SAML_PROVIDER_ARN="${SAML_PROVIDER_ARN:?필요}"
TEST_USER_PASSWORD="${TEST_USER_PASSWORD:?필요}"

ADMIN_PASSWORD=$(aws ssm get-parameter --name "/keycloak/${NAME_PREFIX}/admin-password" \
  --with-decryption --region "$REGION" --query Parameter.Value --output text)

echo "Keycloak 컨테이너 준비 대기 중..."
for i in $(seq 1 90); do
  if curl -sfk https://localhost/realms/master > /dev/null 2>&1; then
    echo "Keycloak 준비 완료"
    break
  fi
  if [ "$i" -eq 90 ]; then
    echo "타임아웃: Keycloak 컨테이너가 15분 내에 준비되지 않았습니다." >&2
    exit 1
  fi
  sleep 10
done

KC="docker exec -i keycloak /opt/keycloak/bin/kcadm.sh"

$KC config credentials \
  --server http://localhost:8080 --realm master --user admin --password "$ADMIN_PASSWORD"

if ! $KC get realms/"$REALM_NAME" > /dev/null 2>&1; then
  $KC create realms -s realm="$REALM_NAME" -s enabled=true

  $KC update realms/"$REALM_NAME" \
    -s otpPolicyType=totp -s otpPolicyAlgorithm=HmacSHA1 -s otpPolicyDigits=6 \
    -s otpPolicyInitialCounter=0 -s otpPolicyPeriod=30 \
    -s bruteForceProtected=true -s failureFactor=5 -s waitIncrementSeconds=60 \
    -s quickLoginCheckMilliSeconds=1000 -s minimumQuickLoginWaitSeconds=60 \
    -s maxFailureWaitSeconds=900 -s maxDeltaTimeSeconds=43200
else
  echo "realm $REALM_NAME 이미 존재 - 섹션 7 건너뜀"
fi

if ! $KC get authentication/flows/browser-with-opa-gate > /dev/null 2>&1; then
  $KC create authentication/flows/browser/copy -r "$REALM_NAME" -b '{"newName":"browser-with-opa-gate"}'

  $KC create "authentication/flows/browser-with-opa-gate%20forms/executions/execution" \
    -r "$REALM_NAME" -b '{"provider":"opa-context-gate"}'

  OPA_EXEC_JSON=$($KC get authentication/flows/browser-with-opa-gate/executions -r "$REALM_NAME" \
    | python3 -c "
import json, sys
data = json.load(sys.stdin)
e = [x for x in data if x.get('providerId') == 'opa-context-gate'][0]
print(json.dumps({'id': e['id'], 'priority': e['priority'], 'requirement': 'REQUIRED'}))
")
  $KC update authentication/flows/browser-with-opa-gate/executions -r "$REALM_NAME" -b "${OPA_EXEC_JSON}"

  $KC update realms/"$REALM_NAME" -s browserFlow=browser-with-opa-gate
else
  echo "browser-with-opa-gate 플로우 이미 존재 - 섹션 7-1 건너뜀"
fi

$KC update users/profile -r "$REALM_NAME" -f - <<'PROFILE'
{
  "attributes": [
    {"name": "username"},
    {"name": "email"}
  ],
  "unmanagedAttributePolicy": "ENABLED"
}
PROFILE

if [ -z "$($KC get clients -r "$REALM_NAME" -q clientId=urn:amazon:webservices --fields id --format csv --noquotes | tail -1 | tr -d '\r')" ]; then
  $KC create clients -r "$REALM_NAME" -f - <<'CLIENT'
{
  "clientId": "urn:amazon:webservices",
  "name": "AWS Console/CLI (SAML)",
  "protocol": "saml",
  "enabled": true,
  "fullScopeAllowed": false,
  "attributes": {
    "saml_assertion_consumer_url_post": "https://signin.aws.amazon.com/saml",
    "saml_name_id_format": "email",
    "saml.server.signature": "true",
    "saml.assertion.signature": "true",
    "saml.authnstatement": "true",
    "saml_force_post_binding": "true",
    "saml_idp_initiated_sso_url_name": "aws"
  }
}
CLIENT

  CID=$($KC get clients -r "$REALM_NAME" -q clientId=urn:amazon:webservices --fields id --format csv --noquotes | tail -1 | tr -d '\r')

  $KC create clients/"$CID"/protocol-mappers/models -r "$REALM_NAME" -f - <<'M1'
{"name":"aws-role-list","protocol":"saml","protocolMapper":"saml-user-attribute-mapper",
 "config":{"attribute.name":"https://aws.amazon.com/SAML/Attributes/Role","attribute.nameformat":"Basic","user.attribute":"aws_role_arn"}}
M1

  $KC create clients/"$CID"/protocol-mappers/models -r "$REALM_NAME" -f - <<'M2'
{"name":"aws-role-session-name","protocol":"saml","protocolMapper":"saml-user-property-mapper",
 "config":{"attribute.name":"https://aws.amazon.com/SAML/Attributes/RoleSessionName","attribute.nameformat":"Basic","user.attribute":"username"}}
M2

  $KC create clients/"$CID"/protocol-mappers/models -r "$REALM_NAME" -f - <<'M3'
{"name":"aws-session-duration","protocol":"saml","protocolMapper":"saml-hardcode-attribute-mapper",
 "config":{"attribute.name":"https://aws.amazon.com/SAML/Attributes/SessionDuration","attribute.nameformat":"Basic","attribute.value":"3600"}}
M3
else
  echo "urn:amazon:webservices 클라이언트 이미 존재 - 섹션 9/10 건너뜀"
fi

create_role_group() {
  local group_name="$1"
  local role_arn="$2"

  if [ -n "$($KC get groups -r "$REALM_NAME" -q search="$group_name" --fields id --format csv --noquotes | tail -1 | tr -d '\r')" ]; then
    echo "group $group_name 이미 존재 - 건너뜀"
    return
  fi

  $KC create groups -r "$REALM_NAME" -f - <<GRPEOF
{"name": "$group_name", "attributes": {"aws_role_arn": ["$role_arn,$SAML_PROVIDER_ARN"]}}
GRPEOF
}

create_role_group "dev-general"       "${DEV_GENERAL_ROLE_ARN}"
create_role_group "dev-lead"          "${DEV_LEAD_ROLE_ARN}"
create_role_group "dev-hr-backend"    "${DEV_HR_BACKEND_ROLE_ARN}"
create_role_group "db-general"        "${DB_GENERAL_ROLE_ARN}"
create_role_group "db-lead"           "${DB_LEAD_ROLE_ARN}"
create_role_group "ops-general"       "${OPS_GENERAL_ROLE_ARN}"
create_role_group "ops-lead"          "${OPS_LEAD_ROLE_ARN}"
create_role_group "security-auditor" "${SECURITY_AUDITOR_ROLE_ARN}"

create_test_user_in_group() {
  local username="$1"
  local group_name="$2"

  if [ -n "$($KC get users -r "$REALM_NAME" -q username="$username" --fields id --format csv --noquotes | tail -1 | tr -d '\r')" ]; then
    echo "user $username 이미 존재 - 건너뜀"
    return
  fi

  $KC create users -r "$REALM_NAME" -f - <<USREOF
{
  "username": "$username",
  "enabled": true,
  "email": "${username}@example.com",
  "emailVerified": true,
  "requiredActions": ["UPDATE_PASSWORD", "CONFIGURE_TOTP"]
}
USREOF

  local group_id
  group_id=$($KC get groups -r "$REALM_NAME" -q search="$group_name" --fields id,name --format csv --noquotes \
    | grep ",$group_name$" | cut -d, -f1)
  local user_id
  user_id=$($KC get users -r "$REALM_NAME" -q username="$username" --fields id --format csv --noquotes | tail -1)

  $KC update "users/${user_id}/groups/${group_id}" -r "$REALM_NAME" -f - <<< '{}'
  $KC set-password -r "$REALM_NAME" --username "$username" --new-password "$TEST_USER_PASSWORD" --temporary
}

create_test_user_in_group "test-dev-general"      "dev-general"
create_test_user_in_group "test-dev-lead"          "dev-lead"
create_test_user_in_group "test-dev-hr-backend"    "dev-hr-backend"
create_test_user_in_group "test-db-general"        "db-general"
create_test_user_in_group "test-db-lead"           "db-lead"
create_test_user_in_group "test-ops-general"       "ops-general"
create_test_user_in_group "test-ops-lead"          "ops-lead"
create_test_user_in_group "test-security-auditor" "security-auditor"

create_hr_app_user() {
  local email="$1"

  if [ -n "$($KC get users -r "$REALM_NAME" -q username="$email" --fields id --format csv --noquotes | tail -1 | tr -d '\r')" ]; then
    echo "user $email 이미 존재 - 건너뜀"
    return
  fi

  $KC create users -r "$REALM_NAME" -f - <<USREOF
{
  "username": "$email",
  "enabled": true,
  "email": "$email",
  "emailVerified": true,
  "requiredActions": ["UPDATE_PASSWORD", "CONFIGURE_TOTP"]
}
USREOF

  $KC set-password -r "$REALM_NAME" --username "$email" --new-password "$TEST_USER_PASSWORD" --temporary
}

create_hr_app_user "chulsoo.kim@company.com"
create_hr_app_user "younghee.lee@company.com"
create_hr_app_user "gildong.hong@company.com"
create_hr_app_user "minsu.park@company.com"

if [ -z "$($KC get users -r "$REALM_NAME" -q username="test-session-revoke-demo" --fields id --format csv --noquotes | tail -1 | tr -d '\r')" ]; then
  $KC create users -r "$REALM_NAME" -f - <<USREOF
{
  "username": "test-session-revoke-demo",
  "enabled": true,
  "email": "test-session-revoke-demo@example.com",
  "emailVerified": true,
  "requiredActions": []
}
USREOF
  SESSION_DEMO_GROUP_ID=$($KC get groups -r "$REALM_NAME" -q search="dev-general" --fields id,name --format csv --noquotes \
    | grep ",dev-general$" | cut -d, -f1)
  SESSION_DEMO_USER_ID=$($KC get users -r "$REALM_NAME" -q username="test-session-revoke-demo" --fields id --format csv --noquotes | tail -1)
  $KC update "users/${SESSION_DEMO_USER_ID}/groups/${SESSION_DEMO_GROUP_ID}" -r "$REALM_NAME" -f - <<< '{}'
  $KC set-password -r "$REALM_NAME" --username "test-session-revoke-demo" --new-password "$TEST_USER_PASSWORD" --temporary=false
else
  echo "test-session-revoke-demo 이미 존재 - 섹션 13 건너뜀"
fi

echo "Keycloak realm 부트스트랩 완료."
echo "테스트 계정 8개(Role별 1명씩) 전부 동일한 임시 비밀번호로 생성됨."
