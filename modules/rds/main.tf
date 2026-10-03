variable "name" { type = string }
variable "vpc_id" { type = string }
variable "private_db_subnets" { type = list(string) }
variable "ecs_security_group" { type = string }
variable "db_name" { type = string }
variable "db_username" { type = string }
variable "instance_class" { type = string }
variable "allocated_storage" { type = number }

resource "aws_security_group" "db" {
  name        = "${var.name}-db-sg"
  description = "PostgreSQL access only from ECS tasks"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.ecs_security_group]
  }
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-db-subnets"
  subnet_ids = var.private_db_subnets
}

resource "aws_db_instance" "this" {
  identifier                  = "${var.name}-postgres"
  engine                      = "postgres"
  instance_class              = var.instance_class
  allocated_storage           = var.allocated_storage
  max_allocated_storage       = max(var.allocated_storage, 100)
  storage_type                = "gp3"
  storage_encrypted           = true
  db_name                     = var.db_name
  username                    = var.db_username
  manage_master_user_password = true
  port                        = 5432
  db_subnet_group_name        = aws_db_subnet_group.this.name
  vpc_security_group_ids      = [aws_security_group.db.id]
  publicly_accessible         = false
  multi_az                    = false
  backup_retention_period     = 7
  deletion_protection         = true
  skip_final_snapshot         = false
  apply_immediately           = false

  lifecycle {
    prevent_destroy = false
    ignore_changes = [final_snapshot_identifier]
  }
}


output "address" { value = aws_db_instance.this.address }
output "port" { value = aws_db_instance.this.port }
output "master_secret_arn" { value = aws_db_instance.this.master_user_secret[0].secret_arn }
