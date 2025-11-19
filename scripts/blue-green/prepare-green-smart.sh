#!/bin/bash
# Smart Prepare Green - Only rebuild/recreate services that have changed
# Usage: prepare-green-smart.sh <service_name>

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

SERVICE_NAME="$1"

if [ -z "$SERVICE_NAME" ]; then
    print_error "Usage: prepare-green-smart.sh <service_name>"
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

log_message "INFO" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Starting smart preparation of $PREPARE_COLOR deployment"

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
REGISTRY_COMPOSE_FILE=$(echo "$REGISTRY" | jq -r '.docker_compose_file')
if [ -z "$REGISTRY_COMPOSE_FILE" ] || [ "$REGISTRY_COMPOSE_FILE" = "null" ]; then
    COMPOSE_FILE="docker-compose.${SERVICE_NAME}.${PREPARE_COLOR}.yml"
else
    COMPOSE_FILE=$(echo "$REGISTRY_COMPOSE_FILE" | sed "s/\.\(blue\|green\)\.yml$/\.${PREPARE_COLOR}.yml/")
fi

# Fallback to generic docker-compose.yml if color-specific file doesn't exist
if [ ! -f "$COMPOSE_FILE" ]; then
    if [ -f "docker-compose.yml" ]; then
        log_message "INFO" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Color-specific compose file not found, using docker-compose.yml"
        COMPOSE_FILE="docker-compose.yml"
    else
        print_error "Docker compose file not found: $COMPOSE_FILE (and docker-compose.yml not found)"
    exit 1
    fi
fi

# Determine project name
PROJECT_NAME="${DOCKER_PROJECT_BASE}_${PREPARE_COLOR}"

# Function to check if service code has changed
service_needs_rebuild() {
    local service_name="$1"
    local hash_file=".deploy-hashes/${service_name}.hash"
    
    # Check if hash file exists
    if [ ! -f "$hash_file" ]; then
        return 0  # Needs rebuild (no previous hash)
    fi
    
    # Get current hash of service directory
    local service_dir="services/${service_name}"
    if [ ! -d "$service_dir" ]; then
        return 1  # Service doesn't exist
    fi
    
    # Get git hash of service directory
    local current_hash=""
    if command -v git >/dev/null 2>&1 && [ -d .git ]; then
        local last_commit=$(git log -1 --format="%H" -- "$service_dir" "shared" "prisma" 2>/dev/null || echo "")
        local uncommitted=$(git diff --name-only "$service_dir" "shared" "prisma" 2>/dev/null | head -1 || echo "")
        if [ -n "$uncommitted" ]; then
            current_hash="$(git ls-files "$service_dir" "shared" "prisma" 2>/dev/null | sort | sha256sum | cut -d' ' -f1)-$(date +%s)"
        else
            current_hash="$last_commit"
        fi
    else
        # Fallback: use file modification times
        current_hash=$(find "$service_dir" "shared" "prisma" -type f -exec stat -c %Y {} \; 2>/dev/null | sort | sha256sum | cut -d' ' -f1 || echo "")
    fi
    
    local stored_hash=$(cat "$hash_file" 2>/dev/null || echo "")
    if [ "$current_hash" != "$stored_hash" ]; then
        # Update hash
        mkdir -p "$(dirname "$hash_file")"
        echo "$current_hash" > "$hash_file"
        return 0  # Needs rebuild
    fi
    
    return 1  # No rebuild needed
}

# Function to check if container is healthy
container_is_healthy() {
    local container_name="$1"
    local port="$2"
    local endpoint="$3"
    
    # Check if container is running
    if ! docker ps --format "{{.Names}}" | grep -q "^${container_name}$"; then
        return 1
    fi
    
    # Check health status
    local health_status=$(docker inspect --format='{{.State.Health.Status}}' "$container_name" 2>/dev/null || echo "none")
    
    if [ "$health_status" = "healthy" ]; then
        return 0
    fi
    
    # Try direct health check
    if [ "$health_status" = "none" ] && [ -n "$port" ] && [ -n "$endpoint" ]; then
        if docker exec "$container_name" curl -f -s --max-time 3 "http://localhost:${port}${endpoint}" >/dev/null 2>&1; then
            return 0
        fi
    fi
    
    return 1
}

# Get all services from docker-compose file
SERVICES=$(docker compose -f "$COMPOSE_FILE" config --services 2>/dev/null || echo "")

if [ -z "$SERVICES" ]; then
    log_message "ERROR" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Failed to get services from docker-compose file"
    exit 1
fi

# Process each service
REBUILT_SERVICES=0
SKIPPED_SERVICES=0
SERVICES_TO_BUILD=()

while IFS= read -r service; do
    # Get container name from registry or construct it
    CONTAINER_BASE=$(echo "$REGISTRY" | jq -r ".services.${service}.container_name_base // empty" 2>/dev/null || echo "")
    if [ -z "$CONTAINER_BASE" ] || [ "$CONTAINER_BASE" = "null" ]; then
        CONTAINER_BASE="${DOCKER_PROJECT_BASE}-${service}"
    fi
    CONTAINER_NAME="${CONTAINER_BASE}-${PREPARE_COLOR}"
    
    PORT=$(echo "$REGISTRY" | jq -r ".services.${service}.port // empty" 2>/dev/null || echo "")
    HEALTH_ENDPOINT=$(echo "$REGISTRY" | jq -r ".services.${service}.health_endpoint // "/health"" 2>/dev/null || echo "/health")
    
    # Check if service needs rebuild
    if service_needs_rebuild "$service"; then
        log_message "INFO" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Service $service has changes, will rebuild"
        SERVICES_TO_BUILD+=("$service")
        REBUILT_SERVICES=$((REBUILT_SERVICES + 1))
    else
        # Check if container is already healthy
        if container_is_healthy "$CONTAINER_NAME" "$PORT" "$HEALTH_ENDPOINT"; then
            log_message "INFO" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Service $service container is healthy, skipping rebuild"
            SKIPPED_SERVICES=$((SKIPPED_SERVICES + 1))
        else
            log_message "INFO" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Service $service has no changes but container not healthy, will rebuild"
            SERVICES_TO_BUILD+=("$service")
            REBUILT_SERVICES=$((REBUILT_SERVICES + 1))
        fi
    fi
done <<< "$SERVICES"

# Build only services that need it
if [ ${#SERVICES_TO_BUILD[@]} -gt 0 ]; then
    log_message "INFO" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Building containers for $PREPARE_COLOR (${#SERVICES_TO_BUILD[@]} services need rebuild)"
    
    # Build only specific services
    for service in "${SERVICES_TO_BUILD[@]}"; do
        if ! docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" build "$service"; then
            log_message "ERROR" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Failed to build service: $service"
            exit 1
        fi
    done
else
    log_message "INFO" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "No services need rebuilding (all containers are healthy)"
fi

# Check if containers already exist and handle them
log_message "INFO" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Checking for existing containers and port conflicts"

# Get all services from docker-compose file
SERVICES=$(docker compose -f "$COMPOSE_FILE" config --services 2>/dev/null || echo "")

if [ -z "$SERVICES" ]; then
    log_message "ERROR" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Failed to get services from docker-compose file"
    exit 1
fi

# Get actual container names from docker-compose config
COMPOSE_CONFIG=$(docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" config 2>/dev/null || echo "")

# Check each service for existing containers and port conflicts
while IFS= read -r service; do
    CONTAINER_BASE=$(echo "$REGISTRY" | jq -r ".services.${service}.container_name_base // empty" 2>/dev/null || echo "")
    if [ -z "$CONTAINER_BASE" ] || [ "$CONTAINER_BASE" = "null" ]; then
        CONTAINER_BASE="${DOCKER_PROJECT_BASE}-${service}"
    fi
    CONTAINER_NAME="${CONTAINER_BASE}-${PREPARE_COLOR}"
    
    # Get actual container name from compose config (may be different from expected)
    ACTUAL_CONTAINER_NAME=$(echo "$COMPOSE_CONFIG" | docker compose -f - -p "$PROJECT_NAME" config 2>/dev/null | grep -A5 "services:" | grep -A5 "^  ${service}:" | grep "container_name:" | awk '{print $2}' | tr -d '"' || echo "")
    
    # If compose config doesn't have container_name, docker-compose will use PROJECT_NAME-SERVICE_NAME format
    if [ -z "$ACTUAL_CONTAINER_NAME" ]; then
        ACTUAL_CONTAINER_NAME="${PROJECT_NAME}-${service}"
    fi
    
    # Check for actual container name that will be created
    if docker ps -a --format "{{.Names}}" | grep -qE "^${ACTUAL_CONTAINER_NAME}$|^${CONTAINER_BASE}$|^${CONTAINER_NAME}$"; then
        EXISTING_CONTAINER=$(docker ps -a --format "{{.Names}}" | grep -E "^${ACTUAL_CONTAINER_NAME}$|^${CONTAINER_BASE}$|^${CONTAINER_NAME}$" | head -1)
        log_message "INFO" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Found existing container ${EXISTING_CONTAINER}"
        
        if docker ps --format "{{.Names}}" | grep -qE "^${EXISTING_CONTAINER}$"; then
            log_message "INFO" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Container ${EXISTING_CONTAINER} is running, stopping and removing it"
            docker stop "${EXISTING_CONTAINER}" 2>/dev/null || true
            docker rm -f "${EXISTING_CONTAINER}" 2>/dev/null || true
        else
            log_message "INFO" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Container ${EXISTING_CONTAINER} exists but not running, removing it"
            docker rm -f "${EXISTING_CONTAINER}" 2>/dev/null || true
        fi
    fi
    
    # Check for port conflicts
    PORT=$(echo "$REGISTRY" | jq -r ".services.${service}.port // empty" 2>/dev/null || echo "")
    if [ -n "$PORT" ] && [ "$PORT" != "null" ]; then
        # Check if port is in use
        PORT_IN_USE=$(docker ps --format "{{.Names}}\t{{.Ports}}" | grep -E ":${PORT}->|:${PORT}/" | grep -v "^${EXISTING_CONTAINER}" | head -1 || echo "")
        if [ -n "$PORT_IN_USE" ]; then
            CONFLICT_CONTAINER=$(echo "$PORT_IN_USE" | awk '{print $1}')
            log_message "WARNING" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Port ${PORT} is in use by container ${CONFLICT_CONTAINER}, stopping it"
            docker stop "${CONFLICT_CONTAINER}" 2>/dev/null || true
            docker rm -f "${CONFLICT_CONTAINER}" 2>/dev/null || true
        fi
    fi
done <<< "$SERVICES"

# Start/restart containers
log_message "INFO" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Starting containers for $PREPARE_COLOR"

if ! docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" up -d; then
    log_message "ERROR" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Failed to start containers"
    exit 1
fi

# Get startup times from registry (capped at 5 seconds maximum)
FRONTEND_STARTUP=$(echo "$REGISTRY" | jq -r '.services.frontend.startup_time // empty')
BACKEND_STARTUP=$(echo "$REGISTRY" | jq -r '.services.backend.startup_time // empty')
if [ -z "$FRONTEND_STARTUP" ] && [ -z "$BACKEND_STARTUP" ]; then
    MAX_STARTUP=5
elif [ -z "$FRONTEND_STARTUP" ]; then
    MAX_STARTUP=$BACKEND_STARTUP
elif [ -z "$BACKEND_STARTUP" ]; then
    MAX_STARTUP=$FRONTEND_STARTUP
else
    MAX_STARTUP=$((FRONTEND_STARTUP > BACKEND_STARTUP ? FRONTEND_STARTUP : BACKEND_STARTUP))
fi

# Cap maximum startup time at 5 seconds
if [ "$MAX_STARTUP" -gt 5 ]; then
    MAX_STARTUP=5
fi

log_message "INFO" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Waiting ${MAX_STARTUP} seconds for services to start"
sleep "$MAX_STARTUP"

# Health check function
check_health() {
    local container_name="$1"
    local port="$2"
    local endpoint="$3"
    local timeout="${4:-5}"
    local retries="${5:-3}"
    
    local attempt=0
    while [ $attempt -lt $retries ]; do
        attempt=$((attempt + 1))
        if docker run --rm --network nginx-network alpine/curl:latest \
            curl -s -f --max-time "$timeout" "http://${container_name}:${port}${endpoint}" >/dev/null 2>&1; then
            return 0
        fi
        if [ $attempt -lt $retries ]; then
            sleep 1
        fi
    done
    return 1
}

# Check backend health (if exists)
BACKEND_CONTAINER=$(echo "$REGISTRY" | jq -r '.services.backend.container_name_base // empty')
BACKEND_PORT=$(echo "$REGISTRY" | jq -r '.services.backend.port // empty')
BACKEND_HEALTH=$(echo "$REGISTRY" | jq -r '.services.backend.health_endpoint // empty')
BACKEND_TIMEOUT=$(echo "$REGISTRY" | jq -r '.services.backend.health_timeout // 5')
BACKEND_RETRIES=$(echo "$REGISTRY" | jq -r '.services.backend.health_retries // 3')

if [ -n "$BACKEND_CONTAINER" ] && [ "$BACKEND_CONTAINER" != "null" ] && [ -n "$BACKEND_PORT" ]; then
    BACKEND_CONTAINER="${BACKEND_CONTAINER}-${PREPARE_COLOR}"
    log_message "INFO" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Checking backend health: $BACKEND_CONTAINER:$BACKEND_PORT${BACKEND_HEALTH}"
    
    if check_health "$BACKEND_CONTAINER" "$BACKEND_PORT" "${BACKEND_HEALTH:-/health}" "$BACKEND_TIMEOUT" "$BACKEND_RETRIES"; then
        log_message "SUCCESS" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Backend health check passed"
    else
        log_message "ERROR" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Backend health check failed after $BACKEND_RETRIES retries"
        docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" down
        exit 1
    fi
fi

# Check frontend health (if exists)
FRONTEND_CONTAINER=$(echo "$REGISTRY" | jq -r '.services.frontend.container_name_base // empty')
FRONTEND_PORT=$(echo "$REGISTRY" | jq -r '.services.frontend.port // empty')
FRONTEND_HEALTH=$(echo "$REGISTRY" | jq -r '.services.frontend.health_endpoint // empty')
FRONTEND_TIMEOUT=$(echo "$REGISTRY" | jq -r '.services.frontend.health_timeout // 5')
FRONTEND_RETRIES=$(echo "$REGISTRY" | jq -r '.services.frontend.health_retries // 3')

if [ -n "$FRONTEND_CONTAINER" ] && [ "$FRONTEND_CONTAINER" != "null" ] && [ -n "$FRONTEND_PORT" ]; then
    FRONTEND_CONTAINER="${FRONTEND_CONTAINER}-${PREPARE_COLOR}"
    log_message "INFO" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Checking frontend health: $FRONTEND_CONTAINER:$FRONTEND_PORT${FRONTEND_HEALTH}"
    
    if check_health "$FRONTEND_CONTAINER" "$FRONTEND_PORT" "${FRONTEND_HEALTH:-/}" "$FRONTEND_TIMEOUT" "$FRONTEND_RETRIES"; then
        log_message "SUCCESS" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Frontend health check passed"
    else
        log_message "ERROR" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Frontend health check failed after $FRONTEND_RETRIES retries"
        docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" down
        exit 1
    fi
fi

# Update state
NEW_STATE=$(echo "$STATE" | jq --arg color "$PREPARE_COLOR" --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    ".\"$color\".status = \"ready\" | .\"$color\".deployed_at = \$timestamp")

save_state "$SERVICE_NAME" "$NEW_STATE"

log_message "SUCCESS" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "$PREPARE_COLOR deployment prepared (rebuilt: $REBUILT_SERVICES, skipped: $SKIPPED_SERVICES)"

exit 0
