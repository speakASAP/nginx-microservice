#!/bin/bash
# Health Check - Check service health with auto-rollback
# Usage: health-check.sh <service_name>

set -e

# Save the script's directory before sourcing utils.sh (which may overwrite SCRIPT_DIR)
HEALTH_CHECK_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$HEALTH_CHECK_SCRIPT_DIR"
source "${SCRIPT_DIR}/utils.sh"
# Restore SCRIPT_DIR after sourcing utils.sh (in case it was overwritten)
SCRIPT_DIR="$HEALTH_CHECK_SCRIPT_DIR"

SERVICE_NAME="$1"

if [ -z "$SERVICE_NAME" ]; then
    print_error "Usage: health-check.sh <service_name>"
    exit 1
fi

# Load service registry
REGISTRY=$(load_service_registry "$SERVICE_NAME")

# Load state - for statex service, get domain from registry
DOMAIN=""
if [ "$SERVICE_NAME" = "statex" ]; then
    REGISTRY=$(load_service_registry "$SERVICE_NAME")
    DOMAIN=$(echo "$REGISTRY" | jq -r '.domain // empty')
fi
STATE=$(load_state "$SERVICE_NAME" "$DOMAIN")
ACTIVE_COLOR=$(echo "$STATE" | jq -r '.active_color')

log_message "INFO" "$SERVICE_NAME" "$ACTIVE_COLOR" "health-check" "Checking health of $ACTIVE_COLOR deployment"

# Health check function
check_health() {
    local container_name="$1"
    local port="$2"
    local endpoint="$3"
    local timeout="${4:-5}"
    local retries="${5:-3}"
    
    # Validate inputs
    if [ -z "$container_name" ] || [ "$container_name" = "null" ] || [ -z "$port" ] || [ "$port" = "null" ] || [ -z "$endpoint" ] || [ "$endpoint" = "null" ]; then
        return 1
    fi
    
    # Ensure timeout and retries are numeric
    if ! [[ "$timeout" =~ ^[0-9]+$ ]]; then
        timeout=5
    fi
    if ! [[ "$retries" =~ ^[0-9]+$ ]]; then
        retries=3
    fi
    
    local network_name="${NETWORK_NAME:-nginx-network}"
    local health_check_image="${HEALTH_CHECK_IMAGE:-alpine/curl:latest}"
    
    # Verify container is running
    if ! docker ps --format "{{.Names}}" | grep -qE "^${container_name}$"; then
        # Try to find container with similar name pattern
        local found_container=$(docker ps --format "{{.Names}}" | grep -E "${container_name}" | head -1 || echo "")
        if [ -n "$found_container" ]; then
            log_message "WARNING" "$SERVICE_NAME" "$ACTIVE_COLOR" "health-check" "Container $container_name not found, using $found_container instead"
            container_name="$found_container"
        else
            log_message "ERROR" "$SERVICE_NAME" "$ACTIVE_COLOR" "health-check" "Container $container_name is not running"
            return 1
        fi
    fi
    
    # Verify container is on the network with retry logic
    # First, wait for container to stabilize (not restarting)
    local stability_wait=0
    local max_stability_wait=30  # Wait up to 30 seconds for container to stabilize
    local stability_check_interval=2
    
    while [ $stability_wait -lt $max_stability_wait ]; do
        local container_status=$(docker ps --filter "name=${container_name}" --format "{{.Status}}" 2>/dev/null || echo "unknown")
        if echo "$container_status" | grep -qE "(Restarting|starting)"; then
            if [ $stability_wait -eq 0 ]; then
                log_message "WARNING" "$SERVICE_NAME" "$ACTIVE_COLOR" "health-check" "Container $container_name is in unstable state: $container_status, waiting for it to stabilize..."
            fi
            sleep $stability_check_interval
            stability_wait=$((stability_wait + stability_check_interval))
            continue
        else
            # Container is stable (not restarting)
            if [ $stability_wait -gt 0 ]; then
                log_message "INFO" "$SERVICE_NAME" "$ACTIVE_COLOR" "health-check" "Container $container_name stabilized after ${stability_wait}s"
            fi
            break
        fi
    done
    
    # Check if container is still restarting after waiting
    local container_status=$(docker ps --filter "name=${container_name}" --format "{{.Status}}" 2>/dev/null || echo "unknown")
    if echo "$container_status" | grep -qE "(Restarting|starting)"; then
        log_message "ERROR" "$SERVICE_NAME" "$ACTIVE_COLOR" "health-check" "Container $container_name is still restarting after ${max_stability_wait}s - checking logs..."
        # Show last 10 lines of logs to help diagnose
        local container_logs=$(docker logs --tail 10 "$container_name" 2>&1 | head -10 || echo "Could not retrieve logs")
        log_message "INFO" "$SERVICE_NAME" "$ACTIVE_COLOR" "health-check" "Container logs (last 10 lines): ${container_logs}"
        return 1
    fi
    
    # Now attempt network connection with retry logic
    local network_retry=0
    local max_network_retries=3
    local network_connected=false
    
    while [ $network_retry -lt $max_network_retries ]; do
        
        # Check if container is on network
        if docker network inspect "${network_name}" --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null | grep -qE "(^| )${container_name}( |$)"; then
            network_connected=true
            break
        fi
        
        # Try to connect container to network
        if [ $network_retry -eq 0 ]; then
            log_message "WARNING" "$SERVICE_NAME" "$ACTIVE_COLOR" "health-check" "Container $container_name is not on network ${network_name}, attempting to connect..."
        fi
        
        local connect_error=""
        if connect_error=$(docker network connect "${network_name}" "${container_name}" 2>&1); then
            log_message "INFO" "$SERVICE_NAME" "$ACTIVE_COLOR" "health-check" "Connected $container_name to ${network_name}"
            sleep 1
            # Verify connection was successful
            if docker network inspect "${network_name}" --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null | grep -qE "(^| )${container_name}( |$)"; then
                network_connected=true
                break
            fi
        else
            if [ $network_retry -eq $((max_network_retries - 1)) ]; then
                log_message "ERROR" "$SERVICE_NAME" "$ACTIVE_COLOR" "health-check" "Failed to connect $container_name to ${network_name} after $max_network_retries attempts: ${connect_error}"
            else
                log_message "WARNING" "$SERVICE_NAME" "$ACTIVE_COLOR" "health-check" "Network connection attempt $((network_retry + 1))/$max_network_retries failed: ${connect_error}, retrying..."
            fi
        fi
        
        network_retry=$((network_retry + 1))
        if [ $network_retry -lt $max_network_retries ]; then
            sleep 2
        fi
    done
    
    if [ "$network_connected" = "false" ]; then
        log_message "ERROR" "$SERVICE_NAME" "$ACTIVE_COLOR" "health-check" "Container $container_name could not be connected to ${network_name} after $max_network_retries attempts"
        return 1
    fi
    
    local attempt=0
    while [ $attempt -lt $retries ]; do
        attempt=$((attempt + 1))
        
        # Try network-based health check first
        if docker run --rm --network "${network_name}" "${health_check_image}" \
            curl -s -f --max-time "$timeout" "http://${container_name}:${port}${endpoint}" >/dev/null 2>&1; then
            return 0
        fi
        
        # Fallback: try direct exec if network check fails
        if docker exec "${container_name}" sh -c "command -v curl >/dev/null 2>&1" 2>/dev/null; then
            if docker exec "${container_name}" curl -s -f --max-time "$timeout" "http://localhost:${port}${endpoint}" >/dev/null 2>&1; then
                log_message "INFO" "$SERVICE_NAME" "$ACTIVE_COLOR" "health-check" "Health check passed via direct exec (network check may have failed)"
                return 0
            fi
        fi
        
        if [ $attempt -lt $retries ]; then
            sleep 1
        fi
    done
    
    # Log detailed error information on final failure
    local container_status=$(docker ps --filter "name=${container_name}" --format "{{.Status}}" 2>/dev/null || echo "unknown")
    log_message "ERROR" "$SERVICE_NAME" "$ACTIVE_COLOR" "health-check" "Health check failed after $retries attempts for $container_name:$port${endpoint} (status: $container_status)"
    return 1
}

# Get all service keys from the registry
SERVICE_KEYS=$(echo "$REGISTRY" | jq -r '.services | keys[]' 2>/dev/null || echo "")

if [ -z "$SERVICE_KEYS" ]; then
    log_message "ERROR" "$SERVICE_NAME" "$ACTIVE_COLOR" "health-check" "No services found in registry"
    exit 1
fi

HEALTHY_COUNT=0
TOTAL_COUNT=0
HEALTHY_SERVICES=()

# Check each service in the registry
while IFS= read -r service_key; do
    # Get service configuration
    CONTAINER_BASE=$(echo "$REGISTRY" | jq -r ".services[\"$service_key\"].container_name_base // empty" 2>/dev/null)
    HEALTH_ENDPOINT=$(echo "$REGISTRY" | jq -r ".services[\"$service_key\"].health_endpoint // empty" 2>/dev/null)
    HEALTH_TIMEOUT=$(echo "$REGISTRY" | jq -r ".services[\"$service_key\"].health_timeout // 5" 2>/dev/null)
    HEALTH_RETRIES=$(echo "$REGISTRY" | jq -r ".services[\"$service_key\"].health_retries // 3" 2>/dev/null)
    
    # Skip if container_base is missing
    if [ -z "$CONTAINER_BASE" ] || [ "$CONTAINER_BASE" = "null" ]; then
        log_message "WARNING" "$SERVICE_NAME" "$ACTIVE_COLOR" "health-check" "Skipping $service_key: missing container_name_base"
        continue
    fi
    
    # Get container port with auto-detection
    PORT=$(get_container_port "$SERVICE_NAME" "$service_key" "$CONTAINER_BASE" "$SERVICE_NAME" "$ACTIVE_COLOR" "health-check")
    
    # Skip if port still missing after auto-detection
    if [ -z "$PORT" ] || [ "$PORT" = "null" ]; then
        log_message "WARNING" "$SERVICE_NAME" "$ACTIVE_COLOR" "health-check" "Skipping $service_key: container_port not found in registry and could not be auto-detected"
        continue
    fi
    
    # Skip if health endpoint is missing
    if [ -z "$HEALTH_ENDPOINT" ] || [ "$HEALTH_ENDPOINT" = "null" ]; then
        log_message "WARNING" "$SERVICE_NAME" "$ACTIVE_COLOR" "health-check" "Skipping $service_key: missing health_endpoint"
        continue
    fi
    
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    
    # Determine container name - check if service uses color suffix or single container
    CONTAINER_NAME="${CONTAINER_BASE}-${ACTIVE_COLOR}"
    
    # Check if container exists with color suffix
    if ! docker ps --format "{{.Names}}" | grep -qE "^${CONTAINER_NAME}$"; then
        # Try without color suffix
        if docker ps --format "{{.Names}}" | grep -qE "^${CONTAINER_BASE}$"; then
            CONTAINER_NAME="${CONTAINER_BASE}"
        else
            # Try to find container with similar name pattern (handles cases where container name might differ)
            found_container=$(docker ps --format "{{.Names}}" | grep -E "^${CONTAINER_BASE}(-${ACTIVE_COLOR})?$" | head -1 || echo "")
            if [ -n "$found_container" ]; then
                log_message "INFO" "$SERVICE_NAME" "$ACTIVE_COLOR" "health-check" "Container ${CONTAINER_NAME} not found, using $found_container instead"
                CONTAINER_NAME="$found_container"
            else
                log_message "WARNING" "$SERVICE_NAME" "$ACTIVE_COLOR" "health-check" "Container ${CONTAINER_NAME} not found, will attempt health check anyway"
            fi
        fi
    fi
    
    log_message "INFO" "$SERVICE_NAME" "$ACTIVE_COLOR" "health-check" "Checking $service_key: $CONTAINER_NAME:$PORT$HEALTH_ENDPOINT"

    if check_health "$CONTAINER_NAME" "$PORT" "$HEALTH_ENDPOINT" "$HEALTH_TIMEOUT" "$HEALTH_RETRIES"; then
        HEALTHY_COUNT=$((HEALTHY_COUNT + 1))
        HEALTHY_SERVICES+=("$service_key")
        log_message "SUCCESS" "$SERVICE_NAME" "$ACTIVE_COLOR" "health-check" "$service_key health check passed"
else
        log_message "ERROR" "$SERVICE_NAME" "$ACTIVE_COLOR" "health-check" "$service_key health check failed"
fi
done <<< "$SERVICE_KEYS"

# If at least one service is healthy, consider it successful
if [ $HEALTHY_COUNT -gt 0 ]; then
    log_message "SUCCESS" "$SERVICE_NAME" "$ACTIVE_COLOR" "health-check" "$HEALTHY_COUNT/$TOTAL_COUNT services healthy: ${HEALTHY_SERVICES[*]}"
    
    # Check HTTPS URL availability if domain is configured
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
            else
                # Default to root for services with frontend
                HTTPS_ENDPOINT="/"
            fi
        fi
        
        # Only check if enabled (default: true)
        if [ "$HTTPS_ENABLED" = "true" ] || [ "$HTTPS_ENABLED" = "null" ]; then
            if check_https_url "$DOMAIN" "$HTTPS_TIMEOUT" "$HTTPS_RETRIES" "$HTTPS_ENDPOINT" "$SERVICE_NAME" "$ACTIVE_COLOR"; then
                log_message "SUCCESS" "$SERVICE_NAME" "$ACTIVE_COLOR" "health-check" "HTTPS URL check passed: https://${DOMAIN}${HTTPS_ENDPOINT}"
            else
                log_message "WARNING" "$SERVICE_NAME" "$ACTIVE_COLOR" "health-check" "HTTPS URL check failed: https://${DOMAIN}${HTTPS_ENDPOINT} (internal checks passed)"
            fi
        fi
    else
        log_message "INFO" "$SERVICE_NAME" "$ACTIVE_COLOR" "health-check" "No domain configured in registry, skipping HTTPS URL check"
    fi
    
    exit 0
fi

# All health checks failed - trigger rollback
log_message "ERROR" "$SERVICE_NAME" "$ACTIVE_COLOR" "health-check" "All health checks failed ($TOTAL_COUNT services), triggering rollback"

# Call rollback script
"${SCRIPT_DIR}/rollback.sh" "$SERVICE_NAME"

exit 1
