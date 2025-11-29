#!/bin/bash
# Switch Traffic - Instant switch to new color
# Usage: switch-traffic.sh <service_name>

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

SERVICE_NAME="$1"

if [ -z "$SERVICE_NAME" ]; then
    print_error "Usage: switch-traffic.sh <service_name>"
    exit 1
fi

# Load service registry
REGISTRY=$(load_service_registry "$SERVICE_NAME")
DOMAIN=$(echo "$REGISTRY" | jq -r '.domain')

# Load state - for statex service, get domain from registry
DOMAIN=$(echo "$REGISTRY" | jq -r '.domain // empty')
if [ "$SERVICE_NAME" = "statex" ]; then
    REGISTRY=$(load_service_registry "$SERVICE_NAME")
    DOMAIN=$(echo "$REGISTRY" | jq -r '.domain // empty')
fi
STATE=$(load_state "$SERVICE_NAME" "$DOMAIN")
ACTIVE_COLOR=$(echo "$STATE" | jq -r '.active_color')

# Determine new active color (switch to opposite)
if [ "$ACTIVE_COLOR" = "blue" ]; then
    NEW_COLOR="green"
else
    NEW_COLOR="blue"
fi

log_message "INFO" "$SERVICE_NAME" "$NEW_COLOR" "switch" "Switching traffic from $ACTIVE_COLOR to $NEW_COLOR"

# Ensure blue and green configs exist
log_message "INFO" "$SERVICE_NAME" "$NEW_COLOR" "switch" "Ensuring blue and green configs exist"

if ! ensure_blue_green_configs "$SERVICE_NAME" "$DOMAIN" "$NEW_COLOR"; then
    log_message "ERROR" "$SERVICE_NAME" "$NEW_COLOR" "switch" "Failed to ensure configs exist"
    exit 1
fi

# Switch symlink to new color
log_message "INFO" "$SERVICE_NAME" "$NEW_COLOR" "switch" "Switching symlink to $NEW_COLOR config"

if ! switch_config_symlink "$DOMAIN" "$NEW_COLOR"; then
    log_message "ERROR" "$SERVICE_NAME" "$NEW_COLOR" "switch" "Failed to switch symlink"
    exit 1
fi

# Test nginx config (per-service validation)
log_message "INFO" "$SERVICE_NAME" "$NEW_COLOR" "switch" "Testing nginx configuration"

if ! test_service_nginx_config "$SERVICE_NAME"; then
    log_message "ERROR" "$SERVICE_NAME" "$NEW_COLOR" "switch" "Nginx configuration test failed, reverting symlink"
    # Revert symlink to previous color
    if switch_config_symlink "$DOMAIN" "$ACTIVE_COLOR"; then
        log_message "WARNING" "$SERVICE_NAME" "$NEW_COLOR" "switch" "Reverted symlink to $ACTIVE_COLOR"
    fi
    exit 1
fi

# Reload nginx
log_message "INFO" "$SERVICE_NAME" "$NEW_COLOR" "switch" "Reloading nginx"

if ! reload_nginx; then
    log_message "ERROR" "$SERVICE_NAME" "$NEW_COLOR" "switch" "Failed to reload nginx, reverting symlink"
    # Revert symlink to previous color
    if switch_config_symlink "$DOMAIN" "$ACTIVE_COLOR"; then
        reload_nginx
        log_message "WARNING" "$SERVICE_NAME" "$NEW_COLOR" "switch" "Reverted symlink to $ACTIVE_COLOR"
    fi
    exit 1
fi

# Update state
NEW_STATE=$(echo "$STATE" | jq --arg color "$NEW_COLOR" --arg old_color "$ACTIVE_COLOR" --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    ".active_color = \$color | .\"$NEW_COLOR\".status = \"running\" | .\"$old_color\".status = \"backup\" | .last_deployment.color = \$color | .last_deployment.timestamp = \$timestamp | .last_deployment.success = true")

save_state "$SERVICE_NAME" "$NEW_STATE" "$DOMAIN"

log_message "SUCCESS" "$SERVICE_NAME" "$NEW_COLOR" "switch" "Traffic switched to $NEW_COLOR successfully"

exit 0

