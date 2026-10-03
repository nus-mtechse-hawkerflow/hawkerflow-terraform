# Add this AFTER you create an S3 bucket for Terraform state.
# Do not use this file as-is. Rename it to backend.tf and replace the values.
#
terraform {
  backend "s3" {
    bucket       = "hawkerflow-tf-state-bucket-147010142233-ap-southeast-1-an"
    key          = "hawkerflow/dev/terraform.tfstate"
    region       = "ap-southeast-1"
    use_lockfile = true
    encrypt      = true
  }
}
