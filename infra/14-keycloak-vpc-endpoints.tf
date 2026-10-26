
resource "aws_ecr_repository" "keycloak_mirror" {
  name                 = "${local.name_prefix}-keycloak-mirror"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "${local.name_prefix}-keycloak-mirror"
  }
}

resource "aws_ecr_lifecycle_policy" "keycloak_mirror" {
  repository = aws_ecr_repository.keycloak_mirror.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "최신 5개만 유지"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}

data "aws_iam_policy_document" "keycloak_ecr_pull" {
  statement {
    effect    = "Allow"
    actions   = ["ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage", "ecr:BatchCheckLayerAvailability"]
    resources = [aws_ecr_repository.keycloak_mirror.arn]
  }
  statement {
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "keycloak_ecr_pull" {
  name   = "keycloak-ecr-pull"
  role   = aws_iam_role.keycloak_ec2.id
  policy = data.aws_iam_policy_document.keycloak_ecr_pull.json
}

output "keycloak_ecr_repository_url" {
  description = "scripts/mirror-keycloak-image-to-ecr.sh로 이미지를 여기에 먼저 올려야 Keycloak EC2가 부팅됨"
  value       = aws_ecr_repository.keycloak_mirror.repository_url
}

resource "aws_security_group" "keycloak_vpc_endpoints" {
  name        = "${local.name_prefix}-keycloak-vpce-sg"
  description = "Keycloak VPC endpoints - 443 inbound from private subnet only"
  vpc_id      = aws_vpc.keycloak.id
}

resource "aws_vpc_security_group_ingress_rule" "keycloak_vpce_from_private" {
  security_group_id = aws_security_group.keycloak_vpc_endpoints.id
  cidr_ipv4         = var.keycloak_vpc_private_subnet_cidr
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "keycloak_vpce_out" {
  security_group_id = aws_security_group.keycloak_vpc_endpoints.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

locals {
  keycloak_interface_endpoints = toset([
    "ecr.api", "ecr.dkr", "ssm", "ssmmessages", "ec2messages",

    "logs",

    "execute-api",
  ])
}

resource "aws_vpc_endpoint" "keycloak_interface" {
  for_each            = local.keycloak_interface_endpoints
  vpc_id              = aws_vpc.keycloak.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.keycloak_private.id]
  security_group_ids  = [aws_security_group.keycloak_vpc_endpoints.id]
  private_dns_enabled = true

  tags = {
    Name = "${local.name_prefix}-keycloak-vpce-${each.value}"
  }
}

resource "aws_vpc_endpoint" "keycloak_s3" {
  vpc_id            = aws_vpc.keycloak.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.keycloak_private.id]
}
