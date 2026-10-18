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
variable "autoscaling_limits" {
  description = "Min and max tasks per ECS service; a service not listed is not auto-scaled. Each order, hawker or customer task can open up to 15 database connections (SQLAlchemy pool_size 5 + max_overflow 10) and an analytics task up to 7, so keep the maxima inside the RDS instance's connection limit (roughly 80-110 on db.t4g.micro)."
  type = map(object({
    min = number
    max = number
  }))
  # Theoretical worst case at these maxima: 15 x (5 + 3 + 2) + 7 x 1 = 157 connections.
  # In practice pools stay small: load test run 0 (17 Oct) used 8 connections across
  # 6 tasks. Watch RDS DatabaseConnections under load; shrink the per-task pools
  # (e.g. pool_size 2, max_overflow 3) before raising these further.
  default = {
    order     = { min = 1, max = 5 }
    hawker    = { min = 1, max = 3 }
    customer  = { min = 1, max = 2 }
    analytics = { min = 1, max = 1 }
  }
}

variable "autoscaling_cpu_target_percent" {
  description = "Average CPU utilisation each service is scaled to hold."
  type        = number
  default     = 60
}

variable "autoscaling_hawker_requests_per_task" {
  description = "ALB requests per hawker task per minute before another task is added. Set from a step load test: about half the rate where p95 latency starts to rise."
  type        = number
  default     = 1500
}

variable "autoscaling_order_backlog_per_task" {
  description = "Queued orders one Order task may hold: acceptable queue wait (s) / average seconds per order."
  type        = number
  default     = 50
}

variable "loadtest_github_subject_prefix" {
  description = "OIDC subject prefix of the GitHub repository whose Actions runs may assume the load-test metrics role. The org's repos use GitHub's immutable subject format, repo:<owner>@<owner-id>/<repo>@<repo-id>; read a repo's prefix with: gh api repos/<owner>/<repo>/actions/oidc/customization/sub"
  type        = string
  default     = "repo:nus-mtechse-hawkerflow@322320064/hawkerflow-qa@1415835750"
}

variable "api_throttling_rate_limit" {
  description = "API Gateway: sustained requests per second per route before requests are rejected with 429. Was 50, which is below the step load test's 100 and 200 req/s steps (the busiest route, browse, carries 70% of the load). Set it just above the highest load the services are shown to handle."
  type        = number
  default     = 500
}

variable "api_throttling_burst_limit" {
  description = "API Gateway: requests per route that can arrive at once (token bucket size) before throttling starts. Was 100."
  type        = number
  default     = 1000
}
