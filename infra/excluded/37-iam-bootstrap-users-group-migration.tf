
resource "aws_iam_group" "bootstrap_admins" {
  name = "${local.name_prefix}-bootstrap-admins"
}

resource "aws_iam_group_policy_attachment" "bootstrap_admins" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonSSMFullAccess",
    "arn:aws:iam::aws:policy/AmazonEC2FullAccess",
    "arn:aws:iam::aws:policy/IAMFullAccess",
    "arn:aws:iam::aws:policy/AmazonS3FullAccess",
    "arn:aws:iam::aws:policy/AWSCloudTrail_FullAccess",
    "arn:aws:iam::aws:policy/AWSCloudTrail_ReadOnlyAccess",
  ])
  group      = aws_iam_group.bootstrap_admins.name
  policy_arn = each.value
}

resource "aws_iam_user_group_membership" "terraform_admin" {
  user   = "terraform-admin"
  groups = [aws_iam_group.bootstrap_admins.name]
}

resource "aws_iam_group" "emergency_admins" {
  name = "${local.name_prefix}-emergency-admins"
}

resource "aws_iam_group_policy_attachment" "emergency_admins" {
  group      = aws_iam_group.emergency_admins.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_user_group_membership" "dev_admin" {
  user   = "dev-admin"
  groups = [aws_iam_group.emergency_admins.name]
}

output "iam2_manual_cleanup_commands" {
  description = "Group 멤버십 적용 확인 후, 이 명령으로 기존 직접 첨부 정책을 제거하세요(순서 중요)"
  value = [
    "aws iam detach-user-policy --user-name terraform-admin --policy-arn arn:aws:iam::aws:policy/AmazonSSMFullAccess",
    "aws iam detach-user-policy --user-name terraform-admin --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess",
    "aws iam detach-user-policy --user-name terraform-admin --policy-arn arn:aws:iam::aws:policy/IAMFullAccess",
    "aws iam detach-user-policy --user-name terraform-admin --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess",
    "aws iam detach-user-policy --user-name terraform-admin --policy-arn arn:aws:iam::aws:policy/AWSCloudTrail_FullAccess",
    "aws iam detach-user-policy --user-name terraform-admin --policy-arn arn:aws:iam::aws:policy/AWSCloudTrail_ReadOnlyAccess",
    "aws iam detach-user-policy --user-name dev-admin --policy-arn arn:aws:iam::aws:policy/AdministratorAccess",
  ]
}
