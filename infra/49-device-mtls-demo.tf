
resource "tls_private_key" "device_ca" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_self_signed_cert" "device_ca" {
  private_key_pem = tls_private_key.device_ca.private_key_pem

  subject {
    common_name  = "${local.name_prefix}-device-ca"
    organization = "ZTNA PoC Device CA"
  }

  validity_period_hours = 24 * 30
  is_ca_certificate     = true

  allowed_uses = [
    "cert_signing",
    "crl_signing",
    "digital_signature",
    "key_encipherment",
  ]
}

resource "tls_private_key" "demo_device" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "demo_device" {
  private_key_pem = tls_private_key.demo_device.private_key_pem

  subject {
    common_name = "device-uuid-demo-0001"
  }
}

resource "tls_locally_signed_cert" "demo_device" {
  cert_request_pem   = tls_cert_request.demo_device.cert_request_pem
  ca_private_key_pem = tls_private_key.device_ca.private_key_pem
  ca_cert_pem        = tls_self_signed_cert.device_ca.cert_pem

  validity_period_hours = 24 * 30

  allowed_uses = [
    "digital_signature",
    "key_encipherment",
    "client_auth",
  ]
}

resource "aws_s3_bucket" "device_mtls_trust_store" {
  bucket        = "${local.name_prefix}-device-mtls-trust-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "device_mtls_trust_store" {
  bucket                  = aws_s3_bucket.device_mtls_trust_store.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "device_ca_bundle" {
  bucket  = aws_s3_bucket.device_mtls_trust_store.id
  key     = "device-ca-bundle.pem"
  content = tls_self_signed_cert.device_ca.cert_pem
}

resource "aws_lb_trust_store" "device_ca" {
  name                             = trimsuffix(substr("${local.name_prefix}-device-ca-trust", 0, 32), "-")
  ca_certificates_bundle_s3_bucket = aws_s3_bucket.device_mtls_trust_store.id
  ca_certificates_bundle_s3_key    = aws_s3_object.device_ca_bundle.key
}

resource "aws_vpc_security_group_ingress_rule" "internal_mtls_alb_device_demo" {
  security_group_id = aws_security_group.internal_mtls_alb.id
  cidr_ipv4         = var.keycloak_admin_cidr[0]
  from_port         = 8443
  to_port           = 8443
  ip_protocol       = "tcp"
}

resource "aws_lb_listener" "device_mtls_demo" {
  load_balancer_arn = aws_lb.internal_mtls.arn
  port              = 8443
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

output "device_mtls_demo_port" {
  value = "https://${aws_lb.internal_mtls.dns_name}:8443 (디바이스 인증서 필요)"
}

output "demo_device_cert_pem" {
  value = tls_locally_signed_cert.demo_device.cert_pem
}

output "demo_device_key_pem" {
  value     = tls_private_key.demo_device.private_key_pem
  sensitive = true
}
