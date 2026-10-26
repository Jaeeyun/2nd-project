
resource "aws_vpc" "keycloak" {
  cidr_block           = var.keycloak_vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${local.name_prefix}-keycloak-vpc"
  }
}

resource "aws_internet_gateway" "keycloak" {
  vpc_id = aws_vpc.keycloak.id

  tags = {
    Name = "${local.name_prefix}-keycloak-igw"
  }
}

resource "aws_subnet" "keycloak_public" {
  vpc_id                  = aws_vpc.keycloak.id
  cidr_block              = var.keycloak_vpc_public_subnet_cidr
  availability_zone       = local.azs[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name_prefix}-keycloak-public-subnet"
  }
}

resource "aws_route_table" "keycloak_public" {
  vpc_id = aws_vpc.keycloak.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.keycloak.id
  }

  route {
    cidr_block                = var.vpc_cidr
    vpc_peering_connection_id = aws_vpc_peering_connection.keycloak_to_demo.id
  }

  tags = {
    Name = "${local.name_prefix}-keycloak-public-rt"
  }
}

resource "aws_route_table_association" "keycloak_public" {
  subnet_id      = aws_subnet.keycloak_public.id
  route_table_id = aws_route_table.keycloak_public.id
}

resource "aws_subnet" "keycloak_public_b" {
  vpc_id                  = aws_vpc.keycloak.id
  cidr_block              = cidrsubnet(var.keycloak_vpc_cidr, 8, 3)
  availability_zone       = local.azs[1]
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name_prefix}-keycloak-public-subnet-b"
  }
}

resource "aws_route_table_association" "keycloak_public_b" {
  subnet_id      = aws_subnet.keycloak_public_b.id
  route_table_id = aws_route_table.keycloak_public.id
}

resource "aws_subnet" "keycloak_private" {
  vpc_id            = aws_vpc.keycloak.id
  cidr_block        = var.keycloak_vpc_private_subnet_cidr
  availability_zone = local.azs[0]

  tags = {
    Name = "${local.name_prefix}-keycloak-private-subnet"
  }
}

resource "aws_route_table" "keycloak_private" {
  vpc_id = aws_vpc.keycloak.id

  route {
    cidr_block                = var.vpc_cidr
    vpc_peering_connection_id = aws_vpc_peering_connection.keycloak_to_demo.id
  }

  tags = {
    Name = "${local.name_prefix}-keycloak-private-rt"
  }
}

resource "aws_route_table_association" "keycloak_private" {
  subnet_id      = aws_subnet.keycloak_private.id
  route_table_id = aws_route_table.keycloak_private.id
}

resource "aws_vpc_peering_connection" "keycloak_to_demo" {
  vpc_id      = aws_vpc.keycloak.id
  peer_vpc_id = aws_vpc.main.id
  auto_accept = true

  accepter {
    allow_remote_vpc_dns_resolution = true
  }
  requester {
    allow_remote_vpc_dns_resolution = true
  }

  tags = {
    Name = "${local.name_prefix}-keycloak-to-demo-peering"
  }
}

resource "aws_route" "demo_public_to_keycloak" {
  route_table_id            = aws_route_table.public.id
  destination_cidr_block    = var.keycloak_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.keycloak_to_demo.id
}

resource "aws_route" "demo_private_to_keycloak" {
  count                     = length(aws_route_table.private)
  route_table_id            = aws_route_table.private[count.index].id
  destination_cidr_block    = var.keycloak_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.keycloak_to_demo.id
}

output "keycloak_vpc_id" {
  value = aws_vpc.keycloak.id
}

output "vpc_peering_connection_id" {
  value = aws_vpc_peering_connection.keycloak_to_demo.id
}
