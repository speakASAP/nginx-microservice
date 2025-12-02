#!/bin/bash
# Central Service Startup Script
# Starts all services in dependency order: Nginx -> Infrastructure -> Microservices -> Applications
# Usage: start-all-services.sh [--skip-infrastructure] [--skip-microservices] [--skip-applications] [--service <name>]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source shared utilities
source "${SCRIPT_DIR}/startup-utils.sh"

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

# Main execution
print_status "=========================================="
print_status "Starting All Services in Dependency Order"
print_status "=========================================="

# Phase 1: Nginx (always runs - mandatory)
print_status ""
print_status "Phase 1: Starting Nginx"
print_status "----------------------------------------"

if ! "${SCRIPT_DIR}/start-nginx.sh"; then
    print_error "Failed to start nginx phase"
    exit 1
fi

print_success "Nginx phase completed"

# Phase 2: Infrastructure
if [ "$SKIP_INFRASTRUCTURE" = false ]; then
    print_status ""
    print_status "Phase 2: Starting Infrastructure Services"
    print_status "----------------------------------------"
    
    if ! "${SCRIPT_DIR}/start-infrastructure.sh"; then
        print_error "Failed to start infrastructure phase"
        exit 1
    fi
    
    print_success "Infrastructure phase completed"
else
    print_status "Skipping infrastructure services"
fi

# Phase 3: Microservices
if [ "$SKIP_MICROSERVICES" = false ]; then
    print_status ""
    print_status "Phase 3: Starting Microservices"
    print_status "--------------------------------"
    
    if [ -n "$SINGLE_SERVICE" ]; then
        if ! "${SCRIPT_DIR}/start-microservices.sh" --service "$SINGLE_SERVICE"; then
            print_error "Failed to start microservice: $SINGLE_SERVICE"
            exit 1
        fi
    else
        if ! "${SCRIPT_DIR}/start-microservices.sh"; then
            print_error "Failed to start microservices phase"
            exit 1
        fi
    fi
    
    print_success "Microservices phase completed"
else
    print_status "Skipping microservices"
fi

# Phase 4: Applications (fault-tolerant)
if [ "$SKIP_APPLICATIONS" = false ]; then
    print_status ""
    print_status "Phase 4: Starting Applications"
    print_status "------------------------------"
    print_status "Note: Applications are fault-tolerant - failures won't stop the system"
    print_status ""
    
    # Start applications with fault tolerance enabled
    # This allows applications to fail independently without stopping the system
    if [ -n "$SINGLE_SERVICE" ]; then
        # Single service mode - still use fault tolerance
        "${SCRIPT_DIR}/start-applications.sh" --service "$SINGLE_SERVICE" --continue-on-failure || {
            print_warning "Application $SINGLE_SERVICE had issues, but system continues running"
        }
    else
        # All applications mode - fault tolerant
        "${SCRIPT_DIR}/start-applications.sh" --continue-on-failure || {
            print_warning "Some applications had issues, but system continues running"
        }
    fi
    
    print_status ""
    print_success "Applications phase completed (fault-tolerant mode)"
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

# Show service status
if [ -f "${SCRIPT_DIR}/status-all-services.sh" ]; then
    "${SCRIPT_DIR}/status-all-services.sh"
fi

exit 0

