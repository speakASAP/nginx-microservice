#!/bin/bash
# Start Database Server
# Checks if database-server (postgres + redis) is running, and starts it if not
# Usage: start-database-server.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Load .env file if it exists
if [ -f "${NGINX_PROJECT_DIR}/.env" ]; then
    set -a
    source "${NGINX_PROJECT_DIR}/.env" 2>/dev/null || true
    set +a
fi

# Source shared utilities
source "${SCRIPT_DIR}/../startup-utils.sh"
source "${SCRIPT_DIR}/utils.sh"

# Function to wait for PostgreSQL health check
wait_for_postgres() {
    log_message "INFO" "database-server" "health" "postgres" "Waiting for PostgreSQL to be healthy..."
    
    local max_attempts=30
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        attempt=$((attempt + 1))
        
        # Check if container is restarting (zero tolerance)
        local container_status=$(check_container_running "db-server-postgres")
        local status_code=$?
        
        if [ $status_code -eq 2 ]; then
            log_message "ERROR" "database-server" "health" "postgres" "db-server-postgres is in RESTARTING state - zero tolerance policy"
            return 1
        fi
        
        log_message "INFO" "database-server" "health" "postgres" "Health check attempt $attempt/$max_attempts..."
        local pg_output
        pg_output=$(docker exec db-server-postgres pg_isready -U ${DB_SERVER_ADMIN_USER:-dbadmin} 2>&1)
        local pg_exit=$?
        
        if [ $pg_exit -eq 0 ]; then
            log_message "SUCCESS" "database-server" "health" "postgres" "PostgreSQL is healthy (pg_isready passed)"
            return 0
        else
            if [ $attempt -lt $max_attempts ]; then
                sleep 2
            fi
        fi
    done
    
    log_message "ERROR" "database-server" "health" "postgres" "PostgreSQL health check failed after $max_attempts attempts"
    return 1
}

# Function to wait for Redis health check
wait_for_redis() {
    log_message "INFO" "database-server" "health" "redis" "Waiting for Redis to be healthy..."
    
    local max_attempts=15
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        attempt=$((attempt + 1))
        
        # Check if container is restarting (zero tolerance)
        local container_status=$(check_container_running "db-server-redis")
        local status_code=$?
        
        if [ $status_code -eq 2 ]; then
            log_message "ERROR" "database-server" "health" "redis" "db-server-redis is in RESTARTING state - zero tolerance policy"
            return 1
        fi
        
        log_message "INFO" "database-server" "health" "redis" "Health check attempt $attempt/$max_attempts..."
        local redis_output
        redis_output=$(docker exec db-server-redis redis-cli ping 2>&1)
        local redis_exit=$?
        
        if echo "$redis_output" | grep -q "PONG"; then
            log_message "SUCCESS" "database-server" "health" "redis" "Redis is healthy (PING/PONG successful)"
            return 0
        else
            if [ $attempt -lt $max_attempts ]; then
                sleep 1
            fi
        fi
    done
    
    log_message "ERROR" "database-server" "health" "redis" "Redis health check failed after $max_attempts attempts"
    return 1
}

# Main function to start database-server
start_database_server() {
    log_message "INFO" "database-server" "start" "check" "Checking database-server status..."
    
    # Check if database-server is already running and healthy
    local postgres_status=$(check_container_running "db-server-postgres")
    local postgres_code=$?
    local redis_status=$(check_container_running "db-server-redis")
    local redis_code=$?
    
    if [ $postgres_code -eq 2 ] || [ $redis_code -eq 2 ]; then
        # Zero tolerance for restarting containers
        if [ $postgres_code -eq 2 ]; then
            log_message "ERROR" "database-server" "start" "postgres" "db-server-postgres is in RESTARTING state - zero tolerance policy"
            return 1
        fi
        if [ $redis_code -eq 2 ]; then
            log_message "ERROR" "database-server" "start" "redis" "db-server-redis is in RESTARTING state - zero tolerance policy"
            return 1
        fi
    fi
    
    if [ $postgres_code -eq 0 ] && [ $redis_code -eq 0 ]; then
        log_message "INFO" "database-server" "start" "check" "database-server is already running"
        
        # Verify health checks
        if ! wait_for_postgres; then
            log_message "ERROR" "database-server" "start" "postgres" "PostgreSQL health check failed"
            return 1
        fi
        if ! wait_for_redis; then
            log_message "ERROR" "database-server" "start" "redis" "Redis health check failed"
            return 1
        fi
        
        log_message "SUCCESS" "database-server" "start" "check" "database-server is running and healthy"
        return 0
    fi
    
    # Check if database-server directory exists
    local db_server_path="${DATABASE_SERVER_PATH:-/home/statex/database-server}"
    if [ ! -d "$db_server_path" ]; then
        log_message "ERROR" "database-server" "start" "check" "database-server directory not found: $db_server_path"
        return 1
    fi
    
    log_message "INFO" "database-server" "start" "check" "database-server is not running, starting it..."
    log_message "INFO" "database-server" "start" "path" "Working directory: $db_server_path"
    
    cd "$db_server_path"
    
    # Check and kill processes using database ports before starting
    log_message "INFO" "database-server" "start" "ports" "Checking for port conflicts on database ports..."
    
    # Get ports from docker-compose file or use defaults
    local postgres_port="${DB_SERVER_PORT:-5432}"
    local redis_port="${REDIS_SERVER_PORT:-6379}"
    
    # Load utils.sh for port checking functions
    if [ -f "${SCRIPT_DIR}/utils.sh" ]; then
        source "${SCRIPT_DIR}/utils.sh" 2>/dev/null || true
        if type kill_port_if_in_use >/dev/null 2>&1; then
            kill_port_if_in_use "$postgres_port" "database-server" "infrastructure" || true
            kill_port_if_in_use "$redis_port" "database-server" "infrastructure" || true
        fi
    fi
    
    # Also kill any existing database containers that might be restarting
    if type kill_container_if_exists >/dev/null 2>&1; then
        kill_container_if_exists "db-server-postgres" "database-server" "infrastructure" || true
        kill_container_if_exists "db-server-redis" "database-server" "infrastructure" || true
    fi
    
    # Fallback: manual port checking if utils.sh not available
    if ! type kill_port_if_in_use >/dev/null 2>&1; then
        # Check for containers using postgres port
        local pg_container=$(docker ps --format "{{.Names}}\t{{.Ports}}" 2>/dev/null | \
            grep -E ":${postgres_port}->|:${postgres_port}/|127\.0\.0\.1:${postgres_port}:" | \
            awk '{print $1}' | grep -v "db-server-postgres" | head -1 || echo "")
        
        if [ -n "$pg_container" ]; then
            log_message "WARNING" "database-server" "start" "ports" "Port ${postgres_port} is in use by container ${pg_container}, stopping it"
            docker stop "${pg_container}" 2>/dev/null || true
            docker kill "${pg_container}" 2>/dev/null || true
            docker rm -f "${pg_container}" 2>/dev/null || true
        fi
        
        # Check for containers using redis port
        local redis_container=$(docker ps --format "{{.Names}}\t{{.Ports}}" 2>/dev/null | \
            grep -E ":${redis_port}->|:${redis_port}/|127\.0\.0\.1:${redis_port}:" | \
            awk '{print $1}' | grep -v "db-server-redis" | head -1 || echo "")
        
        if [ -n "$redis_container" ]; then
            log_message "WARNING" "database-server" "start" "ports" "Port ${redis_port} is in use by container ${redis_container}, stopping it"
            docker stop "${redis_container}" 2>/dev/null || true
            docker kill "${redis_container}" 2>/dev/null || true
            docker rm -f "${redis_container}" 2>/dev/null || true
        fi
        
        # Also kill any existing database containers
        if docker ps -a --format "{{.Names}}" 2>/dev/null | grep -qE "^db-server-postgres$|^db-server-redis$"; then
            log_message "WARNING" "database-server" "start" "ports" "Killing existing database containers"
            docker kill db-server-postgres db-server-redis 2>/dev/null || true
            docker rm -f db-server-postgres db-server-redis 2>/dev/null || true
        fi
    fi
    
    # Start database-server
    log_message "INFO" "database-server" "start" "docker" "Executing: docker compose up -d"
    if docker compose up -d 2>&1; then
        log_message "SUCCESS" "database-server" "start" "docker" "database-server containers started"
        
        # Wait for postgres to be healthy
        if ! wait_for_postgres; then
            log_message "ERROR" "database-server" "start" "postgres" "PostgreSQL health check failed"
            log_message "INFO" "database-server" "start" "postgres" "PostgreSQL container logs (last 20 lines):"
            docker compose logs --tail=20 postgres 2>&1 | sed 's/^/  /' || true
            return 1
        fi
        
        # Wait for redis to be healthy
        if ! wait_for_redis; then
            log_message "ERROR" "database-server" "start" "redis" "Redis health check failed"
            log_message "INFO" "database-server" "start" "redis" "Redis container logs (last 20 lines):"
            docker compose logs --tail=20 redis 2>&1 | sed 's/^/  /' || true
            return 1
        fi
        
        log_message "SUCCESS" "database-server" "start" "complete" "database-server started successfully and is healthy"
        return 0
    else
        log_message "ERROR" "database-server" "start" "docker" "Failed to start database-server"
        log_message "INFO" "database-server" "start" "docker" "Docker compose logs:"
        docker compose logs --tail=30 2>&1 | sed 's/^/  /' || true
        return 1
    fi
}

# Main execution
if ! start_database_server; then
    exit 1
fi

exit 0

