#!/bin/bash
# Start Infrastructure Phase
# Starts database-server (postgres + redis)
# Usage: start-infrastructure.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BLUE_GREEN_DIR="${SCRIPT_DIR}/blue-green"

# Load .env file if it exists
if [ -f "${NGINX_PROJECT_DIR}/.env" ]; then
    set -a
    source "${NGINX_PROJECT_DIR}/.env" 2>/dev/null || true
    set +a
fi

# Source shared utilities
source "${SCRIPT_DIR}/startup-utils.sh"

# Function to start database-server
start_database_server() {
    print_status "Starting database-server..."
    
    # Check if database-server is already running and healthy
    local postgres_status=$(check_container_running "db-server-postgres")
    local postgres_code=$?
    local redis_status=$(check_container_running "db-server-redis")
    local redis_code=$?
    
    if [ $postgres_code -eq 2 ] || [ $redis_code -eq 2 ]; then
        # Zero tolerance for restarting containers
        if [ $postgres_code -eq 2 ]; then
            print_error "db-server-postgres is in RESTARTING state - zero tolerance policy"
            print_detail "Container logs (last 30 lines):"
            docker logs --tail 30 db-server-postgres 2>&1 | sed 's/^/  /' || true
            exit 1
        fi
        if [ $redis_code -eq 2 ]; then
            print_error "db-server-redis is in RESTARTING state - zero tolerance policy"
            print_detail "Container logs (last 30 lines):"
            docker logs --tail 30 db-server-redis 2>&1 | sed 's/^/  /' || true
            exit 1
        fi
    fi
    
    if [ $postgres_code -eq 0 ] && [ $redis_code -eq 0 ]; then
        print_success "database-server is ${GREEN_CHECK} already running"
        print_detail "Container status:"
        docker ps --filter "name=db-server" --format "  - {{.Names}}: {{.Status}}" 2>&1 || true
        
        # Verify health checks
        print_status "Verifying database health checks..."
        if ! wait_for_postgres; then
            print_error "PostgreSQL health check failed"
            exit 1
        fi
        if ! wait_for_redis; then
            print_error "Redis health check failed"
            exit 1
        fi
        return 0
    fi
    
    # Check if database-server directory exists
    local db_server_path="${DATABASE_SERVER_PATH:-/home/statex/database-server}"
    if [ ! -d "$db_server_path" ]; then
        print_error "database-server directory not found: $db_server_path"
        exit 1
    fi
    
    cd "$db_server_path"
    print_detail "Working directory: $(pwd)"
    
    # Check and kill processes using database ports before starting
    print_status "Checking for port conflicts on database ports..."
    
    # Get ports from docker-compose file or use defaults
    local postgres_port="${DB_SERVER_PORT:-5432}"
    local redis_port="${REDIS_SERVER_PORT:-6379}"
    
    if [ -f "${BLUE_GREEN_DIR}/utils.sh" ]; then
        source "${BLUE_GREEN_DIR}/utils.sh" 2>/dev/null || true
        if type kill_port_if_in_use >/dev/null 2>&1; then
            kill_port_if_in_use "$postgres_port" "database-server" "infrastructure"
            kill_port_if_in_use "$redis_port" "database-server" "infrastructure"
        fi
    fi
    
    # Also kill any existing database containers that might be restarting
    if type kill_container_if_exists >/dev/null 2>&1; then
        kill_container_if_exists "db-server-postgres" "database-server" "infrastructure"
        kill_container_if_exists "db-server-redis" "database-server" "infrastructure"
    fi
    
    # Fallback: manual port checking if utils.sh not available
    if ! type kill_port_if_in_use >/dev/null 2>&1; then
        # Check for containers using postgres port
        local pg_container=$(docker ps --format "{{.Names}}\t{{.Ports}}" 2>/dev/null | \
            grep -E ":${postgres_port}->|:${postgres_port}/|127\.0\.0\.1:${postgres_port}:" | \
            awk '{print $1}' | grep -v "db-server-postgres" | head -1 || echo "")
        
        if [ -n "$pg_container" ]; then
            print_warning "Port ${postgres_port} is in use by container ${pg_container}, stopping it"
            docker stop "${pg_container}" 2>/dev/null || true
            docker kill "${pg_container}" 2>/dev/null || true
            docker rm -f "${pg_container}" 2>/dev/null || true
        fi
        
        # Check for containers using redis port
        local redis_container=$(docker ps --format "{{.Names}}\t{{.Ports}}" 2>/dev/null | \
            grep -E ":${redis_port}->|:${redis_port}/|127\.0\.0\.1:${redis_port}:" | \
            awk '{print $1}' | grep -v "db-server-redis" | head -1 || echo "")
        
        if [ -n "$redis_container" ]; then
            print_warning "Port ${redis_port} is in use by container ${redis_container}, stopping it"
            docker stop "${redis_container}" 2>/dev/null || true
            docker kill "${redis_container}" 2>/dev/null || true
            docker rm -f "${redis_container}" 2>/dev/null || true
        fi
        
        # Also kill any existing database containers
        if docker ps -a --format "{{.Names}}" 2>/dev/null | grep -qE "^db-server-postgres$|^db-server-redis$"; then
            print_warning "Killing existing database containers"
            docker kill db-server-postgres db-server-redis 2>/dev/null || true
            docker rm -f db-server-postgres db-server-redis 2>/dev/null || true
        fi
    fi
    
    # Start database-server
    print_detail "Executing: docker compose up -d"
    print_detail "Docker compose output:"
    if docker compose up -d 2>&1; then
        print_success "database-server containers started"
        
        # Show container status
        print_detail "Container status after startup:"
        docker compose ps 2>&1 || true
        
        # Wait for postgres to be healthy
        if ! wait_for_postgres; then
            print_error "PostgreSQL health check failed"
            print_detail "PostgreSQL container logs (last 20 lines):"
            docker compose logs --tail=20 postgres 2>&1 | sed 's/^/  /' || true
            exit 1
        fi
        
        # Wait for redis to be healthy
        if ! wait_for_redis; then
            print_error "Redis health check failed"
            print_detail "Redis container logs (last 20 lines):"
            docker compose logs --tail=20 redis 2>&1 | sed 's/^/  /' || true
            exit 1
        fi
        
        return 0
    else
        print_error "Failed to start database-server"
        print_detail "Docker compose logs:"
        docker compose logs --tail=30 2>&1 | sed 's/^/  /' || true
        exit 1
    fi
}

# Function to wait for PostgreSQL health check
wait_for_postgres() {
    print_status "Waiting for PostgreSQL to be healthy (checking every 2 seconds)..."
    
    local max_attempts=30
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        attempt=$((attempt + 1))
        
        # Check if container is restarting (zero tolerance)
        local container_status=$(check_container_running "db-server-postgres")
        local status_code=$?
        
        if [ $status_code -eq 2 ]; then
            print_error "db-server-postgres is in RESTARTING state - zero tolerance policy"
            print_detail "Container logs (last 30 lines):"
            docker logs --tail 30 db-server-postgres 2>&1 | sed 's/^/  /' || true
            return 1
        fi
        
        print_detail "PostgreSQL health check attempt $attempt/$max_attempts..."
        local pg_output
        pg_output=$(docker exec db-server-postgres pg_isready -U dbadmin 2>&1)
        local pg_exit=$?
        
        if [ $pg_exit -eq 0 ]; then
            print_success "PostgreSQL is ${GREEN_CHECK} healthy (pg_isready passed)"
            print_detail "PostgreSQL connection info:"
            echo "$pg_output" | sed 's/^/  /'
            return 0
        else
            print_detail "PostgreSQL ${RED_X} not ready yet:"
            echo "$pg_output" | sed 's/^/  /' | head -3
            if [ $attempt -lt $max_attempts ]; then
                print_detail "Waiting 2 seconds before retry..."
                sleep 2
            fi
        fi
    done
    
    print_error "PostgreSQL health check ${RED_X} failed after $max_attempts attempts"
    return 1
}

# Function to wait for Redis health check
wait_for_redis() {
    print_status "Waiting for Redis to be healthy (checking every 1 second)..."
    
    local max_attempts=15
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        attempt=$((attempt + 1))
        
        # Check if container is restarting (zero tolerance)
        local container_status=$(check_container_running "db-server-redis")
        local status_code=$?
        
        if [ $status_code -eq 2 ]; then
            print_error "db-server-redis is in RESTARTING state - zero tolerance policy"
            print_detail "Container logs (last 30 lines):"
            docker logs --tail 30 db-server-redis 2>&1 | sed 's/^/  /' || true
            return 1
        fi
        
        print_detail "Redis health check attempt $attempt/$max_attempts..."
        local redis_output
        redis_output=$(docker exec db-server-redis redis-cli ping 2>&1)
        local redis_exit=$?
        
        if echo "$redis_output" | grep -q "PONG"; then
            print_success "Redis is ${GREEN_CHECK} healthy (PING/PONG successful)"
            print_detail "Redis connection info:"
            echo "$redis_output" | sed 's/^/  /'
            return 0
        else
            print_detail "Redis ${RED_X} not ready yet:"
            echo "$redis_output" | sed 's/^/  /' | head -3
            if [ $attempt -lt $max_attempts ]; then
                print_detail "Waiting 1 second before retry..."
                sleep 1
            fi
        fi
    done
    
    print_error "Redis health check ${RED_X} failed after $max_attempts attempts"
    return 1
}

# Main execution
print_status "=========================================="
print_status "Starting Infrastructure Phase"
print_status "=========================================="

# Start database-server
if ! start_database_server; then
    print_error "Failed to start database-server"
    exit 1
fi

print_success "Infrastructure phase completed successfully"

exit 0

