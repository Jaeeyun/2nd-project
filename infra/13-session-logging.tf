
resource "aws_s3_bucket" "session_logs" {
  bucket        = "${local.name_prefix}-ssm-session-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "session_logs" {
  bucket                  = aws_s3_bucket.session_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "session_logs" {
  bucket = aws_s3_bucket.session_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_cloudwatch_log_group" "session_logs" {
  name              = "/ssm/${local.name_prefix}/session-logs"
  retention_in_days = 90
}

resource "aws_ssm_document" "session_manager_prefs" {
  name            = "SSM-SessionManagerRunShell"
  document_type   = "Session"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "1.0"
    description   = "ADR-002 decision 5: S3+CloudWatch session logging enforced"
    sessionType   = "Standard_Stream"
    inputs = {
      s3BucketName           = aws_s3_bucket.session_logs.bucket
      s3EncryptionEnabled    = true
      s3KeyPrefix            = "sessions/"
      cloudWatchLogGroupName = aws_cloudwatch_log_group.session_logs.name

      cloudWatchEncryptionEnabled = false
      cloudWatchStreamingEnabled  = true
      idleSessionTimeout          = "20"
    }
  })
}

data "aws_iam_policy_document" "session_log_bucket_encryption_check" {
  statement {
    effect    = "Allow"
    actions   = ["s3:GetEncryptionConfiguration"]
    resources = [aws_s3_bucket.session_logs.arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.session_logs.arn}/sessions/*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      aws_cloudwatch_log_group.session_logs.arn,
      "${aws_cloudwatch_log_group.session_logs.arn}:*",
    ]
  }
}

resource "aws_iam_role_policy" "keycloak_session_log_bucket_check" {
  name   = "session-log-bucket-encryption-check"
  role   = aws_iam_role.keycloak_ec2.id
  policy = data.aws_iam_policy_document.session_log_bucket_encryption_check.json
}

resource "aws_iam_role_policy" "eks_node_session_log_bucket_check" {
  name   = "session-log-bucket-encryption-check"
  role   = aws_iam_role.eks_node_role.id
  policy = data.aws_iam_policy_document.session_log_bucket_encryption_check.json
}

output "session_log_bucket" {
  value = aws_s3_bucket.session_logs.bucket
}

output "session_log_group" {
  value = aws_cloudwatch_log_group.session_logs.name
}
