#!/bin/bash
# Rollback - Switch back to previous color
# Usage: rollback.sh <service_name>

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

SERVICE_NAME="$1"

if [ -z "$SERVICE_NAME" ]; then
    print_error "Usage: rollback.sh <service_name>"
    exit 1
fi

# Load service registry
REGISTRY=$(load_service_registry "$SERVICE_NAME")
DOMAIN=$(echo "$REGISTRY" | jq -r '.domain')
DOCKER_PROJECT_BASE=$(echo "$REGISTRY" | jq -r '.docker_project_base')
SERVICE_PATH=$(echo "$REGISTRY" | jq -r '.service_path')
PRODUCTION_PATH=$(echo "$REGISTRY" | jq -r '.production_path')

# Determine actual path
if [ -d "$PRODUCTION_PATH" ]; then
    ACTUAL_PATH="$PRODUCTION_PATH"
elif [ -d "$SERVICE_PATH" ]; then
    ACTUAL_PATH="$SERVICE_PATH"
else
    print_error "Service path not found: $SERVICE_PATH or $PRODUCTION_PATH"
    exit 1
fi

# Load state
STATE=$(load_state "$SERVICE_NAME")
ACTIVE_COLOR=$(echo "$STATE" | jq -r '.active_color')

# Determine previous color (rollback to opposite)
if [ "$ACTIVE_COLOR" = "blue" ]; then
    PREVIOUS_COLOR="green"
    FAILED_COLOR="green"
else
    PREVIOUS_COLOR="blue"
    FAILED_COLOR="blue"
fi

log_message "WARNING" "$SERVICE_NAME" "$PREVIOUS_COLOR" "rollback" "Rolling back from $ACTIVE_COLOR to $PREVIOUS_COLOR"

# Determine nginx config file
NGINX_CONF_DIR="${NGINX_PROJECT_DIR}/nginx/conf.d"
CONFIG_FILE="${NGINX_CONF_DIR}/${DOMAIN}.conf"

if [ ! -f "$CONFIG_FILE" ]; then
    print_error "Nginx config file not found: $CONFIG_FILE"
    exit 1
fi

# Update nginx upstream blocks to previous color
log_message "INFO" "$SERVICE_NAME" "$PREVIOUS_COLOR" "rollback" "Updating nginx configuration to $PREVIOUS_COLOR"

if ! update_nginx_upstream "$CONFIG_FILE" "$SERVICE_NAME" "$PREVIOUS_COLOR"; then
    log_message "ERROR" "$SERVICE_NAME" "$PREVIOUS_COLOR" "rollback" "Failed to update nginx configuration"
    exit 1
fi

# Test nginx config
log_message "INFO" "$SERVICE_NAME" "$PREVIOUS_COLOR" "rollback" "Testing nginx configuration"

if ! test_nginx_config; then
    log_message "ERROR" "$SERVICE_NAME" "$PREVIOUS_COLOR" "rollback" "Nginx configuration test failed"
    exit 1
fi

# Reload nginx
log_message "INFO" "$SERVICE_NAME" "$PREVIOUS_COLOR" "rollback" "Reloading nginx"

if ! reload_nginx; then
    log_message "ERROR" "$SERVICE_NAME" "$PREVIOUS_COLOR" "rollback" "Failed to reload nginx"
    exit 1
fi

# Stop failed color containers
log_message "INFO" "$SERVICE_NAME" "$FAILED_COLOR" "rollback" "Stopping failed $FAILED_COLOR containers"

cd "$ACTUAL_PATH"
COMPOSE_FILE="docker-compose.${FAILED_COLOR}.yml"
PROJECT_NAME="${DOCKER_PROJECT_BASE}_${FAILED_COLOR}"

if [ -f "$COMPOSE_FILE" ]; then
    docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" down || true
    log_message "INFO" "$SERVICE_NAME" "$FAILED_COLOR" "rollback" "Stopped $FAILED_COLOR containers"
fi

# Update state
NEW_STATE=$(echo "$STATE" | jq --arg prev_color "$PREVIOUS_COLOR" --arg failed_color "$FAILED_COLOR" --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    ".active_color = \$prev_color | .\"$PREVIOUS_COLOR\".status = \"running\" | .\"$FAILED_COLOR\".status = \"stopped\" | .last_deployment.color = \$prev_color | .last_deployment.timestamp = \$timestamp | .last_deployment.success = false")

save_state "$SERVICE_NAME" "$NEW_STATE"

log_message "SUCCESS" "$SERVICE_NAME" "$PREVIOUS_COLOR" "rollback" "Rollback to $PREVIOUS_COLOR completed successfully"

exit 0

