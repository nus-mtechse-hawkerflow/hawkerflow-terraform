variable "name" { type = string }
variable "vpc_cidr" { type = string }
variable "availability_zones" { type = list(string) }
variable "enable_nat_gateway" { type = bool }
variable "aws_region" { type = string }

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.name}-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-igw" }
}

resource "aws_subnet" "public" {
  for_each = { for i, az in var.availability_zones : az => i }

  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, each.value)
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.name}-public-${each.key}" }
}

resource "aws_subnet" "app" {
  for_each = { for i, az in var.availability_zones : az => i }

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, each.value + 4)
  tags              = { Name = "${var.name}-app-${each.key}" }
}

resource "aws_subnet" "db" {
  for_each = { for i, az in var.availability_zones : az => i }

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, each.value + 8)
  tags              = { Name = "${var.name}-db-${each.key}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "${var.name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  count  = var.enable_nat_gateway ? 1 : 0
  domain = "vpc"
  tags   = { Name = "${var.name}-nat-eip" }
}

resource "aws_nat_gateway" "this" {
  count         = var.enable_nat_gateway ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = values(aws_subnet.public)[0].id
  depends_on    = [aws_internet_gateway.this]
  tags          = { Name = "${var.name}-nat" }
}

resource "aws_route_table" "app" {
  vpc_id = aws_vpc.this.id
  dynamic "route" {
    for_each = var.enable_nat_gateway ? [1] : []
    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.this[0].id
    }
  }
  tags = { Name = "${var.name}-app-rt" }
}

resource "aws_route_table_association" "app" {
  for_each       = aws_subnet.app
  subnet_id      = each.value.id
  route_table_id = aws_route_table.app.id
}

resource "aws_route_table" "db" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-db-rt" }
}

resource "aws_route_table_association" "db" {
  for_each       = aws_subnet.db
  subnet_id      = each.value.id
  route_table_id = aws_route_table.db.id
}

resource "aws_security_group" "vpc_link" {
  name        = "${var.name}-vpc-link-sg"
  description = "API Gateway VPC Link"
  vpc_id      = aws_vpc.this.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "alb" {
  name        = "${var.name}-alb-sg"
  description = "Allow HTTP only from API Gateway VPC Link"
  vpc_id      = aws_vpc.this.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.vpc_link.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "ecs" {
  name        = "${var.name}-ecs-sg"
  description = "Allow application traffic from the internal ALB"
  vpc_id      = aws_vpc.this.id

  ingress {
    from_port       = 0
    to_port         = 65535
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# -------------------------------------------------------------
# 1. Security Group for VPC Endpoints (Allow HTTPS from ECS)
# -------------------------------------------------------------
resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.name}-vpc-endpoints-sg"
  description = "Allow HTTPS inbound from ECS tasks to AWS VPC endpoints"
  vpc_id      = aws_vpc.this.id
  ingress {
    description     = "HTTPS from ECS tasks"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# -------------------------------------------------------------
# 2. S3 Gateway Endpoint (100% FREE - required for ECR image blobs)
# -------------------------------------------------------------
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.app.id]
  tags              = { Name = "${var.name}-s3-endpoint" }
}
data "aws_region" "current" {}
# -------------------------------------------------------------
# 3. Interface Endpoints (ECR, Logs, Secrets Manager)
# -------------------------------------------------------------
locals {
  interface_endpoints = {
    ecr_api = "com.amazonaws.${var.aws_region}.ecr.api"
    ecr_dkr = "com.amazonaws.${var.aws_region}.ecr.dkr"
    logs    = "com.amazonaws.${var.aws_region}.logs"
    secrets = "com.amazonaws.${var.aws_region}.secretsmanager"
  }
}

resource "aws_vpc_endpoint" "interfaces" {
  for_each            = local.interface_endpoints
  vpc_id              = aws_vpc.this.id
  service_name        = each.value
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = values(aws_subnet.app)[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  tags                = { Name = "${var.name}-${each.key}-endpoint" }
}

output "vpc_id" { value = aws_vpc.this.id }
output "public_subnet_ids" { value = values(aws_subnet.public)[*].id }
output "private_app_subnet_ids" { value = values(aws_subnet.app)[*].id }
output "database_subnet_ids" { value = values(aws_subnet.db)[*].id }
output "vpc_link_security_group_id" { value = aws_security_group.vpc_link.id }
output "alb_security_group_id" { value = aws_security_group.alb.id }
output "ecs_security_group_id" { value = aws_security_group.ecs.id }
