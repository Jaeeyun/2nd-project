#!/usr/bin/env bash
set -euo pipefail

INSTANCE_ID="$1"
REGION="$2"
SCRIPT_PATH="$3"
shift 3

echo "SSM Agent 등록 대기 중 ($INSTANCE_ID)..."
for i in $(seq 1 36); do
  PING_STATUS=$(aws ssm describe-instance-information --region "$REGION" \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo "None")
  if [ "$PING_STATUS" = "Online" ]; then
    echo "SSM Agent Online 확인"
    break
  fi
  echo "  아직 Online 아님 (status=$PING_STATUS), 5초 후 재시도... ($i/36)"
  sleep 5
done

PARAMS_FILE=$(mktemp)
python3 -c "
import json, sys
env_kvs = sys.argv[1:]
env_lines = ['export ' + kv for kv in env_kvs]
script_lines = open('$SCRIPT_PATH').read().splitlines()
json.dump({'commands': env_lines + script_lines}, open('$PARAMS_FILE', 'w'))
" "$@"

CMD_ID=$(aws ssm send-command --document-name "AWS-RunShellScript" \
  --instance-ids "$INSTANCE_ID" --region "$REGION" \
  --parameters "file://$PARAMS_FILE" \
  --query 'Command.CommandId' --output text)
echo "SSM CommandId=$CMD_ID ($SCRIPT_PATH on $INSTANCE_ID)"
rm -f "$PARAMS_FILE"

STATUS="Pending"
for _ in $(seq 1 240); do
  STATUS=$(aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" --region "$REGION" \
    --query 'Status' --output text 2>/dev/null || echo "Pending")
  [ "$STATUS" != "Pending" ] && [ "$STATUS" != "InProgress" ] && break
  sleep 5
done

echo "--- stdout ---"
aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" --region "$REGION" \
  --query 'StandardOutputContent' --output text
echo "--- stderr ---"
aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" --region "$REGION" \
  --query 'StandardErrorContent' --output text >&2

if [ "$STATUS" != "Success" ]; then
  echo "SSM 명령 실패 또는 타임아웃: status=$STATUS" >&2
  exit 1
fi
