#!/bin/bash
# Start Microservices Phase
# Starts all microservices in dependency order
# Usage: start-microservices.sh [--service <name>]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTRY_DIR="${NGINX_PROJECT_DIR}/service-registry"
BLUE_GREEN_DIR="${SCRIPT_DIR}/blue-green"

# Source shared utilities
source "${SCRIPT_DIR}/startup-utils.sh"

# Function to discover all microservices from service-registry directory
discover_microservices() {
    local registry_dir="$1"
    local services=()
    
    if [ ! -d "$registry_dir" ]; then
        print_error "Service registry directory not found: $registry_dir"
        return 1
    fi
    
    # Find all .json files in service-registry (excluding backups)
    while IFS= read -r registry_file; do
        local service_name=$(basename "$registry_file" .json)
        # Skip backup files and non-microservices
        if [[ "$service_name" != *".backup" ]] && [[ "$service_name" != *".bak" ]] && [[ "$service_name" == *"-microservice" ]]; then
            services+=("$service_name")
        fi
    done < <(find "$registry_dir" -maxdepth 1 -name "*.json" -type f 2>/dev/null | sort)
    
    # Output services as newline-separated list
    printf '%s\n' "${services[@]}"
}

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
            echo "Usage: start-microservices.sh [--service <name>]"
            exit 1
            ;;
    esac
done

# Discover all microservices from registry at the start
print_status "Discovering microservices from registry..."
MICROSERVICES=($(discover_microservices "$REGISTRY_DIR"))

if [ ${#MICROSERVICES[@]} -eq 0 ]; then
    print_error "No microservices found in registry directory: $REGISTRY_DIR"
    exit 1
fi

# Reorder microservices: ai-microservice should start last (after all other microservices)
# This ensures it starts after all other microservices but before applications
declare -a ORDERED_MICROSERVICES=()
declare -a OTHER_MICROSERVICES=()
for service in "${MICROSERVICES[@]}"; do
    if [ "$service" = "ai-microservice" ]; then
        # ai-microservice will be added at the end
        continue
    else
        OTHER_MICROSERVICES+=("$service")
    fi
done

# Add all other microservices first, then ai-microservice at the end
ORDERED_MICROSERVICES=("${OTHER_MICROSERVICES[@]}")
if [[ " ${MICROSERVICES[@]} " =~ " ai-microservice " ]]; then
    ORDERED_MICROSERVICES+=("ai-microservice")
fi

MICROSERVICES=("${ORDERED_MICROSERVICES[@]}")

print_status "Found ${#MICROSERVICES[@]} microservice(s) to check:"
for service in "${MICROSERVICES[@]}"; do
    print_detail "  - $service"
done

# If --service flag is used, filter to only that service
if [ -n "$SINGLE_SERVICE" ]; then
    if [[ " ${MICROSERVICES[@]} " =~ " ${SINGLE_SERVICE} " ]]; then
        MICROSERVICES=("$SINGLE_SERVICE")
        print_status "Filtered to single service: $SINGLE_SERVICE"
    else
        print_error "Service '$SINGLE_SERVICE' not found in registry"
        print_error "Available microservices: ${MICROSERVICES[*]}"
        exit 1
    fi
fi

# Function to check if service registry exists
service_exists() {
    local service_name="$1"
    [ -f "${REGISTRY_DIR}/${service_name}.json" ]
}

# Function to start a microservice using deploy-smart.sh
start_microservice() {
    local service_name="$1"
    
    print_status "========================================"
    print_status "Starting microservice: $service_name"
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
        print_error "Failed to start microservice: $service_name (exit code: $deploy_exit_code)"
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
    
    print_success "Microservice $service_name deployment completed successfully"
    
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
print_status "Starting Microservices Phase"
print_status "=========================================="

# Arrays to track results
declare -a SUCCESSFUL_SERVICES=()
declare -a FAILED_SERVICES=()
declare -a MISSING_SERVICES=()
declare -a NOT_CHECKED_SERVICES=()

service_count=${#MICROSERVICES[@]}
success_count=0
fail_count=0
missing_count=0
not_checked_count=0

print_status ""
print_status "Checking all $service_count microservice(s)..."
print_status ""

# Check all services - don't stop on first failure
for service in "${MICROSERVICES[@]}"; do
    print_status "========================================"
    print_status "Microservice: $service ($((${#SUCCESSFUL_SERVICES[@]} + ${#FAILED_SERVICES[@]} + 1))/$service_count)"
    print_status "========================================"
    
    # Check if service registry exists
    if ! service_exists "$service"; then
        print_error "Service registry not found: ${service}.json"
        FAILED_SERVICES+=("$service (registry missing)")
        fail_count=$((fail_count + 1))
        print_status ""
        continue
    fi
    
    # Try to start/check the service
    if start_microservice "$service"; then
        SUCCESSFUL_SERVICES+=("$service")
        success_count=$((success_count + 1))
        print_success "Microservice $service ${GREEN_CHECK} started and verified successfully"
    else
        exit_code=$?
        FAILED_SERVICES+=("$service (exit code: $exit_code)")
        fail_count=$((fail_count + 1))
        print_error "Microservice $service ${RED_X} failed to start or verify"
    fi
    
    print_status ""
    
    # Small delay between services
    if [ $((${#SUCCESSFUL_SERVICES[@]} + ${#FAILED_SERVICES[@]})) -lt $service_count ]; then
        print_detail "Waiting 1 second before checking next service..."
        sleep 1
    fi
done

# Final summary
print_status ""
print_status "=========================================="
print_status "Microservices Phase Summary"
print_status "=========================================="
print_status "Total services to check: $service_count"
print_status "Successfully started and verified: $success_count"
print_status "Failed: $fail_count"
print_status ""

if [ $success_count -gt 0 ]; then
    print_success "Successfully checked microservices:"
    for service in "${SUCCESSFUL_SERVICES[@]}"; do
        print_detail "  ${GREEN_CHECK} $service"
    done
    print_status ""
fi

if [ $fail_count -gt 0 ]; then
    print_error "Failed microservices:"
    for service in "${FAILED_SERVICES[@]}"; do
        print_detail "  ${RED_X} $service"
    done
    print_status ""
fi

# Only exit successfully if ALL services passed
if [ $fail_count -eq 0 ] && [ $success_count -eq $service_count ]; then
    print_success "All $service_count microservice(s) started and verified successfully"
    exit 0
else
    print_error "Microservices phase completed with errors"
    print_error "Expected: $service_count services, Success: $success_count, Failed: $fail_count"
    print_error "Script will exit with error - all services must pass for success"
    exit 1
fi
