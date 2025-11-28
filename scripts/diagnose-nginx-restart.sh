#!/bin/bash
# Diagnose Nginx Container Restart Loop
# Usage: diagnose-nginx-restart.sh [container_id]

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

CONTAINER_NAME="nginx-microservice"
CONTAINER_ID="${1:-}"

print_header "Nginx Container Restart Diagnosis"
echo ""

# If container ID provided, use it; otherwise use container name
if [ -n "$CONTAINER_ID" ]; then
    print_info "Checking container ID: $CONTAINER_ID"
    CONTAINER_REF="$CONTAINER_ID"
else
    print_info "Checking container name: $CONTAINER_NAME"
    CONTAINER_REF="$CONTAINER_NAME"
fi

# 1. Check container status
print_header "1. Container Status"
if docker ps -a --format "{{.ID}}\t{{.Names}}\t{{.Status}}" 2>/dev/null | grep -qE "(${CONTAINER_NAME}|${CONTAINER_ID})"; then
    print_info "Container found:"
    docker ps -a --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null | grep -E "(${CONTAINER_NAME}|${CONTAINER_ID})" || true
    echo ""
    
    # Get detailed status
    local status=$(docker ps --format "{{.Names}}\t{{.Status}}" 2>/dev/null | grep -E "^${CONTAINER_NAME}" | awk '{print $2}' || echo "")
    if [ -n "$status" ]; then
        if echo "$status" | grep -qE "Restarting"; then
            print_error "Container is in RESTARTING state - this indicates a restart loop"
        elif echo "$status" | grep -qE "Up"; then
            print_success "Container is running"
        else
            print_warning "Container status: $status"
        fi
    else
        print_warning "Container exists but is not running"
    fi
else
    print_error "Container not found: $CONTAINER_REF"
    exit 1
fi

echo ""

# 2. Check container logs
print_header "2. Container Logs (Last 50 lines)"
if docker logs --tail 50 "$CONTAINER_REF" 2>&1 | head -50; then
    echo ""
    print_info "Logs retrieved successfully"
else
    print_error "Failed to retrieve logs"
fi

echo ""

# 3. Test nginx configuration
print_header "3. Nginx Configuration Test"
print_info "Attempting to test nginx configuration..."

# First, check if container is restarting
local status=$(docker ps --format "{{.Names}}\t{{.Status}}" 2>/dev/null | grep -E "^${CONTAINER_NAME}" | awk '{print $2}' || echo "")
if [ -n "$status" ] && echo "$status" | grep -qE "Restarting"; then
    print_warning "Container is restarting, cannot exec into it"
    print_info "Stopping container temporarily to test config..."
    
    # Stop container
    docker stop "$CONTAINER_REF" 2>/dev/null || true
    sleep 2
    
    # Try to test config using docker run with same volumes
    print_info "Testing config using temporary container with same volumes..."
    cd "$PROJECT_DIR"
    
    if docker compose run --rm nginx nginx -t 2>&1; then
        print_success "Nginx configuration is valid"
        CONFIG_VALID=true
    else
        print_error "Nginx configuration has errors (see above)"
        CONFIG_VALID=false
    fi
else
    # Container is running, test directly
    if docker exec "$CONTAINER_REF" nginx -t 2>&1; then
        print_success "Nginx configuration is valid"
        CONFIG_VALID=true
    else
        print_error "Nginx configuration has errors (see above)"
        CONFIG_VALID=false
    fi
fi

echo ""

# 4. Check port conflicts
print_header "4. Port Conflicts"
print_info "Checking for processes using ports 80 and 443..."

local port80_usage=$(docker ps --format "{{.Names}}\t{{.Ports}}" 2>/dev/null | grep -E ":80->|:80/|0\.0\.0\.0:80:" | grep -v "$CONTAINER_NAME" || echo "")
local port443_usage=$(docker ps --format "{{.Names}}\t{{.Ports}}" 2>/dev/null | grep -E ":443->|:443/|0\.0\.0\.0:443:" | grep -v "$CONTAINER_NAME" || echo "")

if [ -n "$port80_usage" ]; then
    print_warning "Port 80 is in use by other containers:"
    echo "$port80_usage" | sed 's/^/  /'
else
    print_success "Port 80 is available"
fi

if [ -n "$port443_usage" ]; then
    print_warning "Port 443 is in use by other containers:"
    echo "$port443_usage" | sed 's/^/  /'
else
    print_success "Port 443 is available"
fi

echo ""

# 5. Check volume mounts
print_header "5. Volume Mounts"
print_info "Checking volume mounts..."

if docker inspect "$CONTAINER_REF" --format '{{json .Mounts}}' 2>/dev/null | python3 -m json.tool 2>/dev/null; then
    print_success "Volume mounts retrieved"
else
    print_warning "Could not retrieve volume mount information"
fi

echo ""

# 6. Check network connectivity
print_header "6. Network Connectivity"
print_info "Checking if container is on nginx-network..."

if docker inspect "$CONTAINER_REF" --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}}{{end}}' 2>/dev/null | grep -q "nginx-network"; then
    print_success "Container is on nginx-network"
else
    print_warning "Container may not be on nginx-network"
fi

echo ""

# 7. Recommendations
print_header "7. Recommendations"

if [ "$CONFIG_VALID" = "false" ]; then
    print_error "ROOT CAUSE: Invalid nginx configuration"
    echo ""
    print_info "Fix steps:"
    echo "  1. Check nginx configuration files in: $PROJECT_DIR/nginx/conf.d/"
    echo "  2. Look for syntax errors in the logs above"
    echo "  3. Test config manually: docker compose run --rm nginx nginx -t"
    echo "  4. Fix errors and restart: ./scripts/restart-nginx.sh"
elif [ -n "$status" ] && echo "$status" | grep -qE "Restarting"; then
    print_warning "Container is restarting but config appears valid"
    echo ""
    print_info "Possible causes:"
    echo "  - Health check failing (check healthcheck in docker-compose.yml)"
    echo "  - Resource constraints (memory/CPU)"
    echo "  - Dependency issue (certbot not ready)"
    echo ""
    print_info "Fix steps:"
    echo "  1. Stop the container: docker stop $CONTAINER_REF"
    echo "  2. Check logs: docker logs $CONTAINER_REF"
    echo "  3. Restart: ./scripts/restart-nginx.sh"
else
    print_success "No obvious issues detected"
    print_info "If problems persist, check:"
    echo "  - Application logs: docker logs $CONTAINER_REF"
    echo "  - System resources: docker stats $CONTAINER_REF"
    echo "  - Nginx error logs: $PROJECT_DIR/logs/nginx/error.log"
fi

echo ""
print_header "Diagnosis Complete"

