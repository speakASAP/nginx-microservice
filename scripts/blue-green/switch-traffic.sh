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

# Load state
STATE=$(load_state "$SERVICE_NAME")
ACTIVE_COLOR=$(echo "$STATE" | jq -r '.active_color')

# Determine new active color (switch to opposite)
if [ "$ACTIVE_COLOR" = "blue" ]; then
    NEW_COLOR="green"
else
    NEW_COLOR="blue"
fi

log_message "INFO" "$SERVICE_NAME" "$NEW_COLOR" "switch" "Switching traffic from $ACTIVE_COLOR to $NEW_COLOR"

# Determine nginx config file
NGINX_CONF_DIR="${NGINX_PROJECT_DIR}/nginx/conf.d"
CONFIG_FILE="${NGINX_CONF_DIR}/${DOMAIN}.conf"

if [ ! -f "$CONFIG_FILE" ]; then
    print_error "Nginx config file not found: $CONFIG_FILE"
    exit 1
fi

# Update nginx upstream blocks
log_message "INFO" "$SERVICE_NAME" "$NEW_COLOR" "switch" "Updating nginx upstream configuration"

if ! update_nginx_upstream "$CONFIG_FILE" "$SERVICE_NAME" "$NEW_COLOR"; then
    log_message "ERROR" "$SERVICE_NAME" "$NEW_COLOR" "switch" "Failed to update nginx configuration"
    exit 1
fi

# Test nginx config
log_message "INFO" "$SERVICE_NAME" "$NEW_COLOR" "switch" "Testing nginx configuration"

if ! test_nginx_config; then
    log_message "ERROR" "$SERVICE_NAME" "$NEW_COLOR" "switch" "Nginx configuration test failed, reverting changes"
    # Restore backup if exists
    BACKUP_FILE=$(ls -t "${CONFIG_FILE}.backup."* 2>/dev/null | head -1)
    if [ -n "$BACKUP_FILE" ]; then
        cp "$BACKUP_FILE" "$CONFIG_FILE"
        log_message "WARNING" "$SERVICE_NAME" "$NEW_COLOR" "switch" "Reverted to previous configuration"
    fi
    exit 1
fi

# Reload nginx
log_message "INFO" "$SERVICE_NAME" "$NEW_COLOR" "switch" "Reloading nginx"

if ! reload_nginx; then
    log_message "ERROR" "$SERVICE_NAME" "$NEW_COLOR" "switch" "Failed to reload nginx, reverting changes"
    # Restore backup if exists
    BACKUP_FILE=$(ls -t "${CONFIG_FILE}.backup."* 2>/dev/null | head -1)
    if [ -n "$BACKUP_FILE" ]; then
        cp "$BACKUP_FILE" "$CONFIG_FILE"
        reload_nginx
        log_message "WARNING" "$SERVICE_NAME" "$NEW_COLOR" "switch" "Reverted to previous configuration"
    fi
    exit 1
fi

# Update state
NEW_STATE=$(echo "$STATE" | jq --arg color "$NEW_COLOR" --arg old_color "$ACTIVE_COLOR" --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    ".active_color = \$color | .\"$NEW_COLOR\".status = \"running\" | .\"$old_color\".status = \"backup\" | .last_deployment.color = \$color | .last_deployment.timestamp = \$timestamp | .last_deployment.success = true")

save_state "$SERVICE_NAME" "$NEW_STATE"

log_message "SUCCESS" "$SERVICE_NAME" "$NEW_COLOR" "switch" "Traffic switched to $NEW_COLOR successfully"

exit 0

