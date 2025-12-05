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

# Load state - for statex service, get domain from registry
DOMAIN=""
if [ "$SERVICE_NAME" = "statex" ]; then
    REGISTRY=$(load_service_registry "$SERVICE_NAME")
    DOMAIN=$(echo "$REGISTRY" | jq -r '.domain // empty')
fi
STATE=$(load_state "$SERVICE_NAME" "$DOMAIN")
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
    
    # Get container port with auto-detection
    PORT=$(get_container_port "$SERVICE_NAME" "$service" "$CONTAINER_BASE" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare")
    
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
    
    # Enable BuildKit for better caching and performance
    export DOCKER_BUILDKIT=1
    export COMPOSE_DOCKER_CLI_BUILD=1
    
    # Build all services at once - Docker Compose automatically parallelizes independent builds
    # This is much faster than building sequentially
    SERVICES_STRING=$(IFS=' '; echo "${SERVICES_TO_BUILD[*]}")
    log_message "INFO" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Building services in parallel: ${SERVICES_STRING}"
    
    if ! docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" build "${SERVICES_TO_BUILD[@]}"; then
        log_message "ERROR" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Failed to build services: ${SERVICES_STRING}"
        exit 1
    fi
    
    log_message "SUCCESS" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "All services built successfully (parallel build enabled)"
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
    # Escape service name for regex to handle special characters
    escaped_service=$(printf '%s\n' "$service" | sed 's/[[\.*^$()+?{|]/\\&/g')
    ACTUAL_CONTAINER_NAME=$(echo "$COMPOSE_CONFIG" | docker compose -f - -p "$PROJECT_NAME" config 2>/dev/null | grep -A5 "services:" | grep -A5 "^  ${escaped_service}:" | grep "container_name:" | awk '{print $2}' | tr -d '"' || echo "")
    
    # If compose config doesn't have container_name, docker-compose will use PROJECT_NAME-SERVICE_NAME format
    if [ -z "$ACTUAL_CONTAINER_NAME" ]; then
        ACTUAL_CONTAINER_NAME="${PROJECT_NAME}-${service}"
    fi
    
    # Check for actual container name that will be created and kill if exists (handles restarting containers)
    if type kill_container_if_exists >/dev/null 2>&1; then
        # Check all possible container name variations
        kill_container_if_exists "${ACTUAL_CONTAINER_NAME}" "$SERVICE_NAME" "$PREPARE_COLOR"
        kill_container_if_exists "${CONTAINER_NAME}" "$SERVICE_NAME" "$PREPARE_COLOR"
        if [ -n "$CONTAINER_BASE" ] && [ "$CONTAINER_BASE" != "null" ]; then
            kill_container_if_exists "${CONTAINER_BASE}" "$SERVICE_NAME" "$PREPARE_COLOR"
        fi
    else
        # Fallback: manual container checking
        if docker ps -a --format "{{.Names}}" | grep -qE "^${ACTUAL_CONTAINER_NAME}$|^${CONTAINER_BASE}$|^${CONTAINER_NAME}$"; then
            EXISTING_CONTAINER=$(docker ps -a --format "{{.Names}}" | grep -E "^${ACTUAL_CONTAINER_NAME}$|^${CONTAINER_BASE}$|^${CONTAINER_NAME}$" | head -1)
            log_message "INFO" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Found existing container ${EXISTING_CONTAINER}"
            
            # Check if it's restarting
            status=$(docker ps --format "{{.Names}}\t{{.Status}}" 2>/dev/null | grep "^${EXISTING_CONTAINER}" | awk '{print $2}' || echo "")
            if [ -n "$status" ] && echo "$status" | grep -qE "Restarting"; then
                log_message "WARNING" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Container ${EXISTING_CONTAINER} is restarting, force killing it"
                docker kill "${EXISTING_CONTAINER}" 2>/dev/null || true
                sleep 1
            fi
            
            if docker ps --format "{{.Names}}" | grep -qE "^${EXISTING_CONTAINER}$"; then
                log_message "INFO" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Container ${EXISTING_CONTAINER} is running, stopping and removing it"
                docker stop "${EXISTING_CONTAINER}" 2>/dev/null || true
                docker rm -f "${EXISTING_CONTAINER}" 2>/dev/null || true
            else
                log_message "INFO" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Container ${EXISTING_CONTAINER} exists but not running, removing it"
                docker rm -f "${EXISTING_CONTAINER}" 2>/dev/null || true
            fi
        fi
    fi
    
    # Check for port conflicts - get container port with auto-detection
    PORT=$(get_container_port "$SERVICE_NAME" "$service" "$CONTAINER_BASE")
    
    # Try to get actual host port from docker-compose file
    host_port=""
    if [ -f "$COMPOSE_FILE" ]; then
        # Extract host port mapping from compose file for this service
        # Escape service name for regex to handle special characters
        escaped_service=$(printf '%s\n' "$service" | sed 's/[[\.*^$()+?{|]/\\&/g')
        port_mapping=$(docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" config 2>/dev/null | \
            grep -A 20 "^  ${escaped_service}:" | grep -E "^\s+-.*:.*:" | head -1 | \
            sed -E 's/.*"([0-9.]+):([0-9]+):([0-9]+)".*/\1:\2/' | \
            sed -E 's/.*"([0-9]+):([0-9]+)".*/\1/' | \
            grep -oE '^[0-9]+' | head -1 || echo "")
        
        if [ -n "$port_mapping" ]; then
            host_port="$port_mapping"
        fi
    fi
    
    # If we couldn't get host port from compose, use the registry port (internal port)
    # But we still need to check if it's mapped to host
    if [ -z "$host_port" ] && [ -n "$PORT" ] && [ "$PORT" != "null" ]; then
        # Check docker ps output to see if any container has this port mapped
        mapped_port=$(docker ps --format "{{.Names}}\t{{.Ports}}" 2>/dev/null | \
            grep -E ":${PORT}->|:${PORT}/" | \
            sed -E 's/.*:([0-9]+)->.*/\1/' | head -1 || echo "")
        
        if [ -n "$mapped_port" ]; then
            host_port="$mapped_port"
        else
            # Use registry port as fallback (might be internal only)
            host_port="$PORT"
        fi
    fi
    
    # Kill any process/container using the port
    if [ -n "$host_port" ] && [ "$host_port" != "null" ]; then
        if type kill_port_if_in_use >/dev/null 2>&1; then
            kill_port_if_in_use "$host_port" "$SERVICE_NAME" "$PREPARE_COLOR"
        else
            # Fallback: check if port is in use by docker container
            PORT_IN_USE=$(docker ps --format "{{.Names}}\t{{.Ports}}" 2>/dev/null | \
                grep -E ":${host_port}->|:${host_port}/|0\.0\.0\.0:${host_port}:|127\.0\.0\.1:${host_port}:" | \
                grep -v "^${EXISTING_CONTAINER}" | awk '{print $1}' | head -1 || echo "")
            if [ -n "$PORT_IN_USE" ]; then
                log_message "WARNING" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Port ${host_port} is in use by container ${PORT_IN_USE}, stopping it"
                docker stop "${PORT_IN_USE}" 2>/dev/null || true
                docker rm -f "${PORT_IN_USE}" 2>/dev/null || true
            fi
        fi
    fi
done <<< "$SERVICES"

# Start/restart containers
log_message "INFO" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Starting containers for $PREPARE_COLOR"

# Try to start containers, handle container name conflicts
if ! docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" up -d 2>&1 | tee /tmp/docker-compose-output.log; then
    # Check if error is due to container name conflict
    if grep -q "is already in use by container" /tmp/docker-compose-output.log; then
        log_message "WARNING" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Container name conflict detected, removing conflicting containers"
        
        # Extract container names from error messages
        CONFLICTING_CONTAINERS=$(grep -oE "container name \"[^\"]+\"" /tmp/docker-compose-output.log | sed 's/container name "//;s/"//' | sort -u)
        
        # Remove conflicting containers
        for container in $CONFLICTING_CONTAINERS; do
            if [ -n "$container" ]; then
                log_message "INFO" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Removing conflicting container: $container"
                docker rm -f "$container" 2>/dev/null || true
            fi
        done
        
        # Also check for containers that match the expected naming pattern
        while IFS= read -r service; do
            CONTAINER_BASE=$(echo "$REGISTRY" | jq -r ".services.${service}.container_name_base // empty" 2>/dev/null || echo "")
            if [ -z "$CONTAINER_BASE" ] || [ "$CONTAINER_BASE" = "null" ]; then
                CONTAINER_BASE="${DOCKER_PROJECT_BASE}-${service}"
            fi
            EXPECTED_CONTAINER="${CONTAINER_BASE}-${PREPARE_COLOR}"
            
            # Check if container exists (in any state)
            if docker ps -a --format "{{.Names}}" | grep -qE "^${EXPECTED_CONTAINER}$"; then
                log_message "INFO" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Removing existing container: $EXPECTED_CONTAINER"
                docker rm -f "$EXPECTED_CONTAINER" 2>/dev/null || true
            fi
        done <<< "$SERVICES"
        
        # Retry starting containers
        log_message "INFO" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Retrying container startup after removing conflicts"
        if ! docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" up -d; then
            log_message "ERROR" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Failed to start containers after removing conflicts"
            rm -f /tmp/docker-compose-output.log
            exit 1
        fi
    else
        log_message "ERROR" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Failed to start containers"
        rm -f /tmp/docker-compose-output.log
        exit 1
    fi
fi

# Cleanup temp file
rm -f /tmp/docker-compose-output.log

# Get startup times from registry
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

# Ensure MAX_STARTUP is numeric and at least 5 seconds, but cap at 10 seconds
if ! [[ "$MAX_STARTUP" =~ ^[0-9]+$ ]]; then
    MAX_STARTUP=5
fi
if [ "$MAX_STARTUP" -lt 5 ]; then
    MAX_STARTUP=5
fi
if [ "$MAX_STARTUP" -gt 10 ]; then
    MAX_STARTUP=10
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
    local network_name="${NETWORK_NAME:-nginx-network}"
    local health_check_image="${HEALTH_CHECK_IMAGE:-alpine/curl:latest}"
    
    # Verify container is running
    if ! docker ps --format "{{.Names}}" | grep -q "^${container_name}$"; then
        log_message "WARNING" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Container $container_name is not running"
        return 1
    fi
    
    # Verify container is on the network
    if ! docker network inspect "${network_name}" --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null | grep -qE "(^| )${container_name}( |$)"; then
        log_message "WARNING" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Container $container_name is not on network ${network_name}"
        # Try to connect container to network
        if docker network connect "${network_name}" "${container_name}" 2>/dev/null; then
            log_message "INFO" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Connected $container_name to ${network_name}"
            sleep 1
        else
            log_message "ERROR" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Failed to connect $container_name to ${network_name}"
            return 1
        fi
    fi
    
    while [ $attempt -lt $retries ]; do
        attempt=$((attempt + 1))
        
        # Check if port is listening inside container
        # Use strict port matching to avoid partial matches (e.g., :80 matching :8000)
        # Pattern :${port}([^0-9]|$) matches :port followed by non-digit or end of line
        if ! docker exec "${container_name}" sh -c "nc -z localhost ${port} 2>/dev/null || ss -tuln 2>/dev/null | grep -qE ':${port}([^0-9]|$)' || netstat -tuln 2>/dev/null | grep -qE ':${port}([^0-9]|$)'" 2>/dev/null; then
            if [ $attempt -eq $retries ]; then
                log_message "WARNING" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Port ${port} is not listening in container ${container_name}"
            fi
        fi
        
        # Try network-based health check first
        local network_error=""
        if network_error=$(docker run --rm --network "${network_name}" "${health_check_image}" \
            curl -s -f --max-time "$timeout" "http://${container_name}:${port}${endpoint}" 2>&1); then
            return 0
        fi
        
        # Fallback: try direct exec if network check fails
        # First check if curl is available in container
        if docker exec "${container_name}" sh -c "command -v curl >/dev/null 2>&1" 2>/dev/null; then
            local exec_error=""
            if exec_error=$(docker exec "${container_name}" curl -s -f --max-time "$timeout" "http://localhost:${port}${endpoint}" 2>&1); then
                log_message "INFO" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Health check passed via direct exec (network check may have failed)"
                return 0
            elif [ $attempt -eq $retries ]; then
                log_message "WARNING" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Direct exec curl failed: ${exec_error}"
            fi
        else
            # Try using wget if curl is not available
            if docker exec "${container_name}" sh -c "command -v wget >/dev/null 2>&1" 2>/dev/null; then
                local wget_error=""
                if wget_error=$(docker exec "${container_name}" wget -q --spider --timeout="$timeout" "http://localhost:${port}${endpoint}" 2>&1); then
                    log_message "INFO" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Health check passed via direct exec with wget"
                    return 0
                elif [ $attempt -eq $retries ]; then
                    log_message "WARNING" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Direct exec wget failed: ${wget_error}"
                fi
            fi
        fi
        
        if [ $attempt -lt $retries ]; then
            sleep 1
        fi
    done
    
    # Log comprehensive diagnostic information on final failure
    local container_status=$(docker inspect --format='{{.State.Status}}' "$container_name" 2>/dev/null || echo 'unknown')
    local container_health=$(docker inspect --format='{{.State.Health.Status}}' "$container_name" 2>/dev/null || echo 'none')
    
    # Get listening ports - check docker exec exit code, not head's exit code
    local listening_ports=""
    local docker_exec_output=""
    local docker_exec_exit_code=0
    
    # Run docker exec and capture both output and exit code separately
    docker_exec_output=$(docker exec "${container_name}" sh -c "ss -tuln 2>/dev/null | grep LISTEN || netstat -tuln 2>/dev/null | grep LISTEN || echo ''" 2>/dev/null)
    docker_exec_exit_code=$?
    
    if [ $docker_exec_exit_code -eq 0 ]; then
        # docker exec succeeded - pipe output to head and check if result is empty
        listening_ports=$(echo "$docker_exec_output" | head -5 2>/dev/null)
        # Trim whitespace/newlines before checking if empty (echo '' outputs a newline)
        # This handles the case where ss/netstat fail and fallback to echo ''
        local listening_ports_trimmed=$(echo "$listening_ports" | tr -d "[:space:]")
        if [ -z "$listening_ports_trimmed" ]; then
            listening_ports="unknown"
        fi
    else
        # docker exec failed (container not running, crashed, etc.)
        listening_ports="unknown"
    fi
    
    log_message "WARNING" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Health check failed after $retries attempts"
    log_message "WARNING" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Container: $container_name, Status: $container_status, Health: $container_health"
    log_message "WARNING" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Expected: http://${container_name}:${port}${endpoint}"
    log_message "WARNING" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "Listening ports in container: ${listening_ports}"
    
    return 1
}

# Check backend health (if exists)
BACKEND_CONTAINER_BASE=$(echo "$REGISTRY" | jq -r '.services.backend.container_name_base // empty')
BACKEND_HEALTH=$(echo "$REGISTRY" | jq -r '.services.backend.health_endpoint // empty')
BACKEND_TIMEOUT=$(echo "$REGISTRY" | jq -r '.services.backend.health_timeout // 5')
BACKEND_RETRIES=$(echo "$REGISTRY" | jq -r '.services.backend.health_retries // 3')

# Get backend port with auto-detection
if [ -n "$BACKEND_CONTAINER_BASE" ] && [ "$BACKEND_CONTAINER_BASE" != "null" ]; then
    BACKEND_PORT=$(get_container_port "$SERVICE_NAME" "backend" "$BACKEND_CONTAINER_BASE" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare")
fi

if [ -n "$BACKEND_CONTAINER_BASE" ] && [ "$BACKEND_CONTAINER_BASE" != "null" ] && [ -n "$BACKEND_PORT" ] && [ "$BACKEND_PORT" != "null" ]; then
    # Get actual container name from compose config (may be different from expected)
    escaped_service=$(printf '%s\n' "backend" | sed 's/[[\.*^$()+?{|]/\\&/g')
    BACKEND_CONTAINER=$(echo "$COMPOSE_CONFIG" | docker compose -f - -p "$PROJECT_NAME" config 2>/dev/null | grep -A5 "services:" | grep -A5 "^  ${escaped_service}:" | grep "container_name:" | awk '{print $2}' | tr -d '"' || echo "")
    
    # If compose config doesn't have container_name, try to find actual running container
    if [ -z "$BACKEND_CONTAINER" ]; then
        # Try PROJECT_NAME-SERVICE_NAME format (with underscores converted to hyphens)
        PROJECT_NAME_HYPHEN=$(echo "$PROJECT_NAME" | tr '_' '-')
        BACKEND_CONTAINER="${PROJECT_NAME_HYPHEN}-backend"
        
        # Check if this container exists
        if ! docker ps --format "{{.Names}}" | grep -q "^${BACKEND_CONTAINER}$"; then
            # Try alternative: container_name_base without color suffix
            if docker ps --format "{{.Names}}" | grep -q "^${BACKEND_CONTAINER_BASE}$"; then
                BACKEND_CONTAINER="$BACKEND_CONTAINER_BASE"
            # Try with color suffix
            elif docker ps --format "{{.Names}}" | grep -q "^${BACKEND_CONTAINER_BASE}-${PREPARE_COLOR}$"; then
                BACKEND_CONTAINER="${BACKEND_CONTAINER_BASE}-${PREPARE_COLOR}"
            else
                # Find any running container that matches the container_name_base pattern
                FOUND_CONTAINER=$(docker ps --format "{{.Names}}" | grep -E "^${BACKEND_CONTAINER_BASE}(-.*)?$" | head -1 || echo "")
                if [ -n "$FOUND_CONTAINER" ]; then
                    BACKEND_CONTAINER="$FOUND_CONTAINER"
                fi
            fi
        fi
    else
        # Container name from compose config exists, verify it's running
        if ! docker ps --format "{{.Names}}" | grep -q "^${BACKEND_CONTAINER}$"; then
            # Try to find by container_name_base as fallback
            if docker ps --format "{{.Names}}" | grep -q "^${BACKEND_CONTAINER_BASE}$"; then
                BACKEND_CONTAINER="$BACKEND_CONTAINER_BASE"
            fi
        fi
    fi
    
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
FRONTEND_CONTAINER_BASE=$(echo "$REGISTRY" | jq -r '.services.frontend.container_name_base // empty')
FRONTEND_HEALTH=$(echo "$REGISTRY" | jq -r '.services.frontend.health_endpoint // empty')
FRONTEND_TIMEOUT=$(echo "$REGISTRY" | jq -r '.services.frontend.health_timeout // 5')
FRONTEND_RETRIES=$(echo "$REGISTRY" | jq -r '.services.frontend.health_retries // 3')

# Get frontend port with auto-detection
if [ -n "$FRONTEND_CONTAINER_BASE" ] && [ "$FRONTEND_CONTAINER_BASE" != "null" ]; then
    FRONTEND_PORT=$(get_container_port "$SERVICE_NAME" "frontend" "$FRONTEND_CONTAINER_BASE" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare")
fi

if [ -n "$FRONTEND_CONTAINER_BASE" ] && [ "$FRONTEND_CONTAINER_BASE" != "null" ] && [ -n "$FRONTEND_PORT" ] && [ "$FRONTEND_PORT" != "null" ]; then
    # Get actual container name from compose config (may be different from expected)
    escaped_service=$(printf '%s\n' "frontend" | sed 's/[[\.*^$()+?{|]/\\&/g')
    FRONTEND_CONTAINER=$(echo "$COMPOSE_CONFIG" | docker compose -f - -p "$PROJECT_NAME" config 2>/dev/null | grep -A5 "services:" | grep -A5 "^  ${escaped_service}:" | grep "container_name:" | awk '{print $2}' | tr -d '"' || echo "")
    
    # If compose config doesn't have container_name, try to find actual running container
    if [ -z "$FRONTEND_CONTAINER" ]; then
        # Try PROJECT_NAME-SERVICE_NAME format (with underscores converted to hyphens)
        PROJECT_NAME_HYPHEN=$(echo "$PROJECT_NAME" | tr '_' '-')
        FRONTEND_CONTAINER="${PROJECT_NAME_HYPHEN}-frontend"
        
        # Check if this container exists
        if ! docker ps --format "{{.Names}}" | grep -q "^${FRONTEND_CONTAINER}$"; then
            # Try alternative: container_name_base without color suffix
            if docker ps --format "{{.Names}}" | grep -q "^${FRONTEND_CONTAINER_BASE}$"; then
                FRONTEND_CONTAINER="$FRONTEND_CONTAINER_BASE"
            # Try with color suffix
            elif docker ps --format "{{.Names}}" | grep -q "^${FRONTEND_CONTAINER_BASE}-${PREPARE_COLOR}$"; then
                FRONTEND_CONTAINER="${FRONTEND_CONTAINER_BASE}-${PREPARE_COLOR}"
            else
                # Find any running container that matches the container_name_base pattern
                FOUND_CONTAINER=$(docker ps --format "{{.Names}}" | grep -E "^${FRONTEND_CONTAINER_BASE}(-.*)?$" | head -1 || echo "")
                if [ -n "$FOUND_CONTAINER" ]; then
                    FRONTEND_CONTAINER="$FOUND_CONTAINER"
                fi
            fi
        fi
    else
        # Container name from compose config exists, verify it's running
        if ! docker ps --format "{{.Names}}" | grep -q "^${FRONTEND_CONTAINER}$"; then
            # Try to find by container_name_base as fallback
            if docker ps --format "{{.Names}}" | grep -q "^${FRONTEND_CONTAINER_BASE}$"; then
                FRONTEND_CONTAINER="$FRONTEND_CONTAINER_BASE"
            fi
        fi
    fi
    
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

save_state "$SERVICE_NAME" "$NEW_STATE" "$DOMAIN"

log_message "SUCCESS" "$SERVICE_NAME" "$PREPARE_COLOR" "prepare" "$PREPARE_COLOR deployment prepared (rebuilt: $REBUILT_SERVICES, skipped: $SKIPPED_SERVICES)"

exit 0
