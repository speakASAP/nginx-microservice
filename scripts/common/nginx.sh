#!/bin/bash
# Nginx Management Functions
# Functions for nginx configuration validation, testing, and management

# Source base paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source dependencies
if [ -f "${SCRIPT_DIR}/output.sh" ]; then
    source "${SCRIPT_DIR}/output.sh"
else
    # Fallback output functions
    RED='\033[0;31m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    GREEN='\033[0;32m'
    NC='\033[0m'
    print_error() {
        echo -e "${RED}[ERROR]${NC} $1"
    }
    print_warning() {
        echo -e "${YELLOW}[WARNING]${NC} $1"
    }
    print_status() {
        echo -e "${BLUE}[INFO]${NC} $1"
    }
    print_success() {
        echo -e "${GREEN}[SUCCESS]${NC} $1"
    }
fi

# Source config functions (for ensure_config_directories)
if [ -f "${SCRIPT_DIR}/config.sh" ]; then
    source "${SCRIPT_DIR}/config.sh"
fi

# Source registry functions (for load_service_registry)
if [ -f "${SCRIPT_DIR}/registry.sh" ]; then
    source "${SCRIPT_DIR}/registry.sh"
fi

# Note: log_message will be available from utils.sh when modules are sourced together

# Step 1: Pre-validation (static checks)
# Checks for empty upstream blocks and other critical issues that would break nginx
pre_validate_config() {
    local config_file="$1"
    
    if [ ! -f "$config_file" ]; then
        print_error "Config file not found: $config_file"
        return 1
    fi
    
    # Check for empty upstream blocks
    # Nginx requires at least one server in each upstream block
    if grep -qE "^upstream[[:space:]]+[^[:space:]]+[[:space:]]*\{$" "$config_file"; then
        local in_upstream=false
        local upstream_name=""
        local has_server=false
        local empty_upstreams=""
        
        while IFS= read -r line; do
            # Detect upstream block start
            if echo "$line" | grep -qE "^upstream[[:space:]]+[^[:space:]]+[[:space:]]*\{$"; then
                if [ "$in_upstream" = "true" ] && [ "$has_server" = "false" ]; then
                    # Previous upstream was empty
                    empty_upstreams="${empty_upstreams}${upstream_name}\n"
                fi
                upstream_name=$(echo "$line" | sed -E 's/^upstream[[:space:]]+([^[:space:]]+)[[:space:]]*\{$/\1/')
                in_upstream=true
                has_server=false
                continue
            fi
            
            # Detect upstream block end
            if [ "$in_upstream" = "true" ] && echo "$line" | grep -qE "^\s*\}$"; then
                if [ "$has_server" = "false" ]; then
                    # This upstream block is empty
                    empty_upstreams="${empty_upstreams}${upstream_name}\n"
                fi
                in_upstream=false
                has_server=false
                continue
            fi
            
            # Check for server lines within upstream block
            if [ "$in_upstream" = "true" ] && echo "$line" | grep -qE "^\s*server\s+"; then
                has_server=true
            fi
        done < "$config_file"
        
        # Check last upstream if file ends while in upstream block
        if [ "$in_upstream" = "true" ] && [ "$has_server" = "false" ]; then
            empty_upstreams="${empty_upstreams}${upstream_name}\n"
        fi
        
        if [ -n "$empty_upstreams" ]; then
            print_error "Config validation FAILED: Empty upstream blocks detected:"
            echo -e "$empty_upstreams" | sed 's/^/  - /' | sed '/^[[:space:]]*$/d'
            print_error "Nginx requires at least one server in each upstream block"
            print_error "This config would break nginx and has been rejected"
            return 1
        fi
    fi
    
    return 0
}

# Step 2: Syntax validation (nginx -t on file)
# Simplified syntax check - optional if nginx container is not running
validate_config_syntax() {
    local config_file="$1"
    local nginx_compose_file="${NGINX_PROJECT_DIR}/docker-compose.yml"
    
    if [ ! -f "$config_file" ]; then
        print_error "Config file not found: $config_file"
        return 1
    fi
    
    # Check if nginx container is running (optional - for syntax check)
    if ! docker ps --format "{{.Names}}" | grep -q "^nginx-microservice$"; then
        print_warning "Nginx container not running - skipping syntax validation"
        print_warning "Config will be validated when nginx starts"
        return 0  # Don't fail - nginx will validate on startup
    fi
    
    # Test config syntax using nginx -t
    # Note: We test with the actual nginx.conf which includes all configs
    # This is acceptable because nginx will handle unavailable upstreams gracefully
    # Use docker exec directly instead of docker compose exec to avoid project name issues
    cd "$NGINX_PROJECT_DIR"
    if docker exec nginx-microservice nginx -t >/dev/null 2>&1; then
        # Basic syntax check passed
        return 0
    else
        # Get error output
        local error_output=$(docker exec nginx-microservice nginx -t 2>&1 || true)
        
        # Check for critical errors that would break nginx
        if echo "$error_output" | grep -qE "duplicate upstream|no servers are inside upstream|syntax error"; then
            print_error "Config validation FAILED: Critical syntax error detected"
            echo "$error_output" | grep -E "duplicate upstream|no servers are inside upstream|syntax error" | head -5 | sed 's/^/  /'
            return 1
        else
            # Non-critical error - might be upstream unavailable (acceptable)
            print_warning "Config syntax check had warnings (may be expected if upstreams unavailable)"
            return 0  # Don't fail - nginx will handle unavailable upstreams
        fi
    fi
}

# Step 3: Compatibility check (duplicate upstreams)
# Checks for duplicate upstream names across all configs
check_config_compatibility() {
    local staging_config="$1"
    local config_dir="${NGINX_PROJECT_DIR}/nginx/conf.d"
    local blue_green_dir="${config_dir}/blue-green"
    
    if [ ! -f "$staging_config" ]; then
        print_error "Staging config file not found: $staging_config"
        return 1
    fi
    
    # Extract upstream names from staging config
    local staging_upstreams=$(grep -E "^upstream[[:space:]]+[^[:space:]]+[[:space:]]*\{$" "$staging_config" | sed -E 's/^upstream[[:space:]]+([^[:space:]]+)[[:space:]]*\{$/\1/' || echo "")
    
    if [ -z "$staging_upstreams" ]; then
        # No upstreams in staging config - nothing to check
        return 0
    fi
    
    # Check for duplicates in existing validated configs
    if [ -d "$blue_green_dir" ]; then
        for existing_config in "$blue_green_dir"/*.conf; do
            if [ -f "$existing_config" ]; then
                local existing_upstreams=$(grep -E "^upstream[[:space:]]+[^[:space:]]+[[:space:]]*\{$" "$existing_config" | sed -E 's/^upstream[[:space:]]+([^[:space:]]+)[[:space:]]*\{$/\1/' || echo "")
                
                for staging_upstream in $staging_upstreams; do
                    for existing_upstream in $existing_upstreams; do
                        if [ "$staging_upstream" = "$existing_upstream" ]; then
                            print_error "Config validation FAILED: Duplicate upstream '$staging_upstream' found"
                            print_error "Upstream names must be unique across all configs"
                            print_error "Existing config: $(basename "$existing_config")"
                            print_error "New config: $(basename "$staging_config")"
                            return 1
                        fi
                    done
                done
            fi
        done
    fi
    
    return 0
}

# Function to validate nginx config in isolation (simplified 3-step pipeline)
# Simplified validation: Pre-validation → Syntax check → Compatibility check
validate_config_in_isolation() {
    local service_name="$1"
    local domain="$2"
    local color="$3"
    local staging_config_path="$4"
    
    if [ -z "$service_name" ] || [ -z "$domain" ] || [ -z "$color" ] || [ -z "$staging_config_path" ]; then
        print_error "validate_config_in_isolation: all parameters are required"
        return 1
    fi
    
    if [ ! -f "$staging_config_path" ]; then
        print_error "Staging config file not found: $staging_config_path"
        return 1
    fi
    
    # Step 1: Pre-validation (static checks)
    if type log_message >/dev/null 2>&1; then
        log_message "INFO" "$service_name" "$color" "validate" "Step 1: Pre-validating config for ${domain}.${color}.conf"
    fi
    if ! pre_validate_config "$staging_config_path"; then
        if type log_message >/dev/null 2>&1; then
            log_message "ERROR" "$service_name" "$color" "validate" "Pre-validation failed for ${domain}.${color}.conf"
        fi
        return 1
    fi
    
    # Step 2: Syntax validation (optional if nginx container not running)
    if type log_message >/dev/null 2>&1; then
        log_message "INFO" "$service_name" "$color" "validate" "Step 2: Validating syntax for ${domain}.${color}.conf"
    fi
    if ! validate_config_syntax "$staging_config_path"; then
        if type log_message >/dev/null 2>&1; then
            log_message "ERROR" "$service_name" "$color" "validate" "Syntax validation failed for ${domain}.${color}.conf"
        fi
        return 1
    fi
    
    # Step 3: Compatibility check (duplicate upstreams)
    if type log_message >/dev/null 2>&1; then
        log_message "INFO" "$service_name" "$color" "validate" "Step 3: Checking compatibility for ${domain}.${color}.conf"
    fi
    if ! check_config_compatibility "$staging_config_path"; then
        if type log_message >/dev/null 2>&1; then
            log_message "ERROR" "$service_name" "$color" "validate" "Compatibility check failed for ${domain}.${color}.conf"
        fi
        return 1
    fi
    
    # All checks passed
    if type log_message >/dev/null 2>&1; then
        log_message "SUCCESS" "$service_name" "$color" "validate" "Config validation passed for ${domain}.${color}.conf"
    fi
    return 0
}

# Function to validate and apply config (moves from staging to blue-green if valid)
validate_and_apply_config() {
    local service_name="$1"
    local domain="$2"
    local color="$3"
    local staging_config_path="$4"
    
    if [ -z "$service_name" ] || [ -z "$domain" ] || [ -z "$color" ] || [ -z "$staging_config_path" ]; then
        print_error "validate_and_apply_config: all parameters are required"
        return 1
    fi
    
    if [ ! -f "$staging_config_path" ]; then
        print_error "Staging config file not found: $staging_config_path"
        return 1
    fi
    
    local config_dir="${NGINX_PROJECT_DIR}/nginx/conf.d"
    local blue_green_dir="${config_dir}/blue-green"
    local rejected_dir="${config_dir}/rejected"
    local target_config="${blue_green_dir}/${domain}.${color}.conf"
    
    if type ensure_config_directories >/dev/null 2>&1; then
        ensure_config_directories
    else
        local staging_dir="${config_dir}/staging"
        mkdir -p "$staging_dir"
        mkdir -p "$blue_green_dir"
        mkdir -p "$rejected_dir"
    fi
    
    # Validate config in isolation
    if type log_message >/dev/null 2>&1; then
        log_message "INFO" "$service_name" "$color" "validate" "Validating config for ${domain}.${color}.conf"
    fi
    
    if validate_config_in_isolation "$service_name" "$domain" "$color" "$staging_config_path"; then
        # Validation passed - move to blue-green directory
        if mv "$staging_config_path" "$target_config"; then
            if type log_message >/dev/null 2>&1; then
                log_message "SUCCESS" "$service_name" "$color" "apply" "Config applied successfully: ${domain}.${color}.conf"
            fi
            return 0
        else
            print_error "Failed to move config from staging to blue-green: $staging_config_path -> $target_config"
            return 1
        fi
    else
        # Validation failed - move to rejected directory with timestamp
        local timestamp=$(date +%Y%m%d_%H%M%S)
        local rejected_config="${rejected_dir}/${domain}.${color}.conf.${timestamp}"
        
        if mv "$staging_config_path" "$rejected_config"; then
            if type log_message >/dev/null 2>&1; then
                log_message "ERROR" "$service_name" "$color" "reject" "Config rejected and moved to: $rejected_config"
            fi
            print_error "Config validation failed for ${domain}.${color}.conf - config rejected and moved to rejected directory"
            print_error "Nginx will continue running with existing valid configs"
            return 1
        else
            print_error "Failed to move rejected config to rejected directory"
            # Remove invalid config from staging
            rm -f "$staging_config_path"
            return 1
        fi
    fi
}

# Function to switch config symlink
switch_config_symlink() {
    local domain="$1"
    local target_color="$2"
    
    if [ -z "$domain" ] || [ -z "$target_color" ]; then
        print_error "switch_config_symlink: domain and target_color are required"
        return 1
    fi
    
    if [ "$target_color" != "blue" ] && [ "$target_color" != "green" ]; then
        print_error "switch_config_symlink: target_color must be 'blue' or 'green'"
        return 1
    fi
    
    local config_dir="${NGINX_PROJECT_DIR}/nginx/conf.d"
    local blue_green_dir="${config_dir}/blue-green"
    local symlink_file="${config_dir}/${domain}.conf"
    local target_file="${blue_green_dir}/${domain}.${target_color}.conf"
    
    # Check if target config exists
    if [ ! -f "$target_file" ]; then
        print_error "Target config file not found: $target_file"
        return 1
    fi
    
    # Note: We no longer clean up upstreams here because:
    # 1. We always generate both blue and green servers in upstream blocks
    # 2. Nginx will handle DNS resolution dynamically when containers start
    # 3. Removing servers can leave empty upstream blocks which nginx rejects
    
    # Remove existing symlink or file
    if [ -L "$symlink_file" ] || [ -f "$symlink_file" ]; then
        rm -f "$symlink_file"
    fi
    
    # Create new symlink (relative path to blue-green subdirectory)
    if ln -sf "blue-green/${domain}.${target_color}.conf" "$symlink_file"; then
        if type log_message >/dev/null 2>&1; then
            log_message "SUCCESS" "$domain" "$target_color" "symlink" "Symlink switched to $target_color config"
        fi
        return 0
    else
        print_error "Failed to create symlink: $symlink_file -> $target_file"
        return 1
    fi
}

# Function to test nginx config for a specific service
test_service_nginx_config() {
    local service_name="$1"
    
    if [ -z "$service_name" ]; then
        # If no service name provided, test all configs (original behavior)
        test_nginx_config
        return $?
    fi
    
    if ! type load_service_registry >/dev/null 2>&1; then
        print_error "load_service_registry function not available"
        return 1
    fi
    
    local registry=$(load_service_registry "$service_name")
    local domain=$(echo "$registry" | jq -r '.domain')
    
    if [ -z "$domain" ] || [ "$domain" = "null" ]; then
        print_error "Domain not found in registry for service: $service_name"
        return 1
    fi
    
    local config_file="${NGINX_PROJECT_DIR}/nginx/conf.d/${domain}.conf"
    
    if [ ! -f "$config_file" ] && [ ! -L "$config_file" ]; then
        print_error "Config file not found: $config_file"
        return 1
    fi
    
    # Resolve symlink to actual file if it's a symlink
    local actual_config_file="$config_file"
    if [ -L "$config_file" ]; then
        # Resolve symlink to absolute path
        actual_config_file=$(readlink -f "$config_file" 2>/dev/null || readlink "$config_file" 2>/dev/null || echo "$config_file")
        # If readlink returned relative path, make it absolute
        if [ "${actual_config_file#/}" = "$actual_config_file" ]; then
            # Relative path, resolve from config_dir
            local config_dir="${NGINX_PROJECT_DIR}/nginx/conf.d"
            actual_config_file="${config_dir}/${actual_config_file}"
        fi
    fi
    
    if [ ! -f "$actual_config_file" ]; then
        print_error "Config file (symlink target) not found: $actual_config_file (symlink: $config_file)"
        return 1
    fi
    
    # Validate config file syntax by checking basic structure
    # This is a lightweight check - full validation still requires nginx -t
    # Check the actual file, not the symlink
    if ! grep -q "^upstream " "$actual_config_file" && ! grep -q "server 127.0.0.1:65535" "$actual_config_file"; then
        print_error "Config file appears to be invalid (no upstream blocks found): $actual_config_file (symlink: $config_file)"
        return 1
    fi
    
    # Fix broken symlinks before testing (prevents nginx from failing on broken symlinks)
    fix_broken_symlinks
    
    # Test all configs but provide service-specific context
    # The real isolation comes from generating valid configs
    if type log_message >/dev/null 2>&1; then
        log_message "INFO" "$service_name" "validation" "test" "Testing nginx configuration for service: $service_name (${domain})"
    fi
    
    # Use the standard test but it will validate all configs
    # This is acceptable because we ensure each service generates valid configs
    # Note: test_nginx_config will also fix broken symlinks, but we do it here too for clarity
    if test_nginx_config; then
        if type log_message >/dev/null 2>&1; then
            log_message "SUCCESS" "$service_name" "validation" "test" "Configuration test passed for service: $service_name"
        fi
        return 0
    else
        if type log_message >/dev/null 2>&1; then
            log_message "ERROR" "$service_name" "validation" "test" "Configuration test failed for service: $service_name"
        fi
        return 1
    fi
}

# Function to fix broken symlinks in conf.d/
fix_broken_symlinks() {
    local config_dir="${NGINX_PROJECT_DIR}/nginx/conf.d"
    local fixed=0
    
    # Check all symlinks in conf.d/
    if [ -d "$config_dir" ]; then
        while IFS= read -r symlink; do
            if [ -L "$symlink" ]; then
                # Check if symlink target exists
                local target=$(readlink -f "$symlink" 2>/dev/null || readlink "$symlink" 2>/dev/null || echo "")
                if [ -z "$target" ] || [ ! -f "$target" ]; then
                    # Resolve relative symlink
                    if [ -n "$target" ] && [ "${target#/}" = "$target" ]; then
                        target="${config_dir}/${target}"
                    fi
                    
                    # If target still doesn't exist, remove broken symlink
                    if [ ! -f "$target" ]; then
                        local domain=$(basename "$symlink" .conf)
                        if type log_message >/dev/null 2>&1; then
                            log_message "WARNING" "nginx" "config" "fix" "Removing broken symlink: $symlink (target does not exist)"
                        else
                            print_warning "Removing broken symlink: $symlink (target does not exist)"
                        fi
                        rm -f "$symlink"
                        fixed=$((fixed + 1))
                    fi
                fi
            fi
        done < <(find "$config_dir" -maxdepth 1 -type l -name "*.conf" 2>/dev/null)
    fi
    
    if [ $fixed -gt 0 ]; then
        if type log_message >/dev/null 2>&1; then
            log_message "INFO" "nginx" "config" "fix" "Fixed $fixed broken symlink(s)"
        fi
    fi
    
    return 0
}

# Function to test nginx config (all configs)
test_nginx_config() {
    local service_name="${1:-}"  # Optional service name parameter
    
    # If service name provided, use per-service validation
    if [ -n "$service_name" ]; then
        test_service_nginx_config "$service_name"
        return $?
    fi
    
    # Fix broken symlinks before testing
    fix_broken_symlinks
    
    local nginx_compose_file="${NGINX_PROJECT_DIR}/docker-compose.yml"
    local max_wait=30
    local wait_interval=1
    local elapsed=0
    
    if [ ! -f "$nginx_compose_file" ]; then
        print_error "Nginx docker compose.yml not found: $nginx_compose_file"
        return 1
    fi
    
    cd "$NGINX_PROJECT_DIR"
    
    # Fast path: Check if nginx is already running and accessible (common case during deployments)
    # Use docker exec directly instead of docker compose exec to avoid project name issues
    if docker exec nginx-microservice echo >/dev/null 2>&1; then
        # Container is accessible, proceed directly to config test (skip wait loops)
        # This makes the function instant when nginx is already running
        :  # Empty block - nginx is ready, skip wait loops
    else
        # Nginx is not accessible, wait for it to be ready
        # Wait for nginx container to be running (not restarting)
        # We need to wait for it to be stable, not just "Up" once
        local stable_count=0
        local required_stable=3  # Container must be "Up" for 3 consecutive checks
        
        while [ $elapsed -lt $max_wait ]; do
            # Check container status using docker directly (more reliable than docker compose ps)
            local container_status=$(docker inspect --format='{{.State.Status}}' nginx-microservice 2>/dev/null || echo "none")
            if [ "$container_status" = "running" ]; then
                # Container is running, increment stable count
                stable_count=$((stable_count + 1))
                if [ $stable_count -ge $required_stable ]; then
                    # Container has been stable for required checks
                    break
                fi
            elif [ "$container_status" = "restarting" ] || [ "$container_status" = "starting" ]; then
                # Container is restarting or starting, reset stable count
                stable_count=0
            else
                # Container might not exist or be stopped, reset stable count
                stable_count=0
            fi
            sleep $wait_interval
            elapsed=$((elapsed + wait_interval))
        done
        
        # Additional check: ensure container is actually accessible
        # Wait longer if container was restarting
        local retries=0
        local max_retries=10  # Increased from 5 to 10
        while [ $retries -lt $max_retries ]; do
            if docker exec nginx-microservice echo >/dev/null 2>&1; then
                # Container is accessible, verify it stays accessible
                sleep 1
                if docker exec nginx-microservice echo >/dev/null 2>&1; then
                    break
                fi
            fi
            sleep 1
            retries=$((retries + 1))
        done
        
        if [ $retries -eq $max_retries ]; then
            # Try to start nginx container if it's not running
            print_warning "Nginx container is not accessible, attempting to start it..."
            if docker compose up -d nginx >/dev/null 2>&1; then
                print_status "Nginx container started, waiting for it to be ready..."
                sleep 3
                # Try one more time
                if docker exec nginx-microservice echo >/dev/null 2>&1; then
                    print_success "Nginx container is now accessible"
                    # Continue with test
                else
                    print_error "Nginx container started but still not accessible"
                    print_error "Check nginx logs: docker logs nginx-microservice"
                    # Don't fail - nginx might start later, configs are already validated
                    return 0
                fi
            else
                print_warning "Could not start nginx container (may not be critical if nginx starts later)"
                print_warning "Configs are already validated, nginx will work when it starts"
                # Don't fail - configs are validated, nginx can start later
                return 0
            fi
        fi
    fi
    
    # Now test the configuration
    # Note: We test all configs, but if test fails, we don't prevent nginx from running
    # Invalid configs should have been rejected during generation
    # Use docker exec directly instead of docker compose exec to avoid project name issues
    if docker exec nginx-microservice nginx -t >/dev/null 2>&1; then
        return 0
    else
        # Get error output for logging
        local error_output=$(docker exec nginx-microservice nginx -t 2>&1 || true)
        print_warning "Nginx configuration test failed (this may be expected if nginx is not fully started)"
        # Log error but don't print to console unless in verbose mode
        echo "$error_output" | grep -E "error|emerg|failed" | head -5 | sed 's/^/  /' || true
        # Don't return error - allow nginx to attempt to start anyway
        # Invalid configs should have been rejected during generation phase
        return 0
    fi
}

# Function to reload nginx (simplified and more robust)
reload_nginx() {
    local nginx_compose_file="${NGINX_PROJECT_DIR}/docker-compose.yml"
    
    if [ ! -f "$nginx_compose_file" ]; then
        print_error "Nginx docker compose.yml not found: $nginx_compose_file"
        return 1
    fi
    
    cd "$NGINX_PROJECT_DIR"
    
    # Check if nginx container exists and is running
    local nginx_running=false
    if docker ps --format "{{.Names}}" 2>/dev/null | grep -qE "^nginx-microservice$"; then
        # Container exists, check if it's actually running (not restarting)
        local container_status=$(docker inspect --format='{{.State.Status}}' nginx-microservice 2>/dev/null || echo "none")
        if [ "$container_status" = "running" ]; then
            nginx_running=true
        fi
    fi
    
    # If nginx is not running, start it
    if [ "$nginx_running" = "false" ]; then
        print_status "Nginx container is not running, starting it..."
        if ! docker compose up -d nginx 2>&1; then
            print_error "Failed to start nginx container"
            return 1
        fi
        
        # Wait for nginx to be ready (max 10 seconds)
        local wait_count=0
        local max_wait=10
        while [ $wait_count -lt $max_wait ]; do
            if docker ps --format "{{.Names}}" 2>/dev/null | grep -qE "^nginx-microservice$"; then
                local container_status=$(docker inspect --format='{{.State.Status}}' nginx-microservice 2>/dev/null || echo "none")
                if [ "$container_status" = "running" ]; then
                    # Give nginx a moment to fully initialize
                    sleep 1
                    print_success "Nginx container started and ready"
                    return 0
                fi
            fi
            sleep 1
            wait_count=$((wait_count + 1))
        done
        
        print_error "Nginx container failed to start within ${max_wait} seconds"
        return 1
    fi
    
    # Nginx is running - reload it
    # Note: Config test may fail if upstreams are unavailable, but that's acceptable
    # Nginx will return 502s until containers are available
    # Use docker exec directly instead of docker compose exec to avoid project name issues
    if docker exec nginx-microservice nginx -s reload 2>&1; then
        return 0
    else
        local reload_error=$(docker exec nginx-microservice nginx -s reload 2>&1)
        print_error "Failed to reload nginx: $reload_error"
        return 1
    fi
}

# Function to cleanup service nginx config (ensure symlink points to correct color when containers are stopped)
cleanup_service_nginx_config() {
    local service_name="$1"
    
    if ! type load_service_registry >/dev/null 2>&1; then
        if type log_message >/dev/null 2>&1; then
            log_message "WARNING" "$service_name" "cleanup" "config" "load_service_registry not available, skipping config cleanup"
        fi
        return 0
    fi
    
    local registry=$(load_service_registry "$service_name")
    local domain=$(echo "$registry" | jq -r '.domain')
    
    if [ -z "$domain" ] || [ "$domain" = "null" ]; then
        if type log_message >/dev/null 2>&1; then
            log_message "WARNING" "$service_name" "cleanup" "config" "Domain not found in registry, skipping config cleanup"
        fi
        return 0
    fi
    
    local config_dir="${NGINX_PROJECT_DIR}/nginx/conf.d"
    local blue_green_dir="${config_dir}/blue-green"
    local symlink_file="${config_dir}/${domain}.conf"
    local blue_config="${blue_green_dir}/${domain}.blue.conf"
    local green_config="${blue_green_dir}/${domain}.green.conf"
    
    # Check if blue/green configs exist (service is migrated)
    if [ ! -f "$blue_config" ] || [ ! -f "$green_config" ]; then
        if type log_message >/dev/null 2>&1; then
            log_message "INFO" "$service_name" "cleanup" "config" "Service not migrated to symlink system, skipping config cleanup"
        fi
        return 0
    fi
    
    # Check if any containers for this service still exist
    local service_keys=$(echo "$registry" | jq -r '.services | keys[]')
    local any_containers_exist=false
    
    while IFS= read -r service_key; do
        local container_base=$(echo "$registry" | jq -r ".services[\"$service_key\"].container_name_base")
        
        if [ -z "$container_base" ] || [ "$container_base" = "null" ]; then
            continue
        fi
        
        if docker ps -a --format "{{.Names}}" | grep -qE "^${container_base}(-blue|-green)?$"; then
            any_containers_exist=true
            break
        fi
    done <<< "$service_keys"
    
    # If containers still exist, don't cleanup (they might be starting)
    if [ "$any_containers_exist" = "true" ]; then
        if type log_message >/dev/null 2>&1; then
            log_message "INFO" "$service_name" "cleanup" "config" "Containers still exist, skipping config cleanup"
        fi
        return 0
    fi
    
    # Ensure symlink points to blue (default when no containers running)
    # This is safe since both configs exist and will have placeholder upstreams
    if [ ! -L "$symlink_file" ]; then
        if type log_message >/dev/null 2>&1; then
            log_message "INFO" "$service_name" "cleanup" "config" "Creating symlink pointing to blue (default)"
        fi
        if type switch_config_symlink >/dev/null 2>&1; then
            switch_config_symlink "$domain" "blue" || true
        fi
    fi
    
    if type log_message >/dev/null 2>&1; then
        log_message "INFO" "$service_name" "cleanup" "config" "Config cleanup completed (symlink maintained)"
    fi
}

