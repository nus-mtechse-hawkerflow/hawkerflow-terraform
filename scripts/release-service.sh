#!/usr/bin/env bash
set -euo pipefail

# Builds a backend service, pushes its image to ECR and restarts it on ECS.
# `terraform apply` creates the infrastructure but does not ship code: run this
# after changing a service.
#
# Usage:
#   ./scripts/release-service.sh <order|hawker|customer|analytics> <path_to_service_repo>
#
# Examples:
#   ./scripts/release-service.sh order ../hawkerflow-service-order
#   ./scripts/release-service.sh analytics ../hawkerflow-service-analytics

SERVICE="${1:-}"
SERVICE_REPO="${2:-}"

if [[ -z "$SERVICE" || -z "$SERVICE_REPO" ]]; then
  echo "Usage: $0 <service> <path_to_service_repo>"
  exit 1
fi

if [[ ! -f "$SERVICE_REPO/Dockerfile" ]]; then
  echo "Error: '$SERVICE_REPO' has no Dockerfile; is it the right repository?"
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "Reading Terraform outputs from $ROOT_DIR..."
OUTPUTS=$(terraform -chdir="$ROOT_DIR" output -json)
REPO_URL=$(echo "$OUTPUTS" | jq -r --arg s "$SERVICE" '.ecr_repository_urls.value[$s] // empty')
CLUSTER=$(echo "$OUTPUTS" | jq -r '.ecs_cluster_name.value // empty')

if [[ -z "$REPO_URL" || -z "$CLUSTER" ]]; then
  echo "Error: no ECR repository for '$SERVICE' in the Terraform outputs."
  echo "Available services:"
  echo "$OUTPUTS" | jq -r '.ecr_repository_urls.value | keys[]'
  exit 1
fi

REGISTRY="${REPO_URL%%/*}"
REGION=$(echo "$REGISTRY" | sed -E 's#.*\.ecr\.([a-z0-9-]+)\.amazonaws\.com#\1#')
# The cluster is "<name>-cluster" and each ECS service is "<name>-<service>"
ECS_SERVICE="${CLUSTER%-cluster}-$SERVICE"

echo "Logging Docker in to $REGISTRY..."
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"

echo "Building $REPO_URL:latest..."
# Fargate runs linux/amd64; build for it even on an ARM laptop
docker build --platform linux/amd64 -t "$REPO_URL:latest" "$SERVICE_REPO"
docker push "$REPO_URL:latest"

echo "Restarting $ECS_SERVICE on $CLUSTER..."
aws ecs update-service --region "$REGION" --cluster "$CLUSTER" --service "$ECS_SERVICE" \
  --force-new-deployment --query 'service.deployments[0].rolloutState' --output text

echo "Waiting for the new task to become healthy..."
aws ecs wait services-stable --region "$REGION" --cluster "$CLUSTER" --services "$ECS_SERVICE"

echo "Released '$SERVICE'."
