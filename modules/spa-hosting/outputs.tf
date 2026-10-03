output "bucket_id" {
  description = "The ID/name of the S3 bucket."
  value       = aws_s3_bucket.this.id
}

output "bucket_name" {
  description = "The name of the S3 bucket."
  value       = aws_s3_bucket.this.id
}

output "bucket_arn" {
  description = "The ARN of the S3 bucket."
  value       = aws_s3_bucket.this.arn
}

output "distribution_id" {
  description = "The ID of the CloudFront distribution."
  value       = aws_cloudfront_distribution.this.id
}

output "distribution_arn" {
  description = "The ARN of the CloudFront distribution."
  value       = aws_cloudfront_distribution.this.arn
}

output "distribution_domain_name" {
  description = "The domain name of the CloudFront distribution."
  value       = aws_cloudfront_distribution.this.domain_name
}

output "website_url" {
  description = "The HTTPS URL to access the hosted SPA."
  value       = "https://${aws_cloudfront_distribution.this.domain_name}"
}
