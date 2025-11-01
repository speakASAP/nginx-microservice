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

# Load state
STATE=$(load_state "$SERVICE_NAME")
ACTIVE_COLOR=$(echo "$STATE" | jq -r '.active_color')

log_message "INFO" "$SERVICE_NAME" "$ACTIVE_COLOR" "health-check" "Checking health of $ACTIVE_COLOR deployment"

# Get service info
BACKEND_CONTAINER=$(echo "$REGISTRY" | jq -r ".services.backend.container_name_base")-${ACTIVE_COLOR}
FRONTEND_CONTAINER=$(echo "$REGISTRY" | jq -r ".services.frontend.container_name_base")-${ACTIVE_COLOR}
BACKEND_PORT=$(echo "$REGISTRY" | jq -r '.services.backend.port')
FRONTEND_PORT=$(echo "$REGISTRY" | jq -r '.services.frontend.port')
BACKEND_HEALTH=$(echo "$REGISTRY" | jq -r '.services.backend.health_endpoint')
FRONTEND_HEALTH=$(echo "$REGISTRY" | jq -r '.services.frontend.health_endpoint')
BACKEND_TIMEOUT=$(echo "$REGISTRY" | jq -r '.services.backend.health_timeout')
FRONTEND_TIMEOUT=$(echo "$REGISTRY" | jq -r '.services.frontend.health_timeout')
BACKEND_RETRIES=$(echo "$REGISTRY" | jq -r '.services.backend.health_retries')
FRONTEND_RETRIES=$(echo "$REGISTRY" | jq -r '.services.frontend.health_retries')

# Health check function
check_health() {
    local container_name="$1"
    local port="$2"
    local endpoint="$3"
    local timeout="$4"
    local retries="$5"
    
    local attempt=0
    while [ $attempt -lt $retries ]; do
        attempt=$((attempt + 1))
        if docker run --rm --network nginx-network alpine/curl:latest \
            curl -s -f --max-time "$timeout" "http://${container_name}:${port}${endpoint}" >/dev/null 2>&1; then
            return 0
        fi
        if [ $attempt -lt $retries ]; then
            sleep 2
        fi
    done
    return 1
}

BACKEND_HEALTHY=false
FRONTEND_HEALTHY=false

# Check backend health
log_message "INFO" "$SERVICE_NAME" "$ACTIVE_COLOR" "health-check" "Checking backend: $BACKEND_CONTAINER:$BACKEND_PORT$BACKEND_HEALTH"

if check_health "$BACKEND_CONTAINER" "$BACKEND_PORT" "$BACKEND_HEALTH" "$BACKEND_TIMEOUT" "$BACKEND_RETRIES"; then
    BACKEND_HEALTHY=true
    log_message "SUCCESS" "$SERVICE_NAME" "$ACTIVE_COLOR" "health-check" "Backend health check passed"
else
    log_message "ERROR" "$SERVICE_NAME" "$ACTIVE_COLOR" "health-check" "Backend health check failed"
fi

# Check frontend health
log_message "INFO" "$SERVICE_NAME" "$ACTIVE_COLOR" "health-check" "Checking frontend: $FRONTEND_CONTAINER:$FRONTEND_PORT$FRONTEND_HEALTH"

if check_health "$FRONTEND_CONTAINER" "$FRONTEND_PORT" "$FRONTEND_HEALTH" "$FRONTEND_TIMEOUT" "$FRONTEND_RETRIES"; then
    FRONTEND_HEALTHY=true
    log_message "SUCCESS" "$SERVICE_NAME" "$ACTIVE_COLOR" "health-check" "Frontend health check passed"
else
    log_message "ERROR" "$SERVICE_NAME" "$ACTIVE_COLOR" "health-check" "Frontend health check failed"
fi

# If any service is healthy, consider it successful
if [ "$BACKEND_HEALTHY" = true ] || [ "$FRONTEND_HEALTHY" = true ]; then
    log_message "SUCCESS" "$SERVICE_NAME" "$ACTIVE_COLOR" "health-check" "At least one service is healthy"
    exit 0
fi

# All health checks failed - trigger rollback
log_message "ERROR" "$SERVICE_NAME" "$ACTIVE_COLOR" "health-check" "All health checks failed, triggering rollback"

# Call rollback script
"${SCRIPT_DIR}/rollback.sh" "$SERVICE_NAME"

exit 1

