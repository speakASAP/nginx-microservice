#!/bin/bash
# Central Service Stop Script
# Stops all services in reverse dependency order: Applications -> Microservices -> Infrastructure
# Usage: stop-all-services.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTRY_DIR="${NGINX_PROJECT_DIR}/service-registry"

# Load .env file if it exists
if [ -f "${NGINX_PROJECT_DIR}/.env" ]; then
    set -a
    source "${NGINX_PROJECT_DIR}/.env" 2>/dev/null || true
    set +a
fi

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

# Service categories (reverse order of startup)
APPLICATIONS=(
    "flipflop"
    "statex"                     # Includes frontend, submission-service, user-portal, content-service, ai-orchestrator, api-gateway
    "crypto-ai-agent"
    "allegro"                    # Allegro integration service
)

MICROSERVICES=(
    "notifications-microservice"
    "payments-microservice"
    "auth-microservice"
    "logging-microservice"
    "ai-microservice"
)

INFRASTRUCTURE_SERVICES=(
    "database-server"
    "nginx-microservice"
)

# Function to check if service registry exists
service_exists() {
    local service_name="$1"
    [ -f "${REGISTRY_DIR}/${service_name}.json" ]
}

# Function to get service path from registry
get_service_path() {
    local service_name="$1"
    local registry_file="${REGISTRY_DIR}/${service_name}.json"
    
    if [ ! -f "$registry_file" ]; then
        return 1
    fi
    
    if command -v jq >/dev/null 2>&1; then
        jq -r '.production_path // .service_path // empty' "$registry_file" 2>/dev/null
    else
        return 1
    fi
}

# Function to stop a service
stop_service() {
    local service_name="$1"
    
    print_status "Stopping service: $service_name"
    
    if ! service_exists "$service_name"; then
        print_warning "Service registry not found: ${service_name}.json, skipping..."
        return 0
    fi
    
    # Cleanup nginx config before stopping containers
    # Source utils.sh to get cleanup function
    BLUE_GREEN_DIR="${SCRIPT_DIR}/blue-green"
    if [ -f "${BLUE_GREEN_DIR}/utils.sh" ]; then
        source "${BLUE_GREEN_DIR}/utils.sh" 2>/dev/null || true
        if type cleanup_service_nginx_config >/dev/null 2>&1; then
            print_detail "Cleaning up nginx config for $service_name"
            cleanup_service_nginx_config "$service_name" || true
        fi
    fi
    
    local service_path=$(get_service_path "$service_name")
    if [ -z "$service_path" ] || [ "$service_path" = "null" ]; then
        print_warning "Service path not found in registry for $service_name, skipping..."
        return 0
    fi
    
    if [ ! -d "$service_path" ]; then
        print_warning "Service directory not found: $service_path, skipping..."
        return 0
    fi
    
    cd "$service_path"
    print_detail "Working directory: $(pwd)"
    
    # Get docker compose file from registry
    local registry_file="${REGISTRY_DIR}/${service_name}.json"
    local compose_file=$(jq -r '.docker_compose_file // "docker-compose.yml"' "$registry_file" 2>/dev/null)
    local project_base=$(jq -r '.docker_project_base // empty' "$registry_file" 2>/dev/null)
    
    # Try to stop blue and green deployments
    local stopped=false
    
    # Try blue deployment
    if [ -f "docker-compose.blue.yml" ]; then
        print_detail "Stopping blue deployment..."
        if docker compose -f docker-compose.blue.yml -p "${project_base}_blue" down 2>&1; then
            stopped=true
            print_success "Blue deployment stopped for $service_name"
        fi
    fi
    
    # Try green deployment
    if [ -f "docker-compose.green.yml" ]; then
        print_detail "Stopping green deployment..."
        if docker compose -f docker-compose.green.yml -p "${project_base}_green" down 2>&1; then
            stopped=true
            print_success "Green deployment stopped for $service_name"
        fi
    fi
    
    # Try default compose file
    if [ -f "$compose_file" ]; then
        print_detail "Stopping with $compose_file..."
        if docker compose -f "$compose_file" down 2>&1; then
            stopped=true
            print_success "Service stopped using $compose_file"
        fi
    fi
    
    # Try infrastructure compose file (from registry)
    local infra_compose=$(jq -r '.infrastructure_compose_file // empty' "$registry_file" 2>/dev/null)
    local infra_project=$(jq -r '.infrastructure_project_name // empty' "$registry_file" 2>/dev/null)
    
    if [ -n "$infra_compose" ] && [ "$infra_compose" != "null" ] && [ -f "$infra_compose" ]; then
        print_detail "Stopping infrastructure: $infra_compose"
        if [ -n "$infra_project" ] && [ "$infra_project" != "null" ]; then
            if docker compose -f "$infra_compose" -p "$infra_project" down 2>&1; then
                stopped=true
                print_success "Infrastructure stopped for $service_name"
            fi
        else
            if docker compose -f "$infra_compose" down 2>&1; then
                stopped=true
                print_success "Infrastructure stopped for $service_name"
            fi
        fi
    fi
    
    # Also check for standard infrastructure compose file (docker-compose.infrastructure.yml)
    # This is used by services that have service-specific infrastructure
    if [ -f "docker-compose.infrastructure.yml" ]; then
        # Try to determine project name from registry or use default pattern
        local default_infra_project="${project_base}_infrastructure"
        if [ -z "$default_infra_project" ] || [ "$default_infra_project" = "null" ]; then
            default_infra_project="${service_name}_infrastructure"
        fi
        
        print_detail "Stopping service-specific infrastructure: docker-compose.infrastructure.yml"
        if docker compose -f "docker-compose.infrastructure.yml" -p "$default_infra_project" down 2>&1; then
            stopped=true
            print_success "Service-specific infrastructure stopped for $service_name"
        fi
    fi
    
    if [ "$stopped" = "true" ]; then
        print_success "Service $service_name stopped"
    else
        print_warning "No running containers found for $service_name"
    fi
    
    return 0
}

# Function to stop nginx-microservice
stop_nginx_microservice() {
    print_status "Stopping nginx-microservice..."
    
    cd "$NGINX_PROJECT_DIR"
    print_detail "Working directory: $(pwd)"
    
    if docker compose down 2>&1; then
        print_success "nginx-microservice stopped"
        return 0
    else
        print_warning "nginx-microservice may not be running or already stopped"
        return 0
    fi
}

# Function to stop database-server
stop_database_server() {
    print_status "Stopping database-server..."
    
    # Load .env to get PRODUCTION_BASE_PATH
    if [ -f "${NGINX_PROJECT_DIR}/.env" ]; then
        set -a
        source "${NGINX_PROJECT_DIR}/.env" 2>/dev/null || true
        set +a
    fi
    
    local production_base="${PRODUCTION_BASE_PATH:-/home/statex}"
    local db_server_path="${DATABASE_SERVER_PATH:-${production_base}/database-server}"
    if [ ! -d "$db_server_path" ]; then
        print_warning "database-server directory not found: $db_server_path"
        return 0
    fi
    
    cd "$db_server_path"
    print_detail "Working directory: $(pwd)"
    
    if docker compose down 2>&1; then
        print_success "database-server stopped"
        return 0
    else
        print_warning "database-server may not be running or already stopped"
        return 0
    fi
}

# Function to stop all remaining running containers
stop_all_remaining_containers() {
    print_status ""
    print_status "Phase 4: Stopping All Remaining Containers"
    print_status "------------------------------------------"
    
    # Get list of all running containers
    local running_containers=$(docker ps --format "{{.Names}}" 2>/dev/null || echo "")
    
    if [ -z "$running_containers" ]; then
        print_success "No remaining containers to stop"
        return 0
    fi
    
    local container_count=$(echo "$running_containers" | wc -l)
    print_status "Found $container_count remaining container(s) to stop"
    
    local stopped_count=0
    local failed_count=0
    
    while IFS= read -r container_name; do
        if [ -z "$container_name" ]; then
            continue
        fi
        
        print_detail "Stopping container: $container_name"
        
        # Try graceful stop first
        if docker stop "$container_name" 2>/dev/null; then
            print_success "Stopped: $container_name"
            stopped_count=$((stopped_count + 1))
        else
            # If graceful stop fails, try force kill
            print_warning "Graceful stop failed for $container_name, trying force kill..."
            if docker kill "$container_name" 2>/dev/null; then
                print_success "Force stopped: $container_name"
                stopped_count=$((stopped_count + 1))
            else
                print_error "Failed to stop: $container_name"
                failed_count=$((failed_count + 1))
            fi
        fi
        
        # Remove the container
        docker rm -f "$container_name" 2>/dev/null || true
        
        sleep 0.5
    done <<< "$running_containers"
    
    print_status ""
    if [ $failed_count -eq 0 ]; then
        print_success "All remaining containers stopped: $stopped_count/$container_count"
    else
        print_warning "Stopped $stopped_count/$container_count containers ($failed_count failed)"
    fi
    
    return 0
}

# Main execution
print_status "=========================================="
print_status "Stopping All Services in Reverse Order"
print_status "=========================================="

# Phase 1: Stop Applications
print_status ""
print_status "Phase 1: Stopping Applications"
print_status "------------------------------"

service_count=0
success_count=0

for service in "${APPLICATIONS[@]}"; do
    service_count=$((service_count + 1))
    print_status ""
    print_status "Application $service_count/${#APPLICATIONS[@]}: $service"
    
    if stop_service "$service"; then
        success_count=$((success_count + 1))
    fi
    
    sleep 1
done

print_status ""
print_status "Applications summary: $success_count stopped out of $service_count total"

# Phase 2: Stop Microservices
print_status ""
print_status "Phase 2: Stopping Microservices"
print_status "-------------------------------"

service_count=0
success_count=0

for service in "${MICROSERVICES[@]}"; do
    service_count=$((service_count + 1))
    print_status ""
    print_status "Microservice $service_count/${#MICROSERVICES[@]}: $service"
    
    if stop_service "$service"; then
        success_count=$((success_count + 1))
    fi
    
    sleep 1
done

print_status ""
print_status "Microservices summary: $success_count stopped out of $service_count total"

# Phase 3: Stop Infrastructure
print_status ""
print_status "Phase 3: Stopping Infrastructure"
print_status "---------------------------------"

# Stop database-server first
stop_database_server

# Stop nginx-microservice last
stop_nginx_microservice

# Phase 4: Stop all remaining containers (not managed by docker-compose)
stop_all_remaining_containers

print_status ""
print_status "=========================================="
print_success "All services stop process completed!"
print_status "=========================================="

# Show final container status
print_status ""
print_status "=========================================="
print_status "Final Container Status Summary"
print_status "=========================================="
print_detail "All containers (running and stopped):"
docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" 2>&1 | head -40

print_status ""
print_detail "Running containers:"
RUNNING_COUNT=$(docker ps -q | wc -l)
if [ "$RUNNING_COUNT" -eq 0 ]; then
    print_success "No containers are running ${GREEN_CHECK}"
else
    print_warning "$RUNNING_COUNT container(s) still running:"
    docker ps --format "  - {{.Names}}: {{.Status}}" 2>&1
    print_status ""
    print_status "Attempting to stop remaining containers..."
    stop_all_remaining_containers
    print_status ""
    # Check again
    RUNNING_COUNT=$(docker ps -q | wc -l)
    if [ "$RUNNING_COUNT" -eq 0 ]; then
        print_success "All containers are now stopped ${GREEN_CHECK}"
    else
        print_error "$RUNNING_COUNT container(s) still running after stop attempt:"
        docker ps --format "  - {{.Names}}: {{.Status}}" 2>&1
    fi
fi

print_status ""
print_detail "Stopped containers:"
STOPPED_COUNT=$(docker ps -a --filter "status=exited" --format "{{.Names}}" | wc -l)
if [ "$STOPPED_COUNT" -gt 0 ]; then
    print_detail "$STOPPED_COUNT container(s) stopped:"
    docker ps -a --filter "status=exited" --format "  - {{.Names}}: {{.Status}}" 2>&1 | head -20
fi

# Run status script if it exists
if [ -f "$SCRIPT_DIR/status-all-services.sh" ]; then
    "$SCRIPT_DIR/status-all-services.sh" 2>/dev/null || true
fi

exit 0
