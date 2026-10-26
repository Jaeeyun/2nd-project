
resource "aws_ecr_repository" "frontend_test" {
  name                 = "${local.name_prefix}-frontend-test-repo"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "frontend_test" {
  repository = aws_ecr_repository.frontend_test.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "최근 10개 이미지만 유지"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

data "aws_iam_policy_document" "github_ci_ecr_frontend_test" {
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "EcrPushFrontendTestOnly"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
    ]
    resources = [aws_ecr_repository.frontend_test.arn]
  }
}

resource "aws_iam_role_policy" "github_ci_ecr_frontend_test" {
  name   = "github-ci-ecr-frontend-test"
  role   = aws_iam_role.github_ci.id
  policy = data.aws_iam_policy_document.github_ci_ecr_frontend_test.json
}

resource "kubernetes_namespace" "frontend_test" {
  metadata {
    name = "frontend-test"
    labels = {
      "pod-security.kubernetes.io/audit"         = "baseline"
      "pod-security.kubernetes.io/audit-version" = "latest"
      "pod-security.kubernetes.io/warn"          = "baseline"
    }
  }
}

resource "aws_eks_access_entry" "github_ci" {
  cluster_name      = aws_eks_cluster.main.name
  principal_arn     = aws_iam_role.github_ci.arn
  kubernetes_groups = ["ci-frontend-test"]
  type              = "STANDARD"
}

resource "kubernetes_role_binding" "ci_frontend_test_edit" {
  metadata {
    name      = "ci-frontend-test-edit"
    namespace = kubernetes_namespace.frontend_test.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.dev_edit.metadata[0].name
  }

  subject {
    kind      = "Group"
    name      = "ci-frontend-test"
    api_group = "rbac.authorization.k8s.io"
  }
}

resource "aws_eks_access_entry" "keycloak_ec2" {
  cluster_name      = aws_eks_cluster.main.name
  principal_arn     = aws_iam_role.keycloak_ec2.arn
  kubernetes_groups = ["ci-frontend-test"]
  type              = "STANDARD"
}

data "aws_iam_policy_document" "keycloak_ec2_eks_describe" {
  statement {
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = [aws_eks_cluster.main.arn]
  }
}

resource "aws_iam_role_policy" "keycloak_ec2_eks_describe" {
  name   = "keycloak-ec2-eks-describe-frontend-test-cicd"
  role   = aws_iam_role.keycloak_ec2.id
  policy = data.aws_iam_policy_document.keycloak_ec2_eks_describe.json
}

output "frontend_test_ecr_repository_url" {
  value = aws_ecr_repository.frontend_test.repository_url
}
