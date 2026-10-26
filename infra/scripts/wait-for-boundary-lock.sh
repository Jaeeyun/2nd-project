#!/usr/bin/env bash
set -uo pipefail

PROFILE="${1:-dev-general-demo}"
INTERVAL="${2:-10}"
CONSECUTIVE_NEEDED="${3:-3}"

echo "▶ ${PROFILE} 프로필로 eks:ListClusters가 '안정적으로' 막히는 순간을 폴링합니다"
echo "  (${INTERVAL}초 간격, AccessDenied가 연속 ${CONSECUTIVE_NEEDED}번 나와야 완료로 판단 - 전파 중 오락가락 방지)"
START=$(date +%s)
STREAK=0
FIRST_DENY_ELAPSED=""
while true; do
  RESULT=$(aws eks list-clusters --profile "$PROFILE" 2>&1)
  NOW=$(date -u +%T)
  if echo "$RESULT" | grep -q "AccessDenied"; then
    STREAK=$(( STREAK + 1 ))
    if [ -z "$FIRST_DENY_ELAPSED" ]; then
      FIRST_DENY_ELAPSED=$(( $(date +%s) - START ))
    fi
    echo "  막힘 (${STREAK}/${CONSECUTIVE_NEEDED} 연속) ($NOW)"
    if [ "$STREAK" -ge "$CONSECUTIVE_NEEDED" ]; then
      ELAPSED=$(( $(date +%s) - START ))
      echo "✅ 안정적으로 막힘 확인! 총 경과: ${ELAPSED}초 ($(( ELAPSED / 60 ))분 $(( ELAPSED % 60 ))초)"
      echo "   (참고: 첫 AccessDenied는 ${FIRST_DENY_ELAPSED}초에 떴지만, 그 뒤로도 전파가 덜 끝나 잠깐 다시 성공했을 수 있음)"
      break
    fi
  else
    if [ "$STREAK" -gt 0 ]; then
      echo "  ⚠️  다시 성공함 - 아직 전파 중(연속 스트릭 초기화) ($NOW)"
    else
      echo "  아직 안 막힘... ($NOW)"
    fi
    STREAK=0
    FIRST_DENY_ELAPSED=""
  fi
  sleep "$INTERVAL"
done
