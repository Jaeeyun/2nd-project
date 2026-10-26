
resource "aws_security_group" "rds_bastion" {
  name        = "${local.name_prefix}-rds-bastion-sg"
  description = "RDS direct-access SSM port-forwarding bundle - no inbound ports at all (SSM agent dials out)"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-rds-bastion-sg"
  }
}

resource "aws_iam_role" "rds_bastion" {
  name = "${local.name_prefix}-rds-bastion-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "rds_bastion_ssm" {
  role       = aws_iam_role.rds_bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "rds_bastion" {
  name = "${local.name_prefix}-rds-bastion-profile"
  role = aws_iam_role.rds_bastion.name
}

resource "aws_instance" "rds_bastion" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.private_app[0].id
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.rds_bastion.id]
  iam_instance_profile        = aws_iam_instance_profile.rds_bastion.name

  tags = {
    Name = "${local.name_prefix}-rds-bastion"
  }
}

output "rds_bastion_instance_id" {
  description = "RDS 직접 접속용 SSM 포트포워딩 번들 인스턴스 ID (운영자가 --target으로 쓸 값)"
  value       = aws_instance.rds_bastion.id
}
