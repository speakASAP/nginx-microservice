#!/bin/bash
# Ensure Infrastructure - Start shared infrastructure (postgres, redis) if not running
# Usage: ensure-infrastructure.sh <service_name>

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

SERVICE_NAME="$1"

if [ -z "$SERVICE_NAME" ]; then
    print_error "Usage: ensure-infrastructure.sh <service_name>"
    exit 1
fi

# Load service registry
REGISTRY=$(load_service_registry "$SERVICE_NAME")
SERVICE_PATH=$(echo "$REGISTRY" | jq -r '.service_path')
PRODUCTION_PATH=$(echo "$REGISTRY" | jq -r '.production_path')

# Determine if production or development
if [ -d "$PRODUCTION_PATH" ]; then
    ACTUAL_PATH="$PRODUCTION_PATH"
elif [ -d "$SERVICE_PATH" ]; then
    ACTUAL_PATH="$SERVICE_PATH"
else
    print_error "Service path not found: $SERVICE_PATH or $PRODUCTION_PATH"
    exit 1
fi

log_message "INFO" "$SERVICE_NAME" "infrastructure" "check" "Checking shared infrastructure status"

# Check if service uses shared services from registry
SHARED_SERVICES=$(echo "$REGISTRY" | jq -r '.shared_services[]? // empty' 2>/dev/null || echo "")
USE_SHARED_DB=false

# Check if service requires postgres or redis from shared database-server
if echo "$SHARED_SERVICES" | grep -qE "postgres|redis"; then
    USE_SHARED_DB=true
    log_message "INFO" "$SERVICE_NAME" "infrastructure" "check" "Service uses shared services: $(echo "$SHARED_SERVICES" | tr '\n' ' ')"
fi

# If service uses shared services, always use shared database-server
if [ "$USE_SHARED_DB" = "true" ]; then
    log_message "INFO" "$SERVICE_NAME" "infrastructure" "check" "Checking for shared database-server (db-server-postgres, db-server-redis)"
    
    # Check for shared database-server (db-server-postgres, db-server-redis)
    if docker ps --format "{{.Names}}" | grep -q "^db-server-postgres$"; then
        log_message "INFO" "$SERVICE_NAME" "infrastructure" "check" "Shared PostgreSQL (db-server-postgres) is running"
        POSTGRES_RUNNING=true
    else
        log_message "WARNING" "$SERVICE_NAME" "infrastructure" "check" "Shared PostgreSQL (db-server-postgres) is not running"
        POSTGRES_RUNNING=false
    fi
    
    # Check for shared Redis
    if echo "$SHARED_SERVICES" | grep -q "redis"; then
        if docker ps --format "{{.Names}}" | grep -q "^db-server-redis$"; then
            log_message "INFO" "$SERVICE_NAME" "infrastructure" "check" "Shared Redis (db-server-redis) is running"
            REDIS_RUNNING=true
        else
            log_message "WARNING" "$SERVICE_NAME" "infrastructure" "check" "Shared Redis (db-server-redis) is not running"
            REDIS_RUNNING=false
        fi
    else
        REDIS_RUNNING=true  # Service doesn't need Redis
    fi
    
    # If shared services are running, we're done
    if [ "$POSTGRES_RUNNING" = "true" ] && [ "$REDIS_RUNNING" = "true" ]; then
        log_message "SUCCESS" "$SERVICE_NAME" "infrastructure" "check" "Shared infrastructure is available and running"
        exit 0
    else
        print_error "Shared database-server is required but not running"
        print_error "Please start database-server: cd $(cd "$SCRIPT_DIR/../.." && pwd) && docker compose -f docker-compose.db-server.yml up -d"
        exit 1
    fi
fi

# Navigate to service directory for service-specific infrastructure
cd "$ACTUAL_PATH"

# Infrastructure compose file (for services that don't use shared services)
INFRASTRUCTURE_COMPOSE="docker-compose.infrastructure.yml"
INFRASTRUCTURE_PROJECT="${SERVICE_NAME}_infrastructure"

# Check if infrastructure compose file exists
if [ ! -f "$INFRASTRUCTURE_COMPOSE" ]; then
    log_message "INFO" "$SERVICE_NAME" "infrastructure" "check" "Infrastructure compose file not found, checking for shared database-server"
    
    # Check for shared database-server (db-server-postgres, db-server-redis)
    if docker ps --format "{{.Names}}" | grep -q "^db-server-postgres$"; then
        log_message "INFO" "$SERVICE_NAME" "infrastructure" "check" "Using shared database-server (db-server-postgres)"
        POSTGRES_RUNNING=true
        REDIS_RUNNING=$(docker ps --format "{{.Names}}" | grep -q "^db-server-redis$" && echo true || echo false)
        if [ "$REDIS_RUNNING" = "false" ]; then
            log_message "WARNING" "$SERVICE_NAME" "infrastructure" "check" "Shared Redis (db-server-redis) is not running"
        else
            log_message "INFO" "$SERVICE_NAME" "infrastructure" "check" "Shared Redis (db-server-redis) is running"
        fi
        log_message "SUCCESS" "$SERVICE_NAME" "infrastructure" "check" "Shared infrastructure is available"
        exit 0
    else
        print_error "Infrastructure compose file not found: $INFRASTRUCTURE_COMPOSE"
        print_error "And shared database-server is not running"
        print_error "Either start database-server or ensure docker-compose.infrastructure.yml exists"
        exit 1
    fi
fi

# Service-specific infrastructure (only used if service doesn't use shared services)
# Determine container names from service name
SERVICE_POSTGRES_CONTAINER="${SERVICE_NAME}-postgres"
SERVICE_REDIS_CONTAINER="${SERVICE_NAME}-redis"

# Check if postgres container is running (service-specific infrastructure)
if docker ps --format "{{.Names}}" | grep -q "^${SERVICE_POSTGRES_CONTAINER}$"; then
    log_message "INFO" "$SERVICE_NAME" "infrastructure" "check" "PostgreSQL container (${SERVICE_POSTGRES_CONTAINER}) is running"
    POSTGRES_RUNNING=true
else
    log_message "WARNING" "$SERVICE_NAME" "infrastructure" "check" "PostgreSQL container (${SERVICE_POSTGRES_CONTAINER}) is not running"
    POSTGRES_RUNNING=false
fi

# Check if redis container is running (service-specific infrastructure)
if docker ps --format "{{.Names}}" | grep -q "^${SERVICE_REDIS_CONTAINER}$"; then
    log_message "INFO" "$SERVICE_NAME" "infrastructure" "check" "Redis container (${SERVICE_REDIS_CONTAINER}) is running"
    REDIS_RUNNING=true
else
    log_message "WARNING" "$SERVICE_NAME" "infrastructure" "check" "Redis container (${SERVICE_REDIS_CONTAINER}) is not running"
    REDIS_RUNNING=false
fi

# Start infrastructure if not running
if [ "$POSTGRES_RUNNING" = false ] || [ "$REDIS_RUNNING" = false ]; then
    log_message "INFO" "$SERVICE_NAME" "infrastructure" "start" "Starting shared infrastructure"
    
    if ! check_docker_compose_available; then
        exit 1
    fi
    
    # Check and kill processes using infrastructure ports before starting
    log_message "INFO" "$SERVICE_NAME" "infrastructure" "port-check" "Checking for port conflicts on infrastructure ports"
    
    # Get ports from docker-compose file or use defaults
    local postgres_port="${POSTGRES_PORT:-5432}"
    local redis_port="${REDIS_PORT:-6379}"
    
    # Try to extract ports from compose file
    if [ -f "$INFRASTRUCTURE_COMPOSE" ]; then
        local compose_config=$(docker compose -f "$INFRASTRUCTURE_COMPOSE" config 2>/dev/null || echo "")
        if [ -n "$compose_config" ]; then
            # Extract postgres port
            local pg_port_line=$(echo "$compose_config" | grep -A 10 "^  postgres:" | grep -E "^\s+-.*:.*:" | head -1 || echo "")
            if [ -n "$pg_port_line" ]; then
                postgres_port=$(echo "$pg_port_line" | sed -E 's/.*"([0-9.]+):([0-9]+):([0-9]+)".*/\1:\2/' | sed -E 's/.*"([0-9]+):([0-9]+)".*/\1/' | grep -oE '^[0-9]+' | head -1 || echo "5432")
            fi
            
            # Extract redis port
            local redis_port_line=$(echo "$compose_config" | grep -A 10 "^  redis:" | grep -E "^\s+-.*:.*:" | head -1 || echo "")
            if [ -n "$redis_port_line" ]; then
                redis_port=$(echo "$redis_port_line" | sed -E 's/.*"([0-9.]+):([0-9]+):([0-9]+)".*/\1:\2/' | sed -E 's/.*"([0-9]+):([0-9]+)".*/\1/' | grep -oE '^[0-9]+' | head -1 || echo "6379")
            fi
        fi
    fi
    
    # Kill processes using these ports
    if type kill_port_if_in_use >/dev/null 2>&1; then
        if [ "$POSTGRES_RUNNING" = false ]; then
            kill_port_if_in_use "$postgres_port" "$SERVICE_NAME" "infrastructure"
        fi
        if [ "$REDIS_RUNNING" = false ]; then
            kill_port_if_in_use "$redis_port" "$SERVICE_NAME" "infrastructure"
        fi
    else
        # Fallback: manual port checking
        if [ "$POSTGRES_RUNNING" = false ]; then
            local pg_container=$(docker ps --format "{{.Names}}\t{{.Ports}}" 2>/dev/null | \
                grep -E ":${postgres_port}->|:${postgres_port}/|127\.0\.0\.1:${postgres_port}:" | \
                awk '{print $1}' | grep -v "postgres\|db-server" | head -1 || echo "")
            if [ -n "$pg_container" ]; then
                log_message "WARNING" "$SERVICE_NAME" "infrastructure" "port-check" "Port ${postgres_port} is in use by container ${pg_container}, stopping it"
                docker stop "${pg_container}" 2>/dev/null || true
                docker rm -f "${pg_container}" 2>/dev/null || true
            fi
        fi
        
        if [ "$REDIS_RUNNING" = false ]; then
            local redis_container=$(docker ps --format "{{.Names}}\t{{.Ports}}" 2>/dev/null | \
                grep -E ":${redis_port}->|:${redis_port}/|127\.0\.0\.1:${redis_port}:" | \
                awk '{print $1}' | grep -v "redis\|db-server" | head -1 || echo "")
            if [ -n "$redis_container" ]; then
                log_message "WARNING" "$SERVICE_NAME" "infrastructure" "port-check" "Port ${redis_port} is in use by container ${redis_container}, stopping it"
                docker stop "${redis_container}" 2>/dev/null || true
                docker rm -f "${redis_container}" 2>/dev/null || true
            fi
        fi
    fi
    
    # Start infrastructure
    if ! docker compose -f "$INFRASTRUCTURE_COMPOSE" -p "$INFRASTRUCTURE_PROJECT" up -d; then
        log_message "ERROR" "$SERVICE_NAME" "infrastructure" "start" "Failed to start infrastructure"
        exit 1
    fi
    
    log_message "INFO" "$SERVICE_NAME" "infrastructure" "start" "Waiting for infrastructure to be healthy"
    
    # Wait for postgres to be healthy
    POSTGRES_HEALTHY=false
    for i in {1..30}; do
        if docker exec "${SERVICE_POSTGRES_CONTAINER}" pg_isready -U ${POSTGRES_USER:-postgres} -d ${POSTGRES_DB:-postgres} >/dev/null 2>&1; then
            POSTGRES_HEALTHY=true
            break
        fi
        sleep 1
    done
    
    if [ "$POSTGRES_HEALTHY" = false ]; then
        log_message "ERROR" "$SERVICE_NAME" "infrastructure" "start" "PostgreSQL failed to become healthy"
        exit 1
    fi
    
    # Wait for redis to be healthy
    REDIS_HEALTHY=false
    for i in {1..15}; do
        if docker exec "${SERVICE_REDIS_CONTAINER}" redis-cli ping >/dev/null 2>&1; then
            REDIS_HEALTHY=true
            break
        fi
        sleep 1
    done
    
    if [ "$REDIS_HEALTHY" = false ]; then
        log_message "ERROR" "$SERVICE_NAME" "infrastructure" "start" "Redis failed to become healthy"
        exit 1
    fi
    
    log_message "SUCCESS" "$SERVICE_NAME" "infrastructure" "start" "Infrastructure is healthy and ready"
else
    log_message "SUCCESS" "$SERVICE_NAME" "infrastructure" "check" "Infrastructure is already running"
fi

exit 0

