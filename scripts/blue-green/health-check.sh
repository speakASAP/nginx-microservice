#!/bin/bash
# Health Check - Check service health with auto-rollback
# Usage: health-check.sh <service_name>

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

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
    local attempt=0
    while [ $attempt -lt $retries ]; do
        attempt=$((attempt + 1))
        if docker run --rm --network "${network_name}" "${health_check_image}" \
            curl -s -f --max-time "$timeout" "http://${container_name}:${port}${endpoint}" >/dev/null 2>&1; then
            return 0
        fi
        if [ $attempt -lt $retries ]; then
            sleep 1
        fi
    done
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
    
    # Check if single-container deployment exists (no color suffix)
    if ! docker ps --format "{{.Names}}" | grep -qE "^${CONTAINER_NAME}$"; then
        # Try without color suffix
        if docker ps --format "{{.Names}}" | grep -qE "^${CONTAINER_BASE}$"; then
            CONTAINER_NAME="${CONTAINER_BASE}"
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
        HTTPS_TIMEOUT=$(echo "$REGISTRY" | jq -r '.https_check_timeout // 10' 2>/dev/null)
        HTTPS_RETRIES=$(echo "$REGISTRY" | jq -r '.https_check_retries // 3' 2>/dev/null)
        HTTPS_ENDPOINT=$(echo "$REGISTRY" | jq -r '.https_check_endpoint // "/"' 2>/dev/null)
        HTTPS_ENABLED=$(echo "$REGISTRY" | jq -r '.https_check_enabled // true' 2>/dev/null)
        
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
