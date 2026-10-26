
resource "aws_secretsmanager_secret" "slack_app" {
  name        = "${local.name_prefix}-slack-app-credentials"
  description = "Slack Bot Token + Signing Secret (수동으로 값 채워야 함)"

  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "slack_app" {
  secret_id = aws_secretsmanager_secret.slack_app.id
  secret_string = jsonencode({
    bot_token      = "xoxb-여기에-실제-값을-채우세요"
    signing_secret = "여기에-실제-값을-채우세요"
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

data "archive_file" "ciem_key_notify" {
  type        = "zip"
  source_file = "${path.module}/scripts/ciem-key-exception-notify.py"
  output_path = "${path.module}/.build/ciem-key-exception-notify.zip"
}

resource "aws_iam_role" "ciem_key_notify" {
  name = "${local.name_prefix}-ciem-key-notify-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ciem_key_notify_basic_logs" {
  role       = aws_iam_role.ciem_key_notify.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "ciem_key_notify_permissions" {
  statement {
    effect    = "Allow"
    actions   = ["iam:ListUsers", "iam:ListAccessKeys", "iam:GetAccessKeyLastUsed", "iam:ListUserTags"]
    resources = ["*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.slack_app.arn]
  }
}

resource "aws_iam_role_policy" "ciem_key_notify_permissions" {
  name   = "ciem-key-notify-permissions"
  role   = aws_iam_role.ciem_key_notify.id
  policy = data.aws_iam_policy_document.ciem_key_notify_permissions.json
}

resource "aws_lambda_function" "ciem_key_notify" {
  function_name    = "${local.name_prefix}-ciem-key-exception-notify"
  role             = aws_iam_role.ciem_key_notify.arn
  handler          = "ciem-key-exception-notify.handler"
  runtime          = "python3.12"
  timeout          = 120
  filename         = data.archive_file.ciem_key_notify.output_path
  source_code_hash = data.archive_file.ciem_key_notify.output_base64sha256

  environment {
    variables = {
      SLACK_SECRET_ARN = aws_secretsmanager_secret.slack_app.arn
      SLACK_CHANNEL    = "#cspm-findings"
    }
  }
}

resource "aws_scheduler_schedule" "ciem_key_notify_monthly" {
  name       = "${local.name_prefix}-ciem-key-notify-monthly"
  group_name = "default"

  flexible_time_window { mode = "OFF" }
  schedule_expression          = "cron(0 0 1 * ? *)"
  schedule_expression_timezone = "UTC"

  target {
    arn      = aws_lambda_function.ciem_key_notify.arn
    role_arn = aws_iam_role.ciem_scheduler.arn
  }
}

resource "aws_lambda_permission" "allow_scheduler_key_notify" {
  statement_id  = "AllowEventBridgeScheduler"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ciem_key_notify.function_name
  principal     = "scheduler.amazonaws.com"
  source_arn    = aws_scheduler_schedule.ciem_key_notify_monthly.arn
}

data "archive_file" "ciem_key_callback" {
  type        = "zip"
  source_file = "${path.module}/scripts/ciem-key-exception-callback.py"
  output_path = "${path.module}/.build/ciem-key-exception-callback.zip"
}

resource "aws_iam_role" "ciem_key_callback" {
  name = "${local.name_prefix}-ciem-key-callback-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ciem_key_callback_basic_logs" {
  role       = aws_iam_role.ciem_key_callback.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "ciem_key_callback_permissions" {
  statement {
    effect    = "Allow"
    actions   = ["iam:TagUser", "iam:UpdateAccessKey", "iam:DeleteAccessKey"]
    resources = ["*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.slack_app.arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["access-analyzer:GetGeneratedPolicy"]
    resources = ["*"]
  }
  statement {
    effect  = "Allow"
    actions = ["iam:ListRolePolicies", "iam:PutRolePolicy", "iam:TagRole"]

    resources = [for name in local.keycloak_role_names : "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${name}"]
  }

  statement {
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.session_revoke.arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["iam:DetachRolePolicy"]
    resources = [for name in local.keycloak_role_names : "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${name}"]
  }

  statement {
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.iam_boundary_violation.arn}:*"]
  }
}

resource "aws_iam_role_policy" "ciem_key_callback_permissions" {
  name   = "ciem-key-callback-permissions"
  role   = aws_iam_role.ciem_key_callback.id
  policy = data.aws_iam_policy_document.ciem_key_callback_permissions.json
}

resource "aws_lambda_function" "ciem_key_callback" {
  function_name    = "${local.name_prefix}-ciem-key-exception-callback"
  role             = aws_iam_role.ciem_key_callback.arn
  handler          = "ciem-key-exception-callback.handler"
  runtime          = "python3.12"
  timeout          = 30
  filename         = data.archive_file.ciem_key_callback.output_path
  source_code_hash = data.archive_file.ciem_key_callback.output_base64sha256

  environment {
    variables = {
      SLACK_SECRET_ARN             = aws_secretsmanager_secret.slack_app.arn
      SESSION_REVOKE_FUNCTION_NAME = aws_lambda_function.session_revoke.function_name
      BOUNDARY_VIOLATION_LOG_GROUP = aws_cloudwatch_log_group.iam_boundary_violation.name
      CSPM_EXCEPTION_LOG_GROUP     = aws_cloudwatch_log_group.cspm_exception_records.name
    }
  }
}

resource "aws_apigatewayv2_api" "slack_interactivity" {
  name          = "${local.name_prefix}-slack-interactivity"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "slack_interactivity" {
  api_id                 = aws_apigatewayv2_api.slack_interactivity.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.ciem_key_callback.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "slack_interactivity" {
  api_id    = aws_apigatewayv2_api.slack_interactivity.id
  route_key = "POST /slack/interactivity"
  target    = "integrations/${aws_apigatewayv2_integration.slack_interactivity.id}"
}

resource "aws_cloudwatch_log_group" "slack_interactivity_access_logs" {
  name              = "/aws/apigateway/${local.name_prefix}-slack-interactivity"
  retention_in_days = 30
}

resource "aws_apigatewayv2_stage" "slack_interactivity" {
  api_id      = aws_apigatewayv2_api.slack_interactivity.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.slack_interactivity_access_logs.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      protocol       = "$context.protocol"
      responseLength = "$context.responseLength"
    })
  }
}

resource "aws_lambda_permission" "allow_apigw_callback" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ciem_key_callback.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.slack_interactivity.execution_arn}/*/*"
}

output "slack_interactivity_endpoint" {
  description = "Slack App 설정의 Interactivity Request URL에 이 값 + /slack/interactivity 를 넣으세요"
  value       = aws_apigatewayv2_stage.slack_interactivity.invoke_url
}
