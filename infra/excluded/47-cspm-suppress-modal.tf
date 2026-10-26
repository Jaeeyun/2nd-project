
resource "aws_cloudwatch_log_group" "cspm_exception_records" {
  name              = "/aws/cspm/exception-records"
  retention_in_days = 90
}

data "aws_iam_policy_document" "cspm_suppress_modal_permissions" {
  statement {
    effect    = "Allow"
    actions   = ["securityhub:BatchUpdateFindings"]
    resources = ["*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.cspm_exception_records.arn}:*"]
  }
}

resource "aws_iam_role_policy" "cspm_suppress_modal_permissions" {
  name   = "cspm-suppress-modal-permissions"
  role   = aws_iam_role.ciem_key_callback.id
  policy = data.aws_iam_policy_document.cspm_suppress_modal_permissions.json
}

output "cspm_exception_records_log_group" {
  value = aws_cloudwatch_log_group.cspm_exception_records.name
}

data "archive_file" "cspm_reconciler" {
  type        = "zip"
  source_file = "${path.module}/scripts/cspm-exception-reconciler.py"
  output_path = "${path.module}/.build/cspm-exception-reconciler.zip"
}

resource "aws_lambda_function" "cspm_reconciler" {
  function_name    = "${local.name_prefix}-cspm-exception-reconciler"
  runtime          = "python3.12"
  handler          = "cspm-exception-reconciler.handler"
  filename         = data.archive_file.cspm_reconciler.output_path
  source_code_hash = data.archive_file.cspm_reconciler.output_base64sha256
  role             = aws_iam_role.cspm_reconciler_role.arn
  timeout          = 60

  environment {
    variables = {
      CSPM_EXCEPTION_LOG_GROUP = aws_cloudwatch_log_group.cspm_exception_records.name
      DUE_SOON_THRESHOLD_DAYS  = "3"
    }
  }
}

resource "aws_scheduler_schedule" "cspm_reconciliation" {
  name       = "cspm-exception-reconciler-daily"
  group_name = "default"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression = "cron(0 18 * * ? *)"

  target {
    arn      = aws_lambda_function.cspm_reconciler.arn
    role_arn = aws_iam_role.scheduler_invoke_role.arn
  }
}

resource "aws_iam_role" "cspm_reconciler_role" {
  name = "${local.name_prefix}-cspm-reconciler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cspm_reconciler_basic_logs" {
  role       = aws_iam_role.cspm_reconciler_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "cspm_reconciler_permissions" {

  statement {
    effect    = "Allow"
    actions   = ["securityhub:GetFindings"]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "logs:StartQuery",
      "logs:GetQueryResults",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = [
      "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/cspm/exception-records:*"
    ]
  }
}

resource "aws_iam_role_policy" "cspm_reconciler_permissions" {
  name   = "cspm-reconciler-permissions"
  role   = aws_iam_role.cspm_reconciler_role.id
  policy = data.aws_iam_policy_document.cspm_reconciler_permissions.json
}

resource "aws_iam_role" "scheduler_invoke_role" {
  name = "${local.name_prefix}-scheduler-cspm-reconciler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "scheduler.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "scheduler_invoke_permissions" {
  name = "scheduler-invoke-lambda"
  role = aws_iam_role.scheduler_invoke_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["lambda:InvokeFunction"]
      Resource = [aws_lambda_function.cspm_reconciler.arn]
    }]
  })
}