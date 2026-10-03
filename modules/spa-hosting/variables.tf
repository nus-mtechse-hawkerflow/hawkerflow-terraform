variable "name" {
  description = "Name prefix for resources."
  type        = string
}

variable "bucket_name" {
  description = "Globally unique name for the S3 bucket."
  type        = string
}

variable "price_class" {
  description = "CloudFront distribution price class (e.g. PriceClass_100, PriceClass_200, PriceClass_All)."
  type        = string
  default     = "PriceClass_100"
}

variable "comment" {
  description = "Comment/description for the CloudFront distribution."
  type        = string
  default     = "Managed by Terraform"
}
