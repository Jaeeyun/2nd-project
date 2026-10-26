#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"

SCRIPTS=(
  "03-role-rbac-boundaries.sh"
  "05-rds-pii-masking.sh"
  "06-rds-audit-worm.sh"
  "07-eks-pod-isolation.sh"
  "08-asr-remediation.sh"
  "09-permission-drift.sh"
  "10-session-revocation.sh"
  "11-boundary-drift.sh"
  "12-cicd-oidc-audit.sh"
  "13-grafana-soc-dashboard.sh"
)

REPORT_LINES=()
OVERALL_PASS=1
START_TS=$(date +%s)

echo "════════════════════════════════════════════════════════════════"
echo " 10개 시나리오 전체 실행 시작 - $(date -u +%FT%TZ)"
echo "════════════════════════════════════════════════════════════════"

for script in "${SCRIPTS[@]}"; do
  echo
  echo "──────────────────────────────────────────────────────────────"
  echo " ▶▶▶ 실행: $script"
  echo "──────────────────────────────────────────────────────────────"
  OUT=$(./"$script" 2>&1)
  echo "$OUT"
  LINE=$(echo "$OUT" | grep -E "^\| Scene" | tail -1)
  if [ -n "$LINE" ]; then
    REPORT_LINES+=("$LINE")
  else
    REPORT_LINES+=("| Scene ?  | $script (리포트 라인 파싱 실패)                     | FAILED  | -")
  fi
  echo "$LINE" | grep -q "FAILED" && OVERALL_PASS=0
done

END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))

echo
echo "════════════════════════════════════════════════════════════════"
echo " 종합 결과 (총 소요: ${ELAPSED}초)"
echo "════════════════════════════════════════════════════════════════"
printf '| %-8s | %-53s | %-7s | %s\n' "Scene" "목적" "결과" "핵심 명령어"
printf '|%s|%s|%s|%s\n' "----------" "-------------------------------------------------------" "---------" "----------------------------------------"
for line in "${REPORT_LINES[@]}"; do
  echo "$line"
done

echo
if [ "$OVERALL_PASS" = "1" ]; then
  echo "✅ 전체 10개 시나리오 PASSED - 촬영 대기 상태로 세팅 완료"
else
  echo "❌ 일부 시나리오 FAILED - 위 표에서 FAILED 항목 확인 필요"
  exit 1
fi
