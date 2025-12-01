#!/bin/bash
# Start Applications Phase
# Starts all applications
# Usage: start-applications.sh [--service <name>]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTRY_DIR="${NGINX_PROJECT_DIR}/service-registry"
BLUE_GREEN_DIR="${SCRIPT_DIR}/blue-green"

# Source shared utilities
source "${SCRIPT_DIR}/startup-utils.sh"

# Applications list
APPLICATIONS=(
    "allegro"                    # Needs postgres + redis
    "crypto-ai-agent"            # Needs postgres + redis
    "statex"                     # Needs postgres + redis
    "e-commerce"                 # Needs postgres + redis
)

# Parse arguments
SINGLE_SERVICE=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --service)
            SINGLE_SERVICE="$2"
            shift 2
            ;;
        *)
            print_error "Unknown option: $1"
            echo "Usage: start-applications.sh [--service <name>]"
            exit 1
            ;;
    esac
done

# Function to check if service registry exists
service_exists() {
    local service_name="$1"
    [ -f "${REGISTRY_DIR}/${service_name}.json" ]
}

# Function to start an application using deploy-smart.sh
start_application() {
    local service_name="$1"
    
    print_status "========================================"
    print_status "Starting application: $service_name"
    print_status "========================================"
    
    if ! service_exists "$service_name"; then
        print_error "Service registry not found: ${service_name}.json"
        exit 1
    fi
    
    print_detail "Service registry file: ${REGISTRY_DIR}/${service_name}.json"
    
    # Use deploy-smart.sh to start the service
    if [ ! -f "${BLUE_GREEN_DIR}/deploy-smart.sh" ]; then
        print_error "deploy-smart.sh not found at: ${BLUE_GREEN_DIR}/deploy-smart.sh"
        exit 1
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
            print_success "Service $service_name containers are already running"
            
            # Verify containers are not restarting (zero tolerance)
            while IFS= read -r service_key; do
                local container_base=$(echo "$registry" | jq -r ".services[\"$service_key\"].container_name_base // empty" 2>/dev/null)
                if [ -n "$container_base" ] && [ "$container_base" != "null" ]; then
                    # Check blue and green containers
                    for color in blue green; do
                        local container_name="${container_base}-${color}"
                        local container_status=$(check_container_running "$container_name")
                        local status_code=$?
                        if [ $status_code -eq 2 ]; then
                            print_error "Container ${container_name} is in RESTARTING state - zero tolerance policy"
                            print_detail "Container logs (last 30 lines):"
                            docker logs --tail 30 "$container_name" 2>&1 | sed 's/^/  /' || true
                            exit 1
                        fi
                    done
                fi
            done <<< "$service_keys"
            
            # Run health check
            if [ -f "${BLUE_GREEN_DIR}/health-check.sh" ]; then
                print_status "Running health check for $service_name..."
                if "${BLUE_GREEN_DIR}/health-check.sh" "$service_name" >/dev/null 2>&1; then
                    print_success "Health check passed for $service_name"
                else
                    print_error "Health check failed for $service_name"
                    print_detail "Health check output:"
                    "${BLUE_GREEN_DIR}/health-check.sh" "$service_name" 2>&1 | sed 's/^/  /' || true
                    exit 1
                fi
            fi
            
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
    
    if [ $deploy_exit_code -ne 0 ]; then
        print_error "Failed to start application: $service_name (exit code: $deploy_exit_code)"
        print_detail "Error details from deployment:"
        echo "$deploy_output" | grep -i "error\|failed\|fatal" | head -20 | sed 's/^/  /' || true
        
        # Show container status even on failure
        local container_base=""
        local registry_file="${REGISTRY_DIR}/${service_name}.json"
        if [ -f "$registry_file" ]; then
            container_base=$(jq -r '.services | to_entries[0].value.container_name_base // empty' "$registry_file" 2>/dev/null || echo "")
            if [ -n "$container_base" ]; then
                print_detail "Container status after failed deployment:"
                docker ps -a --filter "name=${container_base}" --format "  - {{.Names}}: {{.Status}}" 2>&1 || true
            fi
        fi
        
        exit 1
    fi
    
    print_success "Application $service_name deployment completed successfully"
    
    # Validate nginx config for this service
    print_detail "Validating nginx configuration for $service_name..."
    if [ -f "${BLUE_GREEN_DIR}/utils.sh" ]; then
        source "${BLUE_GREEN_DIR}/utils.sh" 2>/dev/null || true
        if type test_service_nginx_config >/dev/null 2>&1; then
            if test_service_nginx_config "$service_name"; then
                print_success "Nginx configuration validated for $service_name"
            else
                print_error "Nginx configuration validation failed for $service_name"
                exit 1
            fi
        fi
    fi
    
    # Verify containers are running and not restarting (zero tolerance)
    local registry_file="${REGISTRY_DIR}/${service_name}.json"
    if [ -f "$registry_file" ]; then
        local service_keys=$(jq -r '.services | keys[]' "$registry_file" 2>/dev/null || echo "")
        while IFS= read -r service_key; do
            local container_base=$(jq -r ".services[\"$service_key\"].container_name_base // empty" "$registry_file" 2>/dev/null)
            if [ -n "$container_base" ] && [ "$container_base" != "null" ]; then
                # Check blue and green containers
                for color in blue green; do
                    local container_name="${container_base}-${color}"
                    if docker ps --format "{{.Names}}" | grep -q "^${container_name}$"; then
                        local container_status=$(check_container_running "$container_name")
                        local status_code=$?
                        if [ $status_code -eq 2 ]; then
                            print_error "Container ${container_name} is in RESTARTING state - zero tolerance policy"
                            print_detail "Container logs (last 30 lines):"
                            docker logs --tail 30 "$container_name" 2>&1 | sed 's/^/  /' || true
                            exit 1
                        fi
                    fi
                done
            fi
        done <<< "$service_keys"
    fi
    
    # Run health check
    if [ -f "${BLUE_GREEN_DIR}/health-check.sh" ]; then
        print_status "Running health check for $service_name..."
        if "${BLUE_GREEN_DIR}/health-check.sh" "$service_name" >/dev/null 2>&1; then
            print_success "Health check passed for $service_name"
        else
            print_error "Health check failed for $service_name"
            print_detail "Health check output:"
            "${BLUE_GREEN_DIR}/health-check.sh" "$service_name" 2>&1 | sed 's/^/  /' || true
            exit 1
        fi
    fi
    
    # Show container status for this service
    print_detail "Checking container status for $service_name..."
    local container_base=$(jq -r '.services | to_entries[0].value.container_name_base // empty' "$registry_file" 2>/dev/null || echo "")
    if [ -n "$container_base" ]; then
        print_detail "Looking for containers matching: ${container_base}-*"
        docker ps --filter "name=${container_base}" --format "  - {{.Names}}: {{.Status}} ({{.Ports}})" 2>&1 || true
    fi
    
    return 0
}

# Main execution
print_status "=========================================="
print_status "Starting Applications Phase"
print_status "=========================================="

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
    
    if start_application "$service"; then
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

if [ $fail_count -gt 0 ]; then
    print_error "Applications phase completed with errors"
    exit 1
fi

print_success "Applications phase completed successfully"

exit 0

