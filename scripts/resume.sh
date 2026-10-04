#!/usr/bin/env bash
set -euo pipefail

# Brings a paused deployment back (see ./scripts/pause.sh).
# Starts the database and the bastion host, restores the interface VPC
# endpoints and the services, then waits until every service answers.
# Takes about 10 minutes, most of it the database starting.
#
# Usage:
#   ./scripts/resume.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "Reading Terraform outputs from $ROOT_DIR..."
OUTPUTS=$(terraform -chdir="$ROOT_DIR" output -json)
CLUSTER=$(echo "$OUTPUTS" | jq -r '.ecs_cluster_name.value // empty')
BASTION_ID=$(echo "$OUTPUTS" | jq -r '.bastion_instance_id.value // empty')
API_URL=$(echo "$OUTPUTS" | jq -r '.api_url.value // empty')

if [[ -z "$CLUSTER" || -z "$API_URL" ]]; then
  echo "Error: the Terraform outputs are missing. Run terraform init and check the backend."
  exit 1
fi

REGION=$(echo "$API_URL" | sed -E 's#.*execute-api\.([a-z0-9-]+)\.amazonaws\.com.*#\1#')
NAME="${CLUSTER%-cluster}"
DB_ID="$NAME-postgres"

DB_STATUS=$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$DB_ID" \
  --query 'DBInstances[0].DBInstanceStatus' --output text)
if [[ "$DB_STATUS" == "stopped" ]]; then
  echo "Starting database $DB_ID..."
  aws rds start-db-instance --region "$REGION" --db-instance-identifier "$DB_ID" \
    --query 'DBInstance.DBInstanceStatus' --output text
else
  echo "Database $DB_ID is '$DB_STATUS'."
fi

if [[ -n "$BASTION_ID" ]]; then
  echo "Starting bastion $BASTION_ID..."
  aws ec2 start-instances --region "$REGION" --instance-ids "$BASTION_ID" \
    --query 'StartingInstances[0].CurrentState.Name' --output text
fi

# The services create their tables on start, so the database must be up first
echo "Waiting for the database to be available (this is the slow part)..."
aws rds wait db-instance-available --region "$REGION" --db-instance-identifier "$DB_ID"

echo "Restoring the interface VPC endpoints and the services..."
terraform -chdir="$ROOT_DIR" apply -var paused=false

SERVICES=$(echo "$OUTPUTS" | jq -r '.ecr_repository_urls.value | keys[]')
ECS_SERVICES=()
for s in $SERVICES; do ECS_SERVICES+=("$NAME-$s"); done

echo "Waiting for the services to become healthy..."
aws ecs wait services-stable --region "$REGION" --cluster "$CLUSTER" --services "${ECS_SERVICES[@]}"

echo
# The analytics service is routed under /insights (ad blockers refuse /analytics)
FAILED=0
for prefix in order hawker customer insights; do
  CODE=$(curl -s -m 20 -o /dev/null -w '%{http_code}' "$API_URL/$prefix/health" || true)
  echo "  $API_URL/$prefix/health -> $CODE"
  [[ "$CODE" == "200" ]] || FAILED=1
done

if [[ "$FAILED" == "1" ]]; then
  echo "Resumed, but not every service answered 200. Check the service logs in CloudWatch."
  exit 1
fi

echo "Resumed. Sites:"
echo "$OUTPUTS" | jq -r '.frontend_urls.value | to_entries[] | "  \(.key): \(.value)"'
