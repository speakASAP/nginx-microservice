#!/bin/bash
# Sync Containers and Nginx
# Ensures all required containers are running and symlinks point to active containers before restarting nginx
# Usage: sync-containers-and-nginx.sh [--restart-nginx]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BLUE_GREEN_DIR="${SCRIPT_DIR}/blue-green"
REGISTRY_DIR="${NGINX_PROJECT_DIR}/service-registry"
STATE_DIR="${NGINX_PROJECT_DIR}/state"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse arguments
RESTART_NGINX=false
if [ "$1" = "--restart-nginx" ]; then
    RESTART_NGINX=true
fi

# Source utils
if [ -f "${BLUE_GREEN_DIR}/utils.sh" ]; then
    source "${BLUE_GREEN_DIR}/utils.sh"
else
    echo -e "${RED}[ERROR]${NC} utils.sh not found"
    exit 1
fi

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

# Function to check if container is running
container_running() {
    local container_name="$1"
    docker ps --format "{{.Names}}" | grep -qE "^${container_name}$"
}

# Function to check which color containers are running for a service
check_service_containers() {
    local service_name="$1"
    local registry=$(load_service_registry "$service_name")
    local service_keys=$(echo "$registry" | jq -r '.services | keys[]' 2>/dev/null || echo "")
    
    local blue_count=0
    local green_count=0
    local total_count=0
    local blue_containers=()
    local green_containers=()
    
    if [ -z "$service_keys" ]; then
        echo "no-services"
        return
    fi
    
    while IFS= read -r service_key; do
        local container_base=$(echo "$registry" | jq -r ".services[\"$service_key\"].container_name_base // empty" 2>/dev/null)
        if [ -z "$container_base" ] || [ "$container_base" = "null" ]; then
            continue
        fi
        
        total_count=$((total_count + 1))
        
        # Check blue container
        if container_running "${container_base}-blue"; then
            blue_count=$((blue_count + 1))
            blue_containers+=("${container_base}-blue")
        fi
        
        # Check green container
        if container_running "${container_base}-green"; then
            green_count=$((green_count + 1))
            green_containers+=("${container_base}-green")
        fi
        
        # Check single container (no color suffix) - treat as blue for compatibility
        if container_running "${container_base}"; then
            blue_count=$((blue_count + 1))
            blue_containers+=("${container_base}")
        fi
    done <<< "$service_keys"
    
    # Determine which color is active based on running containers
    if [ $blue_count -eq $total_count ] && [ $total_count -gt 0 ]; then
        echo "blue:all"
    elif [ $green_count -eq $total_count ] && [ $total_count -gt 0 ]; then
        echo "green:all"
    elif [ $blue_count -gt 0 ] && [ $green_count -eq 0 ]; then
        echo "blue:partial"
    elif [ $green_count -gt 0 ] && [ $blue_count -eq 0 ]; then
        echo "green:partial"
    elif [ $blue_count -gt 0 ] && [ $green_count -gt 0 ]; then
        # Both have containers, prefer the one with more running
        if [ $blue_count -ge $green_count ]; then
            echo "blue:mixed"
        else
            echo "green:mixed"
        fi
    else
        echo "none:stopped"
    fi
}

# Function to ensure containers are running for a service
ensure_service_containers_running() {
    local service_name="$1"
    local target_color="$2"
    
    local registry=$(load_service_registry "$service_name")
    local service_keys=$(echo "$registry" | jq -r '.services | keys[]' 2>/dev/null || echo "")
    
    if [ -z "$service_keys" ]; then
        print_warning "No services defined for $service_name"
        return 1
    fi
    
    local missing_containers=()
    
    while IFS= read -r service_key; do
        local container_base=$(echo "$registry" | jq -r ".services[\"$service_key\"].container_name_base // empty" 2>/dev/null)
        if [ -z "$container_base" ] || [ "$container_base" = "null" ]; then
            continue
        fi
        
        local container_name="${container_base}-${target_color}"
        
        # Check if container is running
        if ! container_running "$container_name"; then
            # Check if single container exists (no color suffix)
            if ! container_running "$container_base"; then
                missing_containers+=("$container_name")
            fi
        fi
    done <<< "$service_keys"
    
    if [ ${#missing_containers[@]} -eq 0 ]; then
        return 0
    fi
    
    # Try to start missing containers using deploy-smart.sh
    print_status "Starting missing containers for $service_name ($target_color)..."
    if [ -f "${BLUE_GREEN_DIR}/deploy-smart.sh" ]; then
        if "${BLUE_GREEN_DIR}/deploy-smart.sh" "$service_name" >/dev/null 2>&1; then
            print_success "Containers started for $service_name"
            return 0
        else
            print_warning "Failed to start containers for $service_name automatically"
            return 1
        fi
    else
        print_warning "deploy-smart.sh not found, cannot start containers automatically"
        return 1
    fi
}

# Function to sync symlink for a service
sync_service_symlink() {
    local service_name="$1"
    
    local registry=$(load_service_registry "$service_name")
    local domain=$(echo "$registry" | jq -r '.domain // empty' 2>/dev/null)
    
    if [ -z "$domain" ] || [ "$domain" = "null" ]; then
        print_warning "No domain configured for $service_name, skipping symlink sync"
        return 0
    fi
    
    # First, ensure configs are generated from registry (independent of container state)
    print_status "Ensuring nginx configs are generated for $service_name..."
    if ! ensure_blue_green_configs "$service_name" "$domain"; then
        print_error "Failed to generate configs for $service_name"
        return 1
    fi
    
    # Load state to get expected active color
    local state=$(load_state "$service_name" 2>/dev/null || echo "")
    local expected_color="blue"
    if [ -n "$state" ]; then
        expected_color=$(echo "$state" | jq -r '.active_color // "blue"' 2>/dev/null || echo "blue")
    fi
    
    # Check which containers are running (optional - for informational purposes only)
    local container_status=$(check_service_containers "$service_name")
    local running_color=$(echo "$container_status" | cut -d':' -f1)
    local status_type=$(echo "$container_status" | cut -d':' -f2)
    
    # Determine which color to use for symlink
    # Prefer expected color from state, but update if containers don't match
    local target_color="$expected_color"
    
    if [ "$running_color" = "none" ]; then
        print_status "No containers running for $service_name, using expected color: $expected_color"
        # Note: We don't require containers to be running - nginx will return 502s until they start
        # Optionally try to start containers, but don't fail if they can't be started
        ensure_service_containers_running "$service_name" "$expected_color" >/dev/null 2>&1 || true
        target_color="$expected_color"
    elif [ "$running_color" != "$expected_color" ]; then
        print_warning "Running containers ($running_color) don't match expected color ($expected_color) for $service_name"
        if [ "$status_type" = "all" ]; then
            print_status "Updating symlink to match running containers: $running_color"
            target_color="$running_color"
        else
            print_warning "Partial container status, keeping expected color: $expected_color"
            target_color="$expected_color"
            # Optionally try to start missing containers
            ensure_service_containers_running "$service_name" "$expected_color" >/dev/null 2>&1 || true
        fi
    else
        print_success "Symlink for $service_name is correct (pointing to $expected_color)"
        # Optionally verify all containers are running, but don't fail if they're not
        if [ "$status_type" != "all" ]; then
            print_status "Some containers missing for $service_name, optionally starting..."
            ensure_service_containers_running "$service_name" "$expected_color" >/dev/null 2>&1 || true
        fi
    fi
    
    # Update symlink if needed
    local config_dir="${NGINX_PROJECT_DIR}/nginx/conf.d"
    local symlink_file="${config_dir}/${domain}.conf"
    local current_target=$(readlink -f "$symlink_file" 2>/dev/null || echo "")
    local expected_target="${config_dir}/blue-green/${domain}.${target_color}.conf"
    
    if [ "$current_target" != "$expected_target" ]; then
        print_status "Updating symlink for $domain to point to $target_color config"
        if switch_config_symlink "$domain" "$target_color"; then
            print_success "Symlink updated for $service_name ($domain -> $target_color)"
        else
            print_error "Failed to update symlink for $service_name"
            return 1
        fi
    else
        print_success "Symlink for $service_name is already correct ($domain -> $target_color)"
    fi
    
    return 0
}

# Main execution
print_status "=========================================="
print_status "Syncing Containers and Nginx Configuration"
print_status "=========================================="
print_status ""

# Get all services from registry
SERVICES=()
if [ -d "$REGISTRY_DIR" ]; then
    for registry_file in "$REGISTRY_DIR"/*.json; do
        if [ -f "$registry_file" ]; then
            service_name=$(basename "$registry_file" .json)
            SERVICES+=("$service_name")
        fi
    done
fi

if [ ${#SERVICES[@]} -eq 0 ]; then
    print_error "No services found in registry"
    exit 1
fi

print_status "Found ${#SERVICES[@]} service(s) to sync"
print_status ""

# Sync each service
SYNCED_COUNT=0
FAILED_COUNT=0

for service_name in "${SERVICES[@]}"; do
    print_status "----------------------------------------"
    print_status "Syncing service: $service_name"
    print_status "----------------------------------------"
    
    if sync_service_symlink "$service_name"; then
        SYNCED_COUNT=$((SYNCED_COUNT + 1))
        print_success "Service $service_name synced successfully"
    else
        FAILED_COUNT=$((FAILED_COUNT + 1))
        print_error "Failed to sync service $service_name"
        # Continue with other services even if one fails
        # Invalid configs should have been rejected during generation
    fi
    
    print_status ""
done

# Summary
print_status "=========================================="
print_status "Sync Summary"
print_status "=========================================="
print_status "Synced: $SYNCED_COUNT"
if [ $FAILED_COUNT -gt 0 ]; then
    print_warning "Failed: $FAILED_COUNT"
fi
print_status ""

# Test nginx configuration
# Note: Config test may fail if nginx container is not running, but that's okay
# We'll still proceed with reload if nginx is running
print_status "Testing nginx configuration..."
if test_nginx_config; then
    print_success "Nginx configuration is valid"
else
    print_warning "Nginx configuration test failed or nginx container is not running"
    print_warning "This may be expected if nginx is not yet started"
    # Don't exit - allow reload attempt if nginx is running
fi

# Restart nginx if requested
if [ "$RESTART_NGINX" = "true" ]; then
    print_status ""
    print_status "=========================================="
    print_status "Restarting Nginx"
    print_status "=========================================="
    
    if reload_nginx; then
        print_success "Nginx reloaded successfully"
    else
        print_error "Failed to reload nginx"
        exit 1
    fi
else
    print_status ""
    print_warning "Nginx not restarted (use --restart-nginx to restart)"
    print_status "To restart nginx manually, run:"
    print_status "  ./scripts/restart-nginx.sh"
    print_status "  or"
    print_status "  ./scripts/sync-containers-and-nginx.sh --restart-nginx"
fi

print_status ""
print_success "Sync completed successfully!"

exit 0

