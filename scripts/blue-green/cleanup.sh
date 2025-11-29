#!/bin/bash
# Cleanup - Remove old color containers
# Usage: cleanup.sh <service_name>

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

SERVICE_NAME="$1"

if [ -z "$SERVICE_NAME" ]; then
    print_error "Usage: cleanup.sh <service_name>"
    exit 1
fi

# Load service registry
REGISTRY=$(load_service_registry "$SERVICE_NAME")
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

# Load state - for statex service, get domain from registry
DOMAIN=""
if [ "$SERVICE_NAME" = "statex" ]; then
    REGISTRY=$(load_service_registry "$SERVICE_NAME")
    DOMAIN=$(echo "$REGISTRY" | jq -r '.domain // empty')
fi
STATE=$(load_state "$SERVICE_NAME" "$DOMAIN")
ACTIVE_COLOR=$(echo "$STATE" | jq -r '.active_color')

# Determine inactive color (the one to clean up)
if [ "$ACTIVE_COLOR" = "blue" ]; then
    INACTIVE_COLOR="green"
else
    INACTIVE_COLOR="blue"
fi

log_message "INFO" "$SERVICE_NAME" "$INACTIVE_COLOR" "cleanup" "Cleaning up inactive $INACTIVE_COLOR deployment"

# IMPORTANT: Infrastructure containers (postgres, redis) must NOT be stopped
# They are managed separately via docker-compose.infrastructure.yml
log_message "INFO" "$SERVICE_NAME" "$INACTIVE_COLOR" "cleanup" "Note: Infrastructure containers will NOT be stopped (managed separately)"

# Navigate to service directory
cd "$ACTUAL_PATH"

# Determine docker compose file
COMPOSE_FILE="docker-compose.${INACTIVE_COLOR}.yml"
PROJECT_NAME="${DOCKER_PROJECT_BASE}_${INACTIVE_COLOR}"

if [ ! -f "$COMPOSE_FILE" ]; then
    log_message "WARNING" "$SERVICE_NAME" "$INACTIVE_COLOR" "cleanup" "Docker compose file not found: $COMPOSE_FILE"
    exit 0
fi

# Stop and remove containers
log_message "INFO" "$SERVICE_NAME" "$INACTIVE_COLOR" "cleanup" "Stopping and removing $INACTIVE_COLOR containers"

if docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" down; then
    log_message "SUCCESS" "$SERVICE_NAME" "$INACTIVE_COLOR" "cleanup" "Stopped and removed $INACTIVE_COLOR containers"
else
    log_message "WARNING" "$SERVICE_NAME" "$INACTIVE_COLOR" "cleanup" "Some containers may not have been removed"
fi

# Optional: Remove images (commented out by default)
# log_message "INFO" "$SERVICE_NAME" "$INACTIVE_COLOR" "cleanup" "Removing $INACTIVE_COLOR images"
# docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" down --rmi all || true

# Update state
NEW_STATE=$(echo "$STATE" | jq --arg color "$INACTIVE_COLOR" \
    ".\"$INACTIVE_COLOR\".status = \"stopped\" | .\"$INACTIVE_COLOR\".deployed_at = null | .\"$INACTIVE_COLOR\".version = null")

save_state "$SERVICE_NAME" "$NEW_STATE" "$DOMAIN"

log_message "SUCCESS" "$SERVICE_NAME" "$INACTIVE_COLOR" "cleanup" "Cleanup of $INACTIVE_COLOR completed"

exit 0

