#!/usr/bin/env bash
set -euo pipefail

# Parks the deployment to save cost while nobody is using it.
# Stalls, orders, accounts and the site and API addresses are all kept.
#
#   - ECS services go to zero tasks and the interface VPC endpoints are
#     removed (terraform apply -var paused=true)
#   - the database and the bastion host are stopped
#
# The load balancer and the database's disk still bill, about US$0.70 a day.
# AWS restarts a stopped database by itself after 7 days: run this again if
# the pause lasts longer.
#
# Bring everything back with ./scripts/resume.sh
#
# Usage:
#   ./scripts/pause.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "Reading Terraform outputs from $ROOT_DIR..."
OUTPUTS=$(terraform -chdir="$ROOT_DIR" output -json)
CLUSTER=$(echo "$OUTPUTS" | jq -r '.ecs_cluster_name.value // empty')
BASTION_ID=$(echo "$OUTPUTS" | jq -r '.bastion_instance_id.value // empty')
API_URL=$(echo "$OUTPUTS" | jq -r '.api_url.value // empty')

if [[ -z "$CLUSTER" ]]; then
  echo "Error: no ecs_cluster_name in the Terraform outputs. Run terraform init and check the backend."
  exit 1
fi

REGION=$(echo "$API_URL" | sed -E 's#.*execute-api\.([a-z0-9-]+)\.amazonaws\.com.*#\1#')
# The cluster is "<name>-cluster" and the database is "<name>-postgres"
DB_ID="${CLUSTER%-cluster}-postgres"

echo "Scaling services to zero and removing the interface VPC endpoints..."
terraform -chdir="$ROOT_DIR" apply -var paused=true

DB_STATUS=$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$DB_ID" \
  --query 'DBInstances[0].DBInstanceStatus' --output text)
if [[ "$DB_STATUS" == "available" ]]; then
  echo "Stopping database $DB_ID..."
  aws rds stop-db-instance --region "$REGION" --db-instance-identifier "$DB_ID" \
    --query 'DBInstance.DBInstanceStatus' --output text
else
  echo "Database $DB_ID is '$DB_STATUS'; not stopping it."
fi

if [[ -n "$BASTION_ID" ]]; then
  echo "Stopping bastion $BASTION_ID..."
  aws ec2 stop-instances --region "$REGION" --instance-ids "$BASTION_ID" \
    --query 'StoppingInstances[0].CurrentState.Name' --output text
fi

echo
echo "Paused. The sites still load, but ordering and sign-up will not work until"
echo "someone runs ./scripts/resume.sh"
echo "While paused, do not run a plain 'terraform apply': it would start the"
echo "services again with the database still stopped."
