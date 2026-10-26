#!/usr/bin/env bash
set -euo pipefail

ROLE_SUFFIX="${1:?사용법: $0 <role-suffix>}"

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TARGET="aws_iam_role_policy.standard[\"${ROLE_SUFFIX}\"]"

echo "▶ ${TARGET} 를 policies/*.json.tpl 원본 정책으로 되돌립니다"
terraform apply -target="$TARGET" -auto-approve

echo ""
echo "▶ 최종 확인 (복원된 정책의 Action 목록)"
NAME_PREFIX=$(terraform output -raw name_prefix)
ROLE_NAME="${NAME_PREFIX}-${ROLE_SUFFIX}"
POLICY_NAME=$(aws iam list-role-policies --role-name "$ROLE_NAME" --query 'PolicyNames[0]' --output text)
aws iam get-role-policy --role-name "$ROLE_NAME" --policy-name "$POLICY_NAME" \
  --query 'PolicyDocument.Statement[*].Action'

echo ""
echo "Clean Ready State 완료 (${ROLE_SUFFIX})."
echo "⚠️ 방금 복원된 넓은 정책도 IAM 전파 지연(최대 몇 분) 대상입니다 - 바로 다음 테이크를"
echo "  찍기 전에 wait-for-command-denied.sh 등으로 실제로 다시 풀렸는지 확인하는 걸 권장합니다."
