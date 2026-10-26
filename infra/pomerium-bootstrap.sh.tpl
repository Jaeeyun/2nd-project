#!/usr/bin/env bash
set -euo pipefail

REGION="${region}"
NAME_PREFIX="${name_prefix}"
KEYCLOAK_PRIVATE_IP="${keycloak_private_ip}"
KEYCLOAK_ENDPOINT="${keycloak_endpoint}"
REALM_NAME="${realm_name}"

dnf update -y
dnf install -y docker openssl
systemctl enable --now docker

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
MY_PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4)

echo "Keycloak 응답 대기 중..."
for i in $(seq 1 90); do
  if curl -sk --max-time 5 "https://$${KEYCLOAK_PRIVATE_IP}/realms/$${REALM_NAME}" > /dev/null 2>&1; then
    echo "Keycloak 준비 완료"
    break
  fi
  echo "  아직 준비 안 됨, 10초 후 재시도... ($i/90)"
  sleep 10
done

mkdir -p /etc/pki/ca-trust/source/anchors
echo | openssl s_client -connect "$${KEYCLOAK_PRIVATE_IP}:443" -servername "$${KEYCLOAK_PRIVATE_IP}" 2>/dev/null \
  | openssl x509 > /etc/pki/ca-trust/source/anchors/keycloak.pem
update-ca-trust

cat > /etc/pki/ca-trust/source/anchors/internal-ca.pem <<'CAEOF'
${ca_cert_pem}
CAEOF
update-ca-trust

ADMIN_PASSWORD=$(aws ssm get-parameter --name "/keycloak/$${NAME_PREFIX}/admin-password" \
  --with-decryption --query Parameter.Value --output text --region "$${REGION}")

ADMIN_TOKEN=""
for i in $(seq 1 12); do
  ADMIN_TOKEN=$(curl -sfk --max-time 10 -X POST "https://$${KEYCLOAK_PRIVATE_IP}/realms/master/protocol/openid-connect/token" \
    -d "client_id=admin-cli" -d "grant_type=password" \
    -d "username=admin" --data-urlencode "password=$${ADMIN_PASSWORD}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null || echo "")
  if [ -n "$${ADMIN_TOKEN}" ]; then
    echo "관리자 토큰 발급 성공"
    break
  fi
  echo "  관리자 API 아직 준비 안 됨, 5초 후 재시도... ($i/12)"
  sleep 5
done

if [ -z "$${ADMIN_TOKEN}" ]; then
  echo "관리자 토큰 발급 최종 실패 - Keycloak 상태를 SSM으로 직접 확인하세요." >&2
  exit 1
fi

EXISTING_CLIENT=$(curl -sfk -H "Authorization: Bearer $${ADMIN_TOKEN}" \
  "https://$${KEYCLOAK_PRIVATE_IP}/admin/realms/$${REALM_NAME}/clients?clientId=pomerium" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['id'] if d else '')")

if [ -z "$${EXISTING_CLIENT}" ]; then
  echo "Pomerium OIDC 클라이언트 생성 중..."
  curl -sfk -X POST "https://$${KEYCLOAK_PRIVATE_IP}/admin/realms/$${REALM_NAME}/clients" \
    -H "Authorization: Bearer $${ADMIN_TOKEN}" -H "Content-Type: application/json" \
    -d "{
      \"clientId\": \"pomerium\",
      \"protocol\": \"openid-connect\",
      \"publicClient\": false,
      \"standardFlowEnabled\": true,
      \"directAccessGrantsEnabled\": false,
      \"redirectUris\": [\"https://$${MY_PUBLIC_IP}/oauth2/callback\"],
      \"webOrigins\": [\"https://$${MY_PUBLIC_IP}\"]
    }"
  CLIENT_UUID=$(curl -sfk -H "Authorization: Bearer $${ADMIN_TOKEN}" \
    "https://$${KEYCLOAK_PRIVATE_IP}/admin/realms/$${REALM_NAME}/clients?clientId=pomerium" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")
else
  CLIENT_UUID="$${EXISTING_CLIENT}"
  curl -sfk -H "Authorization: Bearer $${ADMIN_TOKEN}" \
    "https://$${KEYCLOAK_PRIVATE_IP}/admin/realms/$${REALM_NAME}/clients/$${CLIENT_UUID}" \
    | python3 -c "
import sys, json
c = json.load(sys.stdin)
c['redirectUris'] = ['https://$${MY_PUBLIC_IP}/oauth2/callback']
c['webOrigins'] = ['https://$${MY_PUBLIC_IP}']
print(json.dumps(c))" > /tmp/pomerium_client.json
  curl -sfk -X PUT "https://$${KEYCLOAK_PRIVATE_IP}/admin/realms/$${REALM_NAME}/clients/$${CLIENT_UUID}" \
    -H "Authorization: Bearer $${ADMIN_TOKEN}" -H "Content-Type: application/json" \
    --data @/tmp/pomerium_client.json
fi

CLIENT_SECRET=$(curl -sfk -H "Authorization: Bearer $${ADMIN_TOKEN}" \
  "https://$${KEYCLOAK_PRIVATE_IP}/admin/realms/$${REALM_NAME}/clients/$${CLIENT_UUID}/client-secret" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['value'])")

mkdir -p /opt/pomerium/certs
openssl req -x509 -newkey rsa:4096 -sha256 -days 30 -nodes \
  -keyout /opt/pomerium/certs/pomerium-key.pem \
  -out /opt/pomerium/certs/pomerium-cert.pem \
  -subj "/CN=$${MY_PUBLIC_IP}" \
  -addext "subjectAltName=IP:$${MY_PUBLIC_IP},DNS:employee.company.com,DNS:hr.company.com"
chmod 644 /opt/pomerium/certs/pomerium-key.pem /opt/pomerium/certs/pomerium-cert.pem

cat > /opt/pomerium/certs/client-cert.pem <<'CERTEOF'
${client_cert_pem}
CERTEOF
cat > /opt/pomerium/certs/client-key.pem <<'KEYEOF'
${client_key_pem}
KEYEOF
chmod 644 /opt/pomerium/certs/client-cert.pem /opt/pomerium/certs/client-key.pem

cp /etc/pki/ca-trust/source/anchors/keycloak.pem /opt/pomerium/certs/keycloak-ca.pem
chmod 644 /opt/pomerium/certs/keycloak-ca.pem

COOKIE_SECRET=$(openssl rand -base64 32)
SHARED_SECRET=$(openssl rand -base64 32)
ROUTE_COMMON="    tls_client_cert_file: /etc/pomerium/certs/client-cert.pem
    tls_client_key_file: /etc/pomerium/certs/client-key.pem
    tls_skip_verify: true
    allow_public_unauthenticated_access: false
    allow_any_authenticated_user: true
    pass_identity_headers: true"

cat > /opt/pomerium/config.yaml <<CONFEOF
address: :443
insecure_server: false
certificate_file: /etc/pomerium/certs/pomerium-cert.pem
certificate_key_file: /etc/pomerium/certs/pomerium-key.pem

cookie_secret: $${COOKIE_SECRET}
shared_secret: $${SHARED_SECRET}

authenticate_service_url: https://$${MY_PUBLIC_IP}

idp_provider: oidc
idp_provider_url: https://$${KEYCLOAK_ENDPOINT}/realms/$${REALM_NAME}
idp_client_id: pomerium
idp_client_secret: $${CLIENT_SECRET}
idp_scopes: [openid, profile, email]
certificate_authority_file: /etc/pomerium/certs/keycloak-ca.pem

routes:
  - from: https://$${MY_PUBLIC_IP}
    to: https://${alb_dns_name}
$${ROUTE_COMMON}
  - from: https://employee.company.com
    to: https://${alb_dns_name}
$${ROUTE_COMMON}
  - from: https://hr.company.com
    to: https://${alb_dns_name}
$${ROUTE_COMMON}
CONFEOF

echo "Pomerium 설정 완료. 컨테이너 기동..."

docker run -d \
  --name pomerium \
  --restart unless-stopped \
  -p 443:443 \
  -v /opt/pomerium/config.yaml:/pomerium/config.yaml:ro \
  -v /opt/pomerium/certs:/etc/pomerium/certs:ro \
  pomerium/pomerium:latest

echo "Pomerium 부트스트랩 완료. https://$${MY_PUBLIC_IP}/ (또는 employee/hr.company.com)"
