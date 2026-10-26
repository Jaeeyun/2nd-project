
variable "boundary_drift_lookback_hours" {
  description = "권한 드리프트 검사 시 CloudTrail을 몇 시간 거슬러 볼지. 기본값(3)은 데모/테스트 전용 - 실운영에서는 훨씬 길게(최소 몇 주) 설정할 것을 권장."
  type        = number
  default     = 3
}

variable "boundary_drift_role_suffixes" {
  description = "권한 드리프트 검사 대상 Role 목록(local.keycloak_role_names의 key). security-auditor는 의도적으로 광범위한 읽기전용 권한이 목적이라 기본 검사 대상에서 제외."
  type        = list(string)
  default     = ["dev-general", "dev-lead", "dev-hr-backend", "db-general", "db-lead", "ops-general", "ops-lead"]
}

resource "aws_iam_role" "access_analyzer_cloudtrail_read" {
  name = "${local.name_prefix}-access-analyzer-cloudtrail-read-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "access-analyzer.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "access_analyzer_cloudtrail_read" {
  name = "cloudtrail-bucket-read"
  role = aws_iam_role.access_analyzer_cloudtrail_read.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetBucketLocation", "s3:ListBucket"]
        Resource = [aws_s3_bucket.cloudtrail_bucket.arn, "${aws_s3_bucket.cloudtrail_bucket.arn}/*"]
      },
      {

        Effect   = "Allow"
        Action   = ["cloudtrail:GetTrail", "cloudtrail:GetTrailStatus"]
        Resource = [aws_cloudtrail.main.arn]
      },
      {

        Effect   = "Allow"
        Action   = ["iam:GetServiceLastAccessedDetails", "iam:GenerateServiceLastAccessedDetails"]
        Resource = "*"
      },
      {

        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [aws_kms_key.cloudtrail.arn]
      }
    ]
  })
}

data "archive_file" "ciem_boundary_drift_notify" {
  type        = "zip"
  source_file = "${path.module}/scripts/ciem-boundary-drift-notify.py"
  output_path = "${path.module}/.build/ciem-boundary-drift-notify.zip"
}

resource "aws_iam_role" "ciem_boundary_drift_notify" {
  name = "${local.name_prefix}-ciem-boundary-drift-notify-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ciem_boundary_drift_notify_basic_logs" {
  role       = aws_iam_role.ciem_boundary_drift_notify.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "ciem_boundary_drift_notify_permissions" {
  statement {
    effect    = "Allow"
    actions   = ["access-analyzer:StartPolicyGeneration", "access-analyzer:GetGeneratedPolicy"]
    resources = ["*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["iam:ListRolePolicies", "iam:GetRolePolicy"]
    resources = [for name in local.keycloak_role_names : "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${name}"]
  }
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.slack_app.arn]
  }
  statement {
    effect    = "Allow"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.access_analyzer_cloudtrail_read.arn]
  }
}

resource "aws_iam_role_policy" "ciem_boundary_drift_notify_permissions" {
  name   = "ciem-boundary-drift-notify-permissions"
  role   = aws_iam_role.ciem_boundary_drift_notify.id
  policy = data.aws_iam_policy_document.ciem_boundary_drift_notify_permissions.json
}

resource "aws_lambda_function" "ciem_boundary_drift_notify" {
  function_name    = "${local.name_prefix}-ciem-boundary-drift-notify"
  role             = aws_iam_role.ciem_boundary_drift_notify.arn
  handler          = "ciem-boundary-drift-notify.handler"
  runtime          = "python3.12"
  timeout          = 540
  filename         = data.archive_file.ciem_boundary_drift_notify.output_path
  source_code_hash = data.archive_file.ciem_boundary_drift_notify.output_base64sha256

  environment {
    variables = {
      NAME_PREFIX              = local.name_prefix
      CLOUDTRAIL_ARN           = aws_cloudtrail.main.arn
      LOOKBACK_HOURS           = tostring(var.boundary_drift_lookback_hours)
      ACCESS_ANALYZER_ROLE_ARN = aws_iam_role.access_analyzer_cloudtrail_read.arn
      SLACK_SECRET_ARN         = aws_secretsmanager_secret.slack_app.arn
      SLACK_CHANNEL            = "#cspm-findings"
    }
  }
}

resource "aws_scheduler_schedule" "ciem_boundary_drift_check" {
  for_each = toset(var.boundary_drift_role_suffixes)

  name       = "${local.name_prefix}-boundary-drift-${each.key}"
  group_name = "default"

  flexible_time_window { mode = "OFF" }
  schedule_expression          = "rate(${var.boundary_drift_lookback_hours} hours)"
  schedule_expression_timezone = "UTC"

  target {
    arn      = aws_lambda_function.ciem_boundary_drift_notify.arn
    role_arn = aws_iam_role.ciem_scheduler.arn
    input    = jsonencode({ role_suffix = each.key })
  }
}

resource "aws_lambda_permission" "allow_scheduler_boundary_drift" {
  for_each = toset(var.boundary_drift_role_suffixes)

  statement_id  = "AllowEventBridgeScheduler-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ciem_boundary_drift_notify.function_name
  principal     = "scheduler.amazonaws.com"
  source_arn    = aws_scheduler_schedule.ciem_boundary_drift_check[each.key].arn
}
