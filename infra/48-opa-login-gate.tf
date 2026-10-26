
resource "aws_s3_bucket" "opa_artifacts" {
  bucket        = "${local.name_prefix}-opa-artifacts-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "opa_artifacts" {
  bucket                  = aws_s3_bucket.opa_artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "opa_artifacts" {
  bucket = aws_s3_bucket.opa_artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_logging" "opa_artifacts" {
  bucket        = aws_s3_bucket.opa_artifacts.id
  target_bucket = aws_s3_bucket.config_bucket.id
  target_prefix = "s3-access-logs/opa-artifacts-bucket/"
}

resource "aws_s3_object" "opa_login_context_policy" {
  bucket      = aws_s3_bucket.opa_artifacts.id
  key         = "policies/login_context.rego"
  source      = "${path.module}/opa/policies/login_context.rego"
  source_hash = filemd5("${path.module}/opa/policies/login_context.rego")
}

resource "aws_s3_object" "opa_decision_log_shipper" {
  bucket      = aws_s3_bucket.opa_artifacts.id
  key         = "scripts/opa-decision-log-shipper.py"
  source      = "${path.module}/scripts/opa-decision-log-shipper.py"
  source_hash = filemd5("${path.module}/scripts/opa-decision-log-shipper.py")
}

resource "aws_cloudwatch_log_group" "opa_decision_logs" {
  name              = "/opa/${local.name_prefix}/decisions"
  retention_in_days = 30
}

data "aws_iam_policy_document" "keycloak_opa_artifacts_read" {
  statement {
    effect  = "Allow"
    actions = ["s3:GetObject"]
    resources = [
      "${aws_s3_bucket.opa_artifacts.arn}/bin/*",
      "${aws_s3_bucket.opa_artifacts.arn}/policies/*",
      "${aws_s3_bucket.opa_artifacts.arn}/spi/*",
      "${aws_s3_bucket.opa_artifacts.arn}/scripts/*",
    ]
  }
  statement {
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.opa_decision_logs.arn}:*"]
  }
}

resource "aws_iam_role_policy" "keycloak_opa_artifacts_read" {
  name   = "keycloak-opa-artifacts-read"
  role   = aws_iam_role.keycloak_ec2.id
  policy = data.aws_iam_policy_document.keycloak_opa_artifacts_read.json
}

output "opa_artifacts_bucket" {
  description = "OPA 바이너리/SPI jar를 사람이 미리 올려둘 S3 버킷 (mirror-opa-binary-to-s3.sh, opa-keycloak-spi/README.md 참고)"
  value       = aws_s3_bucket.opa_artifacts.bucket
}

output "opa_decision_log_group" {
  value = aws_cloudwatch_log_group.opa_decision_logs.name
}
