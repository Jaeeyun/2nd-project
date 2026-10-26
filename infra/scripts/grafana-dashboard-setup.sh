#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

GRAFANA_ENDPOINT="${GRAFANA_ENDPOINT:-$(terraform output -raw grafana_workspace_endpoint)}"
GRAFANA_URL="https://${GRAFANA_ENDPOINT}"
KEYCLOAK_ENDPOINT="${KEYCLOAK_ENDPOINT:-$(terraform output -raw keycloak_alb_dns_name)}"
KEYCLOAK_USER="${KEYCLOAK_USER:?KEYCLOAK_USER 필요(예: test-ops-lead, Grafana Admin 역할 매핑된 계정)}"
KEYCLOAK_PASSWORD="${KEYCLOAK_PASSWORD:?KEYCLOAK_PASSWORD 필요}"
JAR="$(mktemp)"
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

echo "▶ SAML 로그인으로 세션 확보"
REDIRECT=$(curl -sk -A "$UA" -c "$JAR" -D - -o /dev/null --max-time 10 "$GRAFANA_URL/login/saml" | grep -i "^location:" | sed 's/location: //I' | tr -d '\r')
KC_LOGIN_PAGE=$(mktemp)
curl -sk -A "$UA" -b "$JAR" -c "$JAR" --max-time 10 "$REDIRECT" -o "$KC_LOGIN_PAGE"
FORM_ACTION=$(grep -o 'action="[^"]*"' "$KC_LOGIN_PAGE" | head -1 | sed 's/action="//;s/"$//' | sed 's/\&amp;/\&/g')
LOGIN_RESP=$(mktemp)
curl -sk -A "$UA" -b "$JAR" -c "$JAR" --max-time 15 \
  --data-urlencode "username=$KEYCLOAK_USER" \
  --data-urlencode "password=$KEYCLOAK_PASSWORD" \
  --data-urlencode "credentialId=" \
  "$FORM_ACTION" -o "$LOGIN_RESP"

python3 -c "
import re
html = open('$LOGIN_RESP').read()
sr = re.search(r'name=\"SAMLResponse\" value=\"([^\"]*)\"', html)
rs = re.search(r'name=\"RelayState\" value=\"([^\"]*)\"', html)
open('/tmp/g_saml_response.txt','w').write(sr.group(1))
open('/tmp/g_relay_state.txt','w').write(rs.group(1))
"
curl -sk -A "$UA" -b "$JAR" -c "$JAR" --max-time 15 \
  --data-urlencode "SAMLResponse@/tmp/g_saml_response.txt" \
  --data-urlencode "RelayState@/tmp/g_relay_state.txt" \
  "$GRAFANA_URL/saml/acs" -o /dev/null
rm -f /tmp/g_saml_response.txt /tmp/g_relay_state.txt "$KC_LOGIN_PAGE" "$LOGIN_RESP"

WHOAMI=$(curl -sk -b "$JAR" "$GRAFANA_URL/api/user")
echo "  로그인: $WHOAMI"

echo "▶ 서비스 계정 + 토큰 생성(멱등 - 이미 있으면 재사용)"
SA_ID=$(curl -sk -b "$JAR" "$GRAFANA_URL/api/serviceaccounts/search?query=terraform-automation" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['serviceAccounts'][0]['id'] if d['serviceAccounts'] else '')")
if [ -z "$SA_ID" ]; then
  SA_ID=$(curl -sk -b "$JAR" -X POST "$GRAFANA_URL/api/serviceaccounts" -H "Content-Type: application/json" \
    -d '{"name":"terraform-automation","role":"Admin"}' | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
fi
echo "  SA_ID=$SA_ID"
TOKEN=$(curl -sk -b "$JAR" -X POST "$GRAFANA_URL/api/serviceaccounts/$SA_ID/tokens" -H "Content-Type: application/json" \
  -d '{"name":"automation-token-'"$(date +%s)"'","secondsToLive":86400}' | python3 -c "import json,sys; print(json.load(sys.stdin)['key'])")
echo "  발급된 토큰(24시간 유효, 재실행 시마다 새로 발급됨)"

auth() { curl -sk -H "Authorization: Bearer $TOKEN" "$@"; }

echo "▶ CloudWatch 데이터소스 생성(이미 있으면 건너뜀)"
CW_UID=$(auth "$GRAFANA_URL/api/datasources/name/CloudWatch" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('uid',''))" 2>/dev/null || true)
if [ -z "$CW_UID" ]; then
  CW_UID=$(auth -X POST "$GRAFANA_URL/api/datasources" -H "Content-Type: application/json" -d '{
    "name": "CloudWatch", "type": "cloudwatch", "access": "proxy",
    "jsonData": {"authType": "default", "defaultRegion": "ap-northeast-2"}
  }' | python3 -c "import json,sys; print(json.load(sys.stdin)['datasource']['uid'])")
fi
echo "  CW_UID=$CW_UID"

echo "▶ Athena 데이터소스 생성(이미 있으면 건너뜀) - 플러그인 관리 API 활성화 필요"
aws grafana update-workspace-configuration --workspace-id "$(terraform output -raw grafana_workspace_id 2>/dev/null || echo)" \
  --configuration '{"unifiedAlerting":{"enabled":false},"plugins":{"pluginAdminEnabled":true}}' 2>&1 || true
ATHENA_UID=$(auth "$GRAFANA_URL/api/datasources/name/Athena" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('uid',''))" 2>/dev/null || true)
if [ -z "$ATHENA_UID" ]; then
  auth -X POST "$GRAFANA_URL/api/plugins/grafana-athena-datasource/install" -H "Content-Type: application/json" -d '{}' >/dev/null || true
  SECURITY_LAKE_BUCKET=$(aws s3api list-buckets --query "Buckets[?starts_with(Name,'aws-security-data-lake-')].Name | [0]" --output text)
  ATHENA_UID=$(auth -X POST "$GRAFANA_URL/api/datasources" -H "Content-Type: application/json" -d '{
    "name": "Athena", "type": "grafana-athena-datasource", "access": "proxy",
    "jsonData": {
      "authType": "default", "defaultRegion": "ap-northeast-2", "catalog": "AwsDataCatalog",
      "database": "amazon_security_lake_glue_db_ap_northeast_2", "workgroup": "primary",
      "outputLocation": "s3://'"$SECURITY_LAKE_BUCKET"'/athena-results/"
    }
  }' | python3 -c "import json,sys; print(json.load(sys.stdin)['datasource']['uid'])")
fi
echo "  ATHENA_UID=$ATHENA_UID"

DASHBOARD_JSON="${DASHBOARD_JSON:-docs/grafana/grafana-soc-dashboard.json}"
echo "▶ 대시보드 프로비저닝 ($DASHBOARD_JSON, UID는 이 스크립트가 만든 데이터소스 UID로 치환)"
RENDERED=$(mktemp)
python3 -c "
import json
with open('$DASHBOARD_JSON') as f:
    d = json.load(f)
def replace_uid(obj):
    if isinstance(obj, dict):
        if obj.get('type') == 'cloudwatch':
            obj['uid'] = '$CW_UID'
        elif obj.get('type') == 'grafana-athena-datasource':
            obj['uid'] = '$ATHENA_UID'
        for v in obj.values():
            replace_uid(v)
    elif isinstance(obj, list):
        for v in obj:
            replace_uid(v)
replace_uid(d)
with open('$RENDERED', 'w') as f:
    json.dump(d, f)
"
DASHBOARD_UID=$(python3 -c "import json; print(json.load(open('$DASHBOARD_JSON'))['dashboard']['uid'])")
auth -X POST "$GRAFANA_URL/api/dashboards/db" -H "Content-Type: application/json" -d @"$RENDERED"
echo
echo "GRAFANA_DASHBOARD_SETUP_DONE - $GRAFANA_URL/d/$DASHBOARD_UID"
rm -f "$JAR" "$RENDERED"
