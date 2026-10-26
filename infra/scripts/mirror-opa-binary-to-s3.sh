#!/usr/bin/env bash
set -euo pipefail

OPA_VERSION="${OPA_VERSION:-0.70.0}"
DOWNLOAD_URL="https://openpolicyagent.org/downloads/v${OPA_VERSION}/opa_linux_amd64_static"

cd "$(dirname "$0")/.."
BUCKET=$(terraform output -raw opa_artifacts_bucket)

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "▶ OPA v${OPA_VERSION} 바이너리 다운로드 중..."
curl -sfL -o "$TMPDIR/opa" "$DOWNLOAD_URL"
chmod +x "$TMPDIR/opa"

"$TMPDIR/opa" version

echo "▶ s3://$BUCKET/bin/opa 로 업로드 중..."
aws s3 cp "$TMPDIR/opa" "s3://$BUCKET/bin/opa"

echo "완료. Keycloak EC2가 부트스트랩 시 s3://$BUCKET/bin/opa 를 s3 cp로 받아갑니다."
echo "정책 파일(login_context.rego)은 이 스크립트가 아니라 terraform apply가 자동으로 올립니다."
