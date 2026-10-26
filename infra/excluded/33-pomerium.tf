
resource "aws_security_group" "pomerium" {
  name        = "${local.name_prefix}-pomerium-sg"
  description = "Pomerium EC2 - HTTPS only from admin CIDR, no SSH"
  vpc_id      = aws_vpc.keycloak.id
}

resource "aws_vpc_security_group_ingress_rule" "pomerium_https_from_admin" {
  count             = length(var.keycloak_admin_cidr)
  security_group_id = aws_security_group.pomerium.id
  cidr_ipv4         = var.keycloak_admin_cidr[count.index]
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "pomerium_https_from_main_vpc" {
  security_group_id = aws_security_group.pomerium.id
  cidr_ipv4         = var.vpc_cidr
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "pomerium_out" {
  security_group_id = aws_security_group.pomerium.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "keycloak_https_from_pomerium" {
  security_group_id            = aws_security_group.keycloak.id
  referenced_security_group_id = aws_security_group.pomerium.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "aws_iam_role" "pomerium_ec2" {
  name = "${local.name_prefix}-pomerium-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "pomerium_ssm_core" {
  role       = aws_iam_role.pomerium_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "pomerium_read_keycloak_admin_password" {
  statement {
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:*:*:parameter/keycloak/${local.name_prefix}/*"]
  }
}

resource "aws_iam_role_policy" "pomerium_read_keycloak_admin_password" {
  name   = "pomerium-read-keycloak-admin-password"
  role   = aws_iam_role.pomerium_ec2.id
  policy = data.aws_iam_policy_document.pomerium_read_keycloak_admin_password.json
}

resource "aws_iam_instance_profile" "pomerium" {
  name = "${local.name_prefix}-pomerium-ec2-profile"
  role = aws_iam_role.pomerium_ec2.name
}

resource "aws_instance" "pomerium" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.keycloak_instance_type
  subnet_id              = aws_subnet.keycloak_public.id
  vpc_security_group_ids = [aws_security_group.pomerium.id]
  iam_instance_profile   = aws_iam_instance_profile.pomerium.name

  user_data_replace_on_change = true

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  user_data = templatefile("${path.module}/pomerium-bootstrap.sh.tpl", {
    region      = var.aws_region
    name_prefix = local.name_prefix

    keycloak_endpoint = aws_lb.keycloak.dns_name

    keycloak_private_ip = aws_instance.keycloak.private_ip
    realm_name          = var.keycloak_realm_name
    alb_dns_name        = aws_lb.internal_mtls.dns_name
    ca_cert_pem         = tls_self_signed_cert.mtls_ca.cert_pem
    client_cert_pem     = tls_locally_signed_cert.pomerium_client.cert_pem
    client_key_pem      = tls_private_key.pomerium_client.private_key_pem
  })

  tags = {
    Name = "${local.name_prefix}-pomerium-poc"
  }

  depends_on = [

    null_resource.wait_for_keycloak,
    aws_lb_listener.internal_mtls_https,
  ]
}

output "pomerium_public_ip" {
  value = aws_instance.pomerium.public_ip
}

output "pomerium_login_url" {
  description = "브라우저로 열면 Pomerium이 Keycloak 로그인으로 리다이렉트 후, 통과하면 내부 ALB(echo 백엔드)로 프록시"
  value       = "https://${aws_instance.pomerium.public_ip}/"
}
