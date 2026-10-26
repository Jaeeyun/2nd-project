#!/usr/bin/env bash
set -euo pipefail

ROLE_SUFFIX="${1:?사용법: $0 <role-suffix> (dev-general/dev-lead/dev-hr-backend/db-general/db-lead/ops-general/ops-lead)}"

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

NAME_PREFIX=$(terraform output -raw name_prefix)
FUNCTION_NAME="${NAME_PREFIX}-ciem-boundary-drift-notify"
OUT_FILE=$(mktemp)

echo "▶ ${FUNCTION_NAME} 비동기 호출 (role_suffix=${ROLE_SUFFIX})"
aws lambda invoke \
  --function-name "$FUNCTION_NAME" \
  --invocation-type Event \
  --cli-binary-format raw-in-base64-out \
  --payload "{\"role_suffix\": \"${ROLE_SUFFIX}\"}" \
  "$OUT_FILE" >/dev/null

STATUS_CODE=$(python3 -c "import json;print(json.load(open('$OUT_FILE')).get('StatusCode','?'))" 2>/dev/null || echo "?")
echo "  접수됨 (StatusCode: ${STATUS_CODE}, 202면 정상 접수)"
rm -f "$OUT_FILE"

echo ""
echo "▶ Policy Generation 진행상황을 실시간으로 보려면 (보통 1~3분, 최대 7분 소요):"
echo "   aws logs tail /aws/lambda/${FUNCTION_NAME} --follow --since 5m"
echo ""
echo "▶ 결과가 result=flagged면 Slack #cspm-findings 채널에 '✅ 이 권한들 제거' 버튼과 함께 알림이 옵니다."
echo "  result=no_drift면 최근 활동이 정책 전체를 다 커버함(미사용 권한 없음) - 다른 Role로 시도하거나"
echo "  일부러 정책 안의 일부 액션만 써보고 재시도하세요."
