
resource "tls_private_key" "alb_server" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "alb_server" {
  private_key_pem = tls_private_key.alb_server.private_key_pem

  subject {
    common_name = aws_lb.internal_mtls.dns_name
  }

  dns_names = [aws_lb.internal_mtls.dns_name]

  validity_period_hours = 24 * 30

  allowed_uses = [
    "digital_signature",
    "key_encipherment",
    "server_auth",
  ]
}

resource "aws_acm_certificate" "alb_server" {
  private_key      = tls_private_key.alb_server.private_key_pem
  certificate_body = tls_self_signed_cert.alb_server.cert_pem
}

resource "aws_security_group" "internal_mtls_alb" {
  name        = "${local.name_prefix}-internal-mtls-alb-sg"
  description = "Allow inbound 443 from the internet (edge ALB in front of Istio ingressgateway)"
  vpc_id      = aws_vpc.main.id
}

resource "aws_vpc_security_group_ingress_rule" "internal_mtls_alb_from_pomerium_vpc" {
  security_group_id = aws_security_group.internal_mtls_alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "internal_mtls_alb_out" {
  security_group_id = aws_security_group.internal_mtls_alb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_lb" "internal_mtls" {

  name               = trimsuffix(substr("${local.name_prefix}-internal-mtls-alb", 0, 32), "-")
  internal           = false
  load_balancer_type = "application"
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.internal_mtls_alb.id]

  drop_invalid_header_fields = true
}

resource "aws_vpc_security_group_ingress_rule" "eks_cluster_sg_from_internal_alb" {
  security_group_id            = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  referenced_security_group_id = aws_security_group.internal_mtls_alb.id
  from_port                    = 8080
  to_port                      = 15021
  ip_protocol                  = "tcp"
}

resource "aws_lb_listener" "internal_mtls_https" {
  load_balancer_arn = aws_lb.internal_mtls.arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = aws_acm_certificate.alb_server.arn
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"

  mutual_authentication {
    mode            = "verify"
    trust_store_arn = aws_lb_trust_store.device_ca.arn
  }

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.istio_ingressgateway.arn
  }
}

output "internal_mtls_alb_dns_name" {
  value = aws_lb.internal_mtls.dns_name
}

resource "aws_lb_target_group" "istio_ingressgateway" {
  name        = trimsuffix(substr("${local.name_prefix}-istio-gw-tg", 0, 32), "-")
  port        = 8080
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.main.id

  health_check {
    port    = "15021"
    path    = "/healthz/ready"
    matcher = "200"
  }
}
