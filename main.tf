data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_caller_identity" "current" {}

locals {
  name = "${var.project_name}-${var.environment}"
  azs  = slice(data.aws_availability_zones.available.names, 0, 2)

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

module "network" {
  source             = "./modules/network"
  name               = local.name
  vpc_cidr           = var.vpc_cidr
  availability_zones = local.azs
  enable_nat_gateway = var.enable_nat_gateway
  aws_region         = var.aws_region

  # A paused deployment runs no tasks, so it needs no interface endpoints
  enable_interface_endpoints = !var.paused
}

module "ecr" {
  source = "./modules/ecr"

  name     = local.name
  services = keys(var.services)
}

module "iam" {
  source = "./modules/iam"

  name     = local.name
  services = keys(var.services)
}

module "bastion" {
  count  = var.enable_bastion ? 1 : 0
  source = "./modules/bastion"

  name                = local.name
  vpc_id              = module.network.vpc_id
  subnet_id           = module.network.public_subnet_ids[0]
  instance_type       = var.bastion_instance_type
  allowed_cidr_blocks = var.bastion_allowed_cidr_blocks
  public_key          = var.bastion_public_key
}

module "database" {
  source = "./modules/rds"

  name                          = local.name
  vpc_id                        = module.network.vpc_id
  private_db_subnets            = module.network.database_subnet_ids
  ecs_security_group            = module.network.ecs_security_group_id
  additional_security_group_ids = var.enable_bastion ? [module.bastion[0].security_group_id] : []
  db_name                       = var.db_name
  db_username                   = var.db_username
  instance_class                = var.db_instance_class
  allocated_storage             = var.db_allocated_storage
  deletion_protection           = var.db_deletion_protection
  skip_final_snapshot           = var.db_skip_final_snapshot
}

resource "aws_iam_role_policy" "ecs_read_db_secret" {
  name = "${local.name}-read-db-secret"
  role = module.iam.execution_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [module.database.master_secret_arn]
    }]
  })
}

# -------------------------------------------------------------
# Order queue: API Gateway puts diners' orders straight on this queue,
# and the order service's background worker creates them. Orders are
# therefore accepted even while the order service is down or restarting.
# -------------------------------------------------------------
locals {
  order_queue_service = "order"
  has_order_service   = contains(keys(var.services), local.order_queue_service)
}

resource "aws_sqs_queue" "order_dlq" {
  name                      = "${local.name}-order-queue-dlq"
  message_retention_seconds = 1209600
}

resource "aws_sqs_queue" "order" {
  name                       = "${local.name}-order-queue"
  visibility_timeout_seconds = 60

  # A message the worker fails five times is set aside instead of retried forever
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.order_dlq.arn
    maxReceiveCount     = 5
  })
}

# Nothing checks an order's shape before it is queued, so an order the worker
# cannot create ends up here. Anything in this queue needs a person to look.
resource "aws_cloudwatch_metric_alarm" "order_dlq_not_empty" {
  alarm_name          = "${local.name}-order-queue-dlq-not-empty"
  alarm_description   = "An order failed five times and was set aside. Read it in SQS: ${aws_sqs_queue.order_dlq.name}"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.order_dlq.name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
}

data "aws_iam_policy_document" "apigw_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["apigateway.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "apigw_order_queue" {
  name               = "${local.name}-apigw-order-queue"
  assume_role_policy = data.aws_iam_policy_document.apigw_assume.json
}

resource "aws_iam_role_policy" "apigw_order_queue" {
  name = "${local.name}-apigw-order-queue"
  role = aws_iam_role.apigw_order_queue.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:SendMessage"]
      Resource = [aws_sqs_queue.order.arn]
    }]
  })
}

resource "aws_apigatewayv2_integration" "order_queue" {
  api_id                 = module.api_gateway.api_id
  integration_type       = "AWS_PROXY"
  integration_subtype    = "SQS-SendMessage"
  credentials_arn        = aws_iam_role.apigw_order_queue.arn
  payload_format_version = "1.0"

  request_parameters = {
    QueueUrl    = aws_sqs_queue.order.url
    MessageBody = "$request.body"
  }
}

# More specific than the order service's "ANY /order/{proxy+}" route, so this
# one request goes to the queue and everything else still reaches the service.
# The diner site posts the order as plain text so the browser sends no CORS
# preflight: an OPTIONS request would fall through to the order service and
# fail while it is down. (A route with no integration does not catch it.)
resource "aws_apigatewayv2_route" "order_queue" {
  count = local.has_order_service ? 1 : 0

  api_id    = module.api_gateway.api_id
  route_key = "POST ${var.services[local.order_queue_service].route_prefix}/v1/order/orders/queue"
  target    = "integrations/${aws_apigatewayv2_integration.order_queue.id}"
}

# -------------------------------------------------------------
# Order events: the order service announces every step of an order
# (placed, accepted, preparing, ready, completed, cancelled) on an SNS
# topic. A queue subscribed to the topic keeps a copy of each event for
# a day, so an order's journey can be read in the SQS console.
# -------------------------------------------------------------
resource "aws_sns_topic" "order_status" {
  name = "${local.name}-order-status"
}

resource "aws_sqs_queue" "order_events" {
  name                      = "${local.name}-order-events"
  message_retention_seconds = 86400
}

resource "aws_sqs_queue_policy" "order_events" {
  queue_url = aws_sqs_queue.order_events.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.order_events.arn
      Condition = { ArnEquals = { "aws:SourceArn" = aws_sns_topic.order_status.arn } }
    }]
  })
}

resource "aws_sns_topic_subscription" "order_events" {
  topic_arn            = aws_sns_topic.order_status.arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.order_events.arn
  raw_message_delivery = true
}

resource "aws_iam_role_policy" "order_queue_access" {
  count = local.has_order_service ? 1 : 0
  name  = "${local.name}-order-queue-access"
  role  = module.iam.task_role_names[local.order_queue_service]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:ChangeMessageVisibility",
        "sqs:GetQueueAttributes"
      ]
      Resource = [aws_sqs_queue.order.arn]
      }, {
      Effect   = "Allow"
      Action   = ["sns:Publish"]
      Resource = [aws_sns_topic.order_status.arn]
    }]
  })
}

moved {
  from = module.cognito
  to   = module.cognito["customer"]
}

module "cognito" {
  for_each = var.cognito_pools
  source   = "./modules/cognito"

  name                   = "${local.name}-${each.key}"
  generate_client_secret = coalesce(each.value.generate_client_secret, false)
}

module "alb" {
  source = "./modules/alb"

  name               = local.name
  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_app_subnet_ids
  security_group_id  = module.network.alb_security_group_id
  services           = var.services
}

resource "aws_ecs_cluster" "this" {
  name = "${local.name}-cluster"

  setting {
    name  = "containerInsights"
    value = var.enable_container_insights ? "enabled" : "disabled"
  }
}

module "ecs_service" {
  for_each = var.services
  source   = "./modules/ecs-service"

  name                    = local.name
  service_name            = each.key
  cluster_id              = aws_ecs_cluster.this.id
  cluster_name            = aws_ecs_cluster.this.name
  private_subnet_ids      = module.network.private_app_subnet_ids
  security_group_id       = module.network.ecs_security_group_id
  target_group_arn        = module.alb.target_group_arns[each.key]
  execution_role_arn      = module.iam.execution_role_arn
  task_role_arn           = module.iam.task_role_arns[each.key]
  container_image         = "${module.ecr.repository_urls[each.key]}:${each.value.image_tag}"
  container_port          = each.value.container_port
  cpu                     = each.value.cpu
  memory                  = each.value.memory
  desired_count           = var.paused ? 0 : each.value.desired_count
  aws_region              = var.aws_region
  db_host                 = module.database.address
  db_port                 = module.database.port
  db_name                 = var.db_name
  db_master_secret_arn    = module.database.master_secret_arn
  depends_on_listener_arn = module.alb.listener_arn

  # The order service reads these over its config.yml, which ships with
  # the queue and event publishing switched off.
  extra_environment = each.key == local.order_queue_service ? {
    SQS__ENABLED        = "true"
    SQS__QUEUE_URL      = aws_sqs_queue.order.url
    SQS__REGION_NAME    = var.aws_region
    EVENTS__ENABLED     = "true"
    EVENTS__TOPIC_ARN   = aws_sns_topic.order_status.arn
    EVENTS__REGION_NAME = var.aws_region
    # Cancel orders no stall accepted in time; complete uncollected ready orders at day end
    EXPIRY__ENABLED         = "true"
    EXPIRY__PENDING_MINUTES = tostring(var.order_pending_expiry_minutes)
  } : {}
}

module "api_gateway" {
  source = "./modules/api-gateway"

  name               = local.name
  private_subnet_ids = module.network.private_app_subnet_ids
  vpc_link_sg_id     = module.network.vpc_link_security_group_id
  alb_listener_arn   = module.alb.listener_arn
  cognito_issuer     = module.cognito["customer"].issuer
  cognito_client_id  = module.cognito["customer"].client_id
  route_prefixes     = { for k, v in var.services : k => v.route_prefix }
  cors_allow_origins = var.cors_allow_origins
  cors_allow_headers = var.cors_allow_headers
}

module "spa_hosting" {
  for_each = var.frontend_apps
  source   = "./modules/spa-hosting"

  name        = "${local.name}-${each.key}"
  bucket_name = "${local.name}-${each.key}-web-${data.aws_caller_identity.current.account_id}"
  comment     = coalesce(each.value.comment, "${each.key} Angular web app")
  price_class = each.value.price_class
}

