#!/usr/bin/env bash
set -e

docker exec keycloak /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 --realm master --user admin \
  --password "$(aws ssm get-parameter --name /keycloak/demo-project-dev/admin-password --with-decryption --region ap-northeast-2 --query Parameter.Value --output text)" \
  2>&1 | tail -3

GRAFANA_ENDPOINT="${GRAFANA_ENDPOINT:?GRAFANA_ENDPOINT 환경변수 필요(예: g-xxxxx.grafana-workspace.<region>.amazonaws.com)}"
ACS_URL="https://${GRAFANA_ENDPOINT}/saml/acs"
ENTITY_ID="https://${GRAFANA_ENDPOINT}/saml/metadata"

EXISTING=$(docker exec keycloak /opt/keycloak/bin/kcadm.sh get clients -r corp -q clientId="$ENTITY_ID" --fields id --format csv --noquotes | tail -1 | tr -d '\r')
if [ -z "$EXISTING" ]; then
  docker exec -i keycloak /opt/keycloak/bin/kcadm.sh create clients -r corp -f - <<CLIENT
{
  "clientId": "$ENTITY_ID",
  "enabled": true,
  "protocol": "saml",
  "redirectUris": ["$ACS_URL", "https://${GRAFANA_ENDPOINT}/*"],
  "attributes": {
    "saml_assertion_consumer_url_post": "$ACS_URL",
    "saml_name_id_format": "email",
    "saml_force_name_id_format": "true",
    "saml.server.signature": "true",
    "saml.assertion.signature": "true",
    "saml.authnstatement": "true",
    "saml_force_post_binding": "true",
    "saml.client.signature": "false"
  }
}
CLIENT
  echo "grafana saml client created"
else
  echo "grafana saml client already exists: $EXISTING"
  docker exec keycloak /opt/keycloak/bin/kcadm.sh update clients/$EXISTING -r corp \
    -s 'redirectUris=["'"$ACS_URL"'","https://'"$GRAFANA_ENDPOINT"'/*"]' \
    -s 'attributes."saml_force_name_id_format"=true' \
    -s 'attributes."saml.server.signature"=true' \
    -s 'attributes."saml.assertion.signature"=true' \
    -s 'attributes."saml.client.signature"=false'
fi

CID=$(docker exec keycloak /opt/keycloak/bin/kcadm.sh get clients -r corp -q clientId="$ENTITY_ID" --fields id --format csv --noquotes | tail -1 | tr -d '\r')
echo "CID=$CID"

ROLE_LIST_SCOPE_ID=$(docker exec keycloak /opt/keycloak/bin/kcadm.sh get client-scopes -r corp | python3 -c "
import json,sys
for s in json.load(sys.stdin):
    if s['name'] == 'role_list':
        print(s['id'])
")
if [ -n "$ROLE_LIST_SCOPE_ID" ]; then
  docker exec keycloak /opt/keycloak/bin/kcadm.sh delete clients/$CID/default-client-scopes/$ROLE_LIST_SCOPE_ID -r corp 2>&1 || true
fi

docker exec -i keycloak /opt/keycloak/bin/kcadm.sh create clients/"$CID"/protocol-mappers/models -r corp -f - <<'M1' 2>&1 | tail -3 || true
{"name":"grafana-role","protocol":"saml","protocolMapper":"saml-group-membership-mapper",
 "config":{"attribute.name":"role","attribute.nameformat":"Basic","full.path":"false","single":"false"}}
M1

docker exec -i keycloak /opt/keycloak/bin/kcadm.sh create clients/"$CID"/protocol-mappers/models -r corp -f - <<'M2' 2>&1 | tail -3 || true
{"name":"grafana-email","protocol":"saml","protocolMapper":"saml-user-property-mapper",
 "config":{"attribute.name":"email","attribute.nameformat":"Basic","user.attribute":"email"}}
M2

docker exec -i keycloak /opt/keycloak/bin/kcadm.sh create clients/"$CID"/protocol-mappers/models -r corp -f - <<'M3' 2>&1 | tail -3 || true
{"name":"grafana-username","protocol":"saml","protocolMapper":"saml-user-property-mapper",
 "config":{"attribute.name":"login","attribute.nameformat":"Basic","user.attribute":"username"}}
M3

docker exec -i keycloak /opt/keycloak/bin/kcadm.sh create clients/"$CID"/protocol-mappers/models -r corp -f - <<'M4' 2>&1 | tail -3 || true
{"name":"grafana-name","protocol":"saml","protocolMapper":"saml-user-property-mapper",
 "config":{"attribute.name":"name","attribute.nameformat":"Basic","user.attribute":"username"}}
M4

echo "GRAFANA_PREP_DONE"
