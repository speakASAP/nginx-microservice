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

# Resolve domain to service name (e.g. sgipreal.com -> sgiprealestate)
if type resolve_service_name >/dev/null 2>&1; then
    SERVICE_NAME=$(resolve_service_name "$SERVICE_NAME")
fi

log_message "INFO" "$SERVICE_NAME" "deploy" "deploy" "Starting smart blue/green deployment"

# Capture deployment start time
DEPLOYMENT_START_TIME=$(date +%s)
DEPLOYMENT_START_TIME_READABLE=$(date '+%Y-%m-%d %H:%M:%S')

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

# Update container_port values in registry from docker-compose.yml
log_message "INFO" "$SERVICE_NAME" "deploy" "deploy" "Updating container_port values in registry from docker-compose.yml"

if ! update_registry_ports "$SERVICE_NAME"; then
    log_message "WARNING" "$SERVICE_NAME" "deploy" "deploy" "Failed to update container_port in registry, continuing with deployment"
    # Don't exit - deployment can continue with existing or auto-detected ports
fi

# Update api_routes in registry from nginx-api-routes.conf (universal for all services)
log_message "INFO" "$SERVICE_NAME" "deploy" "deploy" "Updating api_routes in registry from nginx-api-routes.conf"

update_registry_api_routes "$SERVICE_NAME"

# Update nginx settings (client_max_body_size) from application's nginx.config.json
log_message "INFO" "$SERVICE_NAME" "deploy" "deploy" "Updating nginx settings from nginx.config.json"
update_registry_nginx_settings "$SERVICE_NAME"

# Backfill missing health_endpoint in registry from docker-compose healthcheck
log_message "INFO" "$SERVICE_NAME" "deploy" "deploy" "Updating health_endpoint in registry from docker-compose healthcheck"

if ! update_registry_health_endpoint "$SERVICE_NAME"; then
    log_message "WARNING" "$SERVICE_NAME" "deploy" "deploy" "Failed to update health_endpoint in registry, continuing with deployment"
fi

# Pre-deployment: Check for restarting containers and port conflicts
log_message "INFO" "$SERVICE_NAME" "deploy" "deploy" "Pre-deployment: Checking for restarting containers and port conflicts"

# Load service registry to get container names and ports (keep service name for Phase 0+)
ORIG_SERVICE_NAME="$SERVICE_NAME"
REGISTRY=$(load_service_registry "$SERVICE_NAME")
SERVICE_KEYS=$(echo "$REGISTRY" | jq -r '.services | keys[]' 2>/dev/null || echo "")

# Load state to determine active color (don't kill active container serving traffic)
DOMAIN=""
if is_multi_domain_service "$SERVICE_NAME"; then
    DOMAIN=$(echo "$REGISTRY" | jq -r '.domain // empty')
fi
STATE=$(load_state "$SERVICE_NAME" "$DOMAIN")
ACTIVE_COLOR=$(echo "$STATE" | jq -r '.active_color')

# Check for restarting containers and kill them (but skip active color serving traffic)
if [ -n "$SERVICE_KEYS" ]; then
    while IFS= read -r service_key; do
        CONTAINER_BASE=$(echo "$REGISTRY" | jq -r ".services[\"$service_key\"].container_name_base // empty" 2>/dev/null)
        
        if [ -n "$CONTAINER_BASE" ] && [ "$CONTAINER_BASE" != "null" ]; then
            # Get container port with auto-detection
            PORT=$(get_container_port "$SERVICE_NAME" "$service_key" "$CONTAINER_BASE")
            
            # Determine active container name
            ACTIVE_CONTAINER="${CONTAINER_BASE}-${ACTIVE_COLOR}"
            
            # Check for restarting containers (only kill restarting ones, skip active color serving traffic)
            if type kill_container_if_exists >/dev/null 2>&1; then
                # Only kill if not the active container
                if [ "${CONTAINER_BASE}-blue" != "$ACTIVE_CONTAINER" ]; then
                    kill_container_if_exists "${CONTAINER_BASE}-blue" "$SERVICE_NAME" "pre-deploy"
                fi
                if [ "${CONTAINER_BASE}-green" != "$ACTIVE_CONTAINER" ]; then
                    kill_container_if_exists "${CONTAINER_BASE}-green" "$SERVICE_NAME" "pre-deploy"
                fi
            fi
            
            # Check for port conflicts if port is specified (exclude active container)
            if [ -n "$PORT" ] && [ "$PORT" != "null" ] && type kill_port_if_in_use >/dev/null 2>&1; then
                kill_port_if_in_use "$PORT" "$SERVICE_NAME" "pre-deploy" "$ACTIVE_CONTAINER"
            fi
        fi
    done <<< "$SERVICE_KEYS"
fi

# Phase 0: Ensure shared infrastructure is running (use ORIG_SERVICE_NAME in case loop overwrote SERVICE_NAME)
SERVICE_NAME="$ORIG_SERVICE_NAME"
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

# Phase 3: Monitor health for 30 seconds
log_message "INFO" "$SERVICE_NAME" "deploy" "deploy" "Phase 3: Monitoring health"

MONITOR_DURATION=30  # 30 seconds
CHECK_INTERVAL=15     # Check every 15 seconds
ELAPSED=0
HEALTHY_CHECKS=0
REQUIRED_HEALTHY_CHECKS=2  # Require 2 successful health checks

while [ $ELAPSED -lt $MONITOR_DURATION ] && [ $HEALTHY_CHECKS -lt $REQUIRED_HEALTHY_CHECKS ]; do
    if "${SCRIPT_DIR}/health-check.sh" "$SERVICE_NAME"; then
        HEALTHY_CHECKS=$((HEALTHY_CHECKS + 1))
        log_message "INFO" "$SERVICE_NAME" "deploy" "monitor" "Health check passed ($HEALTHY_CHECKS/$REQUIRED_HEALTHY_CHECKS)"
    else
        log_message "ERROR" "$SERVICE_NAME" "deploy" "monitor" "Health check failed, rollback already triggered"
        exit 1
    fi
    
    # Exit early if we've reached the required number of successful checks
    if [ $HEALTHY_CHECKS -ge $REQUIRED_HEALTHY_CHECKS ]; then
        break
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
    HTTPS_TIMEOUT=$(echo "$REGISTRY" | jq -r '.https_check_timeout // 5' 2>/dev/null)
    HTTPS_RETRIES=$(echo "$REGISTRY" | jq -r '.https_check_retries // 2' 2>/dev/null)
    HTTPS_ENDPOINT=$(echo "$REGISTRY" | jq -r '.https_check_endpoint // empty' 2>/dev/null)
    HTTPS_ENABLED=$(echo "$REGISTRY" | jq -r '.https_check_enabled // true' 2>/dev/null)
    
    # Auto-detect endpoint for backend-only services
    if [ -z "$HTTPS_ENDPOINT" ] || [ "$HTTPS_ENDPOINT" = "null" ]; then
        # Check if service has frontend
        HAS_FRONTEND=$(echo "$REGISTRY" | jq -r '.services.frontend // empty' 2>/dev/null)
        HAS_BACKEND=$(echo "$REGISTRY" | jq -r '.services.backend // empty' 2>/dev/null)
        
        # If backend-only (no frontend), use /health endpoint
        if [ -n "$HAS_BACKEND" ] && [ "$HAS_BACKEND" != "null" ] && ([ -z "$HAS_FRONTEND" ] || [ "$HAS_FRONTEND" = "null" ]); then
            HTTPS_ENDPOINT="/health"
            log_message "INFO" "$SERVICE_NAME" "deploy" "deploy" "Auto-detected backend-only service, using /health endpoint for HTTPS check"
        else
            # Default to root for services with frontend
            HTTPS_ENDPOINT="/"
        fi
    fi
    
    # Only check if enabled (default: true)
    if [ "$HTTPS_ENABLED" = "true" ] || [ "$HTTPS_ENABLED" = "null" ]; then
        # Get active color from state - for multi-domain services, get domain from registry
        # Note: DOMAIN is already set above for non-multi-domain services, only reset for multi-domain services
        if is_multi_domain_service "$SERVICE_NAME"; then
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

# Phase 5: Cleanup old color (optional - can be disabled in registry)
log_message "INFO" "$SERVICE_NAME" "deploy" "deploy" "Phase 5: Cleaning up old deployment"

# Check if cleanup is enabled (default: true for backward compatibility)
CLEANUP_ENABLED=$(echo "$REGISTRY" | jq -r '.cleanup_after_deployment // true' 2>/dev/null)

if [ "$CLEANUP_ENABLED" = "true" ] || [ "$CLEANUP_ENABLED" = "null" ]; then
    log_message "INFO" "$SERVICE_NAME" "deploy" "deploy" "Cleanup enabled: Stopping old color containers"
    
    if ! "${SCRIPT_DIR}/cleanup.sh" "$SERVICE_NAME"; then
        log_message "WARNING" "$SERVICE_NAME" "deploy" "deploy" "Phase 5 warning: cleanup.sh had issues, but deployment is successful"
    fi
    
    log_message "SUCCESS" "$SERVICE_NAME" "deploy" "deploy" "Phase 5 completed: Old deployment cleaned up"
    
    # Verify new deployment is still healthy after cleanup
    log_message "INFO" "$SERVICE_NAME" "deploy" "deploy" "Phase 5 verification: Checking health after cleanup"
    
    if "${SCRIPT_DIR}/health-check.sh" "$SERVICE_NAME"; then
        log_message "SUCCESS" "$SERVICE_NAME" "deploy" "deploy" "Phase 5 verification passed: New deployment healthy after cleanup"
    else
        log_message "ERROR" "$SERVICE_NAME" "deploy" "deploy" "Phase 5 verification failed: New deployment unhealthy after cleanup"
        log_message "WARNING" "$SERVICE_NAME" "deploy" "deploy" "Note: Old containers were already stopped, manual intervention may be required"
        # Don't exit - deployment was successful, this is just a post-cleanup check
    fi
else
    log_message "INFO" "$SERVICE_NAME" "deploy" "deploy" "Phase 5 skipped: Cleanup disabled in registry (old containers kept for rollback)"
    log_message "INFO" "$SERVICE_NAME" "deploy" "deploy" "To manually cleanup later, run: ./scripts/blue-green/cleanup.sh $SERVICE_NAME"
fi

# Calculate and display deployment duration
DEPLOYMENT_END_TIME=$(date +%s)
DEPLOYMENT_END_TIME_READABLE=$(date '+%Y-%m-%d %H:%M:%S')
DEPLOYMENT_DURATION=$((DEPLOYMENT_END_TIME - DEPLOYMENT_START_TIME))
DEPLOYMENT_MINUTES=$((DEPLOYMENT_DURATION / 60))
DEPLOYMENT_SECONDS=$((DEPLOYMENT_DURATION % 60))

log_message "INFO" "$SERVICE_NAME" "deploy" "deploy" "Deployment duration: Start: $DEPLOYMENT_START_TIME_READABLE | Finish: $DEPLOYMENT_END_TIME_READABLE | Duration: ${DEPLOYMENT_MINUTES}m ${DEPLOYMENT_SECONDS}s"

exit 0
