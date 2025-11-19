#!/bin/bash
# Central Service Startup Script
# Starts all services in dependency order: Infrastructure -> Microservices -> Applications
# Usage: start-all-services.sh [--skip-infrastructure] [--skip-microservices] [--skip-applications] [--service <name>]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTRY_DIR="${NGINX_PROJECT_DIR}/service-registry"
BLUE_GREEN_DIR="${SCRIPT_DIR}/blue-green"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Status symbols
GREEN_CHECK='\033[0;32m✓\033[0m'
RED_X='\033[0;31m✗\033[0m'

# Function to get timestamp
get_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

print_status() {
    echo -e "${BLUE}[INFO]${NC} [$(get_timestamp)] $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} [$(get_timestamp)] $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} [$(get_timestamp)] $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} [$(get_timestamp)] $1"
}

print_detail() {
    echo -e "${CYAN}[DETAIL]${NC} [$(get_timestamp)] $1"
}

# Parse arguments
SKIP_INFRASTRUCTURE=false
SKIP_MICROSERVICES=false
SKIP_APPLICATIONS=false
SINGLE_SERVICE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-infrastructure)
            SKIP_INFRASTRUCTURE=true
            shift
            ;;
        --skip-microservices)
            SKIP_MICROSERVICES=true
            shift
            ;;
        --skip-applications)
            SKIP_APPLICATIONS=true
            shift
            ;;
        --service)
            SINGLE_SERVICE="$2"
            shift 2
            ;;
        *)
            print_error "Unknown option: $1"
            echo "Usage: start-all-services.sh [--skip-infrastructure] [--skip-microservices] [--skip-applications] [--service <name>]"
            exit 1
            ;;
    esac
done

# Service categories and startup order
# Infrastructure services (no dependencies)
INFRASTRUCTURE_SERVICES=(
    "nginx-microservice"
    "database-server"
)

# Microservices (depend only on infrastructure)
MICROSERVICES=(
    "logging-microservice"      # No dependencies
    "auth-microservice"         # Needs postgres
    "payment-microservice"      # Needs postgres
    "notifications-microservice" # Needs postgres + redis
    "crypto-ai-agent"           # Needs postgres + redis
)

# Applications (may depend on microservices)
APPLICATIONS=(
    "statex-platform"           # API gateway, needs postgres + redis
    "statex-ai"                 # Needs postgres + redis
    "statex"                    # Main application, needs postgres + redis
    "e-commerce"                # Heavy application, needs postgres + redis
)

# Function to check if service registry exists
service_exists() {
    local service_name="$1"
    [ -f "${REGISTRY_DIR}/${service_name}.json" ]
}

# Function to check if container is running
container_running() {
    local container_name="$1"
    docker ps --format "{{.Names}}" | grep -q "^${container_name}$"
}

# Function to check if network exists
network_exists() {
    local network_name="$1"
    docker network ls --format "{{.Name}}" | grep -q "^${network_name}$"
}

# Function to start nginx-network
start_nginx_network() {
    print_status "Checking nginx-network..."
    if network_exists "nginx-network"; then
        print_success "Network nginx-network already exists"
        print_detail "Network details:"
        docker network inspect nginx-network --format '  - Subnet: {{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>&1 || true
        return 0
    fi
    
    print_status "Creating nginx-network..."
    print_detail "Executing: docker network create nginx-network"
    if docker network create nginx-network 2>&1; then
        print_success "Network nginx-network created successfully"
        print_detail "Network details:"
        docker network inspect nginx-network --format '  - Subnet: {{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>&1 || true
        return 0
    else
        print_error "Failed to create nginx-network"
        return 1
    fi
}

# Function to start nginx-microservice
start_nginx_microservice() {
    print_status "Starting nginx-microservice..."
    
    cd "$NGINX_PROJECT_DIR"
    print_detail "Working directory: $(pwd)"
    
    # Check if nginx is already running
    if container_running "nginx-microservice"; then
        print_success "nginx-microservice is ${GREEN_CHECK} already running"
        print_detail "Container status:"
        docker ps --filter "name=nginx-microservice" --format "  - {{.Names}}: {{.Status}} ({{.Ports}})" 2>&1 || true
        return 0
    fi
    
    # Start nginx
    print_detail "Executing: docker compose up -d"
    print_detail "Docker compose output:"
    if docker compose up -d 2>&1; then
        print_success "nginx-microservice containers started"
        
        # Show container status
        print_detail "Container status after startup:"
        docker compose ps 2>&1 || true
        
        # Wait for nginx to be healthy
        print_status "Waiting for nginx to be healthy (checking every 2 seconds)..."
        local max_attempts=15
        local attempt=0
        while [ $attempt -lt $max_attempts ]; do
            local nginx_test_output
            nginx_test_output=$(docker exec nginx-microservice nginx -t 2>&1)
            local nginx_test_exit=$?
            if [ $nginx_test_exit -eq 0 ]; then
                print_success "nginx-microservice is ${GREEN_CHECK} healthy (config test passed)"
                print_detail "Config test output:"
                echo "$nginx_test_output" | sed 's/^/  /'
                print_detail "Container logs (last 10 lines):"
                docker compose logs --tail=10 nginx 2>&1 || true
                return 0
            else
                attempt=$((attempt + 1))
                if [ $attempt -lt $max_attempts ]; then
                    print_detail "Health check attempt $attempt/$max_attempts failed:"
                    echo "$nginx_test_output" | sed 's/^/  /' | head -5
                    print_detail "Retrying in 2 seconds..."
                    sleep 2
                fi
            fi
        done
        
        print_warning "nginx-microservice started but config test ${RED_X} failed after $max_attempts attempts"
        print_detail "Container logs (last 20 lines):"
        docker compose logs --tail=20 nginx 2>&1 || true
        return 0  # Continue anyway
    else
        print_error "Failed to start nginx-microservice"
        print_detail "Docker compose logs:"
        docker compose logs --tail=30 2>&1 || true
        return 1
    fi
}

# Function to start database-server
start_database_server() {
    print_status "Starting database-server..."
    
    # Check if database-server is already running
    if container_running "db-server-postgres" && container_running "db-server-redis"; then
        print_success "database-server is ${GREEN_CHECK} already running"
        print_detail "Container status:"
        docker ps --filter "name=db-server" --format "  - {{.Names}}: {{.Status}}" 2>&1 || true
        return 0
    fi
    
    # Check if database-server directory exists
    if [ ! -d "/home/statex/database-server" ]; then
        print_error "database-server directory not found: /home/statex/database-server"
        return 1
    fi
    
    cd /home/statex/database-server
    print_detail "Working directory: $(pwd)"
    
    # Start database-server
    print_detail "Executing: docker compose up -d"
    print_detail "Docker compose output:"
    if docker compose up -d 2>&1; then
        print_success "database-server containers started"
        
        # Show container status
        print_detail "Container status after startup:"
        docker compose ps 2>&1 || true
        
        # Wait for postgres to be healthy
        print_status "Waiting for PostgreSQL to be healthy (checking every 2 seconds)..."
        local max_attempts=30
        local attempt=0
        while [ $attempt -lt $max_attempts ]; do
            attempt=$((attempt + 1))
            print_detail "PostgreSQL health check attempt $attempt/$max_attempts..."
            local pg_output
            pg_output=$(docker exec db-server-postgres pg_isready -U dbadmin 2>&1)
            local pg_exit=$?
            if [ $pg_exit -eq 0 ]; then
                print_success "PostgreSQL is ${GREEN_CHECK} healthy (pg_isready passed)"
                print_detail "PostgreSQL connection info:"
                echo "$pg_output" | sed 's/^/  /'
                break
            else
                print_detail "PostgreSQL ${RED_X} not ready yet:"
                echo "$pg_output" | sed 's/^/  /' | head -3
                print_detail "Waiting 2 seconds before retry..."
            fi
            sleep 2
        done
        
        if [ $attempt -eq $max_attempts ]; then
            print_warning "PostgreSQL health check ${RED_X} timeout after $max_attempts attempts, but continuing..."
            print_detail "PostgreSQL container logs (last 20 lines):"
            docker compose logs --tail=20 postgres 2>&1 || true
        fi
        
        # Wait for redis to be healthy
        print_status "Waiting for Redis to be healthy (checking every 1 second)..."
        attempt=0
        while [ $attempt -lt 15 ]; do
            attempt=$((attempt + 1))
            print_detail "Redis health check attempt $attempt/15..."
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
                print_detail "Waiting 1 second before retry..."
            fi
            sleep 1
        done
        
        if [ $attempt -eq 15 ]; then
            print_warning "Redis health check ${RED_X} timeout after 15 attempts, but continuing..."
            print_detail "Redis container logs (last 20 lines):"
            docker compose logs --tail=20 redis 2>&1 || true
        fi
        
        return 0
    else
        print_error "Failed to start database-server"
        print_detail "Docker compose logs:"
        docker compose logs --tail=30 2>&1 || true
        return 1
    fi
}

# Function to start a service using deploy-smart.sh
start_service() {
    local service_name="$1"
    
    print_status "========================================"
    print_status "Starting service: $service_name"
    print_status "========================================"
    
    if ! service_exists "$service_name"; then
        print_warning "Service registry not found: ${service_name}.json, skipping..."
        return 1
    fi
    
    print_detail "Service registry file: ${REGISTRY_DIR}/${service_name}.json"
    
    # Use deploy-smart.sh to start the service
    if [ ! -f "${BLUE_GREEN_DIR}/deploy-smart.sh" ]; then
        print_error "deploy-smart.sh not found at: ${BLUE_GREEN_DIR}/deploy-smart.sh"
        return 1
    fi
    
    # Check if service containers are already running
    local registry=$(cat "${REGISTRY_DIR}/${service_name}.json" 2>/dev/null)
    if [ -n "$registry" ]; then
        local service_keys=$(echo "$registry" | jq -r '.services | keys[]' 2>/dev/null)
        local all_running=true
        
        while IFS= read -r service_key; do
            local container_base=$(echo "$registry" | jq -r ".services[\"$service_key\"].container_name_base // empty" 2>/dev/null)
            if [ -n "$container_base" ] && [ "$container_base" != "null" ]; then
                # Check for blue, green, or base container name
                if ! docker ps --format "{{.Names}}" | grep -qE "^${container_base}(-blue|-green)?$"; then
                    all_running=false
                    break
                fi
            fi
        done <<< "$service_keys"
        
        if [ "$all_running" = "true" ] && [ -n "$service_keys" ]; then
            print_success "Service $service_name containers are already running, skipping deployment"
            return 0
        fi
    fi
    
    print_detail "Executing: ${BLUE_GREEN_DIR}/deploy-smart.sh $service_name"
    print_detail "Deployment output:"
    print_detail "----------------------------------------"
    
    # Capture output and exit code
    local deploy_output
    local deploy_exit_code
    
    if deploy_output=$("${BLUE_GREEN_DIR}/deploy-smart.sh" "$service_name" 2>&1); then
        deploy_exit_code=0
    else
        deploy_exit_code=$?
    fi
    
    # Display the output
    echo "$deploy_output"
    
    print_detail "----------------------------------------"
    
    # Get container base name from registry (needed for both success and failure cases)
    local container_base=""
    local registry_file="${REGISTRY_DIR}/${service_name}.json"
    if [ -f "$registry_file" ]; then
        container_base=$(jq -r '.services | to_entries[0].value.container_name_base // empty' "$registry_file" 2>/dev/null || echo "")
    fi
    
    if [ $deploy_exit_code -eq 0 ]; then
        print_success "Service $service_name deployment completed successfully"
        
        # Show container status for this service
        print_detail "Checking container status for $service_name..."
        if [ -n "$container_base" ]; then
            print_detail "Looking for containers matching: ${container_base}-*"
            docker ps --filter "name=${container_base}" --format "  - {{.Names}}: {{.Status}} ({{.Ports}})" 2>&1 || true
        fi
        
        # Show recent logs
        print_detail "Recent container logs (last 15 lines):"
        if [ -n "$container_base" ]; then
            local active_container=$(docker ps --filter "name=${container_base}" --format "{{.Names}}" | grep -E "(blue|green)" | head -1)
            if [ -n "$active_container" ]; then
                docker logs --tail=15 "$active_container" 2>&1 | sed 's/^/  /' || true
            fi
        fi
        
        return 0
    else
        print_error "Failed to start service: $service_name (exit code: $deploy_exit_code)"
        print_detail "Error details from deployment:"
        echo "$deploy_output" | grep -i "error\|failed\|fatal" | head -20 | sed 's/^/  /' || true
        
        # Show container status even on failure
        print_detail "Container status after failed deployment:"
        if [ -n "$container_base" ]; then
            docker ps -a --filter "name=${container_base}" --format "  - {{.Names}}: {{.Status}}" 2>&1 || true
        fi
        
        return 1
    fi
}

# Main execution
print_status "=========================================="
print_status "Starting All Services in Dependency Order"
print_status "=========================================="

# Phase 1: Infrastructure
if [ "$SKIP_INFRASTRUCTURE" = false ]; then
    print_status ""
    print_status "Phase 1: Starting Infrastructure Services"
    print_status "----------------------------------------"
    
    # Start nginx-network
    if ! start_nginx_network; then
        print_error "Failed to start nginx-network"
        exit 1
    fi
    
    # Start nginx-microservice
    if ! start_nginx_microservice; then
        print_error "Failed to start nginx-microservice"
        exit 1
    fi
    
    # Start database-server
    if ! start_database_server; then
        print_error "Failed to start database-server"
        exit 1
    fi
    
    print_success "Infrastructure services started"
else
    print_status "Skipping infrastructure services"
fi

# Phase 2: Microservices
if [ "$SKIP_MICROSERVICES" = false ]; then
    print_status ""
    print_status "Phase 2: Starting Microservices"
    print_status "--------------------------------"
    
    service_count=0
    success_count=0
    fail_count=0
    
    for service in "${MICROSERVICES[@]}"; do
        if [ -n "$SINGLE_SERVICE" ] && [ "$SINGLE_SERVICE" != "$service" ]; then
            continue
        fi
        
        service_count=$((service_count + 1))
        print_status ""
        print_status "Microservice $service_count/${#MICROSERVICES[@]}: $service"
        
        if start_service "$service"; then
            success_count=$((success_count + 1))
            print_success "Microservice $service started successfully"
        else
            fail_count=$((fail_count + 1))
            print_error "Microservice $service ${RED_X} failed to start"
            print_error "Stopping startup process due to error"
            exit 1
        fi
        
        # Small delay between services
        print_detail "Waiting 2 seconds before starting next service..."
        sleep 2
    done
    
    print_status ""
    print_status "Microservices summary: $success_count succeeded, $fail_count failed out of $service_count total"
    
    print_success "Microservices phase completed"
else
    print_status "Skipping microservices"
fi

# Phase 3: Applications
if [ "$SKIP_APPLICATIONS" = false ]; then
    print_status ""
    print_status "Phase 3: Starting Applications"
    print_status "------------------------------"
    
    service_count=0
    success_count=0
    fail_count=0
    
    for service in "${APPLICATIONS[@]}"; do
        if [ -n "$SINGLE_SERVICE" ] && [ "$SINGLE_SERVICE" != "$service" ]; then
            continue
        fi
        
        service_count=$((service_count + 1))
        print_status ""
        print_status "Application $service_count/${#APPLICATIONS[@]}: $service"
        
        if start_service "$service"; then
            success_count=$((success_count + 1))
            print_success "Application $service started successfully"
        else
            fail_count=$((fail_count + 1))
            print_error "Application $service ${RED_X} failed to start"
            print_error "Stopping startup process due to error"
            exit 1
        fi
        
        # Small delay between services
        print_detail "Waiting 2 seconds before starting next service..."
        sleep 2
    done
    
    print_status ""
    print_status "Applications summary: $success_count succeeded, $fail_count failed out of $service_count total"
    
    print_success "Applications phase completed"
else
    print_status "Skipping applications"
fi

print_status ""
print_status "=========================================="
print_success "All services startup process completed!"
print_status "=========================================="

# Show running containers
print_status ""
print_status "=========================================="
print_status "Final Container Status Summary"
print_status "=========================================="
print_detail "All running containers:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>&1 | head -30

print_status ""
print_detail "Container health status:"
docker ps --format "{{.Names}}\t{{.Status}}" 2>&1 | head -30 | while IFS=$'\t' read -r name status; do
    if echo "$status" | grep -qE "Up|healthy"; then
        echo -e "  ${GREEN_CHECK} $name: $status"
    else
        echo -e "  ${RED_X} $name: $status"
    fi
done

# Check for unhealthy containers
print_status ""
print_detail "Checking for unhealthy containers..."
if docker ps --format "{{.Names}}\t{{.Status}}" 2>&1 | grep -qE "Restarting|Unhealthy|Exited"; then
    print_warning "Some containers are ${RED_X} not healthy:"
    docker ps --format "{{.Names}}\t{{.Status}}" 2>&1 | grep -E "Restarting|Unhealthy|Exited" | sed "s/^/  ${RED_X} /" || true
else
    print_success "All running containers appear ${GREEN_CHECK} healthy"
fi

exit 0
