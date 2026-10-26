
resource "aws_cloudwatch_log_group" "db_access_structured" {
  name              = "/ztna/${local.name_prefix}/db-access"
  retention_in_days = 3
}

resource "aws_cloudwatch_log_group" "operator_access_structured" {
  name              = "/ztna/${local.name_prefix}/operator-access"
  retention_in_days = 3
}

data "archive_file" "log_normalizer" {
  type        = "zip"
  source_file = "${path.module}/log-normalizer-lambda/handler.py"
  output_path = "${path.module}/.terraform-tmp/log-normalizer-lambda.zip"
}

resource "aws_iam_role" "rds_pgaudit_normalizer" {
  name = "${local.name_prefix}-rds-pgaudit-normalizer-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "rds_pgaudit_normalizer_basic" {
  role       = aws_iam_role.rds_pgaudit_normalizer.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "rds_pgaudit_normalizer_write" {
  name = "write-db-access-structured"
  role = aws_iam_role.rds_pgaudit_normalizer.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.db_access_structured.arn}:*"
    }]
  })
}

resource "aws_lambda_function" "rds_pgaudit_normalizer" {
  function_name    = "${local.name_prefix}-rds-pgaudit-normalizer"
  role             = aws_iam_role.rds_pgaudit_normalizer.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 30
  filename         = data.archive_file.log_normalizer.output_path
  source_code_hash = data.archive_file.log_normalizer.output_base64sha256

  environment {
    variables = {
      MODE           = "rds_pgaudit"
      DEST_LOG_GROUP = aws_cloudwatch_log_group.db_access_structured.name
    }
  }
}

resource "aws_lambda_permission" "rds_pgaudit_normalizer_from_cwl" {
  statement_id   = "AllowInvokeFromRdsLogGroup"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.rds_pgaudit_normalizer.function_name
  principal      = "logs.${var.aws_region}.amazonaws.com"
  source_arn     = "${aws_cloudwatch_log_group.rds_postgresql.arn}:*"
  source_account = data.aws_caller_identity.current.account_id
}

resource "aws_cloudwatch_log_subscription_filter" "rds_pgaudit_to_lambda" {
  name            = "${local.name_prefix}-rds-pgaudit-to-normalizer"
  log_group_name  = aws_cloudwatch_log_group.rds_postgresql.name
  filter_pattern  = ""
  destination_arn = aws_lambda_function.rds_pgaudit_normalizer.arn

  depends_on = [aws_lambda_permission.rds_pgaudit_normalizer_from_cwl]
}

resource "aws_iam_role" "eks_audit_normalizer" {
  name = "${local.name_prefix}-eks-audit-normalizer-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_audit_normalizer_basic" {
  role       = aws_iam_role.eks_audit_normalizer.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "eks_audit_normalizer_access" {
  name = "read-eks-audit-write-operator-access"
  role = aws_iam_role.eks_audit_normalizer.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:StartQuery", "logs:GetQueryResults", "logs:StopQuery"]
        Resource = aws_cloudwatch_log_group.eks_cluster.arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.operator_access_structured.arn}:*"
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:PutParameter"]
        Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/ztna/eks-audit-normalizer/*"
      },
    ]
  })
}

resource "aws_lambda_function" "eks_audit_normalizer" {
  function_name    = "${local.name_prefix}-eks-audit-normalizer"
  role             = aws_iam_role.eks_audit_normalizer.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 60
  filename         = data.archive_file.log_normalizer.output_path
  source_code_hash = data.archive_file.log_normalizer.output_base64sha256

  environment {
    variables = {
      MODE              = "eks_audit"
      DEST_LOG_GROUP    = aws_cloudwatch_log_group.operator_access_structured.name
      SRC_EKS_LOG_GROUP = aws_cloudwatch_log_group.eks_cluster.name
      PROJECT_PREFIX    = "ztna"
    }
  }
}

resource "aws_cloudwatch_event_rule" "eks_audit_normalizer_schedule" {
  name                = "${local.name_prefix}-eks-audit-normalizer-schedule"
  schedule_expression = "rate(5 minutes)"
}

resource "aws_cloudwatch_event_target" "eks_audit_normalizer" {
  rule = aws_cloudwatch_event_rule.eks_audit_normalizer_schedule.name
  arn  = aws_lambda_function.eks_audit_normalizer.arn
}

resource "aws_lambda_permission" "eks_audit_normalizer_from_events" {
  statement_id  = "AllowInvokeFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.eks_audit_normalizer.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.eks_audit_normalizer_schedule.arn
}

output "db_access_structured_log_group" {
  value = aws_cloudwatch_log_group.db_access_structured.name
}

output "operator_access_structured_log_group" {
  value = aws_cloudwatch_log_group.operator_access_structured.name
}
