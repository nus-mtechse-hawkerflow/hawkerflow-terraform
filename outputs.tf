output "api_url" {
  description = "Public API Gateway base URL."
  value       = module.api_gateway.api_endpoint
}

output "cognito_user_pool_id" {
  value = module.cognito.user_pool_id
}

output "cognito_client_id" {
  value = module.cognito.client_id
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
