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
      route_prefix   = "/analytics"
      health_path    = "/health"
      image_tag      = "latest"
      priority       = 40
    }
  }
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