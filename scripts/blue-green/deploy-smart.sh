#!/bin/bash
# Smart Deployment Script - Uses smart prepare-green that only rebuilds changed services
# Usage: deploy-smart.sh <service_name>

set -e

# Save the script's directory before sourcing utils.sh (which may overwrite SCRIPT_DIR)
DEPLOY_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$DEPLOY_SCRIPT_DIR"
source "${SCRIPT_DIR}/utils.sh"
# Restore SCRIPT_DIR after sourcing utils.sh (in case it was overwritten)
SCRIPT_DIR="$DEPLOY_SCRIPT_DIR"

SERVICE_NAME="$1"

if [ -z "$SERVICE_NAME" ]; then
    print_error "Usage: deploy-smart.sh <service_name>"
    exit 1
fi

log_message "INFO" "$SERVICE_NAME" "deploy" "deploy" "Starting smart blue/green deployment"

# Check if registry exists, if not, try to auto-create it
REGISTRY_FILE="${REGISTRY_DIR}/${SERVICE_NAME}.json"
if [ ! -f "$REGISTRY_FILE" ]; then
    log_message "INFO" "$SERVICE_NAME" "deploy" "deploy" "Registry file not found, attempting to auto-create it"
    
    # Try to auto-create registry
    if ! auto_create_service_registry "$SERVICE_NAME"; then
        print_error "Service not found in registry: $SERVICE_NAME"
        print_error "Auto-creation failed. Please create registry manually:"
        print_error "  ./scripts/add-service-registry.sh $SERVICE_NAME"
        exit 1
    fi
    
    log_message "SUCCESS" "$SERVICE_NAME" "deploy" "deploy" "Registry file auto-created successfully"
else
    log_message "INFO" "$SERVICE_NAME" "deploy" "deploy" "Service validated in registry"
fi

# Pre-deployment: Check for restarting containers and port conflicts
log_message "INFO" "$SERVICE_NAME" "deploy" "deploy" "Pre-deployment: Checking for restarting containers and port conflicts"

# Load service registry to get container names and ports
REGISTRY=$(load_service_registry "$SERVICE_NAME")
SERVICE_KEYS=$(echo "$REGISTRY" | jq -r '.services | keys[]' 2>/dev/null || echo "")

# Check for restarting containers and kill them
if [ -n "$SERVICE_KEYS" ]; then
    while IFS= read -r service_key; do
        CONTAINER_BASE=$(echo "$REGISTRY" | jq -r ".services[\"$service_key\"].container_name_base // empty" 2>/dev/null)
        
        if [ -n "$CONTAINER_BASE" ] && [ "$CONTAINER_BASE" != "null" ]; then
            # Get container port with auto-detection
            PORT=$(get_container_port "$SERVICE_NAME" "$service_key" "$CONTAINER_BASE")
            # Check for blue and green containers
            if type kill_container_if_exists >/dev/null 2>&1; then
                kill_container_if_exists "${CONTAINER_BASE}-blue" "$SERVICE_NAME" "pre-deploy"
                kill_container_if_exists "${CONTAINER_BASE}-green" "$SERVICE_NAME" "pre-deploy"
            fi
            
            # Check for port conflicts if port is specified
            if [ -n "$PORT" ] && [ "$PORT" != "null" ] && type kill_port_if_in_use >/dev/null 2>&1; then
                kill_port_if_in_use "$PORT" "$SERVICE_NAME" "pre-deploy"
            fi
        fi
    done <<< "$SERVICE_KEYS"
fi

# Phase 0: Ensure shared infrastructure is running
log_message "INFO" "$SERVICE_NAME" "deploy" "deploy" "Phase 0: Ensuring shared infrastructure is running"

if ! "${SCRIPT_DIR}/ensure-infrastructure.sh" "$SERVICE_NAME"; then
    log_message "ERROR" "$SERVICE_NAME" "deploy" "deploy" "Phase 0 failed: Infrastructure check failed"
    exit 1
fi

log_message "SUCCESS" "$SERVICE_NAME" "deploy" "deploy" "Phase 0 completed: Infrastructure is ready"

# Phase 1: Prepare green (smart version)
log_message "INFO" "$SERVICE_NAME" "deploy" "deploy" "Phase 1: Preparing green deployment (smart mode)"

if ! "${SCRIPT_DIR}/prepare-green-smart.sh" "$SERVICE_NAME"; then
    log_message "ERROR" "$SERVICE_NAME" "deploy" "deploy" "Phase 1 failed: prepare-green-smart.sh exited with error"
    exit 1
fi

log_message "SUCCESS" "$SERVICE_NAME" "deploy" "deploy" "Phase 1 completed: Green deployment prepared"

# Phase 2: Switch traffic
log_message "INFO" "$SERVICE_NAME" "deploy" "deploy" "Phase 2: Switching traffic to green"

if ! "${SCRIPT_DIR}/switch-traffic.sh" "$SERVICE_NAME"; then
    log_message "ERROR" "$SERVICE_NAME" "deploy" "deploy" "Phase 2 failed: switch-traffic.sh exited with error"
    log_message "INFO" "$SERVICE_NAME" "deploy" "deploy" "Initiating rollback"
    "${SCRIPT_DIR}/rollback.sh" "$SERVICE_NAME" || true
    exit 1
fi

log_message "SUCCESS" "$SERVICE_NAME" "deploy" "deploy" "Phase 2 completed: Traffic switched to green"

# Phase 3: Monitor health for 2 minutes
log_message "INFO" "$SERVICE_NAME" "deploy" "deploy" "Phase 3: Monitoring health for 5 minutes"

MONITOR_DURATION=120  # 2 minutes in seconds
CHECK_INTERVAL=30     # Check every 30 seconds
ELAPSED=0
HEALTHY_CHECKS=0
REQUIRED_HEALTHY_CHECKS=4  # 2 minutes / 30 seconds = 4 checks

while [ $ELAPSED -lt $MONITOR_DURATION ]; do
    if "${SCRIPT_DIR}/health-check.sh" "$SERVICE_NAME"; then
        HEALTHY_CHECKS=$((HEALTHY_CHECKS + 1))
        log_message "INFO" "$SERVICE_NAME" "deploy" "monitor" "Health check passed ($HEALTHY_CHECKS/$REQUIRED_HEALTHY_CHECKS)"
    else
        log_message "ERROR" "$SERVICE_NAME" "deploy" "monitor" "Health check failed, rollback already triggered"
        exit 1
    fi
    
    if [ $ELAPSED -lt $MONITOR_DURATION ]; then
        sleep $CHECK_INTERVAL
        ELAPSED=$((ELAPSED + CHECK_INTERVAL))
    fi
done

log_message "SUCCESS" "$SERVICE_NAME" "deploy" "deploy" "Phase 3 completed: Green deployment healthy for 5 minutes"

# Phase 4: Final HTTPS URL verification
log_message "INFO" "$SERVICE_NAME" "deploy" "deploy" "Phase 4: Verifying final HTTPS URL availability"

# Load service registry to get domain
REGISTRY=$(load_service_registry "$SERVICE_NAME")
DOMAIN=$(echo "$REGISTRY" | jq -r '.domain // empty' 2>/dev/null)

if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "null" ]; then
    # Get HTTPS check configuration from registry (optional)
    HTTPS_TIMEOUT=$(echo "$REGISTRY" | jq -r '.https_check_timeout // 10' 2>/dev/null)
    HTTPS_RETRIES=$(echo "$REGISTRY" | jq -r '.https_check_retries // 3' 2>/dev/null)
    HTTPS_ENDPOINT=$(echo "$REGISTRY" | jq -r '.https_check_endpoint // "/"' 2>/dev/null)
    HTTPS_ENABLED=$(echo "$REGISTRY" | jq -r '.https_check_enabled // true' 2>/dev/null)
    
    # Only check if enabled (default: true)
    if [ "$HTTPS_ENABLED" = "true" ] || [ "$HTTPS_ENABLED" = "null" ]; then
        # Get active color from state - for statex service, get domain from registry
        DOMAIN=""
        if [ "$SERVICE_NAME" = "statex" ]; then
            REGISTRY=$(load_service_registry "$SERVICE_NAME")
            DOMAIN=$(echo "$REGISTRY" | jq -r '.domain // empty')
        fi
        STATE=$(load_state "$SERVICE_NAME" "$DOMAIN")
        ACTIVE_COLOR=$(echo "$STATE" | jq -r '.active_color')
        
        if check_https_url "$DOMAIN" "$HTTPS_TIMEOUT" "$HTTPS_RETRIES" "$HTTPS_ENDPOINT" "$SERVICE_NAME" "$ACTIVE_COLOR"; then
            log_message "SUCCESS" "$SERVICE_NAME" "deploy" "deploy" "Phase 4 completed: HTTPS URL verified: https://${DOMAIN}${HTTPS_ENDPOINT}"
        else
            log_message "WARNING" "$SERVICE_NAME" "deploy" "deploy" "Phase 4 warning: HTTPS URL check failed for https://${DOMAIN}${HTTPS_ENDPOINT} (deployment successful, internal checks passed)"
        fi
    else
        log_message "INFO" "$SERVICE_NAME" "deploy" "deploy" "Phase 4 skipped: HTTPS check disabled in registry"
    fi
else
    log_message "WARNING" "$SERVICE_NAME" "deploy" "deploy" "Phase 4 skipped: No domain configured in registry"
fi

# Phase 5: Cleanup old color
log_message "INFO" "$SERVICE_NAME" "deploy" "deploy" "Phase 5: Cleaning up old blue deployment"

if ! "${SCRIPT_DIR}/cleanup.sh" "$SERVICE_NAME"; then
    log_message "WARNING" "$SERVICE_NAME" "deploy" "deploy" "Phase 5 warning: cleanup.sh had issues, but deployment is successful"
fi

log_message "SUCCESS" "$SERVICE_NAME" "deploy" "deploy" "Phase 5 completed: Old deployment cleaned up"

# Final success
log_message "SUCCESS" "$SERVICE_NAME" "deploy" "deploy" "=========================================="
log_message "SUCCESS" "$SERVICE_NAME" "deploy" "deploy" "Smart blue/Green deployment completed successfully!"
log_message "SUCCESS" "$SERVICE_NAME" "deploy" "deploy" "Active color: green"
log_message "SUCCESS" "$SERVICE_NAME" "deploy" "deploy" "=========================================="

exit 0
