
resource "aws_cloudwatch_log_group" "app_access_logs" {
  name              = "/ztna/${local.name_prefix}/app-access"
  retention_in_days = 3
}

data "aws_iam_policy_document" "fluent_bit_cwl" {
  statement {
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams", "logs:DescribeLogGroups"]
    resources = ["${aws_cloudwatch_log_group.app_access_logs.arn}:*"]
  }
}

resource "aws_iam_role" "fluent_bit" {
  name = "${local.name_prefix}-fluent-bit-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}:sub" = "system:serviceaccount:logging:fluent-bit"
            "${replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "fluent_bit_cwl" {
  name   = "fluent-bit-cwl-write"
  role   = aws_iam_role.fluent_bit.id
  policy = data.aws_iam_policy_document.fluent_bit_cwl.json
}

resource "kubernetes_namespace" "logging" {
  metadata {
    name = "logging"
  }
}

resource "helm_release" "fluent_bit" {
  name       = "fluent-bit"
  repository = "https://fluent.github.io/helm-charts"
  chart      = "fluent-bit"
  version    = "0.47.9"
  namespace  = kubernetes_namespace.logging.metadata[0].name

  values = [
    yamlencode({
      serviceAccount = {
        create = true
        name   = "fluent-bit"
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.fluent_bit.arn
        }
      }
      config = {

        service = <<-EOT
          [SERVICE]
              Flush         5
              Daemon        Off
              Log_Level     info
              Parsers_File  parsers.conf
              Parsers_File  /fluent-bit/etc/conf/custom_parsers.conf
              HTTP_Server   On
              HTTP_Listen   0.0.0.0
              HTTP_PORT     2020
        EOT

        customParsers = <<-EOT
          [PARSER]
              Name    decision_log_json
              Format  json
        EOT

        inputs = <<-EOT
          [INPUT]
              Name              tail
              Path              /var/log/containers/*opa-envoy*.log
              Tag               app-access.*
              Parser            cri
              Refresh_Interval  5
              Mem_Buf_Limit     5MB
        EOT

        filters = <<-EOT
          [FILTER]
              Name          parser
              Match         app-access.*
              Key_Name      message
              Parser        decision_log_json
              Reserve_Data  On

          [FILTER]
              Name    lua
              Match   app-access.*
              call    extract_account
              code    function extract_account(tag, timestamp, record) local h = record["input"] and record["input"]["attributes"] and record["input"]["attributes"]["request"] and record["input"]["attributes"]["request"]["http"] and record["input"]["attributes"]["request"]["http"]["headers"] local method = (h and h[":method"]) or "GET" local action_map = {GET="VIEW", POST="CREATE", PUT="EDIT", PATCH="EDIT", DELETE="DELETE"} local out = {} out["log_type"] = "app_access" out["account"] = (h and (h["x-auth-request-email"] or h["x-auth-request-preferred-username"])) or "unknown" out["access_time"] = record["time"] or "unknown" out["access_ip"] = (h and h["x-envoy-external-address"]) or "unknown" out["subject_processed"] = (h and ((h[":authority"] or "") .. (h[":path"] or ""))) or "unknown" out["action"] = action_map[method] or method out["result"] = record["result"] and "ALLOW" or "DENY" out["source"] = "opa-decision-log" return 2, timestamp, out end
        EOT

        outputs = <<-EOT
          [OUTPUT]
              Name                cloudwatch_logs
              Match               app-access.*
              region              ${var.aws_region}
              log_group_name      ${aws_cloudwatch_log_group.app_access_logs.name}
              log_stream_prefix   opa-decision-
              auto_create_group   false
        EOT
      }
    })
  ]

  depends_on = [
    kubernetes_deployment.opa_envoy,
    aws_iam_role_policy.fluent_bit_cwl,
    helm_release.istiod,
  ]
}

resource "aws_cloudwatch_log_group" "login_logout_logs" {
  name              = "/ztna/${local.name_prefix}/login-logout"
  retention_in_days = 3
}

data "aws_iam_policy_document" "keycloak_login_events_logs" {
  statement {
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.login_logout_logs.arn}:*"]
  }
}

resource "aws_iam_role_policy" "keycloak_login_events_logs" {
  name   = "keycloak-login-events-logs-write"
  role   = aws_iam_role.keycloak_ec2.id
  policy = data.aws_iam_policy_document.keycloak_login_events_logs.json
}

resource "aws_s3_object" "keycloak_login_events_shipper" {
  bucket      = aws_s3_bucket.opa_artifacts.id
  key         = "scripts/keycloak-login-events-shipper.py"
  source      = "${path.module}/scripts/keycloak-login-events-shipper.py"
  source_hash = filemd5("${path.module}/scripts/keycloak-login-events-shipper.py")
}

resource "null_resource" "keycloak_login_events_shipper_install" {
  depends_on = [
    null_resource.keycloak_webapp_oidc_bootstrap,
    aws_s3_object.keycloak_login_events_shipper,
    aws_iam_role_policy.keycloak_login_events_logs,
  ]

  triggers = {
    keycloak_instance_id = aws_instance.keycloak.id
    script_hash          = filemd5("${path.module}/scripts/keycloak-install-login-events-shipper.sh")
    shipper_hash         = filemd5("${path.module}/scripts/keycloak-login-events-shipper.py")
  }

  provisioner "local-exec" {
    command = join(" ", [
      "${path.module}/scripts/tf-run-ssm-script.sh",
      aws_instance.keycloak.id,
      var.aws_region,
      "${path.module}/scripts/keycloak-install-login-events-shipper.sh",
      "ARTIFACTS_BUCKET=${aws_s3_bucket.opa_artifacts.id}",
      "LOG_GROUP_NAME=${aws_cloudwatch_log_group.login_logout_logs.name}",
    ])
  }
}

output "app_access_log_group" {
  value = aws_cloudwatch_log_group.app_access_logs.name
}

output "login_logout_log_group" {
  value = aws_cloudwatch_log_group.login_logout_logs.name
}
