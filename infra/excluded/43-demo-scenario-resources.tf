
resource "aws_security_group" "asr_demo_target" {
  name        = "${local.name_prefix}-asr-demo-target-sg"
  description = "Scene 8 ASR remediation demo target - not attached to any instance"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name    = "${local.name_prefix}-asr-demo-target-sg"
    Purpose = "asr-demo-scene8"
  }
}

output "asr_demo_target_sg_id" {
  value = aws_security_group.asr_demo_target.id
}

data "aws_iam_policy_document" "eks_node_rds_connect_demo" {
  statement {
    effect  = "Allow"
    actions = ["rds-db:connect"]
    resources = [
      "arn:aws:rds-db:${var.aws_region}:${data.aws_caller_identity.current.account_id}:dbuser:${aws_db_instance.main.resource_id}/general_user_readonly",
      "arn:aws:rds-db:${var.aws_region}:${data.aws_caller_identity.current.account_id}:dbuser:${aws_db_instance.main.resource_id}/security_auditor_readonly",
      "arn:aws:rds-db:${var.aws_region}:${data.aws_caller_identity.current.account_id}:dbuser:${aws_db_instance.main.resource_id}/db_admin",
    ]
  }
}

resource "aws_iam_role_policy" "eks_node_rds_connect_demo" {
  name   = "eks-node-rds-connect-scene5-demo"
  role   = aws_iam_role.eks_node_role.id
  policy = data.aws_iam_policy_document.eks_node_rds_connect_demo.json
}
