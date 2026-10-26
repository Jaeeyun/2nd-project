
variable "github_org" {
  description = "GitHub organization/user 이름 (예: my-org)"
  type        = string
}

variable "github_repo" {
  description = "이 인프라를 배포하는 GitHub 저장소 이름"
  type        = string
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_policy_document" "github_ci_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}*/${var.github_repo}*:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "github_ci" {
  name = "${local.name_prefix}-github-ci-role"

  description        = "ADR-006: CI-only role assumed via OIDC by GitHub Actions. No static keys."
  assume_role_policy = data.aws_iam_policy_document.github_ci_trust.json
}

data "aws_iam_policy_document" "github_ci_permissions" {
  statement {
    effect = "Allow"
    actions = [
      "ec2:Describe*",
      "eks:Describe*",
      "eks:List*",
      "eks:UpdateAddon",
      "rds:Describe*",
      "ssm:SendCommand",
      "ssm:GetCommandInvocation",
      "s3:GetObject",
      "s3:PutObject",
      "s3:ListBucket",
      "iam:PassRole",
    ]
    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ssm:*:${data.aws_caller_identity.current.account_id}:document/*"]
  }
}

resource "aws_iam_role_policy" "github_ci_permissions" {
  name   = "github-ci-baseline"
  role   = aws_iam_role.github_ci.id
  policy = data.aws_iam_policy_document.github_ci_permissions.json
}

output "github_ci_role_arn" {
  description = "GitHub Actions 워크플로 YAML의 role-to-assume 값으로 사용"
  value       = aws_iam_role.github_ci.arn
}
