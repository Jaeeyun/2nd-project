
resource "aws_security_group" "eks_nodes_sg" {
  name        = "${local.name_prefix}-eks-nodes-sg"
  description = "Security group for EKS worker nodes"
  vpc_id      = aws_vpc.main.id
  ingress {
    description = "Allow all traffic within the VPC (node-to-node, ALB health checks)"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Allow all outbound traffic (ECR image pull, RDS access, etc.)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-eks-nodes-sg"
  }
}

resource "aws_security_group" "rds_sg" {
  name        = "${local.name_prefix}-rds-sg"
  description = "Security group for RDS PostgreSQL - VPC internal access only"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-rds-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_eks_nodes" {
  security_group_id            = aws_security_group.rds_sg.id
  referenced_security_group_id = aws_security_group.eks_nodes_sg.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "Normal app query traffic from hr-app (EKS nodes)"
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_eks_cluster_sg" {
  security_group_id            = aws_security_group.rds_sg.id
  referenced_security_group_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "Normal app query traffic from hr-app (actual EKS cluster SG attached to nodes)"
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_ssm_bastion" {
  security_group_id            = aws_security_group.rds_sg.id
  referenced_security_group_id = aws_security_group.rds_bastion.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "Human direct access only via this SSM port-forwarding bastion"
}

resource "aws_default_security_group" "main" {
  vpc_id = aws_vpc.main.id

}

resource "aws_default_security_group" "keycloak" {
  vpc_id = aws_vpc.keycloak.id
}

data "aws_vpc" "default" {
  default = true
}

resource "aws_default_security_group" "account_default_vpc" {
  vpc_id = data.aws_vpc.default.id
}
