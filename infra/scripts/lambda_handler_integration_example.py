
import os
import boto3

from bedrock_query_generator import generate_cwli_query, format_slack_query_block

bedrock_client = boto3.client("bedrock-runtime", region_name=os.environ.get("BEDROCK_REGION", "ap-northeast-2"))
dynamodb = boto3.resource("dynamodb")

def handler(event, context):

    finding = _parse_finding(event)

    query_result = generate_cwli_query(
        finding, bedrock_client=bedrock_client, dynamodb_resource=dynamodb
    )
    query_block_text = format_slack_query_block(query_result, finding)

    slack_message = _build_slack_message(finding, query_block_text)

    return {"statusCode": 200, "bedrock_used": query_result["source"] == "bedrock"}

def _parse_finding(event):

    detail = event.get("detail", {}).get("findings", [{}])[0]
    return {
        "Title": detail.get("Title", ""),
        "Severity": detail.get("Severity", {}).get("Label", ""),
        "ResourceArn": detail.get("Resources", [{}])[0].get("Id", ""),
        "ResourceType": detail.get("Resources", [{}])[0].get("Type", ""),
        "EventName": detail.get("SourceUrl", ""),
        "AccountId": detail.get("AwsAccountId", ""),
        "Region": detail.get("Region", ""),
    }

def _build_slack_message(finding, query_block_text: str) -> list:

    return [
        {
            "type": "section",
            "text": {"type": "mrkdwn", "text": f"*{finding['Severity']}* — {finding['Title']}"},
        },
        {"type": "section", "text": {"type": "mrkdwn", "text": query_block_text}},

    ]
