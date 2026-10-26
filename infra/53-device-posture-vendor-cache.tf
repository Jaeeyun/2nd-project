
resource "random_password" "device_posture_redis_auth" {
  length  = 32
  special = false
}

resource "aws_security_group" "device_posture_redis" {
  name        = "${local.name_prefix}-device-posture-redis-sg"
  description = "ElastiCache Redis for device posture cache - only sync/lookup lambdas may connect"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-device-posture-redis-sg"
  }
}

resource "aws_security_group" "device_posture_lambda" {
  name        = "${local.name_prefix}-device-posture-lambda-sg"
  description = "device-posture-sync/-lookup lambdas (VPC-attached to reach Redis)"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-device-posture-lambda-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "device_posture_redis_from_lambda" {
  security_group_id            = aws_security_group.device_posture_redis.id
  referenced_security_group_id = aws_security_group.device_posture_lambda.id
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
  description                  = "Only sync/lookup lambdas may reach Redis"
}

resource "aws_elasticache_subnet_group" "device_posture" {
  name       = "${local.name_prefix}-device-posture-redis"
  subnet_ids = aws_subnet.private_app[*].id
}

resource "aws_elasticache_replication_group" "device_posture" {
  replication_group_id = "${local.name_prefix}-device-posture"
  description          = "Device posture cache synced from vendor API"
  engine               = "redis"
  engine_version       = "7.1"
  node_type            = "cache.t3.micro"
  num_cache_clusters   = 1
  port                 = 6379

  subnet_group_name  = aws_elasticache_subnet_group.device_posture.name
  security_group_ids = [aws_security_group.device_posture_redis.id]

  transit_encryption_enabled = true
  auth_token                 = random_password.device_posture_redis_auth.result
  at_rest_encryption_enabled = true
}

resource "null_resource" "device_posture_sync_build" {
  triggers = {
    handler_hash = filesha1("${path.module}/lambda/device-posture-sync/handler.py")
    script_hash  = filesha1("${path.module}/scripts/build-lambda-with-deps.sh")
  }
  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/build-lambda-with-deps.sh ${path.module}/lambda/device-posture-sync ${path.module}/lambda/device-posture-sync-build"
  }
}

resource "null_resource" "device_posture_lookup_build" {
  triggers = {
    handler_hash = filesha1("${path.module}/lambda/device-posture-lookup/handler.py")
    script_hash  = filesha1("${path.module}/scripts/build-lambda-with-deps.sh")
  }
  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/build-lambda-with-deps.sh ${path.module}/lambda/device-posture-lookup ${path.module}/lambda/device-posture-lookup-build"
  }
}

data "archive_file" "device_posture_mock_vendor" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/device-posture-mock-vendor"
  output_path = "${path.module}/lambda/device-posture-mock-vendor.zip"
}

data "archive_file" "device_posture_sync" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/device-posture-sync-build"
  output_path = "${path.module}/lambda/device-posture-sync.zip"
  depends_on  = [null_resource.device_posture_sync_build]
}

data "archive_file" "device_posture_lookup" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/device-posture-lookup-build"
  output_path = "${path.module}/lambda/device-posture-lookup.zip"
  depends_on  = [null_resource.device_posture_lookup_build]
}

resource "aws_iam_role" "device_posture_lambda" {
  name = "${local.name_prefix}-device-posture-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "device_posture_lambda_basic" {
  role       = aws_iam_role.device_posture_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "device_posture_lambda_vpc" {
  role       = aws_iam_role.device_posture_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_lambda_function" "device_posture_mock_vendor" {
  function_name    = "${local.name_prefix}-device-posture-mock-vendor"
  role             = aws_iam_role.device_posture_lambda.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 10
  filename         = data.archive_file.device_posture_mock_vendor.output_path
  source_code_hash = data.archive_file.device_posture_mock_vendor.output_base64sha256
}

data "aws_iam_policy_document" "device_posture_invoke_mock_vendor" {
  statement {
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.device_posture_mock_vendor.arn]
  }
}

resource "aws_iam_role_policy" "device_posture_invoke_mock_vendor" {
  name   = "invoke-mock-vendor"
  role   = aws_iam_role.device_posture_lambda.id
  policy = data.aws_iam_policy_document.device_posture_invoke_mock_vendor.json
}

resource "aws_lambda_function" "device_posture_sync" {
  function_name    = "${local.name_prefix}-device-posture-sync"
  role             = aws_iam_role.device_posture_lambda.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 30
  filename         = data.archive_file.device_posture_sync.output_path
  source_code_hash = data.archive_file.device_posture_sync.output_base64sha256

  vpc_config {
    subnet_ids         = aws_subnet.private_app[*].id
    security_group_ids = [aws_security_group.device_posture_lambda.id]
  }

  environment {
    variables = {
      MOCK_VENDOR_FUNCTION_NAME = aws_lambda_function.device_posture_mock_vendor.function_name
      REDIS_HOST                = aws_elasticache_replication_group.device_posture.primary_endpoint_address
      REDIS_AUTH_TOKEN          = random_password.device_posture_redis_auth.result
    }
  }
}

resource "aws_cloudwatch_event_rule" "device_posture_sync" {
  name                = "${local.name_prefix}-device-posture-sync"
  description         = "Poll vendor device-posture API and refresh the Redis cache"
  schedule_expression = "rate(5 minutes)"
}

resource "aws_cloudwatch_event_target" "device_posture_sync" {
  rule = aws_cloudwatch_event_rule.device_posture_sync.name
  arn  = aws_lambda_function.device_posture_sync.arn
}

resource "aws_lambda_permission" "device_posture_sync_from_events" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.device_posture_sync.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.device_posture_sync.arn
}

resource "random_password" "device_posture_lookup_api_key" {
  length  = 32
  special = false
}

resource "aws_lambda_function" "device_posture_lookup" {
  function_name    = "${local.name_prefix}-device-posture-lookup"
  role             = aws_iam_role.device_posture_lambda.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 10
  filename         = data.archive_file.device_posture_lookup.output_path
  source_code_hash = data.archive_file.device_posture_lookup.output_base64sha256

  vpc_config {
    subnet_ids         = aws_subnet.private_app[*].id
    security_group_ids = [aws_security_group.device_posture_lambda.id]
  }

  environment {
    variables = {
      REDIS_HOST       = aws_elasticache_replication_group.device_posture.primary_endpoint_address
      REDIS_AUTH_TOKEN = random_password.device_posture_redis_auth.result
      API_KEY          = random_password.device_posture_lookup_api_key.result
    }
  }
}

resource "aws_security_group" "device_posture_main_vpc_endpoint" {
  name        = "${local.name_prefix}-device-posture-main-vpce-sg"
  description = "execute-api VPC endpoint (main VPC) - 443 inbound from EKS cluster SG only"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-device-posture-main-vpce-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "device_posture_main_vpce_from_eks" {
  security_group_id            = aws_security_group.device_posture_main_vpc_endpoint.id
  referenced_security_group_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  description                  = "opa-envoy pod calling device-posture-lookup via PrivateLink"
}

resource "aws_vpc_endpoint" "main_execute_api" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.execute-api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private_app[*].id
  security_group_ids  = [aws_security_group.device_posture_main_vpc_endpoint.id]
  private_dns_enabled = true

  tags = {
    Name = "${local.name_prefix}-main-vpce-execute-api"
  }
}

resource "aws_api_gateway_rest_api" "device_posture_lookup" {
  name = "${local.name_prefix}-device-posture-lookup"

  endpoint_configuration {
    types = ["PRIVATE"]
    vpc_endpoint_ids = [
      aws_vpc_endpoint.keycloak_interface["execute-api"].id,
      aws_vpc_endpoint.main_execute_api.id,
    ]
    ip_address_type = "dualstack"
  }

  policy = data.aws_iam_policy_document.device_posture_lookup.json
}

data "aws_iam_policy_document" "device_posture_lookup" {
  statement {
    sid       = "AllowFromEitherVpcEndpoint"
    effect    = "Allow"
    actions   = ["execute-api:Invoke"]
    resources = ["execute-api:/*/*/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceVpce"
      values = [
        aws_vpc_endpoint.keycloak_interface["execute-api"].id,
        aws_vpc_endpoint.main_execute_api.id,
      ]
    }
  }
}

resource "aws_api_gateway_resource" "device_posture_lookup" {
  rest_api_id = aws_api_gateway_rest_api.device_posture_lookup.id
  parent_id   = aws_api_gateway_rest_api.device_posture_lookup.root_resource_id
  path_part   = "posture"
}

resource "aws_api_gateway_method" "device_posture_lookup" {
  rest_api_id   = aws_api_gateway_rest_api.device_posture_lookup.id
  resource_id   = aws_api_gateway_resource.device_posture_lookup.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "device_posture_lookup" {
  rest_api_id             = aws_api_gateway_rest_api.device_posture_lookup.id
  resource_id             = aws_api_gateway_resource.device_posture_lookup.id
  http_method             = aws_api_gateway_method.device_posture_lookup.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.device_posture_lookup.invoke_arn
}

resource "aws_api_gateway_deployment" "device_posture_lookup" {
  rest_api_id = aws_api_gateway_rest_api.device_posture_lookup.id

  triggers = {

    redeploy = sha1(jsonencode([
      aws_api_gateway_resource.device_posture_lookup.id,
      aws_api_gateway_method.device_posture_lookup.id,
      aws_api_gateway_integration.device_posture_lookup.id,
      data.aws_iam_policy_document.device_posture_lookup.json,
      "PRIVATE",
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "device_posture_lookup" {
  rest_api_id   = aws_api_gateway_rest_api.device_posture_lookup.id
  deployment_id = aws_api_gateway_deployment.device_posture_lookup.id
  stage_name    = "prod"
}

resource "aws_lambda_permission" "device_posture_lookup_from_apigw" {
  statement_id  = "AllowAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.device_posture_lookup.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.device_posture_lookup.execution_arn}/*/*"
}

output "device_posture_lookup_url" {
  description = "운영자(login_context.rego)와 앱 접근(envoy.authz policy.rego) 양쪽이 http.send로 호출할 디바이스/사용자 신뢰 조회 URL (?device_cn=<식별자> 붙여서 GET)"
  value       = "${aws_api_gateway_stage.device_posture_lookup.invoke_url}/posture"
}

output "device_posture_lookup_api_key" {
  description = "login_context.rego가 x-api-key 헤더로 보내야 하는 값"
  value       = random_password.device_posture_lookup_api_key.result
  sensitive   = true
}
