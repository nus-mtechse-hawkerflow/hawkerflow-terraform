variable "name" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "vpc_link_sg_id" { type = string }
variable "alb_listener_arn" { type = string }
variable "cognito_issuer" { type = string }
variable "cognito_client_id" { type = string }
variable "route_prefixes" { type = map(string) }
variable "cors_allow_origins" {
  type        = list(string)
  description = "Origins allowed to make cross-origin requests to API Gateway"
  default     = ["*"]
}
variable "throttling_rate_limit" {
  type        = number
  description = "Sustained requests per second allowed per route before API Gateway returns 429"
}
variable "throttling_burst_limit" {
  type        = number
  description = "Requests per route that may arrive at once (token bucket size) before throttling"
}
variable "cors_allow_headers" {
  type        = list(string)
  description = "Allowed headers for API Gateway CORS"
  default     = ["*"]
}

resource "aws_apigatewayv2_vpc_link" "this" {
  name               = "${var.name}-vpc-link"
  security_group_ids = [var.vpc_link_sg_id]
  subnet_ids         = var.private_subnet_ids
}

resource "aws_apigatewayv2_api" "this" {
  name          = "${var.name}-http-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = var.cors_allow_origins
    allow_methods = ["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS", "HEAD"]
    allow_headers = var.cors_allow_headers
    max_age       = 3600
  }
}

resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.this.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "${var.name}-cognito-jwt"

  jwt_configuration {
    audience = [var.cognito_client_id]
    issuer   = var.cognito_issuer
  }
}

resource "aws_apigatewayv2_integration" "alb" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "HTTP_PROXY"
  integration_method     = "ANY"
  integration_uri        = var.alb_listener_arn
  connection_type        = "VPC_LINK"
  connection_id          = aws_apigatewayv2_vpc_link.this.id
  payload_format_version = "1.0"

  request_parameters = {
    "overwrite:path" = "$request.path"
  }
}

resource "aws_apigatewayv2_route" "root" {
  for_each = var.route_prefixes

  api_id             = aws_apigatewayv2_api.this.id
  route_key          = "ANY ${each.value}"
  target             = "integrations/${aws_apigatewayv2_integration.alb.id}"
  authorization_type = "NONE"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_route" "proxy" {
  for_each = var.route_prefixes

  api_id             = aws_apigatewayv2_api.this.id
  route_key          = "ANY ${each.value}/{proxy+}"
  target             = "integrations/${aws_apigatewayv2_integration.alb.id}"
  authorization_type = "NONE"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = var.throttling_burst_limit
    throttling_rate_limit  = var.throttling_rate_limit
  }
}

output "api_endpoint" { value = aws_apigatewayv2_api.this.api_endpoint }
output "api_id" { value = aws_apigatewayv2_api.this.id }
