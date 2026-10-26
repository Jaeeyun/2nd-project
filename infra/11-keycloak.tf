
locals {
  saml_provider_name = "${local.name_prefix}-keycloak"
  saml_provider_arn  = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:saml-provider/${local.saml_provider_name}"

  keycloak_role_names = {
    dev-general      = "${local.name_prefix}-dev-general"
    dev-lead         = "${local.name_prefix}-dev-lead"
    dev-hr-backend   = "${local.name_prefix}-dev-hr-backend"
    db-general       = "${local.name_prefix}-db-general"
    db-lead          = "${local.name_prefix}-db-lead"
    ops-general      = "${local.name_prefix}-ops-general"
    ops-lead         = "${local.name_prefix}-ops-lead"
    security-auditor = "${local.name_prefix}-security-auditor"
  }
  keycloak_role_arns = {
    for k, name in local.keycloak_role_names :
    k => "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${name}"
  }
}

resource "aws_security_group" "keycloak" {
  name        = "${local.name_prefix}-keycloak-sg"
  description = "Keycloak EC2 - HTTPS only from its own ALB, no SSH (ADR-002)"
  vpc_id      = aws_vpc.keycloak.id

  tags = {
    Name = "${local.name_prefix}-keycloak-sg"
    Role = "keycloak"
  }
}

resource "aws_vpc_security_group_ingress_rule" "keycloak_https_from_alb" {
  security_group_id            = aws_security_group.keycloak.id
  referenced_security_group_id = aws_security_group.keycloak_alb.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  description                  = "HTTPS from Keycloak ALB only"
}

resource "aws_vpc_security_group_ingress_rule" "keycloak_https_from_main_vpc" {
  security_group_id = aws_security_group.keycloak.id
  cidr_ipv4         = var.vpc_cidr
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "HTTPS from demo VPC via peering (session-revoke Lambda admin API calls)"
}

resource "aws_vpc_security_group_egress_rule" "keycloak_https_out" {
  security_group_id            = aws_security_group.keycloak.id
  referenced_security_group_id = aws_security_group.keycloak_vpc_endpoints.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  description                  = "HTTPS to Interface VPC endpoints only (ECR API/DKR, SSM)"
}

data "aws_prefix_list" "s3" {
  name = "com.amazonaws.${var.aws_region}.s3"
}

resource "aws_vpc_security_group_egress_rule" "keycloak_https_to_s3" {
  security_group_id = aws_security_group.keycloak.id
  prefix_list_id    = data.aws_prefix_list.s3.id
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "HTTPS to S3 Gateway endpoint (ECR image layers)"
}

resource "aws_security_group" "keycloak_alb" {
  name        = "${local.name_prefix}-keycloak-alb-sg"
  description = "Keycloak ALB - HTTPS only from admin CIDR"
  vpc_id      = aws_vpc.keycloak.id

  tags = {
    Name = "${local.name_prefix}-keycloak-alb-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "keycloak_alb_https_from_admin" {
  count             = length(var.keycloak_admin_cidr)
  security_group_id = aws_security_group.keycloak_alb.id
  cidr_ipv4         = var.keycloak_admin_cidr[count.index]
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "HTTPS from admin CIDR only"
}

resource "aws_vpc_security_group_ingress_rule" "keycloak_alb_device_mtls_from_admin" {
  count             = length(var.keycloak_admin_cidr)
  security_group_id = aws_security_group.keycloak_alb.id
  cidr_ipv4         = var.keycloak_admin_cidr[count.index]
  from_port         = 8443
  to_port           = 8443
  ip_protocol       = "tcp"
  description       = "Device-cert mTLS SAML login from admin CIDR only"
}

resource "aws_vpc_security_group_egress_rule" "keycloak_alb_to_instance" {
  security_group_id            = aws_security_group.keycloak_alb.id
  referenced_security_group_id = aws_security_group.keycloak.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "tls_private_key" "keycloak_alb_ca" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_self_signed_cert" "keycloak_alb_ca" {
  private_key_pem = tls_private_key.keycloak_alb_ca.private_key_pem

  subject {
    common_name  = "${local.name_prefix}-keycloak-alb-ca"
    organization = "PoC Internal CA"
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

resource "tls_private_key" "keycloak_alb_server" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "keycloak_alb_server" {
  private_key_pem = tls_private_key.keycloak_alb_server.private_key_pem

  subject {
    common_name = aws_lb.keycloak.dns_name
  }

  dns_names = [aws_lb.keycloak.dns_name]
}

resource "tls_locally_signed_cert" "keycloak_alb_server" {
  cert_request_pem   = tls_cert_request.keycloak_alb_server.cert_request_pem
  ca_private_key_pem = tls_private_key.keycloak_alb_ca.private_key_pem
  ca_cert_pem        = tls_self_signed_cert.keycloak_alb_ca.cert_pem

  validity_period_hours = 24 * 30

  allowed_uses = [
    "digital_signature",
    "key_encipherment",
    "server_auth",
  ]
}

resource "aws_acm_certificate" "keycloak_alb" {
  private_key       = tls_private_key.keycloak_alb_server.private_key_pem
  certificate_body  = tls_locally_signed_cert.keycloak_alb_server.cert_pem
  certificate_chain = tls_self_signed_cert.keycloak_alb_ca.cert_pem
}

resource "aws_lb" "keycloak" {
  name               = trimsuffix(substr("${local.name_prefix}-keycloak-alb", 0, 32), "-")
  internal           = false
  load_balancer_type = "application"

  subnets         = [aws_subnet.keycloak_public.id, aws_subnet.keycloak_public_b.id]
  security_groups = [aws_security_group.keycloak_alb.id]

  drop_invalid_header_fields = true
}

resource "aws_lb_target_group" "keycloak" {
  name        = trimsuffix(substr("${local.name_prefix}-keycloak-tg", 0, 32), "-")
  port        = 443
  protocol    = "HTTPS"
  target_type = "instance"
  vpc_id      = aws_vpc.keycloak.id

  health_check {
    protocol = "HTTPS"
    path     = "/realms/master"
    matcher  = "200"
  }
}

resource "aws_lb_target_group_attachment" "keycloak" {
  target_group_arn = aws_lb_target_group.keycloak.arn
  target_id        = aws_instance.keycloak.id
  port             = 443
}

resource "aws_lb_listener" "keycloak_https" {
  load_balancer_arn = aws_lb.keycloak.arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = aws_acm_certificate.keycloak_alb.arn
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.keycloak.arn
  }
}

resource "aws_lb_listener" "keycloak_device_mtls" {
  load_balancer_arn = aws_lb.keycloak.arn
  port              = 8443
  protocol          = "HTTPS"
  certificate_arn   = aws_acm_certificate.keycloak_alb.arn
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"

  mutual_authentication {
    mode            = "verify"
    trust_store_arn = aws_lb_trust_store.device_ca.arn
  }

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.keycloak.arn
  }
}

output "keycloak_alb_dns_name" {
  description = "Keycloak 로그인 화면/SAML descriptor의 새 진입점 (예전 keycloak_public_ip를 대체)"
  value       = aws_lb.keycloak.dns_name
}

data "aws_iam_policy_document" "ec2_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "keycloak_ec2" {
  name               = "${local.name_prefix}-keycloak-ec2-role"
  description        = "ADR-011: Keycloak EC2 dedicated Instance Profile, SSM management only"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

resource "aws_iam_role_policy_attachment" "keycloak_ssm_core" {
  role       = aws_iam_role.keycloak_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "keycloak_admin_password_ssm" {
  statement {
    effect    = "Allow"
    actions   = ["ssm:PutParameter", "ssm:GetParameter"]
    resources = ["arn:aws:ssm:*:*:parameter/keycloak/${local.name_prefix}/*"]
  }
}

resource "aws_iam_role_policy" "keycloak_admin_password_ssm" {
  name   = "keycloak-admin-password-ssm"
  role   = aws_iam_role.keycloak_ec2.id
  policy = data.aws_iam_policy_document.keycloak_admin_password_ssm.json
}

resource "aws_iam_instance_profile" "keycloak" {
  name = "${local.name_prefix}-keycloak-ec2-profile"
  role = aws_iam_role.keycloak_ec2.name
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "aws_instance" "keycloak" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.keycloak_instance_type
  subnet_id                   = aws_subnet.keycloak_private.id
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.keycloak.id]
  iam_instance_profile        = aws_iam_instance_profile.keycloak.name

  user_data_replace_on_change = true

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
  }

  user_data = templatefile("${path.module}/keycloak-bootstrap.sh.tpl", {
    region      = var.aws_region
    name_prefix = local.name_prefix

    ecr_repository_url = aws_ecr_repository.keycloak_mirror.repository_url
    alb_dns_name       = aws_lb.keycloak.dns_name

    opa_artifacts_bucket   = aws_s3_bucket.opa_artifacts.bucket
    opa_decision_log_group = aws_cloudwatch_log_group.opa_decision_logs.name

    device_posture_lookup_url     = "${aws_api_gateway_stage.device_posture_lookup.invoke_url}/posture"
    device_posture_lookup_api_key = random_password.device_posture_lookup_api_key.result
    operator_allowed_cidrs        = join(",", var.operator_allowed_cidrs)
  })

  tags = {
    Name = "${local.name_prefix}-keycloak-poc"
    Role = "keycloak"
  }

  depends_on = [
    aws_iam_role_policy_attachment.keycloak_ssm_core,
    aws_iam_role_policy.keycloak_admin_password_ssm,
    aws_iam_role_policy.keycloak_ecr_pull,
    aws_vpc_endpoint.keycloak_interface,
    aws_vpc_endpoint.keycloak_s3,

    aws_iam_role_policy.keycloak_opa_artifacts_read,
    aws_s3_object.opa_login_context_policy,
    aws_s3_object.opa_decision_log_shipper,
  ]
}

resource "null_resource" "keycloak_realm_bootstrap" {
  depends_on = [
    aws_instance.keycloak,
    aws_lb_listener.keycloak_https,
    aws_lb_target_group_attachment.keycloak,
  ]

  triggers = {
    instance_id = aws_instance.keycloak.id
    script_hash = filemd5("${path.module}/scripts/keycloak-realm-bootstrap.sh")
  }

  provisioner "local-exec" {
    command = join(" ", [
      "${path.module}/scripts/tf-run-ssm-script.sh",
      aws_instance.keycloak.id,
      var.aws_region,
      "${path.module}/scripts/keycloak-realm-bootstrap.sh",
      "REGION=${var.aws_region}",
      "NAME_PREFIX=${local.name_prefix}",
      "REALM_NAME=${var.keycloak_realm_name}",
      "DEV_GENERAL_ROLE_ARN=${local.keycloak_role_arns["dev-general"]}",
      "DEV_LEAD_ROLE_ARN=${local.keycloak_role_arns["dev-lead"]}",
      "DEV_HR_BACKEND_ROLE_ARN=${local.keycloak_role_arns["dev-hr-backend"]}",
      "DB_GENERAL_ROLE_ARN=${local.keycloak_role_arns["db-general"]}",
      "DB_LEAD_ROLE_ARN=${local.keycloak_role_arns["db-lead"]}",
      "OPS_GENERAL_ROLE_ARN=${local.keycloak_role_arns["ops-general"]}",
      "OPS_LEAD_ROLE_ARN=${local.keycloak_role_arns["ops-lead"]}",
      "SECURITY_AUDITOR_ROLE_ARN=${local.keycloak_role_arns["security-auditor"]}",
      "SAML_PROVIDER_ARN=${local.saml_provider_arn}",
      "TEST_USER_PASSWORD=${var.keycloak_test_users_password}",
    ])
  }
}

resource "null_resource" "wait_for_keycloak" {
  depends_on = [
    aws_instance.keycloak,
    aws_lb_listener.keycloak_https,
    aws_lb_target_group_attachment.keycloak,
    null_resource.keycloak_realm_bootstrap,
  ]

  triggers = {
    instance_id = aws_instance.keycloak.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      echo "Keycloak SAML descriptor 준비 대기 중 (최대 ~15분)..."
      for i in $(seq 1 90); do
        STATUS=$(curl -sk -o /dev/null -w "%%{http_code}" "https://${aws_lb.keycloak.dns_name}/realms/${var.keycloak_realm_name}/protocol/saml/descriptor" || echo "000")
        if [ "$STATUS" = "200" ]; then
          echo "Keycloak 준비 완료 (descriptor 200 OK)"
          exit 0
        fi
        echo "  아직 준비 안 됨 (status=$STATUS), 10초 후 재시도... ($i/90)"
        sleep 10
      done
      echo "타임아웃: Keycloak이 15분 내에 준비되지 않았습니다. var.keycloak_admin_cidr에 이 머신의 공인 IP가 포함되어 있는지, ALB 타겟그룹이 healthy인지, SSM으로 접속해 user_data 로그(/var/log/cloud-init-output.log)를 확인하세요." >&2
      exit 1
    EOT
  }
}

data "http" "keycloak_saml_metadata" {
  url      = "https://${aws_lb.keycloak.dns_name}/realms/${var.keycloak_realm_name}/protocol/saml/descriptor"
  insecure = true

  depends_on = [null_resource.wait_for_keycloak]
}

resource "aws_iam_saml_provider" "keycloak" {
  name                   = local.saml_provider_name
  saml_metadata_document = data.http.keycloak_saml_metadata.response_body
}

output "keycloak_idp_initiated_sso_login_url" {
  description = "ADR-001 결정 2번: 이 링크를 클릭하면 별도 백엔드 없이 AWS Console로 바로 진입"
  value       = "https://${aws_lb.keycloak.dns_name}/realms/${var.keycloak_realm_name}/protocol/saml/clients/aws"
}

output "keycloak_admin_password_ssm_parameter" {
  description = "Keycloak admin 비밀번호가 저장된 SSM Parameter 이름"
  value       = "/keycloak/${local.name_prefix}/admin-password"
}

output "keycloak_saml_provider_arn" {
  description = "AWS IAM에 등록된 Keycloak SAML Provider ARN"
  value       = aws_iam_saml_provider.keycloak.arn
}
