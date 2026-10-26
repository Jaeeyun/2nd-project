
resource "aws_securityhub_action_target" "revoke_session" {

  name        = "Revoke User Session"
  identifier  = "RevokeUserSession"
  description = "Force-terminate a specific person's AWS sessions (all 8 roles) and Keycloak session at once"

  depends_on = [aws_securityhub_account.main]
}

data "archive_file" "session_revoke" {
  type        = "zip"
  source_file = "${path.module}/scripts/session-revoke.py"
  output_path = "${path.module}/.build/session-revoke.zip"
}

resource "aws_iam_role" "session_revoke" {
  name = "${local.name_prefix}-session-revoke-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "session_revoke_basic_logs" {
  role       = aws_iam_role.session_revoke.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "session_revoke_permissions" {
  statement {
    effect    = "Allow"
    actions   = ["iam:PutRolePolicy"]
    resources = [for name in local.keycloak_role_names : "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${name}"]
  }
  statement {
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:*:${data.aws_caller_identity.current.account_id}:parameter/keycloak/${local.name_prefix}/*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.security_alerts.arn]
  }
}

resource "aws_iam_role_policy" "session_revoke_permissions" {
  name   = "session-revoke-permissions"
  role   = aws_iam_role.session_revoke.id
  policy = data.aws_iam_policy_document.session_revoke_permissions.json
}

resource "aws_iam_role_policy_attachment" "session_revoke_vpc" {
  role       = aws_iam_role.session_revoke.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_security_group" "session_revoke_lambda" {
  name        = "${local.name_prefix}-session-revoke-lambda-sg"
  description = "session-revoke Lambda - outbound to Keycloak(443) only"
  vpc_id      = aws_vpc.main.id
}

resource "aws_vpc_security_group_egress_rule" "session_revoke_lambda_to_internet" {
  security_group_id = aws_security_group.session_revoke_lambda.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "AWS API calls (SSM/SNS) via NAT gateway"
}

resource "aws_vpc_security_group_egress_rule" "session_revoke_lambda_to_keycloak" {
  security_group_id = aws_security_group.session_revoke_lambda.id
  cidr_ipv4         = var.keycloak_vpc_cidr
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "Keycloak admin API via VPC peering"
}

resource "aws_lambda_function" "session_revoke" {
  function_name    = "${local.name_prefix}-session-revoke"
  role             = aws_iam_role.session_revoke.arn
  handler          = "session-revoke.handler"
  runtime          = "python3.12"
  timeout          = 60
  filename         = data.archive_file.session_revoke.output_path
  source_code_hash = data.archive_file.session_revoke.output_base64sha256

  vpc_config {
    subnet_ids         = aws_subnet.private_app[*].id
    security_group_ids = [aws_security_group.session_revoke_lambda.id]
  }

  environment {
    variables = {
      NAME_PREFIX     = local.name_prefix
      KEYCLOAK_HOST   = aws_instance.keycloak.private_ip
      REALM_NAME      = var.keycloak_realm_name
      SNS_TOPIC_ARN   = aws_sns_topic.security_alerts.arn
      ROLE_NAMES_JSON = jsonencode([for name in local.keycloak_role_names : name])
    }
  }
}

resource "aws_cloudwatch_event_rule" "revoke_session_action" {
  name = "${local.name_prefix}-revoke-session-action"

  event_pattern = jsonencode({
    source      = ["aws.securityhub"]
    detail-type = ["Security Hub Findings - Custom Action"]
    resources   = [aws_securityhub_action_target.revoke_session.arn]
  })
}

resource "aws_cloudwatch_event_target" "revoke_session_lambda" {
  rule = aws_cloudwatch_event_rule.revoke_session_action.name
  arn  = aws_lambda_function.session_revoke.arn
}

resource "aws_lambda_permission" "allow_eventbridge_revoke" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.session_revoke.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.revoke_session_action.arn
}
