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
NC='\033[0m' # No Color

print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
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
    if network_exists "nginx-network"; then
        print_success "Network nginx-network already exists"
        return 0
    fi
    
    print_status "Creating nginx-network..."
    if docker network create nginx-network >/dev/null 2>&1; then
        print_success "Network nginx-network created"
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
    
    # Check if nginx is already running
    if container_running "nginx-microservice"; then
        print_success "nginx-microservice is already running"
        return 0
    fi
    
    # Start nginx
    if docker compose up -d >/dev/null 2>&1; then
        print_success "nginx-microservice started"
        
        # Wait for nginx to be healthy
        print_status "Waiting for nginx to be healthy..."
        sleep 5
        
        # Test nginx config
        if docker exec nginx-microservice nginx -t >/dev/null 2>&1; then
            print_success "nginx-microservice is healthy"
            return 0
        else
            print_warning "nginx-microservice started but config test failed"
            return 0  # Continue anyway
        fi
    else
        print_error "Failed to start nginx-microservice"
        return 1
    fi
}

# Function to start database-server
start_database_server() {
    print_status "Starting database-server..."
    
    # Check if database-server is already running
    if container_running "db-server-postgres" && container_running "db-server-redis"; then
        print_success "database-server is already running"
        return 0
    fi
    
    # Check if database-server directory exists
    if [ ! -d "/home/statex/database-server" ]; then
        print_error "database-server directory not found: /home/statex/database-server"
        return 1
    fi
    
    cd /home/statex/database-server
    
    # Start database-server
    if docker compose up -d >/dev/null 2>&1; then
        print_success "database-server started"
        
        # Wait for postgres to be healthy
        print_status "Waiting for PostgreSQL to be healthy..."
        local max_attempts=30
        local attempt=0
        while [ $attempt -lt $max_attempts ]; do
            if docker exec db-server-postgres pg_isready -U dbadmin >/dev/null 2>&1; then
                print_success "PostgreSQL is healthy"
                break
            fi
            attempt=$((attempt + 1))
            sleep 2
        done
        
        if [ $attempt -eq $max_attempts ]; then
            print_warning "PostgreSQL health check timeout, but continuing..."
        fi
        
        # Wait for redis to be healthy
        print_status "Waiting for Redis to be healthy..."
        attempt=0
        while [ $attempt -lt 15 ]; do
            if docker exec db-server-redis redis-cli ping >/dev/null 2>&1; then
                print_success "Redis is healthy"
                return 0
            fi
            attempt=$((attempt + 1))
            sleep 1
        done
        
        if [ $attempt -eq 15 ]; then
            print_warning "Redis health check timeout, but continuing..."
        fi
        
        return 0
    else
        print_error "Failed to start database-server"
        return 1
    fi
}

# Function to start a service using deploy-smart.sh
start_service() {
    local service_name="$1"
    
    if ! service_exists "$service_name"; then
        print_warning "Service registry not found: ${service_name}.json, skipping..."
        return 1
    fi
    
    print_status "Starting service: $service_name"
    
    # Use deploy-smart.sh to start the service
    if [ -f "${BLUE_GREEN_DIR}/deploy-smart.sh" ]; then
        if "${BLUE_GREEN_DIR}/deploy-smart.sh" "$service_name" >/dev/null 2>&1; then
            print_success "Service $service_name started successfully"
            return 0
        else
            print_error "Failed to start service: $service_name"
            return 1
        fi
    else
        print_error "deploy-smart.sh not found"
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
    
    for service in "${MICROSERVICES[@]}"; do
        if [ -n "$SINGLE_SERVICE" ] && [ "$SINGLE_SERVICE" != "$service" ]; then
            continue
        fi
        
        if start_service "$service"; then
            print_success "Microservice $service started"
        else
            print_warning "Microservice $service failed to start, continuing..."
        fi
        
        # Small delay between services
        sleep 2
    done
    
    print_success "Microservices phase completed"
else
    print_status "Skipping microservices"
fi

# Phase 3: Applications
if [ "$SKIP_APPLICATIONS" = false ]; then
    print_status ""
    print_status "Phase 3: Starting Applications"
    print_status "------------------------------"
    
    for service in "${APPLICATIONS[@]}"; do
        if [ -n "$SINGLE_SERVICE" ] && [ "$SINGLE_SERVICE" != "$service" ]; then
            continue
        fi
        
        if start_service "$service"; then
            print_success "Application $service started"
        else
            print_warning "Application $service failed to start, continuing..."
        fi
        
        # Small delay between services
        sleep 2
    done
    
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
print_status "Running containers:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | head -20

exit 0
