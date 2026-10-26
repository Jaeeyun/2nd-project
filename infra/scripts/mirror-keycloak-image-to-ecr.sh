#!/usr/bin/env bash
set -euo pipefail

KEYCLOAK_VERSION="${KEYCLOAK_VERSION:-26.7.0}"
SOURCE_IMAGE="quay.io/keycloak/keycloak:${KEYCLOAK_VERSION}"

cd "$(dirname "$0")/.."
ECR_REPOSITORY_URL=$(terraform output -raw keycloak_ecr_repository_url)
REGISTRY="${ECR_REPOSITORY_URL%%/*}"
REGION=$(echo "$REGISTRY" | cut -d. -f4)

echo "▶ ${SOURCE_IMAGE} pull 중..."
docker pull --platform linux/amd64 "$SOURCE_IMAGE"

echo "▶ ${ECR_REPOSITORY_URL}:${KEYCLOAK_VERSION}로 태깅"
docker tag "$SOURCE_IMAGE" "${ECR_REPOSITORY_URL}:${KEYCLOAK_VERSION}"

echo "▶ ECR 로그인"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"

echo "▶ push 중..."
docker push "${ECR_REPOSITORY_URL}:${KEYCLOAK_VERSION}"

echo ""
echo "완료. scan_on_push=true라 push 직후 자동으로 취약점 스캔이 시작됩니다."
echo "결과 확인: aws ecr describe-image-scan-findings --repository-name $(basename "$ECR_REPOSITORY_URL") --image-id imageTag=${KEYCLOAK_VERSION}"
echo ""
echo "MIRROR_DONE - ${ECR_REPOSITORY_URL}:${KEYCLOAK_VERSION}"
