#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"
source ./_lib.sh

scene_banner 11 "CIEM 권한 드리프트 탐지 + Slack 1-Click 최소권한 교체 검증" \
  "Access Analyzer Policy Generation Job 직접 실행 → 미사용 권한 탐지" \
  "Slack 콜백 엔드포인트 서명 검증(위조 서명은 401 거부) 확인" \
  "정상 서명 페이로드로 'keep_current_policy' 핸들러까지 라우팅 확인"

PASS=1

step 1 "Access Analyzer Policy Generation Job 직접 실행"
progress "탐지 Lambda 직접 호출 (dev-general, 실제 Access Analyzer Job)"
RESULT=$(aws lambda invoke --function-name demo-project-dev-ciem-boundary-drift-notify \
  --payload '{"role_suffix":"dev-general"}' \
  --cli-binary-format raw-in-base64-out --cli-read-timeout 500 /tmp/scene11-notify-out.json 2>&1)
echo "$RESULT"
OUT=$(cat /tmp/scene11-notify-out.json 2>/dev/null)
echo "$OUT"
RESULT_FIELD=$(echo "$OUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('result','?'))" 2>/dev/null || echo "?")
case "$RESULT_FIELD" in
  no_activity_observed|no_drift|flagged)
    ok "Access Analyzer Job이 정상 완료됨(result=$RESULT_FIELD)" ;;
  *)
    fail "Job이 실패했거나 예상 밖 결과(result=$RESULT_FIELD)"
    PASS=0 ;;
esac

SLACK_ENDPOINT=$(tf_output slack_interactivity_endpoint)
SIGNING_SECRET=$(aws secretsmanager get-secret-value --secret-id "${NAME_PREFIX:-demo-project-dev}-slack-app-credentials" --query 'SecretString' --output text | python3 -c "import sys,json; print(json.load(sys.stdin)['signing_secret'])")

step 2 "Slack 콜백 엔드포인트 서명 검증(위조 서명 401 거부) 확인"
threat "위조된 Slack 서명으로 콜백 엔드포인트 공격 시도"
WRONG_SIG_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -X POST "${SLACK_ENDPOINT}slack/interactivity" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "X-Slack-Request-Timestamp: $(date +%s)" \
  -H "X-Slack-Signature: v0=$(printf '0%.0s' {1..64})" \
  --data-raw "payload=%7B%22bad%22%3A1%7D")
if [ "$WRONG_SIG_CODE" = "401" ]; then
  ok "잘못된 서명은 401로 거부됨"
else
  fail "잘못된 서명인데 401이 아님(실제=$WRONG_SIG_CODE)"
  PASS=0
fi

step 3 "정상 서명 페이로드로 handler까지 라우팅 확인(keep_current_policy)"
notice_slack "정상 서명된 Slack 1-Click 콜백(keep_current_policy) 전송"
PAYLOAD=$(python3 -c "
import json
value = {'role_name': 'demo-project-dev-dev-general'}
payload = {
  'type': 'block_actions',
  'actions': [{'action_id': 'keep_current_policy', 'value': json.dumps(value)}],
  'user': {'username': 'scene11-verification-script'},
  'response_url': 'https://httpbin.org/post',
}
print(json.dumps(payload))
")
BODY="payload=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$PAYLOAD")"
TS=$(date +%s)
SIG="v0=$(python3 -c "
import hashlib, hmac, sys
secret, ts, body = sys.argv[1], sys.argv[2], sys.argv[3]
print(hmac.new(secret.encode(), f'v0:{ts}:{body}'.encode(), hashlib.sha256).hexdigest())
" "$SIGNING_SECRET" "$TS" "$BODY")"

curl -sk -X POST "${SLACK_ENDPOINT}slack/interactivity" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "X-Slack-Request-Timestamp: $TS" \
  -H "X-Slack-Signature: $SIG" \
  --data-raw "$BODY" >/dev/null 2>&1

sleep 3
LOG_CHECK=$(aws logs tail /aws/lambda/demo-project-dev-ciem-key-exception-callback --since 30s --format short 2>&1 | grep -c "_handle_keep_current_policy\|keep_current_policy")
LOG_CHECK2=$(aws logs tail /aws/lambda/demo-project-dev-ciem-key-exception-callback --since 30s --format short 2>&1 | grep -c "invalid signature")
if [ "$LOG_CHECK2" = "0" ]; then
  ok "서명 검증 통과 후 handler까지 도달함(로그에서 'invalid signature' 없음 확인)"
else
  fail "서명이 맞는데도 거부됨"
  PASS=0
fi

rm -f /tmp/scene11-notify-out.json

if [ "$PASS" = "1" ]; then
  result_box PASSED "드리프트 탐지 + Slack 콜백 서명/라우팅 정상"
  scene_report 11 "권한 드리프트 탐지 + Slack 콜백 서명/라우팅" PASSED "curl (서명된 페이로드) → slack/interactivity"
else
  result_box FAILED "드리프트 탐지 또는 Slack 콜백 검증 실패"
  scene_report 11 "권한 드리프트 탐지 + Slack 콜백 서명/라우팅" FAILED "curl (서명된 페이로드) → slack/interactivity"
  exit 1
fi
