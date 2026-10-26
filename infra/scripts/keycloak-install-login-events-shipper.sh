#!/usr/bin/env bash
set -e

ARTIFACTS_BUCKET="${ARTIFACTS_BUCKET:?ARTIFACTS_BUCKET 환경변수 필요}"
LOG_GROUP_NAME="${LOG_GROUP_NAME:?LOG_GROUP_NAME 환경변수 필요}"

mkdir -p /opt/keycloak-login-shipper
aws s3 cp "s3://${ARTIFACTS_BUCKET}/scripts/keycloak-login-events-shipper.py" /opt/keycloak-login-shipper/shipper.py

cat > /etc/systemd/system/keycloak-login-shipper.service <<EOF
[Unit]
Description=Keycloak login/logout events -> CloudWatch Logs
After=docker.service

[Service]
Type=oneshot
Environment=LOG_GROUP_NAME=${LOG_GROUP_NAME}
ExecStart=/usr/bin/python3 /opt/keycloak-login-shipper/shipper.py
EOF

cat > /etc/systemd/system/keycloak-login-shipper.timer <<'EOF'
[Unit]
Description=Run keycloak-login-shipper every 2 minutes

[Timer]
OnBootSec=30s
OnUnitActiveSec=2min

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now keycloak-login-shipper.timer

echo "LOGIN_EVENTS_SHIPPER_INSTALLED"
