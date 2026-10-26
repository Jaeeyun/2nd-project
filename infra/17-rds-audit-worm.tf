
import {
  to = aws_s3_bucket.rds_audit_worm
  id = "${local.name_prefix}-rds-audit-worm-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "rds_audit_worm" {
  bucket = "${local.name_prefix}-rds-audit-worm-${data.aws_caller_identity.current.account_id}"

  object_lock_enabled = true
}

resource "aws_s3_bucket_versioning" "rds_audit_worm" {
  bucket = aws_s3_bucket.rds_audit_worm.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_object_lock_configuration" "rds_audit_worm" {
  bucket = aws_s3_bucket.rds_audit_worm.id

  rule {
    default_retention {

      mode = "GOVERNANCE"
      days = var.rds_audit_worm_retention_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.rds_audit_worm]
}

resource "aws_s3_bucket_public_access_block" "rds_audit_worm" {
  bucket                  = aws_s3_bucket.rds_audit_worm.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "rds_audit_worm" {
  bucket = aws_s3_bucket.rds_audit_worm.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "rds_audit_worm" {
  bucket = aws_s3_bucket.rds_audit_worm.id

  rule {
    id     = "transition-to-deep-archive"
    status = "Enabled"

    filter {}

    transition {
      days          = 30
      storage_class = "DEEP_ARCHIVE"
    }
  }
}

resource "aws_iam_role" "firehose_rds_audit" {
  name = "${local.name_prefix}-firehose-rds-audit-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "firehose.amazonaws.com" }
    }]
  })
}

data "aws_iam_policy_document" "firehose_rds_audit" {
  statement {
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:GetBucketLocation", "s3:ListBucket"]
    resources = [aws_s3_bucket.rds_audit_worm.arn, "${aws_s3_bucket.rds_audit_worm.arn}/*"]
  }
}

resource "aws_iam_role_policy" "firehose_rds_audit" {
  name   = "firehose-s3-write"
  role   = aws_iam_role.firehose_rds_audit.id
  policy = data.aws_iam_policy_document.firehose_rds_audit.json
}

resource "aws_kinesis_firehose_delivery_stream" "rds_audit" {
  name        = "${local.name_prefix}-rds-audit-worm-stream"
  destination = "extended_s3"

  server_side_encryption {
    enabled = true
  }

  extended_s3_configuration {
    role_arn           = aws_iam_role.firehose_rds_audit.arn
    bucket_arn         = aws_s3_bucket.rds_audit_worm.arn
    prefix             = "rds-postgresql-audit/"
    compression_format = "GZIP"
    buffering_size     = 5
    buffering_interval = 300
  }
}

resource "aws_iam_role" "cwl_to_firehose" {
  name = "${local.name_prefix}-cwl-to-firehose-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "logs.${var.aws_region}.amazonaws.com" }
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
      }
    }]
  })
}

data "aws_iam_policy_document" "cwl_to_firehose" {
  statement {
    effect    = "Allow"
    actions   = ["firehose:PutRecord", "firehose:PutRecordBatch"]
    resources = [aws_kinesis_firehose_delivery_stream.rds_audit.arn]
  }
}

resource "aws_iam_role_policy" "cwl_to_firehose" {
  name   = "cwl-to-firehose-put-record"
  role   = aws_iam_role.cwl_to_firehose.id
  policy = data.aws_iam_policy_document.cwl_to_firehose.json
}

resource "aws_cloudwatch_log_subscription_filter" "rds_audit_to_worm" {
  name           = "${local.name_prefix}-rds-audit-to-worm"
  log_group_name = aws_cloudwatch_log_group.rds_postgresql.name

  filter_pattern  = "AUDIT"
  destination_arn = aws_kinesis_firehose_delivery_stream.rds_audit.arn
  role_arn        = aws_iam_role.cwl_to_firehose.arn
}

output "rds_audit_worm_bucket" {
  description = "RDS 감사로그 장기 보관용 S3 버킷 (Object Lock Compliance mode)"
  value       = aws_s3_bucket.rds_audit_worm.bucket
}
