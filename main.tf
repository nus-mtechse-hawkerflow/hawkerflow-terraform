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

module "database" {
  source = "./modules/rds"

  name                = local.name
  vpc_id              = module.network.vpc_id
  private_db_subnets  = module.network.database_subnet_ids
  ecs_security_group  = module.network.ecs_security_group_id
  db_name             = var.db_name
  db_username         = var.db_username
  instance_class      = var.db_instance_class
  allocated_storage   = var.db_allocated_storage
  deletion_protection = var.db_deletion_protection
  skip_final_snapshot = var.db_skip_final_snapshot
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
  desired_count           = each.value.desired_count
  aws_region              = var.aws_region
  db_host                 = module.database.address
  db_port                 = module.database.port
  db_name                 = var.db_name
  db_master_secret_arn    = module.database.master_secret_arn
  depends_on_listener_arn = module.alb.listener_arn
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
}

module "spa_hosting" {
  for_each = var.frontend_apps
  source   = "./modules/spa-hosting"

  name        = "${local.name}-${each.key}"
  bucket_name = "${local.name}-${each.key}-web-${data.aws_caller_identity.current.account_id}"
  comment     = coalesce(each.value.comment, "${each.key} Angular web app")
  price_class = each.value.price_class
}

