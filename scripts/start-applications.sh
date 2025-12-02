#!/bin/bash
# Start Applications Phase
# Starts all applications
# Usage: start-applications.sh [--service <name>] [--continue-on-failure]

# Note: set -e is not used here to allow fault-tolerant behavior
# Individual application failures are handled gracefully

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTRY_DIR="${NGINX_PROJECT_DIR}/service-registry"
BLUE_GREEN_DIR="${SCRIPT_DIR}/blue-green"

# Source shared utilities
source "${SCRIPT_DIR}/startup-utils.sh"

# Function to discover all applications from service-registry directory
discover_applications() {
    local registry_dir="$1"
    local services=()
    
    if [ ! -d "$registry_dir" ]; then
        print_error "Service registry directory not found: $registry_dir"
        return 1
    fi
    
    # Find all .json files in service-registry (excluding backups and microservices)
    while IFS= read -r registry_file; do
        local service_name=$(basename "$registry_file" .json)
        # Skip backup files, microservices, and infrastructure services
        if [[ "$service_name" != *".backup" ]] && \
           [[ "$service_name" != *".bak" ]] && \
           [[ "$service_name" != *"-microservice" ]] && \
           [[ "$service_name" != "nginx-microservice" ]] && \
           [[ "$service_name" != "database-server" ]]; then
            services+=("$service_name")
        fi
    done < <(find "$registry_dir" -maxdepth 1 -name "*.json" -type f 2>/dev/null | sort)
    
    # Output services as newline-separated list
    printf '%s\n' "${services[@]}"
}

# Parse arguments
SINGLE_SERVICE=""
CONTINUE_ON_FAILURE=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --service)
            SINGLE_SERVICE="$2"
            shift 2
            ;;
        --continue-on-failure)
            CONTINUE_ON_FAILURE=true
            shift
            ;;
        *)
            print_error "Unknown option: $1"
            echo "Usage: start-applications.sh [--service <name>] [--continue-on-failure]"
            exit 1
            ;;
    esac
done

# Discover all applications from registry at the start
print_status "Discovering applications from registry..."
APPLICATIONS=($(discover_applications "$REGISTRY_DIR"))

if [ ${#APPLICATIONS[@]} -eq 0 ]; then
    print_error "No applications found in registry directory: $REGISTRY_DIR"
    exit 1
fi

print_status "Found ${#APPLICATIONS[@]} application(s) to check:"
for app in "${APPLICATIONS[@]}"; do
    print_detail "  - $app"
done

# If --service flag is used, filter to only that application
if [ -n "$SINGLE_SERVICE" ]; then
    if [[ " ${APPLICATIONS[@]} " =~ " ${SINGLE_SERVICE} " ]]; then
        APPLICATIONS=("$SINGLE_SERVICE")
        print_status "Filtered to single application: $SINGLE_SERVICE"
    else
        print_error "Application '$SINGLE_SERVICE' not found in registry"
        print_error "Available applications: ${APPLICATIONS[*]}"
        exit 1
    fi
fi

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
                            return 1
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
                    return 1
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
        
        return 1
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
                return 1
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
                            return 1
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
            return 1
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

# Arrays to track results
declare -a SUCCESSFUL_APPLICATIONS=()
declare -a FAILED_APPLICATIONS=()

service_count=${#APPLICATIONS[@]}
success_count=0
fail_count=0

print_status ""
print_status "Checking all $service_count application(s)..."
print_status ""

# Check all applications - don't stop on first failure
for service in "${APPLICATIONS[@]}"; do
    print_status "========================================"
    print_status "Application: $service ($((${#SUCCESSFUL_APPLICATIONS[@]} + ${#FAILED_APPLICATIONS[@]} + 1))/$service_count)"
    print_status "========================================"
    
    # Check if service registry exists
    if ! service_exists "$service"; then
        print_error "Service registry not found: ${service}.json"
        FAILED_APPLICATIONS+=("$service (registry missing)")
        fail_count=$((fail_count + 1))
        print_status ""
        continue
    fi
    
    # Try to start/check the application
    if start_application "$service"; then
        SUCCESSFUL_APPLICATIONS+=("$service")
        success_count=$((success_count + 1))
        print_success "Application $service ${GREEN_CHECK} started and verified successfully"
    else
        exit_code=$?
        FAILED_APPLICATIONS+=("$service (exit code: $exit_code)")
        fail_count=$((fail_count + 1))
        print_error "Application $service ${RED_X} failed to start or verify"
    fi
    
    print_status ""
    
    # Small delay between services
    if [ $((${#SUCCESSFUL_APPLICATIONS[@]} + ${#FAILED_APPLICATIONS[@]})) -lt $service_count ]; then
        print_detail "Waiting 1 second before checking next application..."
        sleep 1
    fi
done

# Final summary
print_status ""
print_status "=========================================="
print_status "Applications Phase Summary"
print_status "=========================================="
print_status "Total applications to check: $service_count"
print_status "Successfully started and verified: $success_count"
print_status "Failed: $fail_count"
print_status ""

if [ $success_count -gt 0 ]; then
    print_success "Successfully checked applications:"
    for app in "${SUCCESSFUL_APPLICATIONS[@]}"; do
        print_detail "  ${GREEN_CHECK} $app"
    done
    print_status ""
fi

if [ $fail_count -gt 0 ]; then
    print_error "Failed applications:"
    for app in "${FAILED_APPLICATIONS[@]}"; do
        print_detail "  ${RED_X} $app"
    done
    print_status ""
fi

# Exit behavior based on --continue-on-failure flag
if [ $fail_count -eq 0 ] && [ $success_count -eq $service_count ]; then
    print_success "All $service_count application(s) started and verified successfully"
    exit 0
elif [ "$CONTINUE_ON_FAILURE" = "true" ]; then
    # Fault-tolerant mode: report failures but exit successfully
    print_warning "Applications phase completed with some failures (fault-tolerant mode)"
    print_warning "Expected: $service_count applications, Success: $success_count, Failed: $fail_count"
    print_status "System continues running with available applications"
    exit 0  # Exit successfully to allow system to continue
else
    # Strict mode: exit with error if any application failed
    print_error "Applications phase completed with errors"
    print_error "Expected: $service_count applications, Success: $success_count, Failed: $fail_count"
    print_error "Script will exit with error - all applications must pass for success"
    print_error "Use --continue-on-failure flag to continue on application failures"
    exit 1
fi

