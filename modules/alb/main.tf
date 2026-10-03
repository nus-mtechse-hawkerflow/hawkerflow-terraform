variable "name" { type = string }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "security_group_id" { type = string }
variable "services" {
  type = map(object({
    container_port = number
    cpu            = number
    memory         = number
    desired_count  = number
    route_prefix   = string
    health_path    = string
    image_tag      = string
    priority       = optional(number)
  }))
}

resource "aws_lb" "this" {
  name               = substr(replace("${var.name}-internal", "_", "-"), 0, 32)
  internal           = true
  load_balancer_type = "application"
  security_groups    = [var.security_group_id]
  subnets            = var.private_subnet_ids
}

resource "aws_lb_target_group" "service" {
  for_each = var.services

  name        = substr(replace("${var.name}-${each.key}", "_", "-"), 0, 32)
  port        = each.value.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = each.value.health_path
    matcher             = "200-399"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "application/json"
      message_body = "{\"message\":\"route not found\"}"
      status_code  = "404"
    }
  }
}

resource "aws_lb_listener_rule" "service" {
  for_each = var.services

  listener_arn = aws_lb_listener.http.arn
  priority     = coalesce(each.value.priority, 100 + index(sort(keys(var.services)), each.key))

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.service[each.key].arn
  }

  condition {
    path_pattern {
      values = [each.value.route_prefix, "${each.value.route_prefix}/*"]
    }
  }
}

output "listener_arn" { value = aws_lb_listener.http.arn }
output "target_group_arns" { value = { for k, v in aws_lb_target_group.service : k => v.arn } }
