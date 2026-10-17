variable "name" { type = string }
variable "service_name" { type = string }
variable "cluster_id" { type = string }
variable "cluster_name" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "security_group_id" { type = string }
variable "target_group_arn" { type = string }
variable "execution_role_arn" { type = string }
variable "task_role_arn" { type = string }
variable "container_image" { type = string }
variable "container_port" { type = number }
variable "cpu" { type = number }
variable "memory" { type = number }
variable "desired_count" { type = number }
variable "aws_region" { type = string }
variable "db_host" { type = string }
variable "db_port" { type = number }
variable "db_name" { type = string }
variable "db_master_secret_arn" { type = string }
variable "depends_on_listener_arn" { type = string }
variable "extra_environment" {
  type        = map(string)
  default     = {}
  description = "Additional plain environment variables for this service's container"
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.name}/${var.service_name}"
  retention_in_days = 14
}

resource "aws_ecs_task_definition" "this" {
  family                   = "${var.name}-${var.service_name}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.cpu)
  memory                   = tostring(var.memory)
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn

  container_definitions = jsonencode([{
    name      = var.service_name
    image     = var.container_image
    essential = true

    portMappings = [{
      containerPort = var.container_port
      hostPort      = var.container_port
      protocol      = "tcp"
    }]

    environment = concat(
      [
        { name = "DB_HOST", value = var.db_host },
        { name = "DB_PORT", value = tostring(var.db_port) },
        { name = "DB_NAME", value = var.db_name }
      ],
      [for k, v in var.extra_environment : { name = k, value = v }]
    )

    # RDS stores its managed master credentials as JSON in Secrets Manager.
    # ECS extracts the JSON keys and injects them as environment variables.
    secrets = [
      { name = "DB_USERNAME", valueFrom = "${var.db_master_secret_arn}:username::" },
      { name = "DB_PASSWORD", valueFrom = "${var.db_master_secret_arn}:password::" }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.this.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = var.service_name
      }
    }
  }])
}

resource "aws_ecs_service" "this" {
  name            = "${var.name}-${var.service_name}"
  cluster         = var.cluster_id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = 60

  # Fail fast and roll back when a new version's tasks keep failing
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.security_group_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = var.service_name
    container_port   = var.container_port
  }

  # The CI/CD pipeline deploys new task-definition revisions (SHA-tagged images).
  # Terraform keeps managing desired_count (pause/resume), but leaves the
  # running revision alone so an apply does not roll services back to :latest.
  lifecycle {
    ignore_changes = [task_definition]
  }

  # Forces Terraform to wait until the listener exists. The ARN itself is not
  # otherwise needed by this resource.
  depends_on = [aws_ecs_task_definition.this]
}

output "service_name" { value = aws_ecs_service.this.name }
