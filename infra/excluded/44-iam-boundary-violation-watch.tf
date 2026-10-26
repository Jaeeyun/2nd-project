
resource "aws_cloudwatch_log_group" "iam_boundary_violation" {
  name              = "/demo-project/iam-boundary-violations"
  retention_in_days = 30
}

data "archive_file" "iam_boundary_violation_watch" {
  type        = "zip"
  source_file = "${path.module}/scripts/iam-boundary-violation-watch.py"
  output_path = "${path.module}/.build/iam-boundary-violation-watch.zip"
}

resource "aws_iam_role" "iam_boundary_violation_watch" {
  provider = aws.us_east_1
  name     = "${local.name_prefix}-iam-boundary-watch-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "iam_boundary_violation_watch_basic_logs" {
  provider   = aws.us_east_1
  role       = aws_iam_role.iam_boundary_violation_watch.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "iam_boundary_violation_watch_permissions" {
  statement {
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.iam_boundary_violation.arn}:*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.slack_app.arn]
  }
}

resource "aws_iam_role_policy" "iam_boundary_violation_watch_permissions" {
  provider = aws.us_east_1
  name     = "iam-boundary-watch-permissions"
  role     = aws_iam_role.iam_boundary_violation_watch.id
  policy   = data.aws_iam_policy_document.iam_boundary_violation_watch_permissions.json
}

resource "aws_lambda_function" "iam_boundary_violation_watch" {
  provider         = aws.us_east_1
  function_name    = "${local.name_prefix}-iam-boundary-violation-watch"
  role             = aws_iam_role.iam_boundary_violation_watch.arn
  handler          = "iam-boundary-violation-watch.handler"
  runtime          = "python3.12"
  timeout          = 30
  filename         = data.archive_file.iam_boundary_violation_watch.output_path
  source_code_hash = data.archive_file.iam_boundary_violation_watch.output_base64sha256

  environment {
    variables = {
      LOG_GROUP_NAME               = aws_cloudwatch_log_group.iam_boundary_violation.name
      SLACK_SECRET_ARN             = aws_secretsmanager_secret.slack_app.arn
      NAME_PREFIX                  = local.name_prefix
      EXPECTED_MANAGED_POLICY_ARNS = ""
    }
  }
}

resource "aws_cloudwatch_event_rule" "attach_role_policy" {
  provider    = aws.us_east_1
  name        = "${local.name_prefix}-attach-role-policy-watch"
  description = "8개 SAML Role에 관리형 정책이 붙는 순간(Permission Boundary 모델 밖) 감지"

  event_pattern = jsonencode({
    source      = ["aws.iam"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["iam.amazonaws.com"]
      eventName   = ["AttachRolePolicy"]
      requestParameters = {
        roleName = [for name in local.keycloak_role_names : name]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "attach_role_policy_to_lambda" {
  provider = aws.us_east_1
  rule     = aws_cloudwatch_event_rule.attach_role_policy.name
  arn      = aws_lambda_function.iam_boundary_violation_watch.arn
}

resource "aws_lambda_permission" "allow_eventbridge_attach_role_policy" {
  provider      = aws.us_east_1
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.iam_boundary_violation_watch.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.attach_role_policy.arn
}
