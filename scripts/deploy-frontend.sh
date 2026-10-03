#!/usr/bin/env bash
set -euo pipefail

# Helper script to deploy an Angular application to AWS S3 & CloudFront
# Usage:
#   ./scripts/deploy-frontend.sh <app_name> <path_to_angular_dist_folder>
#
# Examples:
#   ./scripts/deploy-frontend.sh customer ../hawkerflow-frontend-customer/dist/customer/browser
#   ./scripts/deploy-frontend.sh hawker ../hawkerflow-frontend-hawker/dist/hawker/browser

APP_NAME="${1:-}"
DIST_PATH="${2:-}"

if [[ -z "$APP_NAME" || -z "$DIST_PATH" ]]; then
  echo "Usage: $0 <app_name> <path_to_dist_folder>"
  echo "  app_name: Name of the frontend app key (e.g., customer, hawker)"
  echo "  path_to_dist_folder: Path containing compiled Angular assets (index.html, *.js, etc.)"
  exit 1
fi

if [[ ! -d "$DIST_PATH" ]]; then
  echo "Error: Directory '$DIST_PATH' does not exist."
  exit 1
fi

if [[ ! -f "$DIST_PATH/index.html" ]]; then
  echo "Warning: No 'index.html' found directly inside '$DIST_PATH'."
  echo "Please verify this is the build output folder (e.g. dist/<project>/browser)."
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "Fetching Terraform outputs from $ROOT_DIR..."
BUCKET_NAME=$(terraform -chdir="$ROOT_DIR" output -json frontend_s3_buckets | jq -r --arg app "$APP_NAME" '.[$app] // empty')
DIST_ID=$(terraform -chdir="$ROOT_DIR" output -json frontend_distribution_ids | jq -r --arg app "$APP_NAME" '.[$app] // empty')

if [[ -z "$BUCKET_NAME" || -z "$DIST_ID" ]]; then
  echo "Error: Could not find outputs for app '$APP_NAME' in Terraform state."
  echo "Available buckets:"
  terraform -chdir="$ROOT_DIR" output frontend_s3_buckets
  exit 1
fi

echo "Deploying '$APP_NAME' to S3 bucket: s3://$BUCKET_NAME..."
aws s3 sync "$DIST_PATH" "s3://$BUCKET_NAME" --delete

echo "Invalidating CloudFront cache for distribution: $DIST_ID..."
INVALIDATION_ID=$(aws cloudfront create-invalidation --distribution-id "$DIST_ID" --paths "/*" --query "Invalidation.Id" --output text)

echo "Deployment complete! CloudFront invalidation ID: $INVALIDATION_ID"
echo "URL: $(terraform -chdir="$ROOT_DIR" output -json frontend_urls | jq -r --arg app "$APP_NAME" '.[$app]')"
