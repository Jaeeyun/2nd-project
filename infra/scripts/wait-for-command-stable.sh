#!/usr/bin/env bash
set -uo pipefail

MODE="${1:?사용법: $0 <denied|allowed> [간격초] [연속횟수] -- <aws 명령...>}"
shift
INTERVAL="${1:-10}"
shift || true
CONSECUTIVE_NEEDED="${1:-3}"
shift || true

if [ "${1:-}" = "--" ]; then
  shift
fi
CMD=("$@")

if [ "${#CMD[@]}" -eq 0 ]; then
  echo "❌ 폴링할 명령이 없습니다. -- 뒤에 aws 명령을 붙여주세요." >&2
  exit 1
fi
if [ "$MODE" != "denied" ] && [ "$MODE" != "allowed" ]; then
  echo "❌ 첫 인자는 denied 또는 allowed 여야 합니다." >&2
  exit 1
fi

echo "▶ 명령: ${CMD[*]}"
echo "▶ 목표 상태: ${MODE} (${INTERVAL}초 간격, 연속 ${CONSECUTIVE_NEEDED}번 같은 상태가 나와야 완료로 판단)"

START=$(date +%s)
STREAK=0
FIRST_HIT_ELAPSED=""
while true; do
  RESULT=$("${CMD[@]}" 2>&1)
  NOW=$(date -u +%T)

  if echo "$RESULT" | grep -qi "AccessDenied\|explicit deny\|not authorized"; then
    CURRENT="denied"
  else
    CURRENT="allowed"
  fi

  if [ "$CURRENT" = "$MODE" ]; then
    STREAK=$(( STREAK + 1 ))
    if [ -z "$FIRST_HIT_ELAPSED" ]; then
      FIRST_HIT_ELAPSED=$(( $(date +%s) - START ))
    fi
    echo "  목표 상태(${MODE}) 확인 (${STREAK}/${CONSECUTIVE_NEEDED} 연속) ($NOW)"
    if [ "$STREAK" -ge "$CONSECUTIVE_NEEDED" ]; then
      ELAPSED=$(( $(date +%s) - START ))
      echo "✅ 안정적으로 ${MODE} 상태 확인! 총 경과: ${ELAPSED}초 ($(( ELAPSED / 60 ))분 $(( ELAPSED % 60 ))초)"
      echo "   (첫 감지는 ${FIRST_HIT_ELAPSED}초에 떴지만, 전파가 덜 끝나 그 뒤 잠깐 되돌아갔을 수도 있음)"
      break
    fi
  else
    if [ "$STREAK" -gt 0 ]; then
      echo "  ⚠️  다시 ${CURRENT} 상태로 돌아옴 - 아직 전파 중(연속 스트릭 초기화) ($NOW)"
    else
      echo "  아직 ${CURRENT} 상태 (목표: ${MODE})... ($NOW)"
    fi
    STREAK=0
    FIRST_HIT_ELAPSED=""
  fi
  sleep "$INTERVAL"
done
