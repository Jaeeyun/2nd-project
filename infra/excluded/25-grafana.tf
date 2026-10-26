
resource "aws_iam_role" "grafana" {
  name = "${local.name_prefix}-grafana-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "grafana.amazonaws.com" }
    }]
  })
}

data "aws_iam_policy_document" "grafana_datasources" {
  statement {
    effect = "Allow"
    actions = [
      "cloudwatch:DescribeAlarmsForMetric",
      "cloudwatch:DescribeAlarmHistory",
      "cloudwatch:DescribeAlarms",
      "cloudwatch:ListMetrics",
      "cloudwatch:GetMetricData",
      "cloudwatch:GetInsightRuleReport",
      "logs:DescribeLogGroups",
      "logs:GetLogGroupFields",
      "logs:StartQuery",
      "logs:StopQuery",
      "logs:GetQueryResults",
      "logs:GetLogEvents",

      "oam:ListSinks",
      "oam:ListAttachedLinks",
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "athena:GetDataCatalog",
      "athena:GetDatabase",
      "athena:GetTableMetadata",
      "athena:ListDatabases",
      "athena:ListTableMetadata",
      "athena:StartQueryExecution",
      "athena:GetQueryExecution",
      "athena:GetQueryResults",
      "athena:StopQueryExecution",
      "athena:GetWorkGroup",
      "athena:ListWorkGroups",
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:GetTable",
      "glue:GetTables",
      "glue:GetPartition",
      "glue:GetPartitions",
      "glue:BatchGetPartition",
    ]
    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:GetBucketLocation", "s3:GetObject", "s3:ListBucket"]
    resources = ["arn:aws:s3:::aws-security-data-lake-*", "arn:aws:s3:::aws-security-data-lake-*/*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:GetBucketLocation", "s3:GetObject", "s3:ListBucket"]
    resources = [aws_s3_bucket.cloudtrail_bucket.arn, "${aws_s3_bucket.cloudtrail_bucket.arn}/*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["arn:aws:s3:::aws-security-data-lake-*/athena-results/*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = [aws_kms_key.cloudtrail.arn]
  }
}

resource "aws_iam_role_policy" "grafana_datasources" {
  name   = "grafana-datasources-readonly"
  role   = aws_iam_role.grafana.id
  policy = data.aws_iam_policy_document.grafana_datasources.json
}

resource "aws_lakeformation_permissions" "grafana_database" {
  principal   = aws_iam_role.grafana.arn
  permissions = ["DESCRIBE"]

  database {
    name = "amazon_security_lake_glue_db_${replace(var.aws_region, "-", "_")}"
  }
}

resource "aws_lakeformation_permissions" "grafana_tables" {
  principal   = aws_iam_role.grafana.arn
  permissions = ["SELECT", "DESCRIBE"]

  table {
    database_name = "amazon_security_lake_glue_db_${replace(var.aws_region, "-", "_")}"
    wildcard      = true
  }
}

resource "aws_glue_catalog_table" "cloudtrail" {
  name          = "demo_project_cloudtrail_logs"
  database_name = "default"
  table_type    = "EXTERNAL_TABLE"

  storage_descriptor {

    location      = "s3://${aws_s3_bucket.cloudtrail_bucket.id}/prefix/AWSLogs/${data.aws_caller_identity.current.account_id}/CloudTrail/"
    input_format  = "com.amazon.emr.cloudtrail.CloudTrailInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      serialization_library = "com.amazon.emr.hive.serde.CloudTrailSerde"
    }

    columns {
      name = "eventversion"
      type = "string"
    }
    columns {
      name = "useridentity"
      type = "struct<type:string,principalid:string,arn:string,accountid:string,invokedby:string,accesskeyid:string,userName:string,sessioncontext:struct<attributes:struct<mfaauthenticated:string,creationdate:string>,sessionissuer:struct<type:string,principalId:string,arn:string,accountId:string,userName:string>>>"
    }
    columns {
      name = "eventtime"
      type = "string"
    }
    columns {
      name = "eventsource"
      type = "string"
    }
    columns {
      name = "eventname"
      type = "string"
    }
    columns {
      name = "awsregion"
      type = "string"
    }
    columns {
      name = "sourceipaddress"
      type = "string"
    }
    columns {
      name = "useragent"
      type = "string"
    }
    columns {
      name = "errorcode"
      type = "string"
    }
    columns {
      name = "errormessage"
      type = "string"
    }
    columns {
      name = "requestparameters"
      type = "string"
    }
    columns {
      name = "responseelements"
      type = "string"
    }
    columns {
      name = "additionaleventdata"
      type = "string"
    }
    columns {
      name = "requestid"
      type = "string"
    }
    columns {
      name = "eventid"
      type = "string"
    }
    columns {
      name = "resources"
      type = "array<struct<arn:string,accountId:string,type:string>>"
    }
    columns {
      name = "eventtype"
      type = "string"
    }
    columns {
      name = "apiversion"
      type = "string"
    }
    columns {
      name = "readonly"
      type = "string"
    }
    columns {
      name = "recipientaccountid"
      type = "string"
    }
    columns {
      name = "serviceeventdetails"
      type = "string"
    }
    columns {
      name = "sharedeventid"
      type = "string"
    }
    columns {
      name = "vpcendpointid"
      type = "string"
    }
  }
}

resource "aws_lakeformation_permissions" "grafana_default_database" {
  principal   = aws_iam_role.grafana.arn
  permissions = ["DESCRIBE"]

  database {
    name = "default"
  }
}

resource "aws_lakeformation_permissions" "grafana_cloudtrail_table" {
  principal   = aws_iam_role.grafana.arn
  permissions = ["SELECT", "DESCRIBE"]

  table {
    database_name = "default"
    name          = aws_glue_catalog_table.cloudtrail.name
  }
}

resource "aws_grafana_workspace" "main" {
  name                     = "${local.name_prefix}-soc"
  account_access_type      = "CURRENT_ACCOUNT"
  authentication_providers = ["SAML"]
  permission_type          = "SERVICE_MANAGED"
  role_arn                 = aws_iam_role.grafana.arn
  data_sources             = ["CLOUDWATCH", "ATHENA"]

  configuration = jsonencode({
    unifiedAlerting = { enabled = false }
    plugins         = { pluginAdminEnabled = true }
  })
}

resource "null_resource" "keycloak_grafana_saml_client" {
  depends_on = [null_resource.wait_for_keycloak, aws_grafana_workspace.main]

  triggers = {
    grafana_endpoint     = aws_grafana_workspace.main.endpoint
    keycloak_instance_id = aws_instance.keycloak.id
    script_hash          = filemd5("${path.module}/scripts/keycloak-grafana-saml-client.sh")
  }

  provisioner "local-exec" {
    command = "${path.module}/scripts/tf-run-ssm-script.sh ${aws_instance.keycloak.id} ${var.aws_region} ${path.module}/scripts/keycloak-grafana-saml-client.sh GRAFANA_ENDPOINT=${aws_grafana_workspace.main.endpoint}"
  }
}

resource "aws_grafana_workspace_saml_configuration" "keycloak" {
  workspace_id     = aws_grafana_workspace.main.id
  idp_metadata_xml = data.http.keycloak_saml_metadata.response_body

  role_assertion  = "role"
  email_assertion = "email"
  login_assertion = "login"
  name_assertion  = "name"

  admin_role_values  = ["dev-lead", "ops-lead", "db-lead"]
  editor_role_values = ["dev-general", "ops-general", "db-general", "security-auditor", "dev-hr-backend"]

  depends_on = [null_resource.keycloak_grafana_saml_client]
}

resource "null_resource" "grafana_securityhub_standard_dashboard" {
  depends_on = [
    aws_grafana_workspace_saml_configuration.keycloak,
    aws_iam_role_policy.grafana_datasources,
    null_resource.keycloak_grafana_saml_client,
  ]

  triggers = {
    dashboard_hash   = filemd5("${path.module}/docs/grafana/grafana-securityhub-standard-dashboard.json")
    grafana_endpoint = aws_grafana_workspace.main.endpoint
  }

  provisioner "local-exec" {
    command = <<-EOT
      cd ${path.module}
      export GRAFANA_ENDPOINT="${aws_grafana_workspace.main.endpoint}"
      export KEYCLOAK_ENDPOINT="${aws_lb.keycloak.dns_name}"
      export KEYCLOAK_USER="test-ops-lead"
      export KEYCLOAK_PASSWORD="${var.keycloak_test_users_password}"
      export DASHBOARD_JSON="docs/grafana/grafana-securityhub-standard-dashboard.json"
      for i in $(seq 1 10); do
        if bash scripts/grafana-dashboard-setup.sh; then
          echo "표준 대시보드 프로비저닝 성공"
          exit 0
        fi
        echo "대시보드 프로비저닝 실패, 15초 후 재시도... ($i/10)"
        sleep 15
      done
      echo "표준 대시보드 프로비저닝 최종 실패" >&2
      exit 1
    EOT
  }
}

output "grafana_workspace_endpoint" {
  value = aws_grafana_workspace.main.endpoint
}

output "grafana_workspace_id" {
  value = aws_grafana_workspace.main.id
}

output "grafana_saml_configuration_status" {
  value = aws_grafana_workspace_saml_configuration.keycloak.status
}

resource "aws_athena_workgroup" "primary" {
  count = var.enable_security_lake ? 1 : 0
  name  = "primary"

  configuration {

    enforce_workgroup_configuration = false

    result_configuration {
      output_location = "s3://${split(":::", aws_securitylake_data_lake.main[0].s3_bucket_arn)[1]}/athena-results/"
    }
  }
}

resource "null_resource" "grafana_cspm_interactive_dashboard" {
  depends_on = [
    aws_grafana_workspace_saml_configuration.keycloak,
    aws_iam_role_policy.grafana_datasources,
    null_resource.keycloak_grafana_saml_client,
  ]

  triggers = {
    dashboard_hash   = filemd5("${path.module}/docs/grafana/grafana-cspm-interactive-dashboard.json")
    grafana_endpoint = aws_grafana_workspace.main.endpoint
  }

  provisioner "local-exec" {
    command = <<-EOT
      cd ${path.module}
      export GRAFANA_ENDPOINT="${aws_grafana_workspace.main.endpoint}"
      export KEYCLOAK_ENDPOINT="${aws_lb.keycloak.dns_name}"
      export KEYCLOAK_USER="test-ops-lead"
      export KEYCLOAK_PASSWORD="${var.keycloak_test_users_password}"
      export DASHBOARD_JSON="docs/grafana/grafana-cspm-interactive-dashboard.json"
      for i in $(seq 1 10); do
        if bash scripts/grafana-dashboard-setup.sh; then
          echo "CSPM 인터랙티브 대시보드 프로비저닝 성공"
          exit 0
        fi
        echo "대시보드 프로비저닝 실패, 15초 후 재시도... ($i/10)"
        sleep 15
      done
      echo "CSPM 인터랙티브 대시보드 프로비저닝 최종 실패" >&2
      exit 1
    EOT
  }
}

resource "null_resource" "grafana_cspm_resource_explorer_dashboard" {
  depends_on = [
    aws_grafana_workspace_saml_configuration.keycloak,
    aws_iam_role_policy.grafana_datasources,
    null_resource.keycloak_grafana_saml_client,
  ]

  triggers = {
    dashboard_hash   = filemd5("${path.module}/docs/grafana/grafana-cspm-resource-explorer-dashboard.json")
    grafana_endpoint = aws_grafana_workspace.main.endpoint
  }

  provisioner "local-exec" {
    command = <<-EOT
      cd ${path.module}
      export GRAFANA_ENDPOINT="${aws_grafana_workspace.main.endpoint}"
      export KEYCLOAK_ENDPOINT="${aws_lb.keycloak.dns_name}"
      export KEYCLOAK_USER="test-ops-lead"
      export KEYCLOAK_PASSWORD="${var.keycloak_test_users_password}"
      export DASHBOARD_JSON="docs/grafana/grafana-cspm-resource-explorer-dashboard.json"
      for i in $(seq 1 10); do
        if bash scripts/grafana-dashboard-setup.sh; then
          echo "CSPM 자원 탐색기 대시보드 프로비저닝 성공"
          exit 0
        fi
        echo "대시보드 프로비저닝 실패, 15초 후 재시도... ($i/10)"
        sleep 15
      done
      echo "CSPM 자원 탐색기 대시보드 프로비저닝 최종 실패" >&2
      exit 1
    EOT
  }
}

resource "null_resource" "grafana_platform_dashboards" {
  for_each = fileset("${path.module}/platform-grafana", "*.json")

  depends_on = [
    aws_grafana_workspace_saml_configuration.keycloak,
    aws_iam_role_policy.grafana_datasources,
    null_resource.keycloak_grafana_saml_client,
  ]

  triggers = {
    dashboard_hash   = filemd5("${path.module}/platform-grafana/${each.value}")
    grafana_endpoint = aws_grafana_workspace.main.endpoint
  }

  provisioner "local-exec" {
    command = <<-EOT
      cd ${path.module}
      export GRAFANA_ENDPOINT="${aws_grafana_workspace.main.endpoint}"
      export KEYCLOAK_ENDPOINT="${aws_lb.keycloak.dns_name}"
      export KEYCLOAK_USER="test-ops-lead"
      export KEYCLOAK_PASSWORD="${var.keycloak_test_users_password}"
      export DASHBOARD_JSON="platform-grafana/${each.value}"
      for i in $(seq 1 10); do
        if bash scripts/grafana-dashboard-setup.sh; then
          echo "${each.value} 프로비저닝 성공"
          exit 0
        fi
        echo "${each.value} 프로비저닝 실패, 15초 후 재시도... ($i/10)"
        sleep 15
      done
      echo "${each.value} 프로비저닝 최종 실패" >&2
      exit 1
    EOT
  }
}