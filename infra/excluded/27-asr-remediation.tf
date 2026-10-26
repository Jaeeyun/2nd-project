
variable "enable_asr_remediation" {
  description = "Automated Security Response on AWS(27-asr-remediation.tf) 활성화 여부. 이 템플릿의 Web UI 구성요소가 계정의 Lambda 동시실행 할당량을 초과 요구할 수 있어(신규/제한된 계정에서 흔함), 할당량 증가가 확인되기 전까지는 false로 두고 나머지 인프라부터 배포하는 용도."
  type        = bool
  default     = false
}

resource "aws_cloudformation_stack" "asr" {
  count        = var.enable_asr_remediation ? 1 : 0
  name         = "${local.name_prefix}-asr"
  template_url = var.asr_template_url
  capabilities = ["CAPABILITY_IAM", "CAPABILITY_NAMED_IAM", "CAPABILITY_AUTO_EXPAND"]

  parameters = {
    ShouldDeployWebUI = "no"
  }

  tags = {
    Name = "${local.name_prefix}-asr"
  }
}

resource "null_resource" "asr_termination_protection" {
  count = var.enable_asr_remediation ? 1 : 0

  triggers = {
    stack_name = aws_cloudformation_stack.asr[0].name
    region     = var.aws_region
  }

  provisioner "local-exec" {
    command = "aws cloudformation update-termination-protection --enable-termination-protection --stack-name ${self.triggers.stack_name} --region ${self.triggers.region}"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "aws cloudformation update-termination-protection --no-enable-termination-protection --stack-name ${self.triggers.stack_name} --region ${self.triggers.region} || true"
  }
}

variable "asr_template_url" {
  description = "Automated Security Response on AWS admin 템플릿의 S3 URL"
  type        = string
  default     = "https://s3.amazonaws.com/solutions-reference/automated-security-response-on-aws/latest/automated-security-response-admin.template"
}

output "asr_stack_id" {
  value = var.enable_asr_remediation ? aws_cloudformation_stack.asr[0].id : "disabled (enable_asr_remediation=false)"
}
