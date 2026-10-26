
locals {

  asr_namespace = "asrdemo"
}

resource "aws_cloudformation_stack" "asr_member_roles" {
  count        = var.enable_asr_remediation ? 1 : 0
  name         = "${local.name_prefix}-asr-member-roles"
  template_url = "https://s3.amazonaws.com/solutions-reference/automated-security-response-on-aws/latest/automated-security-response-member-roles.template"
  capabilities = ["CAPABILITY_IAM", "CAPABILITY_NAMED_IAM"]

  parameters = {
    SecHubAdminAccount = data.aws_caller_identity.current.account_id
    Namespace          = local.asr_namespace
  }

  tags = {
    Name = "${local.name_prefix}-asr-member-roles"
  }
}

resource "aws_cloudformation_stack" "asr_member" {
  count        = var.enable_asr_remediation ? 1 : 0
  name         = "${local.name_prefix}-asr-member"
  template_url = "https://s3.amazonaws.com/solutions-reference/automated-security-response-on-aws/latest/automated-security-response-member.template"
  capabilities = ["CAPABILITY_IAM", "CAPABILITY_NAMED_IAM", "CAPABILITY_AUTO_EXPAND"]

  parameters = {
    SecHubAdminAccount                    = data.aws_caller_identity.current.account_id
    Namespace                             = local.asr_namespace
    LogGroupName                          = aws_cloudwatch_log_group.cloudtrail.name
    EnableCloudTrailForASRActionLog       = "no"
    CreateS3BucketForRedshiftAuditLogging = "no"
    LoadSCMemberStack                     = "yes"
    LoadAFSBPMemberStack                  = "no"
    LoadCIS120MemberStack                 = "no"
    LoadCIS140MemberStack                 = "no"
    LoadCIS300MemberStack                 = "no"
    LoadNIST80053MemberStack              = "no"
    LoadPCI321MemberStack                 = "no"
  }

  tags = {
    Name = "${local.name_prefix}-asr-member"
  }

  depends_on = [aws_cloudformation_stack.asr_member_roles]
}

output "asr_member_stack_id" {
  value = var.enable_asr_remediation ? aws_cloudformation_stack.asr_member[0].id : "disabled (enable_asr_remediation=false)"
}
