variable "name" {
  description = "Base name for the Cognito User Pool and Client."
  type        = string
}

variable "generate_client_secret" {
  description = "Whether to generate a client secret for the user pool client."
  type        = bool
  default     = false
}

resource "aws_cognito_user_pool" "this" {
  name = "${var.name}-pool"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length                   = 10
    require_lowercase                = true
    require_numbers                  = true
    require_symbols                  = false
    require_uppercase                = true
    temporary_password_validity_days = 7
  }

  lifecycle {
    prevent_destroy = false
  }
}

resource "aws_cognito_user_pool_client" "this" {
  name         = "${var.name}-client"
  user_pool_id = aws_cognito_user_pool.this.id

  generate_secret = var.generate_client_secret

  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH"
  ]

  prevent_user_existence_errors = "ENABLED"
}

output "user_pool_id" { value = aws_cognito_user_pool.this.id }
output "client_id" { value = aws_cognito_user_pool_client.this.id }
output "issuer" { value = "https://${aws_cognito_user_pool.this.endpoint}" }
