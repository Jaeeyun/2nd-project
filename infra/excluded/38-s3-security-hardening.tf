
data "aws_iam_policy_document" "rds_audit_worm_ssl" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.rds_audit_worm.arn, "${aws_s3_bucket.rds_audit_worm.arn}/*"]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "rds_audit_worm_ssl" {
  bucket = aws_s3_bucket.rds_audit_worm.id
  policy = data.aws_iam_policy_document.rds_audit_worm_ssl.json
}

resource "aws_s3_bucket_logging" "rds_audit_worm" {
  bucket = aws_s3_bucket.rds_audit_worm.id

  target_bucket = aws_s3_bucket.config_bucket.id
  target_prefix = "s3-access-logs/rds-audit-worm/"
}

data "aws_iam_policy_document" "session_logs_ssl" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.session_logs.arn, "${aws_s3_bucket.session_logs.arn}/*"]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid    = "S3ServerAccessLogsPolicy"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["logging.s3.amazonaws.com"]
    }
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.session_logs.arn}/s3-access-logs/*"]
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.config_bucket.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_s3_bucket_policy" "session_logs_ssl" {
  bucket = aws_s3_bucket.session_logs.id
  policy = data.aws_iam_policy_document.session_logs_ssl.json
}

resource "aws_s3_bucket_logging" "session_logs" {
  bucket = aws_s3_bucket.session_logs.id

  target_bucket = aws_s3_bucket.config_bucket.id
  target_prefix = "s3-access-logs/session-logs/"
}

resource "aws_s3_bucket_lifecycle_configuration" "session_logs" {
  bucket = aws_s3_bucket.session_logs.id

  rule {
    id     = "expire_after_90_days"
    status = "Enabled"
    filter {}
    expiration {
      days = 90
    }
  }
}

resource "aws_s3_bucket_logging" "config_bucket" {
  bucket = aws_s3_bucket.config_bucket.id

  target_bucket = aws_s3_bucket.session_logs.id
  target_prefix = "s3-access-logs/config-bucket/"
}

data "aws_iam_policy_document" "mtls_trust_store_ssl" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.mtls_trust_store.arn, "${aws_s3_bucket.mtls_trust_store.arn}/*"]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "mtls_trust_store_ssl" {
  bucket = aws_s3_bucket.mtls_trust_store.id
  policy = data.aws_iam_policy_document.mtls_trust_store_ssl.json
}

resource "aws_s3_bucket_logging" "mtls_trust_store" {
  bucket = aws_s3_bucket.mtls_trust_store.id

  target_bucket = aws_s3_bucket.config_bucket.id
  target_prefix = "s3-access-logs/mtls-trust-store/"
}

resource "aws_s3_bucket_lifecycle_configuration" "mtls_trust_store" {
  bucket = aws_s3_bucket.mtls_trust_store.id

  rule {
    id     = "expire_after_90_days"
    status = "Enabled"
    filter {}
    expiration {
      days = 90
    }
  }
}

resource "aws_ebs_encryption_by_default" "main" {
  enabled = true
}

resource "aws_iam_role" "aws_support_access" {
  name = "${local.name_prefix}-aws-support-access-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "aws_support_access" {
  role       = aws_iam_role.aws_support_access.name
  policy_arn = "arn:aws:iam::aws:policy/AWSSupportAccess"
}
