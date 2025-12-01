#!/bin/bash
# Start Nginx Phase
# Starts nginx-network and nginx-microservice
# Usage: start-nginx.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BLUE_GREEN_DIR="${SCRIPT_DIR}/blue-green"

# Source shared utilities
source "${SCRIPT_DIR}/startup-utils.sh"

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
    
    # Check if nginx is already running and healthy
    local container_status=$(check_container_running "nginx-microservice")
    local status_code=$?
    
    if [ $status_code -eq 2 ]; then
        # Container is restarting - zero tolerance, run diagnostic and exit
        print_error "nginx-microservice is in RESTARTING state - zero tolerance policy"
        run_diagnostic_and_exit "${SCRIPT_DIR}/diagnose-nginx-restart.sh" "nginx-microservice" "nginx-microservice is restarting"
    elif [ $status_code -eq 0 ]; then
        # Container is running - check if it's healthy
        print_success "nginx-microservice is ${GREEN_CHECK} already running"
        print_detail "Container status:"
        docker ps --filter "name=nginx-microservice" --format "  - {{.Names}}: {{.Status}} ({{.Ports}})" 2>&1 || true
        
        # Check for unhealthy status (zero tolerance)
        local container_status_full=$(docker ps --filter "name=nginx-microservice" --format "{{.Status}}" 2>/dev/null || echo "")
        if echo "$container_status_full" | grep -qiE "unhealthy"; then
            print_error "nginx-microservice is in UNHEALTHY state - zero tolerance policy"
            print_detail "Container status: $container_status_full"
            print_detail "Container logs (last 30 lines):"
            docker logs --tail 30 nginx-microservice 2>&1 | sed 's/^/  /' || true
            run_diagnostic_and_exit "${SCRIPT_DIR}/diagnose-nginx-restart.sh" "nginx-microservice" "nginx-microservice is unhealthy"
        fi
        
        # Always test nginx configuration (zero tolerance)
        print_status "Testing nginx configuration..."
        if docker compose exec -T nginx nginx -t >/dev/null 2>&1; then
            print_success "Nginx configuration test ${GREEN_CHECK} passed"
        else
            print_error "Nginx configuration test ${RED_X} failed"
            print_detail "Nginx config test output:"
            docker compose exec -T nginx nginx -t 2>&1 | sed 's/^/  /' || true
            run_diagnostic_and_exit "${SCRIPT_DIR}/diagnose-nginx-restart.sh" "nginx-microservice" "Nginx configuration test failed"
        fi
        
        return 0
    fi
    
    # Check and kill processes using ports 80 and 443 before starting
    print_status "Checking for port conflicts on ports 80 and 443..."
    if [ -f "${BLUE_GREEN_DIR}/utils.sh" ]; then
        source "${BLUE_GREEN_DIR}/utils.sh" 2>/dev/null || true
        if type kill_port_if_in_use >/dev/null 2>&1; then
            kill_port_if_in_use "80" "nginx-microservice" "infrastructure"
            kill_port_if_in_use "443" "nginx-microservice" "infrastructure"
        fi
        # Also kill any existing nginx containers that might be restarting
        if type kill_container_if_exists >/dev/null 2>&1; then
            kill_container_if_exists "nginx-microservice" "nginx-microservice" "infrastructure"
            kill_container_if_exists "nginx-certbot" "nginx-microservice" "infrastructure"
        fi
    fi
    
    # Fallback: manual port checking if utils.sh not available
    if ! type kill_port_if_in_use >/dev/null 2>&1; then
        # Check for containers using ports 80 or 443
        local port80_container=$(docker ps --format "{{.Names}}\t{{.Ports}}" 2>/dev/null | grep -E ":80->|:80/|0\.0\.0\.0:80:" | awk '{print $1}' | head -1 || echo "")
        local port443_container=$(docker ps --format "{{.Names}}\t{{.Ports}}" 2>/dev/null | grep -E ":443->|:443/|0\.0\.0\.0:443:" | awk '{print $1}' | head -1 || echo "")
        
        if [ -n "$port80_container" ] && [ "$port80_container" != "nginx-microservice" ]; then
            print_warning "Port 80 is in use by container ${port80_container}, stopping it"
            docker stop "${port80_container}" 2>/dev/null || true
            docker kill "${port80_container}" 2>/dev/null || true
            docker rm -f "${port80_container}" 2>/dev/null || true
        fi
        
        if [ -n "$port443_container" ] && [ "$port443_container" != "nginx-microservice" ]; then
            print_warning "Port 443 is in use by container ${port443_container}, stopping it"
            docker stop "${port443_container}" 2>/dev/null || true
            docker kill "${port443_container}" 2>/dev/null || true
            docker rm -f "${port443_container}" 2>/dev/null || true
        fi
        
        # Also kill any existing nginx containers
        if docker ps -a --format "{{.Names}}" 2>/dev/null | grep -qE "^nginx-microservice$|^nginx-certbot$"; then
            print_warning "Killing existing nginx containers"
            docker kill nginx-microservice nginx-certbot 2>/dev/null || true
            docker rm -f nginx-microservice nginx-certbot 2>/dev/null || true
        fi
    fi
    
    # Start nginx
    print_detail "Executing: docker compose up -d"
    print_detail "Docker compose output:"
    if docker compose up -d 2>&1; then
        print_success "nginx-microservice containers started"
        
        # Show container status
        print_detail "Container status after startup:"
        docker compose ps 2>&1 || true
        
        # Wait for nginx container to be running
        # Nginx is independent of container state - it can start even if upstreams are unavailable
        # Nginx will return 502 errors until containers are available, which is acceptable
        print_status "Waiting for nginx container to be running (checking every 2 seconds)..."
        local max_attempts=15
        local attempt=0
        while [ $attempt -lt $max_attempts ]; do
            attempt=$((attempt + 1))
            
            # Check container status
            local container_status=$(check_container_running "nginx-microservice")
            local status_code=$?
            
            if [ $status_code -eq 2 ]; then
                # Container is restarting - zero tolerance
                print_error "nginx-microservice is in RESTARTING state after $attempt attempts"
                run_diagnostic_and_exit "${SCRIPT_DIR}/diagnose-nginx-restart.sh" "nginx-microservice" "nginx-microservice is restarting"
            elif [ $status_code -eq 0 ]; then
                # Container is running - check if it's healthy
                print_success "nginx-microservice is ${GREEN_CHECK} running"
                print_detail "Container status:"
                docker ps --filter "name=nginx-microservice" --format "  - {{.Names}}: {{.Status}} ({{.Ports}})" 2>&1 || true
                
                # Check for unhealthy status (zero tolerance)
                local container_status_full=$(docker ps --filter "name=nginx-microservice" --format "{{.Status}}" 2>/dev/null || echo "")
                if echo "$container_status_full" | grep -qiE "unhealthy"; then
                    print_error "nginx-microservice is in UNHEALTHY state - zero tolerance policy"
                    print_detail "Container status: $container_status_full"
                    print_detail "Container logs (last 30 lines):"
                    docker logs --tail 30 nginx-microservice 2>&1 | sed 's/^/  /' || true
                    run_diagnostic_and_exit "${SCRIPT_DIR}/diagnose-nginx-restart.sh" "nginx-microservice" "nginx-microservice is unhealthy"
                fi
                
                print_detail ""
                print_detail "Note: Nginx may return 502 errors if upstream containers are not yet available."
                print_detail "This is expected behavior - nginx will connect when containers start."
                
                # Test nginx configuration (zero tolerance)
                print_status "Testing nginx configuration..."
                if docker compose exec -T nginx nginx -t >/dev/null 2>&1; then
                    print_success "Nginx configuration test ${GREEN_CHECK} passed"
                else
                    print_error "Nginx configuration test ${RED_X} failed"
                    print_detail "Nginx config test output:"
                    docker compose exec -T nginx nginx -t 2>&1 | sed 's/^/  /' || true
                    run_diagnostic_and_exit "${SCRIPT_DIR}/diagnose-nginx-restart.sh" "nginx-microservice" "Nginx configuration test failed"
                fi
                
                return 0
            else
                # Container not running yet
                if [ $attempt -lt $max_attempts ]; then
                    print_detail "Container not running yet, waiting... (attempt $attempt/$max_attempts)"
                    sleep 2
                fi
            fi
        done
        
        # Container did not start after max attempts
        print_error "nginx-microservice container did not start after $max_attempts attempts"
        print_detail "Container logs (last 20 lines):"
        docker compose logs --tail=20 nginx 2>&1 | sed 's/^/  /' || true
        run_diagnostic_and_exit "${SCRIPT_DIR}/diagnose-nginx-restart.sh" "nginx-microservice" "nginx-microservice failed to start"
    else
        print_error "Failed to start nginx-microservice"
        print_detail "Docker compose logs:"
        docker compose logs --tail=30 2>&1 | sed 's/^/  /' || true
        exit 1
    fi
}

# Main execution
print_status "=========================================="
print_status "Starting Nginx Phase"
print_status "=========================================="

# Ensure Docker daemon is running
if ! ensure_docker_daemon; then
    print_error "Failed to ensure Docker daemon is running"
    exit 1
fi

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

print_success "Nginx phase completed successfully"

exit 0

