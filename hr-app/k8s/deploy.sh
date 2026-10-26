#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

TF_DIR=~/ztna-eks-poc/infra

echo "▶ terraform output / AWS CLI로 동적 값 조회 중..."
export AWS_REGION="ap-northeast-2"
export AWS_ACCOUNT_ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

export DB_HOST
DB_HOST=$(cd "$TF_DIR" && terraform output -raw rds_endpoint | cut -d: -f1)

export DB_PASSWORD
DB_PASSWORD=$(grep '^db_password' "$TF_DIR/terraform.tfvars" | sed -E 's/^db_password\s*=\s*"(.*)"$/\1/')

export KEYCLOAK_ALB_DNS
KEYCLOAK_ALB_DNS=$(cd "$TF_DIR" && terraform output -raw keycloak_alb_dns_name)
export KEYCLOAK_REALM
KEYCLOAK_REALM=$(grep -A3 'variable "keycloak_realm_name"' "$TF_DIR"/01-variables.tf | grep default | sed -E 's/.*"(.*)"/\1/')

export ISTIO_GATEWAY_TG_ARN
ISTIO_GATEWAY_TG_ARN=$(aws elbv2 describe-target-groups --names demo-project-dev-istio-gw-tg --region "$AWS_REGION" --query "TargetGroups[0].TargetGroupArn" --output text)

export DB_ACCESS_LOG_GROUP
DB_ACCESS_LOG_GROUP=$(cd "$TF_DIR" && terraform output -raw db_access_log_group_name)

echo "  AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID"
echo "  DB_HOST=$DB_HOST"
echo "  KEYCLOAK_ALB_DNS=$KEYCLOAK_ALB_DNS"
echo "  KEYCLOAK_REALM=$KEYCLOAK_REALM"
echo "  ISTIO_GATEWAY_TG_ARN=$ISTIO_GATEWAY_TG_ARN"

render() {
  local template="$1"
  local out="${template%.yaml}.rendered.yaml"
  envsubst < "$template" > "$out"
  echo "$out"
}

echo "▶ ConfigMap/Secret 렌더링 후 적용"
kubectl apply -f "$(render 00-employee-backend-config.yaml)"
kubectl apply -f "$(render 00-hr-backend-config.yaml)"

echo "▶ Deployment/Service 렌더링 후 적용"
kubectl apply -f "$(render 10-employee-service.yaml)"
kubectl apply -f "$(render 20-hr-service.yaml)"
kubectl apply -f "$(render 15-frontend.yaml)"

echo "▶ TargetGroupBinding 렌더링 후 적용 (ALB -> istio-ingressgateway 단일 바인딩)"
kubectl apply -f "$(render 25-target-group-bindings.yaml)"

echo "▶ DB 마이그레이션/시드 Job (기존 Job이 있으면 삭제 후 재실행 - Job은 수정 불가)"
kubectl delete job hr-db-migrate -n hr-backend --ignore-not-found
kubectl apply -f "$(render 40-migrate-job.yaml)"
kubectl wait --for=condition=complete job/hr-db-migrate -n hr-backend --timeout=120s

echo "▶ 롤아웃 대기"
kubectl rollout status deployment/employee-service -n employee-backend --timeout=120s
kubectl rollout status deployment/hr-service -n hr-backend --timeout=120s
kubectl rollout status deployment/frontend -n frontend --timeout=120s

EDGE_ALB_DNS=$(cd "$TF_DIR" && terraform output -raw internal_mtls_alb_dns_name)
echo
echo "✅ 배포 완료."
echo "ALB는 DNS 이름만 받고 고정 IP가 없어서, hosts 파일 대신 요청마다 --resolve로 테스트하세요:"
echo "  curl -k --resolve employee.company.com:443:\$(dig +short $EDGE_ALB_DNS | head -1) https://employee.company.com/"
echo "  curl -k --resolve hr.company.com:443:\$(dig +short $EDGE_ALB_DNS | head -1) https://hr.company.com/"
echo "브라우저로 직접 테스트하려면 C:\\Windows\\System32\\drivers\\etc\\hosts (관리자 권한)에"
echo "아래처럼 ALB가 반환하는 IP 중 하나를 넣으세요(ALB IP는 바뀔 수 있어 재조회 필요):"
echo "  dig +short $EDGE_ALB_DNS"
