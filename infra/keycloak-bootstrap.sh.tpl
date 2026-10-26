#!/usr/bin/env bash
set -euo pipefail

REGION="${region}"
NAME_PREFIX="${name_prefix}"
ECR_REPOSITORY_URL="${ecr_repository_url}"
ALB_DNS_NAME="${alb_dns_name}"
OPA_ARTIFACTS_BUCKET="${opa_artifacts_bucket}"
OPA_DECISION_LOG_GROUP="${opa_decision_log_group}"

dnf install -y amazon-ssm-agent
systemctl enable --now amazon-ssm-agent

dnf update -y
dnf install -y docker
systemctl enable --now docker

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
MY_PRIVATE_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)

mkdir -p /opt/keycloak/certs
openssl req -x509 -newkey rsa:4096 -sha256 -days 30 -nodes \
  -keyout /opt/keycloak/certs/key.pem \
  -out /opt/keycloak/certs/cert.pem \
  -subj "/CN=keycloak.internal.local" \
  -addext "subjectAltName=DNS:keycloak.internal.local,DNS:$${ALB_DNS_NAME},IP:$${MY_PRIVATE_IP}"

chmod 644 /opt/keycloak/certs/key.pem
chmod 644 /opt/keycloak/certs/cert.pem

ADMIN_PASSWORD=$(openssl rand -base64 24)
aws ssm put-parameter \
  --name "/keycloak/$${NAME_PREFIX}/admin-password" \
  --value "$ADMIN_PASSWORD" \
  --type "SecureString" \
  --overwrite \
  --region "$REGION"

mkdir -p /opt/keycloak/providers /opt/opa /var/log/opa

aws s3 cp "s3://$${OPA_ARTIFACTS_BUCKET}/bin/opa" /usr/local/bin/opa
chmod +x /usr/local/bin/opa

aws s3 cp "s3://$${OPA_ARTIFACTS_BUCKET}/policies/login_context.rego" /opt/opa/login_context.rego

aws s3 cp "s3://$${OPA_ARTIFACTS_BUCKET}/spi/opa-context-authenticator-1.0.0.jar" \
  /opt/keycloak/providers/opa-context-authenticator.jar

cat > /etc/systemd/system/opa.service <<'OPAUNIT'
[Unit]
Description=OPA login context gate (ADR-022)
After=network.target

[Service]
Environment=DEVICE_POSTURE_LOOKUP_URL=${device_posture_lookup_url}
Environment=DEVICE_POSTURE_LOOKUP_API_KEY=${device_posture_lookup_api_key}
Environment=OPERATOR_ALLOWED_CIDRS=${operator_allowed_cidrs}
ExecStart=/usr/local/bin/opa run --server --addr 0.0.0.0:8181 --set decision_logs.console=true /opt/opa/login_context.rego
Restart=always
RestartSec=3
StandardOutput=append:/var/log/opa/opa.log
StandardError=append:/var/log/opa/opa.log

[Install]
WantedBy=multi-user.target
OPAUNIT

systemctl daemon-reload
systemctl enable --now opa

echo "OPA 기동 대기 중..."
for i in $(seq 1 30); do
  if curl -sf http://127.0.0.1:8181/health > /dev/null 2>&1; then
    echo "OPA 준비 완료"
    break
  fi
  sleep 2
done

dnf install -y python3-boto3
mkdir -p /opt/opa-shipper
aws s3 cp "s3://$${OPA_ARTIFACTS_BUCKET}/scripts/opa-decision-log-shipper.py" \
  /opt/opa-shipper/opa-decision-log-shipper.py

cat > /etc/systemd/system/opa-shipper.service <<UNITEOF
[Unit]
Description=OPA decision log -> CloudWatch Logs shipper (ADR-022)

[Service]
Type=oneshot
Environment=LOG_GROUP_NAME=$${OPA_DECISION_LOG_GROUP}
ExecStart=/usr/bin/python3 /opt/opa-shipper/opa-decision-log-shipper.py
UNITEOF

cat > /etc/systemd/system/opa-shipper.timer <<'TIMEREOF'
[Unit]
Description=Run opa-shipper every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
TIMEREOF

systemctl daemon-reload
systemctl enable --now opa-shipper.timer

aws ecr get-login-password --region "$REGION" | \
  docker login --username AWS --password-stdin "$ECR_REPOSITORY_URL"

docker run -d \
  --name keycloak \
  --restart unless-stopped \
  -p 443:8443 \
  --add-host=host.docker.internal:host-gateway \
  -e KEYCLOAK_ADMIN=admin \
  -e KEYCLOAK_ADMIN_PASSWORD="$ADMIN_PASSWORD" \
  -e KC_HTTPS_CERTIFICATE_FILE=/etc/keycloak/certs/cert.pem \
  -e KC_HTTPS_CERTIFICATE_KEY_FILE=/etc/keycloak/certs/key.pem \
  -e KC_HOSTNAME=https://${alb_dns_name}/ \
  -e OPA_URL=http://host.docker.internal:8181/v1/data/login_context/allow \
  -v /opt/keycloak/certs:/etc/keycloak/certs:ro \
  -v /opt/keycloak/providers:/opt/keycloak/providers:ro \
  "$ECR_REPOSITORY_URL:26.7.0" \
  start-dev --log-level=info,org.keycloak.events:debug

echo "Keycloak 기동 대기 중..."
for i in $(seq 1 60); do
  if curl -sfk https://localhost/realms/master > /dev/null 2>&1; then
    echo "Keycloak 준비 완료"
    break
  fi
  sleep 5
done

KC="docker exec -i keycloak /opt/keycloak/bin/kcadm.sh"

echo "Keycloak 컨테이너 기동 완료. admin 비밀번호: SSM Parameter /keycloak/$${NAME_PREFIX}/admin-password"
