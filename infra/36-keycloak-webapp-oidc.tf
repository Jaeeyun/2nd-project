
resource "random_password" "webapp_oidc_client_secret" {
  length  = 32
  special = false
}

resource "aws_vpc_security_group_ingress_rule" "keycloak_alb_https_from_eks_nat" {
  security_group_id = aws_security_group.keycloak_alb.id
  cidr_ipv4         = "${aws_eip.nat[0].public_ip}/32"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "oauth2-proxy(EKS) backend OIDC calls via NAT Gateway"
}

resource "null_resource" "keycloak_webapp_oidc_bootstrap" {
  depends_on = [null_resource.wait_for_keycloak]

  triggers = {
    keycloak_instance_id = aws_instance.keycloak.id
    client_secret        = random_password.webapp_oidc_client_secret.result
    script_hash          = filemd5("${path.module}/scripts/keycloak-webapp-oidc-bootstrap.sh")
  }

  provisioner "local-exec" {
    command = join(" ", [
      "${path.module}/scripts/tf-run-ssm-script.sh",
      aws_instance.keycloak.id,
      var.aws_region,
      "${path.module}/scripts/keycloak-webapp-oidc-bootstrap.sh",
      "REALM=${var.keycloak_realm_name}",
      "CLIENT_SECRET=${random_password.webapp_oidc_client_secret.result}",
      "TEST_USERS_PASSWORD=${var.keycloak_test_users_password}",
    ])
  }
}

output "webapp_oidc_issuer_url" {
  description = "oauth2-proxy --oidc-issuer-url에 쓸 값"
  value       = "https://${aws_lb.keycloak.dns_name}/realms/${var.keycloak_realm_name}"
}
