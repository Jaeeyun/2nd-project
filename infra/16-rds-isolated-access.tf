
resource "aws_subnet" "rds_readonly_isolated" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.200.0/24"
  availability_zone = local.azs[0]

  tags = {
    Name = "${local.name_prefix}-rds-readonly-isolated-subnet"
  }
}

resource "aws_route_table" "rds_readonly_isolated" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-rds-readonly-isolated-rt"
  }
}

resource "aws_route_table_association" "rds_readonly_isolated" {
  subnet_id      = aws_subnet.rds_readonly_isolated.id
  route_table_id = aws_route_table.rds_readonly_isolated.id
}

resource "aws_security_group" "rds_readonly_cloudshell" {
  name = "${local.name_prefix}-rds-readonly-cloudshell-sg"

  description = "HR RDS read-only CloudShell VPC environment - outbound to RDS(5432) only"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-rds-readonly-cloudshell-sg"
  }
}

resource "aws_vpc_security_group_egress_rule" "rds_readonly_cloudshell_to_rds" {
  security_group_id            = aws_security_group.rds_readonly_cloudshell.id
  referenced_security_group_id = aws_security_group.rds_sg.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "PostgreSQL only"
}

output "rds_readonly_isolated_subnet_id" {
  description = "HR RDS 조회 전용 CloudShell VPC 환경을 만들 때 선택할 서브넷"
  value       = aws_subnet.rds_readonly_isolated.id
}

output "rds_readonly_cloudshell_sg_id" {
  description = "위 CloudShell VPC 환경에 붙일 보안그룹"
  value       = aws_security_group.rds_readonly_cloudshell.id
}
