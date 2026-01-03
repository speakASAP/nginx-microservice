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

# Load state - for multi-domain services, get domain from registry
# For other services, get domain from registry
DOMAIN=""
if is_multi_domain_service "$SERVICE_NAME"; then
    # For multi-domain services, domain is in registry but we need to get it from state or use default
    DOMAIN=$(echo "$REGISTRY" | jq -r '.domain // empty')
else
    # For other services, get domain from registry
    DOMAIN=$(echo "$REGISTRY" | jq -r '.domain // empty')
fi

# Validate domain is not empty
if [ -z "$DOMAIN" ] || [ "$DOMAIN" = "null" ]; then
    print_error "Domain not found in registry for service: $SERVICE_NAME"
    exit 1
fi

STATE=$(load_state "$SERVICE_NAME" "$DOMAIN")
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

# Ensure blue and green configs exist
log_message "INFO" "$SERVICE_NAME" "$PREVIOUS_COLOR" "rollback" "Ensuring blue and green configs exist"

if ! ensure_blue_green_configs "$SERVICE_NAME" "$DOMAIN" "$PREVIOUS_COLOR"; then
    log_message "ERROR" "$SERVICE_NAME" "$PREVIOUS_COLOR" "rollback" "Failed to ensure configs exist"
    exit 1
fi

# Switch symlink to previous color
log_message "INFO" "$SERVICE_NAME" "$PREVIOUS_COLOR" "rollback" "Switching symlink to $PREVIOUS_COLOR config"

if ! switch_config_symlink "$DOMAIN" "$PREVIOUS_COLOR"; then
    log_message "ERROR" "$SERVICE_NAME" "$PREVIOUS_COLOR" "rollback" "Failed to switch symlink"
    exit 1
fi

# Test nginx config (per-service validation)
log_message "INFO" "$SERVICE_NAME" "$PREVIOUS_COLOR" "rollback" "Testing nginx configuration"

if ! test_service_nginx_config "$SERVICE_NAME"; then
    log_message "ERROR" "$SERVICE_NAME" "$PREVIOUS_COLOR" "rollback" "Nginx configuration test failed"
    exit 1
fi

# Reload nginx
log_message "INFO" "$SERVICE_NAME" "$PREVIOUS_COLOR" "rollback" "Reloading nginx"

if ! reload_nginx; then
    log_message "ERROR" "$SERVICE_NAME" "$PREVIOUS_COLOR" "rollback" "Failed to reload nginx"
    exit 1
fi

# Navigate to service directory
cd "$ACTUAL_PATH"

# Determine compose file for previous color (to restart it)
REGISTRY_COMPOSE_FILE=$(echo "$REGISTRY" | jq -r '.docker_compose_file')
if [ -z "$REGISTRY_COMPOSE_FILE" ] || [ "$REGISTRY_COMPOSE_FILE" = "null" ]; then
    PREVIOUS_COMPOSE_FILE="docker-compose.${SERVICE_NAME}.${PREVIOUS_COLOR}.yml"
else
    PREVIOUS_COMPOSE_FILE=$(echo "$REGISTRY_COMPOSE_FILE" | sed "s/\.\(blue\|green\)\.yml$/\.${PREVIOUS_COLOR}.yml/")
fi

# Fallback to generic docker-compose.yml if color-specific doesn't exist
if [ ! -f "$PREVIOUS_COMPOSE_FILE" ]; then
    if [ -f "docker-compose.yml" ]; then
        PREVIOUS_COMPOSE_FILE="docker-compose.yml"
    fi
fi

PREVIOUS_PROJECT_NAME="${DOCKER_PROJECT_BASE}_${PREVIOUS_COLOR}"

# Restart previous color containers (they may have been stopped during prepare phase)
if [ -f "$PREVIOUS_COMPOSE_FILE" ]; then
    log_message "INFO" "$SERVICE_NAME" "$PREVIOUS_COLOR" "rollback" "Restarting previous ${PREVIOUS_COLOR} containers"
    
    # Check if containers exist but are stopped
    if docker compose -f "$PREVIOUS_COMPOSE_FILE" -p "$PREVIOUS_PROJECT_NAME" ps -q 2>/dev/null | grep -q .; then
        # Containers exist, restart them
        docker compose -f "$PREVIOUS_COMPOSE_FILE" -p "$PREVIOUS_PROJECT_NAME" start 2>/dev/null || {
            # If start fails, try up -d (in case containers were removed)
            log_message "INFO" "$SERVICE_NAME" "$PREVIOUS_COLOR" "rollback" "Containers may have been removed, recreating them"
            docker compose -f "$PREVIOUS_COMPOSE_FILE" -p "$PREVIOUS_PROJECT_NAME" up -d 2>/dev/null || true
        }
        log_message "INFO" "$SERVICE_NAME" "$PREVIOUS_COLOR" "rollback" "Previous ${PREVIOUS_COLOR} containers restarted"
    else
        # Containers don't exist, create them
        log_message "INFO" "$SERVICE_NAME" "$PREVIOUS_COLOR" "rollback" "Previous ${PREVIOUS_COLOR} containers not found, creating them"
        docker compose -f "$PREVIOUS_COMPOSE_FILE" -p "$PREVIOUS_PROJECT_NAME" up -d 2>/dev/null || true
        log_message "INFO" "$SERVICE_NAME" "$PREVIOUS_COLOR" "rollback" "Previous ${PREVIOUS_COLOR} containers created"
    fi
else
    log_message "WARNING" "$SERVICE_NAME" "$PREVIOUS_COLOR" "rollback" "Previous compose file not found: $PREVIOUS_COMPOSE_FILE"
fi

# Stop failed color containers
log_message "INFO" "$SERVICE_NAME" "$FAILED_COLOR" "rollback" "Stopping failed $FAILED_COLOR containers"

FAILED_COMPOSE_FILE=""
if [ -n "$REGISTRY_COMPOSE_FILE" ] && [ "$REGISTRY_COMPOSE_FILE" != "null" ]; then
    FAILED_COMPOSE_FILE=$(echo "$REGISTRY_COMPOSE_FILE" | sed "s/\.\(blue\|green\)\.yml$/\.${FAILED_COLOR}.yml/")
else
    FAILED_COMPOSE_FILE="docker-compose.${SERVICE_NAME}.${FAILED_COLOR}.yml"
fi

# Fallback to generic docker-compose.yml if color-specific file doesn't exist
if [ ! -f "$FAILED_COMPOSE_FILE" ]; then
    if [ -f "docker-compose.yml" ]; then
        FAILED_COMPOSE_FILE="docker-compose.yml"
    fi
fi

FAILED_PROJECT_NAME="${DOCKER_PROJECT_BASE}_${FAILED_COLOR}"

if [ -f "$FAILED_COMPOSE_FILE" ]; then
    docker compose -f "$FAILED_COMPOSE_FILE" -p "$FAILED_PROJECT_NAME" down || true
    log_message "INFO" "$SERVICE_NAME" "$FAILED_COLOR" "rollback" "Stopped $FAILED_COLOR containers"
fi

# Update state
NEW_STATE=$(echo "$STATE" | jq --arg prev_color "$PREVIOUS_COLOR" --arg failed_color "$FAILED_COLOR" --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    ".active_color = \$prev_color | .\"$PREVIOUS_COLOR\".status = \"running\" | .\"$FAILED_COLOR\".status = \"stopped\" | .last_deployment.color = \$prev_color | .last_deployment.timestamp = \$timestamp | .last_deployment.success = false")

save_state "$SERVICE_NAME" "$NEW_STATE" "$DOMAIN"

log_message "SUCCESS" "$SERVICE_NAME" "$PREVIOUS_COLOR" "rollback" "Rollback to $PREVIOUS_COLOR completed successfully"

exit 0

