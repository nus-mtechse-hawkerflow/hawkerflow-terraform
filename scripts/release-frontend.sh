#!/usr/bin/env bash
set -euo pipefail

# Builds a frontend against this deployment and publishes it.
# The API address and Cognito IDs come from `terraform output`, so nothing
# deployment-specific has to be committed to the UI repositories.
#
# Usage:
#   ./scripts/release-frontend.sh <customer|hawker> <path_to_ui_repo>
#
# Examples:
#   ./scripts/release-frontend.sh customer ../diner-ui
#   ./scripts/release-frontend.sh hawker ../hawker-ui

APP_NAME="${1:-}"
UI_REPO="${2:-}"

if [[ -z "$APP_NAME" || -z "$UI_REPO" ]]; then
  echo "Usage: $0 <customer|hawker> <path_to_ui_repo>"
  exit 1
fi

if [[ ! -f "$UI_REPO/set-env.js" ]]; then
  echo "Error: '$UI_REPO' has no set-env.js; is it the right repository?"
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UI_REPO="$(cd "$UI_REPO" && pwd)"

echo "Reading Terraform outputs from $ROOT_DIR..."
OUTPUTS=$(terraform -chdir="$ROOT_DIR" output -json)
out() { echo "$OUTPUTS" | jq -r "$1 // empty"; }

API_URL=$(out '.api_url.value')
REGION=$(echo "$API_URL" | sed -E 's#.*execute-api\.([a-z0-9-]+)\.amazonaws\.com.*#\1#')

if [[ -z "$API_URL" ]]; then
  echo "Error: no api_url in the Terraform outputs. Run terraform init and check the backend."
  exit 1
fi

export AWS_REGION="$REGION"
export COGNITO_ENDPOINT="https://cognito-idp.$REGION.amazonaws.com"

case "$APP_NAME" in
  customer)
    DIST_DIR="dist/hawkerflow-diner-ui/browser"
    export COGNITO_USER_POOL_ID=$(out '.cognito_user_pool_ids.value.customer')
    export COGNITO_CLIENT_ID=$(out '.cognito_client_ids.value.customer')
    export HAWKER_STALLS_URL="$API_URL/hawker/v1/hawker/stalls"
    export ORDER_SUBMIT_URL="$API_URL/order/v1/order/orders"
    export ORDER_QUEUE_URL="$API_URL/order/v1/order/orders/queue"
    export CUSTOMER_REGISTER_URL="$API_URL/customer/v1/customer/register"
    export CUSTOMER_CHECK_ACCOUNT_URL="$API_URL/customer/v1/customer/check_account_exist"
    export CUSTOMER_USER_BASE_URL="$API_URL/customer/v1/customer/user"
    export CUSTOMER_UPDATE_ORDER_URL="$API_URL/customer/v1/customer/user/update_order"
    export ORDER_STATUS_TOPIC_ARN=$(out '.order_status_topic_arn.value')
    ;;
  hawker)
    DIST_DIR="dist/hawkerflow-ui/browser"
    export COGNITO_USER_POOL_ID=$(out '.cognito_user_pool_ids.value.hawker')
    export COGNITO_USER_POOL_CLIENT_ID=$(out '.cognito_client_ids.value.hawker')
    export HAWKER_API_URL="$API_URL/hawker"
    export ORDER_API_URL="$API_URL/order"
    export ANALYTICS_API_URL="$API_URL/analytics"
    ;;
  *)
    echo "Error: app must be 'customer' or 'hawker', not '$APP_NAME'."
    exit 1
    ;;
esac

if [[ -z "$COGNITO_USER_POOL_ID" || -z "$COGNITO_USER_POOL_CLIENT_ID" ]]; then
  echo "Error: no Cognito pool or client for '$APP_NAME' in the Terraform outputs."
  exit 1
fi

cd "$UI_REPO"

# set-env.js overwrites the tracked environment file; put it back afterwards so
# the deployment's values are never left behind to be committed by accident.
ENV_FILE="src/environments/environment.ts"
ENV_BACKUP="$(mktemp)"
cp "$ENV_FILE" "$ENV_BACKUP"
trap 'cp "$ENV_BACKUP" "$UI_REPO/$ENV_FILE"; rm -f "$ENV_BACKUP"' EXIT

if [[ ! -d node_modules ]]; then
  echo "Installing dependencies..."
  npm ci --legacy-peer-deps --no-audit --no-fund
fi

echo "Building '$APP_NAME' for $API_URL..."
node set-env.js
npx ng build --configuration production

bash "$ROOT_DIR/scripts/deploy-frontend.sh" "$APP_NAME" "$UI_REPO/$DIST_DIR"
