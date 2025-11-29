#!/bin/bash
# Diagnose Allegro Service Restart Issues
# Usage: diagnose-allegro-restarts.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

print_info() {
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

# Allegro service containers
ALLEGRO_CONTAINERS=(
    "allegro-api-gateway-blue"
    "allegro-api-gateway-green"
    "allegro-import-service-blue"
    "allegro-import-service-green"
    "allegro-webhook-service-blue"
    "allegro-webhook-service-green"
    "allegro-allegro-service-blue"
    "allegro-allegro-service-green"
    "allegro-sync-service-blue"
    "allegro-sync-service-green"
    "allegro-product-service-blue"
    "allegro-product-service-green"
    "allegro-scheduler-service-blue"
    "allegro-scheduler-service-green"
    "allegro-settings-service-blue"
    "allegro-settings-service-green"
)

print_header "Allegro Service Restart Diagnosis"
echo ""

# 1. Check container status
print_header "1. Container Status"
RESTARTING_CONTAINERS=()
RUNNING_CONTAINERS=()
STOPPED_CONTAINERS=()

for container in "${ALLEGRO_CONTAINERS[@]}"; do
    if docker ps -a --format "{{.Names}}\t{{.Status}}" 2>/dev/null | grep -q "^${container}"; then
        status=$(docker ps -a --format "{{.Names}}\t{{.Status}}" 2>/dev/null | grep "^${container}" | awk '{print $2}')
        
        if echo "$status" | grep -qE "Restarting"; then
            RESTARTING_CONTAINERS+=("$container")
            print_error "Restarting: $container - $status"
        elif echo "$status" | grep -qE "^Up"; then
            RUNNING_CONTAINERS+=("$container")
            print_success "Running: $container - $status"
        else
            STOPPED_CONTAINERS+=("$container")
            print_warning "Stopped/Exited: $container - $status"
        fi
    fi
done

echo ""
print_info "Summary:"
print_info "  Running: ${#RUNNING_CONTAINERS[@]}"
print_info "  Restarting: ${#RESTARTING_CONTAINERS[@]}"
print_info "  Stopped: ${#STOPPED_CONTAINERS[@]}"

if [ ${#RESTARTING_CONTAINERS[@]} -eq 0 ]; then
    print_success "No restarting containers found"
    exit 0
fi

echo ""

# 2. Check logs for restarting containers
print_header "2. Container Logs (Last 50 lines)"
for container in "${RESTARTING_CONTAINERS[@]}"; do
    print_header "Logs for: $container"
    if docker logs --tail 50 "$container" 2>&1 | head -50; then
        echo ""
    else
        print_error "Failed to retrieve logs for $container"
    fi
    echo ""
done

# 3. Check for common issues
print_header "3. Common Issues Check"

# Check database connectivity
print_info "Checking database connectivity..."
if docker ps --format "{{.Names}}" | grep -q "^db-server-postgres$"; then
    print_success "Shared PostgreSQL (db-server-postgres) is running"
    
    # Try to connect to database
    if docker exec db-server-postgres pg_isready -U ${DB_SERVER_ADMIN_USER:-dbadmin} >/dev/null 2>&1; then
        print_success "PostgreSQL is accepting connections"
    else
        print_error "PostgreSQL is not accepting connections"
    fi
else
    print_error "Shared PostgreSQL (db-server-postgres) is not running"
    print_info "Allegro services require shared database-server"
fi

echo ""

# Check network connectivity
print_info "Checking network connectivity..."
if docker network ls --format "{{.Name}}" | grep -q "^nginx-network$"; then
    print_success "nginx-network exists"
    
    # Check if restarting containers are on the network
    for container in "${RESTARTING_CONTAINERS[@]}"; do
        if docker inspect "$container" --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}}{{end}}' 2>/dev/null | grep -q "nginx-network"; then
            print_success "$container is on nginx-network"
        else
            print_error "$container is NOT on nginx-network"
        fi
    done
else
    print_error "nginx-network does not exist"
fi

echo ""

# Check resource constraints
print_header "4. Resource Constraints"
print_info "Checking container resource usage..."
for container in "${RESTARTING_CONTAINERS[@]}"; do
    print_info "Resource usage for: $container"
    docker stats --no-stream --format "  CPU: {{.CPUPerc}}, Memory: {{.MemUsage}}" "$container" 2>/dev/null || print_warning "  Could not retrieve stats"
done

echo ""

# Check health check status
print_header "5. Health Check Status"
for container in "${RESTARTING_CONTAINERS[@]}"; do
    print_info "Health check for: $container"
    health=$(docker inspect "$container" --format '{{.State.Health.Status}}' 2>/dev/null || echo "no healthcheck")
    print_info "  Health status: $health"
    
    if [ "$health" != "no healthcheck" ]; then
        health_logs=$(docker inspect "$container" --format '{{range .State.Health.Log}}{{.Output}}{{end}}' 2>/dev/null | tail -3 || echo "")
        if [ -n "$health_logs" ]; then
            print_info "  Recent health check output:"
            echo "$health_logs" | sed 's/^/    /'
        fi
    fi
    echo ""
done

# 6. Recommendations
print_header "6. Recommendations"

if [ ${#RESTARTING_CONTAINERS[@]} -gt 0 ]; then
    print_warning "Found ${#RESTARTING_CONTAINERS[@]} restarting container(s)"
    echo ""
    print_info "Common causes and fixes:"
    echo ""
    echo "  1. Database connection issues:"
    echo "     - Verify db-server-postgres is running: docker ps | grep db-server-postgres"
    echo "     - Check database credentials in service environment variables"
    echo "     - Verify network connectivity: docker network inspect nginx-network"
    echo ""
    echo "  2. Application errors:"
    echo "     - Check logs above for error messages"
    echo "     - Verify environment variables are set correctly"
    echo "     - Check if required dependencies are available"
    echo ""
    echo "  3. Resource constraints:"
    echo "     - Check if containers are running out of memory"
    echo "     - Verify CPU limits are appropriate"
    echo "     - Check disk space: df -h"
    echo ""
    echo "  4. Health check failures:"
    echo "     - Verify health check endpoints are accessible"
    echo "     - Check if health check timeouts are too short"
    echo "     - Review health check configuration in docker-compose files"
    echo ""
    print_info "To view full logs for a specific container:"
    echo "  docker logs -f <container-name>"
    echo ""
    print_info "To restart a specific service:"
    echo "  ./scripts/blue-green/deploy-smart.sh allegro"
fi

echo ""
print_header "Diagnosis Complete"

