#!/bin/bash
# Diagnostic Functions
# Modular functions for container diagnostics

# Source output functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/output.sh" ]; then
    source "${SCRIPT_DIR}/output.sh"
fi

# Check container restart loop
check_container_restart() {
    local container="$1"
    
    print_section "1. Container Restart Status"
    
    if ! docker ps -a --format "{{.Names}}" 2>/dev/null | grep -q "^${container}$"; then
        print_error "Container not found: $container"
        return 1
    fi
    
    local status=$(docker ps --format "{{.Names}}\t{{.Status}}" 2>/dev/null | grep "^${container}" | awk '{print $2}' || echo "")
    
    if [ -z "$status" ]; then
        print_warning "Container exists but is not running"
        print_info "Container details:"
        docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null | grep "^${container}" || true
        return 1
    fi
    
    if echo "$status" | grep -qE "Restarting"; then
        print_error "Container is in RESTARTING state - restart loop detected"
        local restart_count=$(docker inspect --format='{{.RestartCount}}' "$container" 2>/dev/null || echo "unknown")
        print_info "Restart count: $restart_count"
        return 1
    elif echo "$status" | grep -qE "Up"; then
        print_success "Container is running"
        print_info "Status: $status"
        return 0
    else
        print_warning "Container status: $status"
        return 1
    fi
}

# Check 502 errors
check_502_errors() {
    local container="$1"
    
    print_section "2. 502 Error Check"
    
    # Check if nginx-network exists
    if ! docker network inspect nginx-network >/dev/null 2>&1; then
        print_error "nginx-network does not exist"
        print_info "Create it with: docker network create nginx-network"
        return 1
    fi
    
    print_success "nginx-network exists"
    
    # Check if container is on nginx-network
    local on_network=$(docker network inspect nginx-network --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null | grep -o "$container" || echo "")
    
    if [ -z "$on_network" ]; then
        print_error "Container $container is not on nginx-network"
        print_info "Connect with: docker network connect nginx-network $container"
        
        # Show containers that are on the network
        print_info "Containers on nginx-network:"
        docker network inspect nginx-network --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null | tr ' ' '\n' | grep -v '^$' | sed 's/^/  - /' || true
        return 1
    else
        print_success "Container is on nginx-network"
    fi
    
    # Check if container is responding (generic health check)
    if docker ps --format "{{.Names}}" | grep -q "^${container}$"; then
        print_info "Container network connectivity: OK"
        return 0
    else
        print_warning "Container is not running - cannot check network connectivity"
        return 1
    fi
}

# Check container health
check_container_health() {
    local container="$1"
    
    print_section "3. Container Health"
    
    if ! docker ps -a --format "{{.Names}}" 2>/dev/null | grep -q "^${container}$"; then
        print_error "Container not found: $container"
        return 1
    fi
    
    local health_status=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "none")
    
    if [ "$health_status" = "healthy" ]; then
        print_success "Container health: healthy"
        return 0
    elif [ "$health_status" = "unhealthy" ]; then
        print_error "Container health: unhealthy"
        print_info "Check container logs for health check failures"
        return 1
    elif [ "$health_status" = "starting" ]; then
        print_warning "Container health: starting (health check in progress)"
        return 0
    else
        print_info "Container health: $health_status (no health check configured)"
        return 0
    fi
}

# Check network connectivity
check_network_connectivity() {
    local container="$1"
    
    print_section "4. Network Connectivity"
    
    # Check if container exists
    if ! docker ps -a --format "{{.Names}}" 2>/dev/null | grep -q "^${container}$"; then
        print_error "Container not found: $container"
        return 1
    fi
    
    # Check networks
    local networks=$(docker inspect --format='{{range $net, $conf := .NetworkSettings.Networks}}{{$net}} {{end}}' "$container" 2>/dev/null || echo "")
    
    if [ -z "$networks" ]; then
        print_error "Container has no networks attached"
        return 1
    fi
    
    if echo "$networks" | grep -q "nginx-network"; then
        print_success "Container is on nginx-network"
    else
        print_warning "Container is not on nginx-network"
    fi
    
    print_info "Networks: $networks"
    
    # Check if container is running
    if docker ps --format "{{.Names}}" | grep -q "^${container}$"; then
        print_success "Container is running and network connectivity should be available"
        return 0
    else
        print_warning "Container is not running - network connectivity unavailable"
        return 1
    fi
}

# Show container logs
show_container_logs() {
    local container="$1"
    local lines="${2:-50}"
    
    print_section "5. Container Logs (Last $lines lines)"
    
    if ! docker ps -a --format "{{.Names}}" 2>/dev/null | grep -q "^${container}$"; then
        print_error "Container not found: $container"
        return 1
    fi
    
    if docker logs --tail "$lines" "$container" 2>&1; then
        echo ""
        print_success "Logs retrieved successfully"
        return 0
    else
        print_error "Failed to retrieve logs"
        return 1
    fi
}

# Check nginx configuration
check_nginx_config() {
    local container="${1:-nginx-microservice}"
    
    print_section "6. Nginx Configuration"
    
    if ! docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^${container}$"; then
        print_error "Container not found: $container"
        return 1
    fi
    
    # Check if container is restarting
    local status=$(docker ps --format "{{.Names}}\t{{.Status}}" 2>/dev/null | grep "^${container}" | awk '{print $2}' || echo "")
    if echo "$status" | grep -qE "Restarting"; then
        print_warning "Container is restarting - cannot test configuration"
        return 1
    fi
    
    # Test nginx configuration
    print_info "Testing nginx configuration..."
    if docker exec "$container" nginx -t 2>&1; then
        print_success "Nginx configuration is valid"
        return 0
    else
        print_error "Nginx configuration test failed"
        print_info "Check nginx error logs for details"
        return 1
    fi
}

