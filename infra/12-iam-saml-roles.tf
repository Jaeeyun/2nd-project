
locals {
  role_policy_files = {
    dev-general      = "07-role-dev-general.json.tpl"
    dev-lead         = "08-role-dev-lead.json.tpl"
    dev-hr-backend   = "11-role-dev-hr-backend.json.tpl"
    db-general       = "09-role-db-general.json.tpl"
    db-lead          = "10-role-db-lead.json.tpl"
    ops-general      = "03-role-general-user.json.tpl"
    ops-lead         = "04-role-approver.json.tpl"
    security-auditor = "06-role-security-auditor.json.tpl"
  }
}

resource "aws_iam_policy" "permission_boundary" {
  name        = "${local.name_prefix}-permission-boundary"
  description = "ADR-001 decision 7: upper bound for all SAML-federated roles"
  policy      = file("${path.module}/policies/01-permission-boundary.json")
}

resource "aws_iam_role" "standard" {
  for_each = { for k, v in local.role_policy_files : k => v if k != "security-auditor" }

  name = local.keycloak_role_names[each.key]
  assume_role_policy = templatefile("${path.module}/policies/02-trust-policy-saml-common.json.tpl", {
    account_id         = data.aws_caller_identity.current.account_id
    saml_provider_name = local.saml_provider_name
  })
  permissions_boundary = aws_iam_policy.permission_boundary.arn

  depends_on = [aws_iam_saml_provider.keycloak]
}

resource "aws_iam_role_policy" "standard" {
  for_each = aws_iam_role.standard

  name = "${each.key}-policy"
  role = each.value.id
  policy = templatefile("${path.module}/policies/${local.role_policy_files[each.key]}", {
    account_id              = data.aws_caller_identity.current.account_id
    db_resource_id          = aws_db_instance.main.resource_id
    rds_bastion_instance_id = aws_instance.rds_bastion.id
  })
}

resource "aws_iam_role" "security_auditor" {
  name = local.keycloak_role_names["security-auditor"]
  assume_role_policy = templatefile("${path.module}/policies/05-trust-policy-saml-security-auditor.json.tpl", {
    account_id             = data.aws_caller_identity.current.account_id
    saml_provider_name     = local.saml_provider_name
    allowed_cidr_list_json = jsonencode(var.security_auditor_allowed_cidrs)
  })
  permissions_boundary = aws_iam_policy.permission_boundary.arn

  depends_on = [aws_iam_saml_provider.keycloak]
}

resource "aws_iam_role_policy" "security_auditor" {
  name = "security-auditor-policy"
  role = aws_iam_role.security_auditor.id
  policy = templatefile("${path.module}/policies/06-role-security-auditor.json.tpl", {
    account_id              = data.aws_caller_identity.current.account_id
    db_resource_id          = aws_db_instance.main.resource_id
    rds_bastion_instance_id = aws_instance.rds_bastion.id
  })
}

output "iam_role_arns" {
  description = "Keycloak Group ↔ AWS IAM Role ARN 매핑 (검증용, ADR-019 8종)"
  value = merge(
    { for k, v in aws_iam_role.standard : k => v.arn },
    { security-auditor = aws_iam_role.security_auditor.arn }
  )
}
