
resource "aws_securityhub_automation_rule" "suppress_dev_tagged" {
  rule_name   = "${local.name_prefix}-suppress-dev-tagged"
  description = "Environment=suppresstag 태그가 명시적으로 붙은 리소스의 finding만 평가 즉시 억제"
  rule_order  = 1
  rule_status = "ENABLED"
  is_terminal = false

  criteria {
    resource_tags {
      comparison = "EQUALS"
      key        = "Environment"
      value      = "suppresstag"
    }
    workflow_status {
      comparison = "EQUALS"
      value      = "NEW"
    }
    record_state {
      comparison = "EQUALS"
      value      = "ACTIVE"
    }
  }

  actions {
    type = "FINDING_FIELDS_UPDATE"
    finding_fields_update {
      workflow {
        status = "SUPPRESSED"
      }
      note {
        text       = "Environment=suppresstag 태그(명시적 억제 옵트인) - Automation Rule에 의해 자동 억제됨"
        updated_by = "automation-rule-suppress-dev-tagged"
      }
    }
  }
}

resource "aws_securityhub_automation_rule" "suppress_known_accepted_risks" {
  rule_name   = "${local.name_prefix}-suppress-known-accepted-risks"
  description = "이미 위험 수용 결정된 유형의 finding은 재발해도 평가 즉시 억제 (근거: security-hub-suppress-accepted-risks.sh)"
  rule_order  = 2
  rule_status = "ENABLED"
  is_terminal = false

  criteria {
    title {
      comparison = "EQUALS"
      value      = "VPCs should be configured with an interface endpoint for Systems Manager"
    }
    title {
      comparison = "EQUALS"
      value      = "Amazon EC2 should be configured to use VPC endpoints that are created for the Amazon EC2 service"
    }
    title {
      comparison = "EQUALS"
      value      = "Amazon Inspector EC2 scanning should be enabled"
    }
    title {
      comparison = "EQUALS"
      value      = "GuardDuty Runtime Monitoring should be enabled"
    }
    title {
      comparison = "EQUALS"
      value      = "RDS DB instances should be configured with multiple Availability Zones"
    }
    title {
      comparison = "EQUALS"
      value      = "Secrets Manager secrets should have automatic rotation enabled"
    }
    title {
      comparison = "EQUALS"
      value      = "DynamoDB tables should automatically scale capacity with demand"
    }
    title {
      comparison = "EQUALS"
      value      = "CloudFormation stacks should have associated service roles"
    }
    workflow_status {
      comparison = "EQUALS"
      value      = "NEW"
    }
  }

  actions {
    type = "FINDING_FIELDS_UPDATE"
    finding_fields_update {
      workflow {
        status = "SUPPRESSED"
      }
      note {
        text       = "이미 위험 수용 결정됨(security-hub-suppress-accepted-risks.sh 근거 참고) - Automation Rule에 의해 재발 시 자동 억제"
        updated_by = "automation-rule-suppress-known-accepted-risks"
      }
    }
  }
}

resource "aws_config_config_rule" "s3_bucket_public_read_prohibited" {
  name = "${local.name_prefix}-s3-bucket-public-read-prohibited"
  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_PUBLIC_READ_PROHIBITED"
  }
  depends_on = [aws_config_configuration_recorder.main]
}

resource "aws_config_config_rule" "s3_bucket_public_write_prohibited" {
  name = "${local.name_prefix}-s3-bucket-public-write-prohibited"
  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_PUBLIC_WRITE_PROHIBITED"
  }
  depends_on = [aws_config_configuration_recorder.main]
}
