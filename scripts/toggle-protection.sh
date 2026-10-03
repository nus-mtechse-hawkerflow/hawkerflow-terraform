#!/usr/bin/env bash
set -euo pipefail

# Script to toggle lifecycle.prevent_destroy on stateful resources (Cognito, RDS)
# Usage:
#   ./scripts/toggle-protection.sh enable   # sets prevent_destroy = true
#   ./scripts/toggle-protection.sh disable  # sets prevent_destroy = false
#   ./scripts/toggle-protection.sh status   # inspects current settings

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COGNITO_FILE="$ROOT_DIR/modules/cognito/main.tf"
RDS_FILE="$ROOT_DIR/modules/rds/main.tf"

cmd="${1:-status}"

case "$cmd" in
  enable)
    echo "Enabling prevent_destroy on stateful resources..."
    sed -i '' 's/prevent_destroy = false/prevent_destroy = true/g' "$COGNITO_FILE" "$RDS_FILE"
    echo "Done. State:"
    grep -Hn "prevent_destroy" "$COGNITO_FILE" "$RDS_FILE"
    ;;
  disable)
    echo "Disabling prevent_destroy on stateful resources..."
    sed -i '' 's/prevent_destroy = true/prevent_destroy = false/g' "$COGNITO_FILE" "$RDS_FILE"
    echo "Done. State:"
    grep -Hn "prevent_destroy" "$COGNITO_FILE" "$RDS_FILE"
    ;;
  status)
    echo "Current prevent_destroy settings:"
    grep -Hn "prevent_destroy" "$COGNITO_FILE" "$RDS_FILE" || echo "None found"
    ;;
  *)
    echo "Usage: $0 {enable|disable|status}"
    exit 1
    ;;
esac
