variable "name" { type = string }
variable "services" { type = set(string) }

resource "aws_ecr_repository" "this" {
  for_each = var.services
  name     = "${var.name}/${each.key}"

  image_scanning_configuration { scan_on_push = true }
  image_tag_mutability = "MUTABLE"
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 3 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 3
      }
      action = { type = "expire" }
    }]
  })
}

output "repository_urls" {
  value = { for k, v in aws_ecr_repository.this : k => v.repository_url }
}
