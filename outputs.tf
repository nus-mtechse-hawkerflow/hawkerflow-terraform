output "api_url" {
  description = "Public API Gateway base URL."
  value       = module.api_gateway.api_endpoint
}

output "cognito_user_pool_id" {
  description = "Default/customer Cognito user pool ID for backward compatibility."
  value       = try(module.cognito["customer"].user_pool_id, null)
}

output "cognito_client_id" {
  description = "Default/customer Cognito client ID for backward compatibility."
  value       = try(module.cognito["customer"].client_id, null)
}

output "cognito_user_pool_ids" {
  description = "Map of Cognito user pool IDs keyed by pool name."
  value = {
    for k, v in module.cognito : k => v.user_pool_id
  }
}

output "cognito_client_ids" {
  description = "Map of Cognito user pool client IDs keyed by pool name."
  value = {
    for k, v in module.cognito : k => v.client_id
  }
}

output "cognito_issuers" {
  description = "Map of Cognito issuer URLs keyed by pool name."
  value = {
    for k, v in module.cognito : k => v.issuer
  }
}

output "ecr_repository_urls" {
  value = module.ecr.repository_urls
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "database_endpoint" {
  value = module.database.address
}

output "database_secret_arn" {
  description = "ARN of the AWS-managed Secrets Manager secret containing the RDS master credentials."
  value       = module.database.master_secret_arn
}

output "frontend_urls" {
  description = "CloudFront HTTPS URLs for the Angular web applications."
  value = {
    for k, v in module.spa_hosting : k => v.website_url
  }
}

output "frontend_s3_buckets" {
  description = "S3 bucket names for deploying Angular build artifacts."
  value = {
    for k, v in module.spa_hosting : k => v.bucket_name
  }
}

output "frontend_distribution_ids" {
  description = "CloudFront distribution IDs for invalidating cache on deployment."
  value = {
    for k, v in module.spa_hosting : k => v.distribution_id
  }
}

