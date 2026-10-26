#!/usr/bin/env bash
set -e

REALM="${REALM:?REALM 환경변수 필요}"
CLIENT_SECRET="${CLIENT_SECRET:?CLIENT_SECRET 환경변수 필요}"
TEST_USERS_PASSWORD="${TEST_USERS_PASSWORD:?TEST_USERS_PASSWORD 환경변수 필요}"

docker exec keycloak /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 --realm master --user admin \
  --password "$(aws ssm get-parameter --name /keycloak/demo-project-dev/admin-password --with-decryption --region ap-northeast-2 --query Parameter.Value --output text)" \
  2>&1 | tail -3

CID=$(docker exec keycloak /opt/keycloak/bin/kcadm.sh get clients -r "$REALM" -q clientId=hr-app --fields id --format csv --noquotes | tail -1 | tr -d '\r')
if [ -z "$CID" ]; then
  docker exec -i keycloak /opt/keycloak/bin/kcadm.sh create clients -r "$REALM" -f - <<CLIENT
{
  "clientId": "hr-app",
  "enabled": true,
  "protocol": "openid-connect",
  "publicClient": false,
  "standardFlowEnabled": true,
  "directAccessGrantsEnabled": false,
  "secret": "$CLIENT_SECRET",
  "redirectUris": ["https://employee.company.com/oauth2/callback", "https://hr.company.com/oauth2/callback"],
  "webOrigins": ["https://employee.company.com", "https://hr.company.com"]
}
CLIENT
  echo "hr-app oidc client created"
else
  echo "hr-app oidc client already exists: $CID"
  docker exec keycloak /opt/keycloak/bin/kcadm.sh update clients/"$CID" -r "$REALM" \
    -s "secret=$CLIENT_SECRET" \
    -s 'redirectUris=["https://employee.company.com/oauth2/callback","https://hr.company.com/oauth2/callback"]' \
    -s 'webOrigins=["https://employee.company.com","https://hr.company.com"]'
fi

CID=$(docker exec keycloak /opt/keycloak/bin/kcadm.sh get clients -r "$REALM" -q clientId=hr-app --fields id --format csv --noquotes | tail -1 | tr -d '\r')
echo "CID=$CID"

BROWSER_FLOW_ID=$(docker exec keycloak /opt/keycloak/bin/kcadm.sh get authentication/flows -r "$REALM" \
  | python3 -c "
import json, sys
data = json.load(sys.stdin)
f = [x for x in data if x.get('alias') == 'browser'][0]
print(f['id'])
")
docker exec keycloak /opt/keycloak/bin/kcadm.sh update clients/"$CID" -r "$REALM" \
  -s "authenticationFlowBindingOverrides.browser=$BROWSER_FLOW_ID"

docker exec -i keycloak /opt/keycloak/bin/kcadm.sh create clients/"$CID"/protocol-mappers/models -r "$REALM" -f - <<'M1' 2>&1 | tail -3 || true
{"name":"groups","protocol":"openid-connect","protocolMapper":"oidc-group-membership-mapper",
 "config":{"claim.name":"groups","full.path":"false","id.token.claim":"true","access.token.claim":"true","userinfo.token.claim":"true"}}
M1

GID=$(docker exec keycloak /opt/keycloak/bin/kcadm.sh get groups -r "$REALM" -q search=hr-group --fields id --format csv --noquotes | tail -1 | tr -d '\r')
if [ -z "$GID" ]; then
  docker exec -i keycloak /opt/keycloak/bin/kcadm.sh create groups -r "$REALM" -f - <<'GRP'
{"name": "hr-group"}
GRP
  GID=$(docker exec keycloak /opt/keycloak/bin/kcadm.sh get groups -r "$REALM" -q search=hr-group --fields id --format csv --noquotes | tail -1 | tr -d '\r')
  echo "hr-group created: $GID"
else
  echo "hr-group already exists: $GID"
fi

for USERNAME in trusteduser untrusteduser hruser; do
  UID_=$(docker exec keycloak /opt/keycloak/bin/kcadm.sh get users -r "$REALM" -q username="$USERNAME" --fields id --format csv --noquotes | tail -1 | tr -d '\r')
  if [ -z "$UID_" ]; then
    docker exec -i keycloak /opt/keycloak/bin/kcadm.sh create users -r "$REALM" -f - <<USR
{"username": "$USERNAME", "enabled": true, "emailVerified": true, "email": "$USERNAME@example.com"}
USR
    UID_=$(docker exec keycloak /opt/keycloak/bin/kcadm.sh get users -r "$REALM" -q username="$USERNAME" --fields id --format csv --noquotes | tail -1 | tr -d '\r')
    docker exec keycloak /opt/keycloak/bin/kcadm.sh set-password -r "$REALM" --userid "$UID_" --new-password "$TEST_USERS_PASSWORD" --temporary=false
    echo "user $USERNAME created: $UID_"
  else
    echo "user $USERNAME already exists: $UID_"
  fi

  if [ "$USERNAME" = "hruser" ]; then
    docker exec keycloak /opt/keycloak/bin/kcadm.sh update "users/$UID_/groups/$GID" -r "$REALM" \
      -s realm="$REALM" -s userId="$UID_" -s groupId="$GID" -n 2>&1 | tail -3 || true
  fi
done

docker exec keycloak /opt/keycloak/bin/kcadm.sh update events/config -r "$REALM" \
  -s eventsEnabled=true \
  -s 'enabledEventTypes=["LOGIN","LOGIN_ERROR","LOGOUT","LOGOUT_ERROR"]' \
  -s eventsListeners='["jboss-logging"]' 2>&1 | tail -3

echo "WEBAPP_OIDC_BOOTSTRAP_DONE"
