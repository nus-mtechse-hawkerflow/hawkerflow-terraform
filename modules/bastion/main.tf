variable "name" {
  description = "Resource name prefix"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the bastion host will reside"
  type        = string
}

variable "subnet_id" {
  description = "Public subnet ID for the bastion host"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for the bastion host"
  type        = string
  default     = "t4g.nano"
}

variable "allowed_cidr_blocks" {
  description = "List of CIDR blocks allowed to SSH into the bastion host"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "public_key" {
  description = "Optional existing SSH public key. If not provided, a new 4096-bit RSA key pair will be generated."
  type        = string
  default     = null
}

locals {
  is_arm       = can(regex("^t4g\\.", var.instance_type)) || can(regex("^c7g\\.", var.instance_type)) || can(regex("^m7g\\.", var.instance_type)) || can(regex("^r7g\\.", var.instance_type))
  architecture = local.is_arm ? "arm64" : "x86_64"
}

# Fetch the latest official Amazon Linux 2023 AMI via SSM parameter store
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${local.architecture}"
}

# Auto-generate RSA private key if public_key is not specified
resource "tls_private_key" "this" {
  count     = var.public_key == null ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

# AWS Key Pair
resource "aws_key_pair" "this" {
  key_name   = "${var.name}-bastion-key"
  public_key = var.public_key != null ? var.public_key : tls_private_key.this[0].public_key_openssh

  tags = {
    Name = "${var.name}-bastion-key"
  }
}

# Bastion Security Group
resource "aws_security_group" "bastion" {
  name        = "${var.name}-bastion-sg"
  description = "Security group for EC2 Bastion host"
  vpc_id      = var.vpc_id

  ingress {
    description = "SSH from allowed CIDRs"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name}-bastion-sg"
  }
}

# EC2 Instance in public subnet
resource "aws_instance" "bastion" {
  ami                         = data.aws_ssm_parameter.al2023_ami.value
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  key_name                    = aws_key_pair.this.key_name
  associate_public_ip_address = true

  root_block_device {
    volume_size           = 8
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  tags = {
    Name = "${var.name}-bastion"
  }
}

output "instance_id" {
  description = "Bastion EC2 instance ID"
  value       = aws_instance.bastion.id
}

output "public_ip" {
  description = "Public IP address of the bastion host"
  value       = aws_instance.bastion.public_ip
}

output "security_group_id" {
  description = "Security group ID of the bastion host"
  value       = aws_security_group.bastion.id
}

output "private_key_pem" {
  description = "PEM encoded private key for SSH (if auto-generated)"
  value       = var.public_key == null ? tls_private_key.this[0].private_key_pem : null
  sensitive   = true
}
