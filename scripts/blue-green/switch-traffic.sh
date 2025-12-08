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

# Get domain from registry
DOMAIN=$(echo "$REGISTRY" | jq -r '.domain // empty')

# Validate domain is not empty
if [ -z "$DOMAIN" ] || [ "$DOMAIN" = "null" ]; then
    print_error "Domain not found in registry for service: $SERVICE_NAME"
    exit 1
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
# Ensure old_color is not empty to avoid creating empty keys
if [ -z "$ACTIVE_COLOR" ] || [ "$ACTIVE_COLOR" = "null" ]; then
    ACTIVE_COLOR="blue"
fi

NEW_STATE=$(echo "$STATE" | jq --arg color "$NEW_COLOR" --arg old_color "$ACTIVE_COLOR" --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    ".active_color = \$color | .\"$NEW_COLOR\".status = \"running\" | (if .\"$old_color\" then .\"$old_color\".status = \"backup\" else . end) | .last_deployment.color = \$color | .last_deployment.timestamp = \$timestamp | .last_deployment.success = true")

save_state "$SERVICE_NAME" "$NEW_STATE" "$DOMAIN"

# Verify state was saved correctly
VERIFY_STATE=$(load_state "$SERVICE_NAME" "$DOMAIN")
VERIFY_COLOR=$(echo "$VERIFY_STATE" | jq -r '.active_color')
if [ "$VERIFY_COLOR" != "$NEW_COLOR" ]; then
    log_message "ERROR" "$SERVICE_NAME" "$NEW_COLOR" "switch" "State file verification failed: expected $NEW_COLOR but got $VERIFY_COLOR"
    exit 1
fi

log_message "SUCCESS" "$SERVICE_NAME" "$NEW_COLOR" "switch" "Traffic switched to $NEW_COLOR successfully"

exit 0

