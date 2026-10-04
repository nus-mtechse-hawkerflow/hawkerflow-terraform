variable "aws_region" {
  description = "AWS region in which resources are created."
  type        = string
  default     = "ap-southeast-1"
}

variable "project_name" {
  description = "Short project name used as a resource-name prefix."
  type        = string
  default     = "hawkerflow"
}

variable "environment" {
  description = "Deployment environment, for example dev, staging, or prod."
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "services" {
  description = "Microservices deployed to ECS. Route prefix must be unique."
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

  default = {
    order = {
      container_port = 8080
      cpu            = 256
      memory         = 512
      desired_count  = 1
      route_prefix   = "/order"
      health_path    = "/health"
      image_tag      = "latest"
      priority       = 10
    }
    hawker = {
      container_port = 8080
      cpu            = 256
      memory         = 512
      desired_count  = 1
      route_prefix   = "/hawker"
      health_path    = "/health"
      image_tag      = "latest"
      priority       = 20
    }
    customer = {
      container_port = 8080
      cpu            = 256
      memory         = 512
      desired_count  = 1
      route_prefix   = "/customer"
      health_path    = "/health"
      image_tag      = "latest"
      priority       = 30
    }
    analytics = {
      container_port = 8080
      cpu            = 256
      memory         = 512
      desired_count  = 1
      # Not "/analytics": ad and tracker blockers refuse requests to that path
      route_prefix = "/insights"
      health_path  = "/health"
      image_tag    = "latest"
      priority     = 40
    }
  }
}

variable "paused" {
  description = "Park the deployment to save cost: no running tasks and no interface VPC endpoints. Data, accounts and addresses are kept. Use scripts/pause.sh and scripts/resume.sh, which also stop and start the database and bastion."
  type        = bool
  default     = false
}

variable "order_pending_expiry_minutes" {
  description = "Minutes a stall has to accept an order before the order service cancels it."
  type        = number
  default     = 15
}

variable "db_name" {
  type    = string
  default = "hawkerflow"
}

variable "db_username" {
  type    = string
  default = "hawkerflow_admin"
}

variable "db_instance_class" {
  description = "Small development default. Increase for production."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_allocated_storage" {
  type    = number
  default = 20
}

variable "enable_nat_gateway" {
  description = "NAT gives private ECS tasks outbound internet access. Set false only after adding the VPC endpoints your workloads require."
  type        = bool
  default     = false
}

variable "enable_container_insights" {
  description = "Enable CloudWatch Container Insights for the ECS cluster"
  type        = bool
  default     = true # Off for dev, toggle on for prod
}

variable "db_deletion_protection" {
  description = "Whether to enable deletion protection on the RDS instance. Set false for disposable environments."
  type        = bool
  default     = false
}

variable "db_skip_final_snapshot" {
  description = "Whether to skip final snapshot when destroying RDS. Set true for disposable environments."
  type        = bool
  default     = true
}

variable "frontend_apps" {
  description = "Map of frontend SPAs (e.g. Angular web applications) to host on S3 + CloudFront."
  type = map(object({
    comment     = optional(string)
    price_class = optional(string, "PriceClass_100")
  }))
  default = {
    customer = {
      comment     = "Customer portal Angular web application"
      price_class = "PriceClass_100"
    }
    hawker = {
      comment     = "Hawker / Merchant portal Angular web application"
      price_class = "PriceClass_100"
    }
  }
}

variable "cors_allow_origins" {
  description = "Allowed origins for API Gateway CORS. Defaults to ['*'] for dev, can be set to specific CloudFront or local URLs."
  type        = list(string)
  default     = ["*"]
}

variable "cors_allow_headers" {
  description = "Allowed headers for API Gateway CORS. Defaults to ['*']."
  type        = list(string)
  default     = ["*"]
}


variable "cognito_pools" {
  description = "Map of Cognito user pools to create."
  type = map(object({
    generate_client_secret = optional(bool, false)
  }))
  default = {
    customer = {}
    hawker   = {}
  }
}

variable "enable_bastion" {
  description = "Whether to deploy an EC2 bastion host for SSH tunneling to RDS."
  type        = bool
  default     = true
}

variable "bastion_instance_type" {
  description = "EC2 instance type for the bastion host. Defaults to t4g.nano for lowest cost."
  type        = string
  default     = "t4g.nano"
}

variable "bastion_allowed_cidr_blocks" {
  description = "List of CIDR blocks permitted to SSH into the bastion host. Can be restricted to your specific IP (e.g. ['203.0.113.195/32'])."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "bastion_public_key" {
  description = "Optional existing SSH public key. If null, a 4096-bit RSA key pair is generated automatically."
  type        = string
  default     = null
}