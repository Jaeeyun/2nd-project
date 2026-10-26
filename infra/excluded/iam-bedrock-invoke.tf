
data "aws_iam_policy_document" "bedrock_invoke_scoped" {
  statement {
    sid    = "AllowInvokeSpecificHaikuModelOnly"
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
    ]
    resources = [
      "arn:aws:bedrock:ap-northeast-2::foundation-model/anthropic.claude-3-haiku-20240307-v1:0",
    ]
  }
}

resource "aws_iam_policy" "bedrock_invoke_scoped" {
  name        = "cspm-lambda-bedrock-invoke-scoped"
  description = "CSPM 알림 Lambda가 Haiku 모델만 호출할 수 있도록 제한된 권한"
  policy      = data.aws_iam_policy_document.bedrock_invoke_scoped.json
}

resource "aws_iam_role_policy_attachment" "cspm_lambda_bedrock" {
  role       = aws_iam_role.cspm_alert_lambda_role.name
  policy_arn = aws_iam_policy.bedrock_invoke_scoped.arn
}

resource "aws_dynamodb_table" "cspm_bedrock_usage" {
  name         = "cspm-bedrock-usage"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "date"

  attribute {
    name = "date"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }
}

data "aws_iam_policy_document" "bedrock_usage_table_access" {
  statement {
    sid    = "AllowUpdateItemOnly"
    effect = "Allow"
    actions = [
      "dynamodb:UpdateItem",
    ]
    resources = [aws_dynamodb_table.cspm_bedrock_usage.arn]
  }
}

resource "aws_iam_policy" "bedrock_usage_table_access" {
  name   = "cspm-lambda-bedrock-usage-table"
  policy = data.aws_iam_policy_document.bedrock_usage_table_access.json
}

resource "aws_iam_role_policy_attachment" "cspm_lambda_bedrock_usage" {
  role       = aws_iam_role.cspm_alert_lambda_role.name
  policy_arn = aws_iam_policy.bedrock_usage_table_access.arn
}
