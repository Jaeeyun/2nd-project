
resource "aws_securityhub_action_target" "isolate_eks_pod" {

  name        = "Isolate EKS Pod"
  identifier  = "IsolateEksPod"
  description = "Isolate the selected finding's pod (quarantine label + deny-all NetworkPolicy)"

  depends_on = [aws_securityhub_account.main]
}

data "archive_file" "eks_pod_isolate" {
  type        = "zip"
  source_file = "${path.module}/scripts/eks-pod-isolate.py"
  output_path = "${path.module}/.build/eks-pod-isolate.zip"
}

resource "aws_iam_role" "eks_pod_isolate" {
  name = "${local.name_prefix}-eks-pod-isolate-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_pod_isolate_basic_logs" {
  role       = aws_iam_role.eks_pod_isolate.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "eks_pod_isolate_permissions" {
  statement {
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = [aws_eks_cluster.main.arn]
  }
  statement {
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.security_alerts.arn]
  }
}

resource "aws_iam_role_policy" "eks_pod_isolate_permissions" {
  name   = "eks-pod-isolate-permissions"
  role   = aws_iam_role.eks_pod_isolate.id
  policy = data.aws_iam_policy_document.eks_pod_isolate_permissions.json
}

resource "aws_iam_role_policy_attachment" "eks_pod_isolate_vpc" {
  role       = aws_iam_role.eks_pod_isolate.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_security_group" "eks_pod_isolate_lambda" {
  name        = "${local.name_prefix}-eks-pod-isolate-lambda-sg"
  description = "eks-pod-isolate Lambda - outbound to EKS API(443) only"
  vpc_id      = aws_vpc.main.id
}

resource "aws_vpc_security_group_egress_rule" "eks_pod_isolate_lambda_to_eks" {
  security_group_id            = aws_security_group.eks_pod_isolate_lambda.id
  referenced_security_group_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "eks_pod_isolate_lambda_to_internet" {
  security_group_id = aws_security_group.eks_pod_isolate_lambda.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "AWS API calls (eks:DescribeCluster) via NAT gateway"
}

resource "aws_vpc_security_group_ingress_rule" "eks_cluster_sg_from_pod_isolate_lambda" {
  security_group_id            = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  referenced_security_group_id = aws_security_group.eks_pod_isolate_lambda.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "aws_lambda_function" "eks_pod_isolate" {
  function_name    = "${local.name_prefix}-eks-pod-isolate"
  role             = aws_iam_role.eks_pod_isolate.arn
  handler          = "eks-pod-isolate.handler"
  runtime          = "python3.12"
  timeout          = 60
  filename         = data.archive_file.eks_pod_isolate.output_path
  source_code_hash = data.archive_file.eks_pod_isolate.output_base64sha256

  vpc_config {
    subnet_ids         = aws_subnet.private_app[*].id
    security_group_ids = [aws_security_group.eks_pod_isolate_lambda.id]
  }

  environment {
    variables = {
      CLUSTER_NAME  = aws_eks_cluster.main.name
      SNS_TOPIC_ARN = aws_sns_topic.security_alerts.arn
    }
  }
}

resource "aws_eks_access_entry" "pod_isolate_lambda" {
  cluster_name      = aws_eks_cluster.main.name
  principal_arn     = aws_iam_role.eks_pod_isolate.arn
  type              = "STANDARD"
  kubernetes_groups = ["pod-isolator"]
}

resource "kubernetes_cluster_role" "pod_isolator" {
  metadata {
    name = "pod-isolator"
  }

  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "patch"]
  }

  rule {
    api_groups = ["networking.k8s.io"]
    resources  = ["networkpolicies"]
    verbs      = ["get", "create", "patch"]
  }
}

resource "kubernetes_cluster_role_binding" "pod_isolator" {
  metadata {
    name = "pod-isolator-binding"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.pod_isolator.metadata[0].name
  }

  subject {
    kind      = "Group"
    name      = "pod-isolator"
    api_group = "rbac.authorization.k8s.io"
  }

  depends_on = [aws_eks_access_entry.pod_isolate_lambda]
}

resource "aws_cloudwatch_event_rule" "isolate_eks_pod_action" {
  name = "${local.name_prefix}-isolate-eks-pod-action"

  event_pattern = jsonencode({
    source      = ["aws.securityhub"]
    detail-type = ["Security Hub Findings - Custom Action"]
    resources   = [aws_securityhub_action_target.isolate_eks_pod.arn]
  })
}

resource "aws_cloudwatch_event_target" "isolate_eks_pod_lambda" {
  rule = aws_cloudwatch_event_rule.isolate_eks_pod_action.name
  arn  = aws_lambda_function.eks_pod_isolate.arn
}

resource "aws_lambda_permission" "allow_eventbridge_isolate" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.eks_pod_isolate.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.isolate_eks_pod_action.arn
}
