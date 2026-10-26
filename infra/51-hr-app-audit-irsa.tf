
data "aws_iam_policy_document" "hr_app_audit_write" {
  statement {
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = ["${aws_cloudwatch_log_group.db_access_structured.arn}:*"]
  }
}

resource "aws_iam_role" "hr_app_audit" {
  name = "${local.name_prefix}-hr-app-audit-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}:aud" = "sts.amazonaws.com"
            "${replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}:sub" = [
              "system:serviceaccount:hr-backend:hr-service",
              "system:serviceaccount:employee-backend:employee-service",
            ]
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "hr_app_audit_write" {
  name   = "hr-app-audit-cwl-write"
  role   = aws_iam_role.hr_app_audit.id
  policy = data.aws_iam_policy_document.hr_app_audit_write.json
}

resource "kubernetes_service_account" "hr_service" {
  metadata {
    name      = "hr-service"
    namespace = kubernetes_namespace.app_namespaces["hr-backend"].metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.hr_app_audit.arn
    }
  }
}

resource "kubernetes_service_account" "employee_service" {
  metadata {
    name      = "employee-service"
    namespace = kubernetes_namespace.app_namespaces["employee-backend"].metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.hr_app_audit.arn
    }
  }
}

output "db_access_log_group_name" {
  description = "hr-app이 ②DB 접속기록을 직접 쓸 CloudWatch 로그 그룹 이름 (DB_ACCESS_LOG_GROUP 환경변수에 넣을 값)"
  value       = aws_cloudwatch_log_group.db_access_structured.name
}
