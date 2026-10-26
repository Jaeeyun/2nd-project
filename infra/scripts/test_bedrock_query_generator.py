
import json
from unittest.mock import MagicMock
from io import BytesIO

from bedrock_query_generator import (
    generate_cwli_query,
    format_slack_query_block,
    Finding,
)

SAMPLE_FINDING: Finding = {
    "Title": "IAM Role has excessive permissions granted",
    "Severity": "HIGH",
    "ResourceArn": "arn:aws:iam::123456789012:role/hr-backend-role",
    "ResourceType": "AwsIamRole",
    "EventName": "AttachRolePolicy",
    "AccountId": "123456789012",
    "Region": "ap-northeast-2",
}

def _mock_bedrock_client(response_text: str):
    client = MagicMock()
    body_payload = json.dumps({"content": [{"text": response_text}]}).encode("utf-8")
    client.invoke_model.return_value = {"body": BytesIO(body_payload)}
    return client

def test_no_client_falls_back():
    result = generate_cwli_query(SAMPLE_FINDING, bedrock_client=None)
    assert result["source"] == "fallback"
    assert result["reason"] == "no_bedrock_client"
    assert "hr-backend-role" in result["query"]
    print("[PASS] test_no_client_falls_back")

def test_bedrock_success():
    fake_query = (
        'fields @timestamp, eventName, userIdentity.arn\n'
        '| filter resources.0.ARN = "arn:aws:iam::123456789012:role/hr-backend-role"\n'
        '| sort @timestamp desc\n| limit 100'
    )
    client = _mock_bedrock_client(fake_query)
    result = generate_cwli_query(SAMPLE_FINDING, bedrock_client=client)
    assert result["source"] == "bedrock"
    assert result["query"] == fake_query
    assert client.invoke_model.called
    print("[PASS] test_bedrock_success")

def test_bedrock_exception_falls_back():
    client = MagicMock()
    client.invoke_model.side_effect = RuntimeError("throttled")
    result = generate_cwli_query(SAMPLE_FINDING, bedrock_client=client)
    assert result["source"] == "fallback"
    assert "bedrock_error" in result["reason"]
    print("[PASS] test_bedrock_exception_falls_back")

def test_empty_response_falls_back():
    client = _mock_bedrock_client("")
    result = generate_cwli_query(SAMPLE_FINDING, bedrock_client=client)
    assert result["source"] == "fallback"
    print("[PASS] test_empty_response_falls_back")

def test_daily_cap_exceeded_falls_back():
    client = _mock_bedrock_client("some query")

    fake_dynamodb = MagicMock()
    fake_table = MagicMock()
    fake_table.update_item.return_value = {"Attributes": {"invocation_count": 9999}}
    fake_dynamodb.Table.return_value = fake_table

    result = generate_cwli_query(SAMPLE_FINDING, bedrock_client=client, dynamodb_resource=fake_dynamodb)
    assert result["source"] == "fallback"
    assert result["reason"] == "daily_cap_exceeded"
    assert not client.invoke_model.called
    print("[PASS] test_daily_cap_exceeded_falls_back")

def test_slack_block_formatting():
    result = {"query": "fields @timestamp\n| limit 10", "source": "bedrock", "reason": None}
    text = format_slack_query_block(result, SAMPLE_FINDING)
    assert "Bedrock 생성 쿼리" in text
    assert "```" in text
    print("[PASS] test_slack_block_formatting")

if __name__ == "__main__":
    test_no_client_falls_back()
    test_bedrock_success()
    test_bedrock_exception_falls_back()
    test_empty_response_falls_back()
    test_daily_cap_exceeded_falls_back()
    test_slack_block_formatting()
    print("\n모든 테스트 통과 ✅")
