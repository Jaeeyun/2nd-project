#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

AWS_REGION="ap-northeast-2"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

echo "▶ ECR 로그인"
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REGISTRY"

echo "▶ employee-service"
docker build --no-cache -t employee-service:latest ./employee-service
docker tag employee-service:latest "$ECR_REGISTRY/demo-project-dev-backend-repo:employee-service-latest"
docker push "$ECR_REGISTRY/demo-project-dev-backend-repo:employee-service-latest"

echo "▶ hr-service"
docker build --no-cache -t hr-service:latest ./hr-service
docker tag hr-service:latest "$ECR_REGISTRY/demo-project-dev-backend-repo:hr-service-latest"
docker push "$ECR_REGISTRY/demo-project-dev-backend-repo:hr-service-latest"

echo "▶ frontend"
docker build --no-cache -t frontend:latest ./frontend
docker tag frontend:latest "$ECR_REGISTRY/demo-project-dev-frontend-repo:latest"
docker push "$ECR_REGISTRY/demo-project-dev-frontend-repo:latest"

echo "✅ 이미지 3개 push 완료."
