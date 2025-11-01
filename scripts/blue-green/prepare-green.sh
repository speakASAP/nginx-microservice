#!/bin/bash
# Prepare Green - Build and start green instance
# Usage: prepare-green.sh <service_name>

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

SERVICE_NAME="$1"

if [ -z "$SERVICE_NAME" ]; then
    print_error "Usage: prepare-green.sh <service_name>"
    exit 1
fi

# Load service registry
REGISTRY=$(load_service_registry "$SERVICE_NAME")
SERVICE_PATH=$(echo "$REGISTRY" | jq -r '.service_path')
PRODUCTION_PATH=$(echo "$REGISTRY" | jq -r '.production_path')
DOCKER_PROJECT_BASE=$(echo "$REGISTRY" | jq -r '.docker_project_base')

# Determine if production or development
if [ -d "$PRODUCTION_PATH" ]; then
    ACTUAL_PATH="$PRODUCTION_PATH"
elif [ -d "$SERVICE_PATH" ]; then
    ACTUAL_PATH="$SERVICE_PATH"
else
    print_error "Service path not found: $SERVICE_PATH or $PRODUCTION_PATH"
    exit 1
fi

# Load state
STATE=$(load_state "$SERVICE_NAME")
ACTIVE_COLOR=$(echo "$STATE" | jq -r '.active_color')

# Determine inactive color (the one we're preparing)
if [ "$ACTIVE_COLOR" = "blue" ]; then
    PREPARE_COLOR="green"
else
    PREPARE_COLOR="blue"
fi

log_message "INFO" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Starting preparation of $PREPARE_COLOR deployment"

# Ensure shared infrastructure is running
log_message "INFO" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Ensuring shared infrastructure is running"

if ! "${SCRIPT_DIR}/ensure-infrastructure.sh" "$SERVICE_NAME"; then
    log_message "ERROR" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Infrastructure check failed"
    exit 1
fi

# Check docker compose
if ! check_docker_compose_available; then
    exit 1
fi

# Navigate to service directory
cd "$ACTUAL_PATH"

# Determine docker compose file
COMPOSE_FILE="docker-compose.${PREPARE_COLOR}.yml"
if [ ! -f "$COMPOSE_FILE" ]; then
    print_error "Docker compose file not found: $COMPOSE_FILE"
    exit 1
fi

# Determine project name
PROJECT_NAME="${DOCKER_PROJECT_BASE}_${PREPARE_COLOR}"

log_message "INFO" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Building containers for $PREPARE_COLOR"

# Build containers
if ! docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" build; then
    log_message "ERROR" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Failed to build containers"
    exit 1
fi

log_message "INFO" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Starting containers for $PREPARE_COLOR"

# Start containers
if ! docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" up -d; then
    log_message "ERROR" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Failed to start containers"
    exit 1
fi

# Get startup times from registry
FRONTEND_STARTUP=$(echo "$REGISTRY" | jq -r '.services.frontend.startup_time')
BACKEND_STARTUP=$(echo "$REGISTRY" | jq -r '.services.backend.startup_time')
MAX_STARTUP=$((FRONTEND_STARTUP > BACKEND_STARTUP ? FRONTEND_STARTUP : BACKEND_STARTUP))

log_message "INFO" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Waiting ${MAX_STARTUP} seconds for services to start"

# Wait for startup
sleep "$MAX_STARTUP"

# Get service info from registry
FRONTEND_CONTAINER=$(echo "$REGISTRY" | jq -r ".services.frontend.container_name_base")-${PREPARE_COLOR}
BACKEND_CONTAINER=$(echo "$REGISTRY" | jq -r ".services.backend.container_name_base")-${PREPARE_COLOR}
FRONTEND_PORT=$(echo "$REGISTRY" | jq -r '.services.frontend.port')
BACKEND_PORT=$(echo "$REGISTRY" | jq -r '.services.backend.port')
FRONTEND_HEALTH=$(echo "$REGISTRY" | jq -r '.services.frontend.health_endpoint')
BACKEND_HEALTH=$(echo "$REGISTRY" | jq -r '.services.backend.health_endpoint')
FRONTEND_TIMEOUT=$(echo "$REGISTRY" | jq -r '.services.frontend.health_timeout')
BACKEND_TIMEOUT=$(echo "$REGISTRY" | jq -r '.services.backend.health_timeout')
FRONTEND_RETRIES=$(echo "$REGISTRY" | jq -r '.services.frontend.health_retries')
BACKEND_RETRIES=$(echo "$REGISTRY" | jq -r '.services.backend.health_retries')

# Check if containers are running
if ! docker ps | grep -q "$FRONTEND_CONTAINER"; then
    log_message "ERROR" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Frontend container not running: $FRONTEND_CONTAINER"
    docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" down
    exit 1
fi

if ! docker ps | grep -q "$BACKEND_CONTAINER"; then
    log_message "ERROR" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Backend container not running: $BACKEND_CONTAINER"
    docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" down
    exit 1
fi

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

# Check backend health
log_message "INFO" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Checking backend health: $BACKEND_CONTAINER:$BACKEND_PORT$BACKEND_HEALTH"

if check_health "$BACKEND_CONTAINER" "$BACKEND_PORT" "$BACKEND_HEALTH" "$BACKEND_TIMEOUT" "$BACKEND_RETRIES"; then
    log_message "SUCCESS" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Backend health check passed"
else
    log_message "ERROR" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Backend health check failed after $BACKEND_RETRIES retries"
    docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" down
    exit 1
fi

# Check frontend health
log_message "INFO" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Checking frontend health: $FRONTEND_CONTAINER:$FRONTEND_PORT$FRONTEND_HEALTH"

if check_health "$FRONTEND_CONTAINER" "$FRONTEND_PORT" "$FRONTEND_HEALTH" "$FRONTEND_TIMEOUT" "$FRONTEND_RETRIES"; then
    log_message "SUCCESS" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Frontend health check passed"
else
    log_message "ERROR" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Frontend health check failed after $FRONTEND_RETRIES retries"
    docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" down
    exit 1
fi

# Update state
NEW_STATE=$(echo "$STATE" | jq --arg color "$PREPARE_COLOR" --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    ".\"$color\".status = \"ready\" | .\"$color\".deployed_at = \$timestamp")

save_state "$SERVICE_NAME" "$NEW_STATE"

log_message "SUCCESS" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "$PREPARE_COLOR deployment prepared and healthy"

exit 0

