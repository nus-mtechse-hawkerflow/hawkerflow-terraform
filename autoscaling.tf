# -------------------------------------------------------------
# ECS service auto-scaling. Each service gets a policy matched to what
# limits it:
#   every service  CPU target tracking
#   hawker         also ALB requests per task (the stall catalogue read is the hot path)
#   order          also SQS backlog per task (its worker drains the order queue,
#                  and CPU lags the backlog)
#
# Pausing (var.paused, scripts/pause.sh) sets min and max to 0, so auto-scaling
# can never start tasks on a paused stack, whatever order Terraform applies in.
#
# Terraform still sets each service's desired_count (that is how pausing works),
# so an apply resets a scaled-out service to its desired_count; auto-scaling
# then scales it back within the limits below.
# -------------------------------------------------------------

locals {
  autoscaled_services = {
    for k, v in var.autoscaling_limits : k => v if contains(keys(var.services), k)
  }
}

resource "aws_appautoscaling_target" "ecs" {
  for_each = local.autoscaled_services

  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = "service/${aws_ecs_cluster.this.name}/${module.ecs_service[each.key].service_name}"
  min_capacity       = var.paused ? 0 : each.value.min
  max_capacity       = var.paused ? 0 : each.value.max
}

resource "aws_appautoscaling_policy" "cpu" {
  for_each = aws_appautoscaling_target.ecs

  name               = "${local.name}-${each.key}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = each.value.service_namespace
  scalable_dimension = each.value.scalable_dimension
  resource_id        = each.value.resource_id

  target_tracking_scaling_policy_configuration {
    target_value       = var.autoscaling_cpu_target_percent
    scale_out_cooldown = 60
    scale_in_cooldown  = 180 # scale in slowly so a lunch peak does not flap

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

resource "aws_appautoscaling_policy" "hawker_requests" {
  count = contains(keys(local.autoscaled_services), "hawker") ? 1 : 0

  name               = "${local.name}-hawker-alb-requests"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.ecs["hawker"].service_namespace
  scalable_dimension = aws_appautoscaling_target.ecs["hawker"].scalable_dimension
  resource_id        = aws_appautoscaling_target.ecs["hawker"].resource_id

  target_tracking_scaling_policy_configuration {
    target_value       = var.autoscaling_hawker_requests_per_task
    scale_out_cooldown = 60
    scale_in_cooldown  = 180

    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${module.alb.arn_suffix}/${module.alb.target_group_arn_suffixes["hawker"]}"
    }
  }
}

# Queued orders per running Order task. The task count comes from Container
# Insights, so this policy exists only while Container Insights is enabled.
resource "aws_appautoscaling_policy" "order_backlog" {
  count = contains(keys(local.autoscaled_services), local.order_queue_service) && var.enable_container_insights ? 1 : 0

  name               = "${local.name}-order-sqs-backlog-per-task"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.ecs[local.order_queue_service].service_namespace
  scalable_dimension = aws_appautoscaling_target.ecs[local.order_queue_service].scalable_dimension
  resource_id        = aws_appautoscaling_target.ecs[local.order_queue_service].resource_id

  target_tracking_scaling_policy_configuration {
    target_value       = var.autoscaling_order_backlog_per_task
    scale_out_cooldown = 60
    scale_in_cooldown  = 180

    customized_metric_specification {
      metrics {
        id          = "backlog"
        return_data = false
        metric_stat {
          metric {
            namespace   = "AWS/SQS"
            metric_name = "ApproximateNumberOfMessagesVisible"
            dimensions {
              name  = "QueueName"
              value = aws_sqs_queue.order.name
            }
          }
          stat = "Sum"
        }
      }

      metrics {
        id          = "tasks"
        return_data = false
        metric_stat {
          metric {
            namespace   = "ECS/ContainerInsights"
            metric_name = "RunningTaskCount"
            dimensions {
              name  = "ClusterName"
              value = aws_ecs_cluster.this.name
            }
            dimensions {
              name  = "ServiceName"
              value = module.ecs_service[local.order_queue_service].service_name
            }
          }
          stat = "Average"
        }
      }

      metrics {
        id          = "backlog_per_task"
        label       = "Queued orders per Order task"
        expression  = "backlog / IF(tasks > 0, tasks, 1)"
        return_data = true
      }
    }
  }
}
