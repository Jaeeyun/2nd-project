
variable "psycopg2_layer_arn" {
  description = "psycopg2 Lambda Layer ARN. AWS 공식 Layer가 없어 커뮤니티 Layer나 직접 빌드가 필요합니다. apply 전 실제 값으로 채우세요(리전/Python 버전에 맞는 Layer)."
  type        = string
  default     = ""
}

data "archive_file" "rds_view_permission_check" {
  type        = "zip"
  source_file = "${path.module}/scripts/rds-view-permission-check.py"
  output_path = "${path.module}/.build/rds-view-permission-check.zip"
}

resource "aws_iam_role" "rds_view_permission_check" {
  name = "${local.name_prefix}-rds-view-permission-check-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "rds_view_permission_check_basic_logs" {
  role       = aws_iam_role.rds_view_permission_check.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "rds_view_permission_check_vpc" {
  role       = aws_iam_role.rds_view_permission_check.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy_document" "rds_view_permission_check_permissions" {
  statement {
    effect    = "Allow"
    actions   = ["rds-db:connect"]
    resources = ["arn:aws:rds-db:*:${data.aws_caller_identity.current.account_id}:dbuser:${aws_db_instance.main.resource_id}/remediation_admin"]
  }
}

resource "aws_iam_role_policy" "rds_view_permission_check_permissions" {
  name   = "rds-view-permission-check-permissions"
  role   = aws_iam_role.rds_view_permission_check.id
  policy = data.aws_iam_policy_document.rds_view_permission_check_permissions.json
}

resource "aws_security_group" "rds_view_permission_check_lambda" {
  name = "${local.name_prefix}-rds-view-check-lambda-sg"

  description = "RDS permission drift check Lambda - outbound to RDS(5432) only"
  vpc_id      = aws_vpc.main.id
}

resource "aws_vpc_security_group_egress_rule" "rds_view_check_lambda_to_rds" {
  security_group_id            = aws_security_group.rds_view_permission_check_lambda.id
  referenced_security_group_id = aws_security_group.rds_sg.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_lambda_function" "rds_view_permission_check" {
  function_name = "${local.name_prefix}-rds-view-permission-check"
  role          = aws_iam_role.rds_view_permission_check.arn
  handler       = "rds-view-permission-check.handler"
  runtime       = "python3.12"

  timeout          = 60
  filename         = data.archive_file.rds_view_permission_check.output_path
  source_code_hash = data.archive_file.rds_view_permission_check.output_base64sha256
  layers           = var.psycopg2_layer_arn != "" ? [var.psycopg2_layer_arn] : []

  vpc_config {
    subnet_ids         = aws_subnet.private_app[*].id
    security_group_ids = [aws_security_group.rds_view_permission_check_lambda.id]
  }

  environment {
    variables = {
      DB_HOST = aws_db_instance.main.address
      DB_NAME = aws_db_instance.main.db_name
    }
  }
}

resource "aws_scheduler_schedule" "rds_view_permission_check_daily" {
  name       = "${local.name_prefix}-rds-view-check-daily"
  group_name = "default"

  flexible_time_window { mode = "OFF" }
  schedule_expression          = "cron(0 18 * * ? *)"
  schedule_expression_timezone = "UTC"

  target {
    arn      = aws_lambda_function.rds_view_permission_check.arn
    role_arn = aws_iam_role.ciem_scheduler.arn
  }
}

resource "aws_lambda_permission" "allow_scheduler_rds_check" {
  statement_id  = "AllowEventBridgeScheduler"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rds_view_permission_check.function_name
  principal     = "scheduler.amazonaws.com"
  source_arn    = aws_scheduler_schedule.rds_view_permission_check_daily.arn
}
