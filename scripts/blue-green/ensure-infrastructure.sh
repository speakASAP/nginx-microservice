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

# Navigate to service directory
cd "$ACTUAL_PATH"

# Infrastructure compose file
INFRASTRUCTURE_COMPOSE="docker-compose.infrastructure.yml"
INFRASTRUCTURE_PROJECT="crypto_ai_agent_infrastructure"

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

# Check if postgres container is running (service-specific infrastructure)
if docker ps --format "{{.Names}}" | grep -q "^crypto-ai-postgres$"; then
    log_message "INFO" "$SERVICE_NAME" "infrastructure" "check" "PostgreSQL container is running"
    POSTGRES_RUNNING=true
else
    log_message "WARNING" "$SERVICE_NAME" "infrastructure" "check" "PostgreSQL container is not running"
    POSTGRES_RUNNING=false
fi

# Check if redis container is running (service-specific infrastructure)
if docker ps --format "{{.Names}}" | grep -q "^crypto-ai-redis$"; then
    log_message "INFO" "$SERVICE_NAME" "infrastructure" "check" "Redis container is running"
    REDIS_RUNNING=true
else
    log_message "WARNING" "$SERVICE_NAME" "infrastructure" "check" "Redis container is not running"
    REDIS_RUNNING=false
fi

# Start infrastructure if not running
if [ "$POSTGRES_RUNNING" = false ] || [ "$REDIS_RUNNING" = false ]; then
    log_message "INFO" "$SERVICE_NAME" "infrastructure" "start" "Starting shared infrastructure"
    
    if ! check_docker_compose_available; then
        exit 1
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
        if docker exec crypto-ai-postgres pg_isready -U ${POSTGRES_USER:-crypto} -d ${POSTGRES_DB:-crypto_ai_agent} >/dev/null 2>&1; then
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
        if docker exec crypto-ai-redis redis-cli ping >/dev/null 2>&1; then
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

