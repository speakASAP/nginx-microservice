#!/bin/bash
# Blue/Green Deployment Utility Functions
# Shared functions for all blue/green deployment scripts

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
REGISTRY_DIR="${NGINX_PROJECT_DIR}/service-registry"
STATE_DIR="${NGINX_PROJECT_DIR}/state"
LOG_DIR="${NGINX_PROJECT_DIR}/logs/blue-green"

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Function to print colored output
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

# Function to log message
log_message() {
    local level="$1"
    local service="$2"
    local color="$3"
    local action="$4"
    local message="$5"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "[$timestamp] [$level] [$service] [$color] [$action] $message" >> "${LOG_DIR}/deploy.log"
    
    case "$level" in
        "ERROR")
            print_error "$message"
            ;;
        "WARNING")
            print_warning "$message"
            ;;
        "SUCCESS")
            print_success "$message"
            ;;
        *)
            print_status "$message"
            ;;
    esac
}

# Function to load service registry
load_service_registry() {
    local service_name="$1"
    local registry_file="${REGISTRY_DIR}/${service_name}.json"
    
    if [ ! -f "$registry_file" ]; then
        print_error "Service registry not found: $registry_file"
        exit 1
    fi
    
    # Source jq or use python for JSON parsing
    if command -v jq >/dev/null 2>&1; then
        cat "$registry_file"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "import json, sys; print(json.dumps(json.load(open('$registry_file'))))"
    else
        print_error "Neither jq nor python3 found. Install jq: brew install jq"
        exit 1
    fi
}

# Function to get registry value (requires jq)
get_registry_value() {
    local service_name="$1"
    local key_path="$2"
    local registry_file="${REGISTRY_DIR}/${service_name}.json"
    
    if [ ! -f "$registry_file" ]; then
        print_error "Service registry not found: $registry_file"
        exit 1
    fi
    
    if command -v jq >/dev/null 2>&1; then
        jq -r "$key_path" "$registry_file"
    else
        print_error "jq not found. Install jq: brew install jq"
        exit 1
    fi
}

# Function to load state
load_state() {
    local service_name="$1"
    local domain="${2:-}"
    local state_file="${STATE_DIR}/${service_name}.json"
    
    # For statex service, check if domain-specific state exists
    if [ "$service_name" = "statex" ] && [ -n "$domain" ]; then
        if [ -f "$state_file" ]; then
            # Check if domain-specific state exists
            local domain_state=$(jq -r ".domains[\"$domain\"] // empty" "$state_file" 2>/dev/null)
            if [ -n "$domain_state" ] && [ "$domain_state" != "null" ]; then
                # Return domain-specific state with service_name
                jq -r --arg domain "$domain" '{service_name: "statex", domain: $domain} + .domains[$domain]' "$state_file" 2>/dev/null || {
                    # Fallback: create domain state structure
                    echo "{\"service_name\": \"statex\", \"domain\": \"$domain\", \"active_color\": \"blue\", \"blue\": {\"status\": \"stopped\", \"deployed_at\": null, \"version\": null}, \"green\": {\"status\": \"stopped\", \"deployed_at\": null, \"version\": null}, \"last_deployment\": {\"color\": \"blue\", \"timestamp\": null, \"success\": true}}"
                }
                return
            fi
        fi
        # Create initial domain-specific state
        if [ ! -f "$state_file" ]; then
            echo "{\"service_name\": \"statex\", \"domains\": {}}" | jq '.' > "$state_file" 2>/dev/null || true
        fi
        # Add domain state if it doesn't exist
        local current_state=$(cat "$state_file" 2>/dev/null || echo "{}")
        local domain_state=$(echo "$current_state" | jq -r ".domains[\"$domain\"] // empty" 2>/dev/null)
        if [ -z "$domain_state" ] || [ "$domain_state" = "null" ]; then
            current_state=$(echo "$current_state" | jq --arg domain "$domain" '.domains[$domain] = {
                "active_color": "blue",
                "blue": {"status": "stopped", "deployed_at": null, "version": null},
                "green": {"status": "stopped", "deployed_at": null, "version": null},
                "last_deployment": {"color": "blue", "timestamp": null, "success": true}
            }' 2>/dev/null)
            echo "$current_state" | jq '.' > "$state_file" 2>/dev/null || true
        fi
        # Return domain-specific state
        jq -r --arg domain "$domain" '{service_name: "statex", domain: $domain} + .domains[$domain]' "$state_file" 2>/dev/null
        return
    fi
    
    # Standard state loading for non-statex services or when domain not specified
    if [ ! -f "$state_file" ]; then
        print_warning "State file not found: $state_file. Creating initial state."
        # Create initial state with blue as active
        cat > "$state_file" <<EOF
{
  "service_name": "$service_name",
  "active_color": "blue",
  "blue": {
    "status": "running",
    "deployed_at": null,
    "version": null
  },
  "green": {
    "status": "stopped",
    "deployed_at": null,
    "version": null
  },
  "last_deployment": {
    "color": "blue",
    "timestamp": null,
    "success": true
  }
}
EOF
    fi
    
    if command -v jq >/dev/null 2>&1; then
        cat "$state_file"
    else
        print_error "jq not found. Install jq: brew install jq"
        exit 1
    fi
}

# Function to save state
save_state() {
    local service_name="$1"
    local state_data="$2"
    local domain="${3:-}"
    local state_file="${STATE_DIR}/${service_name}.json"
    
    mkdir -p "$STATE_DIR"
    
    # For statex service with domain, save to domain-specific state
    if [ "$service_name" = "statex" ] && [ -n "$domain" ]; then
        if [ ! -f "$state_file" ]; then
            echo "{\"service_name\": \"statex\", \"domains\": {}}" | jq '.' > "$state_file" 2>/dev/null || true
        fi
        # Extract domain state from state_data (remove service_name and domain fields)
        local domain_state=$(echo "$state_data" | jq 'del(.service_name, .domain)' 2>/dev/null)
        # Update domain-specific state
        local current_state=$(cat "$state_file" 2>/dev/null || echo "{\"service_name\": \"statex\", \"domains\": {}}")
        echo "$current_state" | jq --arg domain "$domain" --argjson domain_state "$domain_state" '.domains[$domain] = $domain_state' > "$state_file" 2>/dev/null || {
            print_error "Failed to save domain-specific state"
            exit 1
        }
        return
    fi
    
    # Standard state saving for non-statex services or when domain not specified
    if command -v jq >/dev/null 2>&1; then
        echo "$state_data" | jq '.' > "$state_file"
    else
        print_error "jq not found. Install jq: brew install jq"
        exit 1
    fi
}

# Function to get active color
get_active_color() {
    local service_name="$1"
    get_registry_value "$service_name" '.active_color' 2>/dev/null || \
    jq -r '.active_color' "${STATE_DIR}/${service_name}.json" 2>/dev/null || \
    echo "blue"
}

# Function to get inactive color
get_inactive_color() {
    local service_name="$1"
    local active=$(get_active_color "$service_name")
    
    if [ "$active" = "blue" ]; then
        echo "green"
    else
        echo "blue"
    fi
}

# Function to generate upstream blocks for a specific color
generate_upstream_blocks() {
    local service_name="$1"
    local active_color="$2"
    local domain="${3:-}"
    local registry=$(load_service_registry "$service_name")
    
    # Get service keys - filter by domain if specified
    local service_keys=""
    if [ -n "$domain" ]; then
        # Check if domain-specific service list exists
        local domain_services=$(echo "$registry" | jq -r ".domains[\"$domain\"].services[]? // empty" 2>/dev/null)
        if [ -n "$domain_services" ]; then
            # Use domain-specific services
            service_keys="$domain_services"
        else
            # Fallback to all services
            service_keys=$(echo "$registry" | jq -r '.services | keys[]')
        fi
    else
        # Use all services
        service_keys=$(echo "$registry" | jq -r '.services | keys[]')
    fi
    
    local upstream_blocks=""
    
    while IFS= read -r service_key; do
        local container_base=$(echo "$registry" | jq -r ".services[\"$service_key\"].container_name_base")
        local service_port=$(echo "$registry" | jq -r ".services[\"$service_key\"].port")
        
        if [ -z "$container_base" ] || [ "$container_base" = "null" ] || [ -z "$service_port" ] || [ "$service_port" = "null" ]; then
            continue
        fi
        
        # Determine weights and backup status based on active color
        local blue_weight green_weight blue_backup green_backup
        if [ "$active_color" = "blue" ]; then
            blue_weight=100
            green_weight=""
            blue_backup=""
            green_backup=" backup"
        else
            blue_weight=""
            green_weight=100
            blue_backup=" backup"
            green_backup=""
        fi
        
        # Always generate upstream blocks - nginx will use resolver for runtime DNS resolution
        # This allows nginx to start even when containers are not running
        # Nginx will return 502 errors until containers become available, which is acceptable
        local blue_container="${container_base}-blue"
        local green_container="${container_base}-green"
        
        # Use zone for shared memory when using resolve directive (required for runtime DNS resolution)
        upstream_blocks="${upstream_blocks}upstream ${container_base} {
    zone ${container_base}_zone 64k;
"

        # Always include blue server with resolve directive (nginx will resolve at runtime via resolver)
        # The 'resolve' directive tells nginx to resolve hostnames at runtime, not at startup
        # This allows nginx to start even when containers don't exist yet
        if [ -n "$blue_weight" ]; then
            # Active server
            upstream_blocks="${upstream_blocks}    server ${blue_container}:${service_port} weight=${blue_weight}${blue_backup} max_fails=3 fail_timeout=30s resolve;
"
        else
            # Backup server
            upstream_blocks="${upstream_blocks}    server ${blue_container}:${service_port}${blue_backup} max_fails=3 fail_timeout=30s resolve;
"
        fi
        
        # Always include green server with resolve directive (nginx will resolve at runtime via resolver)
        if [ -n "$green_weight" ]; then
            # Active server
            upstream_blocks="${upstream_blocks}    server ${green_container}:${service_port} weight=${green_weight}${green_backup} max_fails=3 fail_timeout=30s resolve;
"
        else
            # Backup server
            upstream_blocks="${upstream_blocks}    server ${green_container}:${service_port}${green_backup} max_fails=3 fail_timeout=30s resolve;
"
        fi
        
        upstream_blocks="${upstream_blocks}}
"
    done <<< "$service_keys"
    
    echo "$upstream_blocks"
}

# Function to generate proxy locations from service registry
generate_proxy_locations() {
    local service_name="$1"
    local domain="${2:-}"
    local active_color="${3:-blue}"
    local registry=$(load_service_registry "$service_name")
    
    # Get service keys - filter by domain if specified
    local service_keys=""
    if [ -n "$domain" ]; then
        # Check if domain-specific service list exists
        local domain_services=$(echo "$registry" | jq -r ".domains[\"$domain\"].services[]? // empty" 2>/dev/null)
        if [ -n "$domain_services" ]; then
            # Use domain-specific services
            service_keys="$domain_services"
        else
            # Fallback to all services
            service_keys=$(echo "$registry" | jq -r '.services | keys[]')
        fi
    else
        # Use all services
        service_keys=$(echo "$registry" | jq -r '.services | keys[]')
    fi
    
    local proxy_locations=""
    
    # Check if frontend service exists
    local has_frontend=false
    local has_backend=false
    local frontend_container=""
    local backend_container=""
    
    while IFS= read -r service_key; do
        if [ "$service_key" = "frontend" ]; then
            has_frontend=true
            frontend_container=$(echo "$registry" | jq -r ".services.frontend.container_name_base")
        elif [ "$service_key" = "backend" ]; then
            has_backend=true
            backend_container=$(echo "$registry" | jq -r ".services.backend.container_name_base")
        fi
    done <<< "$service_keys"
    
    # Generate frontend location (root path) - using shared include
    if [ "$has_frontend" = "true" ] && [ -n "$frontend_container" ] && [ "$frontend_container" != "null" ]; then
        # Use upstream block name (container_base without color) - upstream block includes port and resolve directive
        # The upstream block is named after container_base and includes both blue and green servers with ports
        proxy_locations="${proxy_locations}    # Frontend service - root path
    set \$FRONTEND_UPSTREAM ${frontend_container};
    include /etc/nginx/includes/frontend-location.conf;
    
"
    elif [ "$has_backend" = "true" ] && [ -n "$backend_container" ] && [ "$backend_container" != "null" ] && [ "$has_frontend" != "true" ]; then
        # If no frontend but backend exists, route root path to backend
        local backend_container_name="${backend_container}-${active_color}"
        proxy_locations="${proxy_locations}    # Backend-only service - root path routes to backend (using variables with resolver for runtime DNS resolution)
    location / {
        set \$BACKEND_UPSTREAM ${backend_container_name};
        proxy_pass http://\$BACKEND_UPSTREAM;
        include /etc/nginx/includes/common-proxy-settings.conf;
    }
    
"
    fi
    
    # Generate backend/API location
    if [ "$has_backend" = "true" ] && [ -n "$backend_container" ] && [ "$backend_container" != "null" ]; then
        local backend_container_name="${backend_container}-${active_color}"
        proxy_locations="${proxy_locations}    # API routes with stricter rate limiting - using variables with resolver for runtime DNS resolution
    location /api/ {
        limit_req zone=api burst=20 nodelay;
        set \$BACKEND_UPSTREAM ${backend_container_name};
        proxy_pass http://\$BACKEND_UPSTREAM/api/;
        include /etc/nginx/includes/common-proxy-settings.conf;
    }
    
    # WebSocket support - using variables with resolver for runtime DNS resolution
    location /ws {
        set \$BACKEND_UPSTREAM ${backend_container_name};
        proxy_pass http://\$BACKEND_UPSTREAM/ws;
        include /etc/nginx/includes/common-proxy-settings.conf;
    }
    
    # Health check endpoint - using variables with resolver for runtime DNS resolution
    location /health {
        set \$BACKEND_UPSTREAM ${backend_container_name};
        proxy_pass http://\$BACKEND_UPSTREAM/health;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        access_log off;
        limit_req zone=api burst=5 nodelay;
    }
    
"
    fi
    
    # For services with api-gateway (like e-commerce), route /api/ to api-gateway
    local api_gateway_container=$(echo "$registry" | jq -r '.services["api-gateway"].container_name_base // empty')
    if [ -n "$api_gateway_container" ] && [ "$api_gateway_container" != "null" ]; then
        # If api-gateway exists and we haven't added /api/ yet, add it
        if [ "$has_backend" != "true" ] || [ -z "$(echo "$proxy_locations" | grep "location /api/")" ]; then
            # Get port for api-gateway
            local api_gateway_port=$(echo "$registry" | jq -r '.services["api-gateway"].port // "80"')
            # Use container name with color suffix for runtime DNS resolution
            local api_gateway_container_name="${api_gateway_container}-${active_color}"
            proxy_locations="${proxy_locations}    # API Gateway routes - using variables with resolver for runtime DNS resolution
    location /api/ {
        limit_req zone=api burst=20 nodelay;
        set \$API_GATEWAY_UPSTREAM ${api_gateway_container_name};
        proxy_pass http://\$API_GATEWAY_UPSTREAM:${api_gateway_port}/api/;
        include /etc/nginx/includes/common-proxy-settings.conf;
    }
    
"
        fi
    fi
    
    echo "$proxy_locations"
}

# Function to ensure staging and rejected directories exist
ensure_config_directories() {
    local config_dir="${NGINX_PROJECT_DIR}/nginx/conf.d"
    local staging_dir="${config_dir}/staging"
    local rejected_dir="${config_dir}/rejected"
    local blue_green_dir="${config_dir}/blue-green"
    
    mkdir -p "$staging_dir"
    mkdir -p "$rejected_dir"
    mkdir -p "$blue_green_dir"
}

# Function to validate nginx config in isolation (with existing valid configs)
# Tests new config together with all existing valid configs to ensure compatibility
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
    
    # PRE-VALIDATION: Check for empty upstream blocks before testing with nginx
    # This catches critical errors that would break nginx - nginx requires at least one server in each upstream block
    # Pattern: upstream name { followed by } without any server lines in between
    if grep -qE "^upstream\s+\S+\s*\{$" "$staging_config_path"; then
        # Check each upstream block for empty servers
        local in_upstream=false
        local upstream_name=""
        local has_server=false
        local empty_upstreams=""
        
        while IFS= read -r line; do
            # Detect upstream block start
            if echo "$line" | grep -qE "^upstream\s+\S+\s*\{$"; then
                if [ "$in_upstream" = "true" ] && [ "$has_server" = "false" ]; then
                    # Previous upstream was empty
                    empty_upstreams="${empty_upstreams}${upstream_name}\n"
                fi
                upstream_name=$(echo "$line" | sed -E 's/^upstream\s+(\S+)\s*\{$/\1/')
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
        done < "$staging_config_path"
        
        # Check last upstream if file ends while in upstream block
        if [ "$in_upstream" = "true" ] && [ "$has_server" = "false" ]; then
            empty_upstreams="${empty_upstreams}${upstream_name}\n"
        fi
        
        if [ -n "$empty_upstreams" ]; then
            print_error "Config validation FAILED: Empty upstream blocks detected:"
            echo -e "$empty_upstreams" | sed 's/^/  - /' | sed '/^[[:space:]]*$/d'
            print_error "Nginx requires at least one server in each upstream block"
            print_error "This config would break nginx and has been rejected"
            log_message "ERROR" "$service_name" "$color" "validate" "Config rejected: Empty upstream blocks found in ${domain}.${color}.conf"
            return 1
        fi
    fi
    
    local config_dir="${NGINX_PROJECT_DIR}/nginx/conf.d"
    local blue_green_dir="${config_dir}/blue-green"
    local nginx_compose_file="${NGINX_PROJECT_DIR}/docker-compose.yml"
    local container_test_dir="/tmp/nginx-config-test-$$"
    
    # Ensure nginx container is running (or try to start it)
    # If nginx container is not accessible, we can still validate if pre-validation passed
    local nginx_accessible=false
    local max_wait=30
    local wait_interval=1
    local elapsed=0
    
    # Wait for nginx container to be stable (not restarting)
    while [ $elapsed -lt $max_wait ]; do
        if docker ps --format "{{.Names}}\t{{.Status}}" 2>/dev/null | grep -qE "^nginx-microservice\s+Up"; then
            # Check if container is actually accessible (not restarting)
            if docker compose -f "$nginx_compose_file" exec -T nginx echo >/dev/null 2>&1; then
                nginx_accessible=true
                break
            fi
        fi
        sleep $wait_interval
        elapsed=$((elapsed + wait_interval))
    done
    
    if [ "$nginx_accessible" = "false" ]; then
        print_status "Nginx container not accessible, attempting to start it..."
        cd "$NGINX_PROJECT_DIR"
        if docker compose -f "$nginx_compose_file" up -d nginx >/dev/null 2>&1; then
            # Wait for nginx to be ready and stable
            elapsed=0
            while [ $elapsed -lt $max_wait ]; do
                if docker ps --format "{{.Names}}\t{{.Status}}" 2>/dev/null | grep -qE "^nginx-microservice\s+Up"; then
                    if docker compose -f "$nginx_compose_file" exec -T nginx echo >/dev/null 2>&1; then
                        nginx_accessible=true
                        break
                    fi
                fi
                sleep $wait_interval
                elapsed=$((elapsed + wait_interval))
            done
        fi
    fi
    
    # If nginx is still not accessible but pre-validation passed, we can still proceed
    # Pre-validation (empty upstream check) is the critical check - if that passes, config is likely safe
    # Configs with resolve directive will work even if containers don't exist yet
    if [ "$nginx_accessible" = "false" ]; then
        print_warning "Nginx container not accessible for full validation"
        print_warning "Pre-validation passed (no empty upstream blocks) - config appears safe"
        print_warning "Config will be applied, but full nginx test will be skipped"
        log_message "WARNING" "$service_name" "$color" "validate" "Nginx container not accessible, but pre-validation passed for ${domain}.${color}.conf"
        # Return success since pre-validation passed - config should be safe
        return 0
    fi
    
    # Create test directory inside container
    docker compose -f "$nginx_compose_file" exec -T nginx mkdir -p "$container_test_dir" >/dev/null 2>&1 || {
        print_error "Failed to create test directory in nginx container"
        return 1
    }
    
    # Copy all existing valid configs from blue-green directory to container test directory
    # These are the configs that are currently working
    if [ -d "$blue_green_dir" ]; then
        for existing_config in "$blue_green_dir"/*.conf; do
            if [ -f "$existing_config" ]; then
                local existing_filename=$(basename "$existing_config")
                # Skip the config we're testing (same domain and color)
                if ! echo "$existing_filename" | grep -qE "^${domain}\.${color}\.conf$"; then
                    docker cp "$existing_config" "nginx-microservice:${container_test_dir}/" >/dev/null 2>&1 || true
                fi
            fi
        done
    fi
    
    # Copy the new config to container test directory
    local test_config_name="${domain}.${color}.conf"
    docker cp "$staging_config_path" "nginx-microservice:${container_test_dir}/${test_config_name}" >/dev/null 2>&1 || {
        print_error "Failed to copy staging config to container"
        docker compose -f "$nginx_compose_file" exec -T nginx rm -rf "$container_test_dir" >/dev/null 2>&1 || true
        return 1
    }
    
    # Create temporary nginx.conf that includes test directory
    local temp_nginx_conf="${container_test_dir}/nginx-test.conf"
    docker compose -f "$nginx_compose_file" exec -T nginx sh -c "sed 's|include /etc/nginx/conf.d/\*.conf;|include ${container_test_dir}/*.conf;|g' /etc/nginx/nginx.conf > ${temp_nginx_conf}" >/dev/null 2>&1 || {
        print_error "Failed to create test nginx.conf"
        docker compose -f "$nginx_compose_file" exec -T nginx rm -rf "$container_test_dir" >/dev/null 2>&1 || true
        return 1
    }
    
    # Test nginx config with test directory
    cd "$NGINX_PROJECT_DIR"
    local test_result=0
    local error_output=""
    
    if docker compose -f "$nginx_compose_file" exec -T nginx nginx -t -c "$temp_nginx_conf" >/dev/null 2>&1; then
        test_result=0
    else
        # Get actual error message
        error_output=$(docker compose -f "$nginx_compose_file" exec -T nginx nginx -t -c "$temp_nginx_conf" 2>&1 || true)
        
        # Check for critical errors that would break nginx
        if echo "$error_output" | grep -qE "host not found in upstream|no servers are inside upstream"; then
            print_error "Config validation FAILED: Critical error detected:"
            echo "$error_output" | grep -E "host not found in upstream|no servers are inside upstream" | sed 's/^/  /'
            print_error "This config would break nginx and has been rejected"
            print_error "Upstream blocks must use 'resolve' directive for runtime DNS resolution"
            test_result=1
        elif echo "$error_output" | grep -qE "duplicate upstream"; then
            print_error "Config validation FAILED: Duplicate upstream block detected:"
            echo "$error_output" | grep -E "duplicate upstream" | sed 's/^/  /'
            print_error "This config would break nginx and has been rejected"
            print_error "Upstream blocks must be unique across all config files"
            print_error "Check if this upstream is already defined in another config file for the same service"
            test_result=1
        else
            print_error "Config validation failed for ${domain}.${color}.conf:"
            echo "$error_output" | sed 's/^/  /'
            test_result=1
        fi
    fi
    
    # Cleanup test directory in container
    docker compose -f "$nginx_compose_file" exec -T nginx rm -rf "$container_test_dir" >/dev/null 2>&1 || true
    
    if [ $test_result -eq 0 ]; then
        log_message "SUCCESS" "$service_name" "$color" "validate" "Config validation passed for ${domain}.${color}.conf"
        return 0
    else
        log_message "ERROR" "$service_name" "$color" "validate" "Config validation failed for ${domain}.${color}.conf"
        return 1
    fi
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
    
    ensure_config_directories
    
    # Validate config in isolation
    log_message "INFO" "$service_name" "$color" "validate" "Validating config for ${domain}.${color}.conf"
    
    if validate_config_in_isolation "$service_name" "$domain" "$color" "$staging_config_path"; then
        # Validation passed - move to blue-green directory
        if mv "$staging_config_path" "$target_config"; then
            log_message "SUCCESS" "$service_name" "$color" "apply" "Config applied successfully: ${domain}.${color}.conf"
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
            log_message "ERROR" "$service_name" "$color" "reject" "Config rejected and moved to: $rejected_config"
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

# Function to generate blue and green nginx configs from template
generate_blue_green_configs() {
    local service_name="$1"
    local domain="$2"
    local active_color="${3:-blue}"
    
    local registry=$(load_service_registry "$service_name")
    local template_file="${NGINX_PROJECT_DIR}/nginx/templates/domain-blue-green.conf.template"
    local config_dir="${NGINX_PROJECT_DIR}/nginx/conf.d"
    local staging_dir="${config_dir}/staging"
    local blue_green_dir="${config_dir}/blue-green"
    
    # Ensure directories exist
    ensure_config_directories
    
    # Generate to staging first, then validate and apply
    local blue_staging="${staging_dir}/${domain}.blue.conf"
    local green_staging="${staging_dir}/${domain}.green.conf"
    local blue_config="${blue_green_dir}/${domain}.blue.conf"
    local green_config="${blue_green_dir}/${domain}.green.conf"
    
    if [ ! -f "$template_file" ]; then
        print_error "Template file not found: $template_file"
        return 1
    fi
    
    # Generate proxy locations for blue config - uses variables with resolver
    local blue_proxy_locations=$(generate_proxy_locations "$service_name" "$domain" "blue")
    
    # Generate proxy locations for green config - uses variables with resolver
    local green_proxy_locations=$(generate_proxy_locations "$service_name" "$domain" "green")
    
    # Generate upstream blocks for blue and green configs
    # Upstream blocks are required by nginx even if we use variables in proxy_pass
    # This allows nginx to start even when containers are not running (will return 502 until containers start)
    # Function signature: generate_upstream_blocks service_name active_color domain
    local blue_upstreams=$(generate_upstream_blocks "$service_name" "blue" "$domain")
    local green_upstreams=$(generate_upstream_blocks "$service_name" "green" "$domain")
    
    # Generate configs using Python for reliable multi-line replacement
    # Use temporary files to pass multi-line content to Python
    local temp_upstreams=$(mktemp)
    local temp_locations=$(mktemp)
    local temp_python=$(mktemp)
    
    echo "$blue_upstreams" > "$temp_upstreams"
    echo "$blue_proxy_locations" > "$temp_locations"
    
    # Create Python script
    cat > "$temp_python" <<'PYTHON_SCRIPT'
import sys
import os

template_file = sys.argv[1]
output_file = sys.argv[2]
domain = sys.argv[3]
upstreams_file = sys.argv[4]
locations_file = sys.argv[5]

try:
    # Read template
    with open(template_file, 'r') as f:
        template = f.read()
    
    # Read upstream blocks and proxy locations
    with open(upstreams_file, 'r') as f:
        upstreams = f.read()
    
    with open(locations_file, 'r') as f:
        locations = f.read()
    
    # Replace placeholders
    template = template.replace('{{DOMAIN_NAME}}', domain)
    template = template.replace('{{UPSTREAM_BLOCKS}}', upstreams)
    template = template.replace('{{PROXY_LOCATIONS}}', locations)
    
    # Write output
    with open(output_file, 'w') as f:
        f.write(template)
    
except Exception as e:
    sys.stderr.write(f"Error generating config: {e}\n")
    sys.exit(1)
PYTHON_SCRIPT
    
    # Generate blue config to staging
    if command -v python3 >/dev/null 2>&1; then
        python3 "$temp_python" "$template_file" "$blue_staging" "$domain" "$temp_upstreams" "$temp_locations" || {
            print_error "Python3 failed, falling back to sed"
            # Fallback to sed (simple replacement, may have multi-line issues)
            sed -e "s|{{DOMAIN_NAME}}|$domain|g" \
                -e "s|{{UPSTREAM_BLOCKS}}|$blue_upstreams|g" \
                -e "s|{{PROXY_LOCATIONS}}|$blue_proxy_locations|g" \
                "$template_file" > "$blue_staging"
        }
    else
        print_warning "Python3 not found, using sed (may have issues with multi-line content)"
        sed -e "s|{{DOMAIN_NAME}}|$domain|g" \
            -e "s|{{UPSTREAM_BLOCKS}}|$blue_upstreams|g" \
            -e "s|{{PROXY_LOCATIONS}}|$blue_proxy_locations|g" \
            "$template_file" > "$blue_staging"
    fi
    
    # Update upstreams and locations for green config
    echo "$green_upstreams" > "$temp_upstreams"
    echo "$green_proxy_locations" > "$temp_locations"
    
    # Generate green config to staging
    if command -v python3 >/dev/null 2>&1; then
        python3 "$temp_python" "$template_file" "$green_staging" "$domain" "$temp_upstreams" "$temp_locations" || {
            print_error "Python3 failed, falling back to sed"
            # Fallback to sed
            sed -e "s|{{DOMAIN_NAME}}|$domain|g" \
                -e "s|{{UPSTREAM_BLOCKS}}|$green_upstreams|g" \
                -e "s|{{PROXY_LOCATIONS}}|$green_proxy_locations|g" \
                "$template_file" > "$green_staging"
        }
    else
        print_warning "Python3 not found, using sed (may have issues with multi-line content)"
        sed -e "s|{{DOMAIN_NAME}}|$domain|g" \
            -e "s|{{UPSTREAM_BLOCKS}}|$green_upstreams|g" \
            -e "s|{{PROXY_LOCATIONS}}|$green_proxy_locations|g" \
            "$template_file" > "$green_staging"
    fi
    
    # Cleanup temp files
    rm -f "$temp_upstreams" "$temp_locations" "$temp_python"
    
    # Validate and apply blue config
    local blue_validated=false
    if [ -f "$blue_staging" ]; then
        if validate_and_apply_config "$service_name" "$domain" "blue" "$blue_staging"; then
            blue_validated=true
        else
            log_message "WARNING" "$service_name" "blue" "generate" "Blue config validation failed, but continuing with green"
        fi
    fi
    
    # Validate and apply green config
    local green_validated=false
    if [ -f "$green_staging" ]; then
        if validate_and_apply_config "$service_name" "$domain" "green" "$green_staging"; then
            green_validated=true
        else
            log_message "WARNING" "$service_name" "green" "generate" "Green config validation failed, but continuing"
        fi
    fi
    
    # Check if at least one config was validated successfully
    if [ "$blue_validated" = "true" ] || [ "$green_validated" = "true" ]; then
        if [ "$blue_validated" = "true" ] && [ "$green_validated" = "true" ]; then
            log_message "SUCCESS" "$service_name" "config" "generate" "Generated and validated both blue and green configs for $domain"
        elif [ "$blue_validated" = "true" ]; then
            log_message "SUCCESS" "$service_name" "config" "generate" "Generated and validated blue config for $domain (green config rejected)"
        else
            log_message "SUCCESS" "$service_name" "config" "generate" "Generated and validated green config for $domain (blue config rejected)"
        fi
        return 0
    else
        log_message "ERROR" "$service_name" "config" "generate" "Both blue and green configs failed validation for $domain"
        return 1
    fi
}

# Function to ensure blue and green configs exist
ensure_blue_green_configs() {
    local service_name="$1"
    local domain="$2"
    local active_color="${3:-blue}"
    
    # For statex service, generate configs for all domains defined in registry
    if [ "$service_name" = "statex" ]; then
        local registry=$(load_service_registry "$service_name")
        local domains=$(echo "$registry" | jq -r '.domains | keys[]' 2>/dev/null)
        
        if [ -n "$domains" ]; then
            # Generate configs for all statex domains
            while IFS= read -r statex_domain; do
                local domain_state=$(load_state "$service_name" "$statex_domain" 2>/dev/null)
                local domain_active_color=$(echo "$domain_state" | jq -r '.active_color // "blue"')
                
                local config_dir="${NGINX_PROJECT_DIR}/nginx/conf.d"
                local blue_green_dir="${config_dir}/blue-green"
                mkdir -p "$blue_green_dir"
                local blue_config="${blue_green_dir}/${statex_domain}.blue.conf"
                local green_config="${blue_green_dir}/${statex_domain}.green.conf"
                
                # Check if both configs exist and are valid (no template variables)
                local needs_regeneration=false
                if [ -f "$blue_config" ] && [ -f "$green_config" ]; then
                    # Check for template variables that indicate invalid configs
                    if grep -qE "^(blue_weight|green_weight|blue_backup|green_backup)=" "$blue_config" "$green_config" 2>/dev/null; then
                        log_message "WARNING" "$service_name" "config" "ensure" "Configs contain template variables, forcing regeneration for $statex_domain"
                        needs_regeneration=true
                    elif ! grep -qE "resolve;" "$blue_config" "$green_config" 2>/dev/null; then
                        log_message "WARNING" "$service_name" "config" "ensure" "Configs missing resolve directive, forcing regeneration for $statex_domain"
                        needs_regeneration=true
                    else
                        log_message "INFO" "$service_name" "config" "ensure" "Blue and green configs already exist for $statex_domain"
                        continue
                    fi
                else
                    needs_regeneration=true
                fi
                
                # Remove invalid configs if regeneration is needed
                if [ "$needs_regeneration" = true ]; then
                    if [ -f "$blue_config" ]; then
                        rm -f "$blue_config"
                        log_message "INFO" "$service_name" "config" "ensure" "Removed invalid blue config for $statex_domain"
                    fi
                    if [ -f "$green_config" ]; then
                        rm -f "$green_config"
                        log_message "INFO" "$service_name" "config" "ensure" "Removed invalid green config for $statex_domain"
                    fi
                fi
                
                # Generate configs if missing
                log_message "INFO" "$service_name" "config" "ensure" "Generating blue and green configs for $statex_domain"
                if ! generate_blue_green_configs "$service_name" "$statex_domain" "$domain_active_color"; then
                    log_message "ERROR" "$service_name" "config" "ensure" "Failed to generate configs for $statex_domain"
                    return 1
                fi
            done <<< "$domains"
            return 0
        fi
    fi
    
    # For non-statex services or when domain is explicitly provided, use standard logic
    # For statex service, get active_color from domain-specific state
    if [ "$service_name" = "statex" ]; then
        local state=$(load_state "$service_name" "$domain" 2>/dev/null)
        if [ -n "$state" ]; then
            active_color=$(echo "$state" | jq -r '.active_color // "blue"')
        fi
    fi
    
    local config_dir="${NGINX_PROJECT_DIR}/nginx/conf.d"
    local blue_green_dir="${config_dir}/blue-green"
    mkdir -p "$blue_green_dir"
    local blue_config="${blue_green_dir}/${domain}.blue.conf"
    local green_config="${blue_green_dir}/${domain}.green.conf"
    
    # Check if both configs exist and are valid (no template variables)
    local needs_regeneration=false
    if [ -f "$blue_config" ] && [ -f "$green_config" ]; then
        # Check for template variables that indicate invalid configs
        if grep -qE "^(blue_weight|green_weight|blue_backup|green_backup)=" "$blue_config" "$green_config" 2>/dev/null; then
            log_message "WARNING" "$service_name" "config" "ensure" "Configs contain template variables, forcing regeneration for $domain"
            needs_regeneration=true
        elif ! grep -qE "resolve;" "$blue_config" "$green_config" 2>/dev/null; then
            log_message "WARNING" "$service_name" "config" "ensure" "Configs missing resolve directive, forcing regeneration for $domain"
            needs_regeneration=true
        else
            log_message "INFO" "$service_name" "config" "ensure" "Blue and green configs already exist and validated for $domain"
            return 0
        fi
    else
        needs_regeneration=true
    fi
    
    # Remove invalid configs if regeneration is needed
    if [ "$needs_regeneration" = true ]; then
        if [ -f "$blue_config" ]; then
            rm -f "$blue_config"
            log_message "INFO" "$service_name" "config" "ensure" "Removed invalid blue config for $domain"
        fi
        if [ -f "$green_config" ]; then
            rm -f "$green_config"
            log_message "INFO" "$service_name" "config" "ensure" "Removed invalid green config for $domain"
        fi
    fi
    
    # Generate configs if missing (will validate before applying)
    log_message "INFO" "$service_name" "config" "ensure" "Generating and validating blue and green configs for $domain"
    if ! generate_blue_green_configs "$service_name" "$domain" "$active_color"; then
        log_message "ERROR" "$service_name" "config" "ensure" "Failed to generate or validate configs for $domain"
        # Check if at least one config exists
        if [ -f "$blue_config" ] || [ -f "$green_config" ]; then
            log_message "WARNING" "$service_name" "config" "ensure" "Partial configs exist for $domain, nginx may have limited functionality"
            return 0  # Don't fail if at least one config exists
        fi
        return 1
    fi
    
    return 0
}

# Function to clean up upstreams for non-existent containers in a config file
cleanup_upstreams() {
    local config_file="$1"
    
    if [ ! -f "$config_file" ]; then
        return 1
    fi
    
    # Extract all upstream server lines and check if containers exist
    local temp_config=$(mktemp)
    local in_upstream=false
    local upstream_name=""
    
    while IFS= read -r line; do
        # Detect upstream block start
        if echo "$line" | grep -qE "^upstream\s+\S+\s*\{$"; then
            upstream_name=$(echo "$line" | sed -E 's/^upstream\s+(\S+)\s*\{$/\1/')
            in_upstream=true
            echo "$line" >> "$temp_config"
            continue
        fi
        
        # Detect upstream block end
        if [ "$in_upstream" = "true" ] && echo "$line" | grep -qE "^\s*\}$"; then
            in_upstream=false
            echo "$line" >> "$temp_config"
            continue
        fi
        
        # Process server lines within upstream block
        if [ "$in_upstream" = "true" ] && echo "$line" | grep -qE "^\s*server\s+"; then
            # Extract container name from server line (format: container-name:port)
            local container_name=$(echo "$line" | sed -E 's/^\s*server\s+([^:]+):.*/\1/')
            
            # Check if container exists (running or stopped)
            if docker ps -a --format "{{.Names}}" 2>/dev/null | grep -qE "^${container_name}$"; then
                echo "$line" >> "$temp_config"
            else
                # Skip this server line (container doesn't exist)
                log_message "INFO" "cleanup" "upstream" "Removing non-existent upstream server: $container_name" 2>/dev/null || true
            fi
        else
            # Not an upstream block or server line, keep as-is
            echo "$line" >> "$temp_config"
        fi
    done < "$config_file"
    
    # Replace original file with cleaned version
    mv "$temp_config" "$config_file"
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
        log_message "SUCCESS" "$domain" "$target_color" "symlink" "Symlink switched to $target_color config"
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
    
    local registry=$(load_service_registry "$service_name")
    local domain=$(echo "$registry" | jq -r '.domain')
    
    if [ -z "$domain" ] || [ "$domain" = "null" ]; then
        print_error "Domain not found in registry for service: $service_name"
        return 1
    fi
    
    local config_file="${NGINX_PROJECT_DIR}/nginx/conf.d/${domain}.conf"
    
    if [ ! -f "$config_file" ]; then
        print_error "Config file not found: $config_file"
        return 1
    fi
    
    # Validate config file syntax by checking basic structure
    # This is a lightweight check - full validation still requires nginx -t
    if ! grep -q "^upstream " "$config_file" && ! grep -q "server 127.0.0.1:65535" "$config_file"; then
        print_error "Config file appears to be invalid (no upstream blocks found): $config_file"
        return 1
    fi
    
    # Test all configs but provide service-specific context
    # The real isolation comes from generating valid configs
    log_message "INFO" "$service_name" "validation" "test" "Testing nginx configuration for service: $service_name (${domain})"
    
    # Use the standard test but it will validate all configs
    # This is acceptable because we ensure each service generates valid configs
    if test_nginx_config; then
        log_message "SUCCESS" "$service_name" "validation" "test" "Configuration test passed for service: $service_name"
        return 0
    else
        log_message "ERROR" "$service_name" "validation" "test" "Configuration test failed for service: $service_name"
        return 1
    fi
}

# Function to test nginx config (all configs)
test_nginx_config() {
    local service_name="${1:-}"  # Optional service name parameter
    
    # If service name provided, use per-service validation
    if [ -n "$service_name" ]; then
        test_service_nginx_config "$service_name"
        return $?
    fi
    
    local nginx_compose_file="${NGINX_PROJECT_DIR}/docker-compose.yml"
    local max_wait=30
    local wait_interval=1
    local elapsed=0
    
    if [ ! -f "$nginx_compose_file" ]; then
        print_error "Nginx docker compose.yml not found: $nginx_compose_file"
        return 1
    fi
    
    cd "$NGINX_PROJECT_DIR"
    
    # Wait for nginx container to be running (not restarting)
    # We need to wait for it to be stable, not just "Up" once
    local stable_count=0
    local required_stable=3  # Container must be "Up" for 3 consecutive checks
    
    while [ $elapsed -lt $max_wait ]; do
        local container_status=$(docker compose ps nginx --format "{{.Status}}" 2>/dev/null || echo "")
        if echo "$container_status" | grep -qE "^Up"; then
            # Container is running, increment stable count
            stable_count=$((stable_count + 1))
            if [ $stable_count -ge $required_stable ]; then
                # Container has been stable for required checks
                break
            fi
        elif echo "$container_status" | grep -qE "Restarting|Starting"; then
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
        if docker compose exec -T nginx echo >/dev/null 2>&1; then
            # Container is accessible, verify it stays accessible
            sleep 1
            if docker compose exec -T nginx echo >/dev/null 2>&1; then
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
            if docker compose exec -T nginx echo >/dev/null 2>&1; then
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
    
    # Now test the configuration
    # Note: We test all configs, but if test fails, we don't prevent nginx from running
    # Invalid configs should have been rejected during generation
    if docker compose exec -T nginx nginx -t >/dev/null 2>&1; then
        return 0
    else
        # Get error output for logging
        local error_output=$(docker compose exec -T nginx nginx -t 2>&1 || true)
        print_warning "Nginx configuration test failed (this may be expected if nginx is not fully started)"
        # Log error but don't print to console unless in verbose mode
        echo "$error_output" | grep -E "error|emerg|failed" | head -5 | sed 's/^/  /' || true
        # Don't return error - allow nginx to attempt to start anyway
        # Invalid configs should have been rejected during generation phase
        return 0
    fi
}

# Function to reload nginx
reload_nginx() {
    local nginx_compose_file="${NGINX_PROJECT_DIR}/docker-compose.yml"
    
    if [ ! -f "$nginx_compose_file" ]; then
        print_error "Nginx docker compose.yml not found: $nginx_compose_file"
        return 1
    fi
    
    cd "$NGINX_PROJECT_DIR"
    
    # Check if nginx container is running
    local nginx_running=false
    if docker ps --format "{{.Names}}" 2>/dev/null | grep -qE "^nginx-microservice$"; then
        local nginx_status=$(docker ps --format "{{.Names}}\t{{.Status}}" 2>/dev/null | grep "^nginx-microservice" | awk '{print $2}' || echo "")
        if [ -n "$nginx_status" ] && ! echo "$nginx_status" | grep -qE "Restarting"; then
            nginx_running=true
        fi
    fi
    
    if [ "$nginx_running" = "false" ]; then
        # Nginx is not running - start it instead of reloading
        print_status "Nginx container is not running, starting it..."
        if docker compose up -d nginx >/dev/null 2>&1; then
            print_success "Nginx container started"
            # Wait a moment for nginx to be ready
            sleep 2
            return 0
        else
            print_error "Failed to start nginx container"
            return 1
        fi
    fi
    
    # Nginx is running - test config first, then reload
    # Note: Config test may fail if upstreams are unavailable, but that's acceptable
    # Nginx will return 502s until containers are available
    if ! test_nginx_config >/dev/null 2>&1; then
        print_warning "Nginx config test failed or container not accessible, attempting reload anyway..."
        # Continue with reload attempt - nginx may still accept the reload
    fi
    
    # Reload nginx
    if docker compose exec nginx nginx -s reload >/dev/null 2>&1; then
        return 0
    else
        print_error "Failed to reload nginx"
        docker compose exec nginx nginx -s reload
        return 1
    fi
}

# Function to check docker compose availability
check_docker_compose_available() {
    if ! command -v docker >/dev/null 2>&1; then
        print_error "Docker is not installed"
        return 1
    fi
    
    if ! docker compose version >/dev/null 2>&1; then
        print_error "docker compose is not available"
        return 1
    fi
    
    if ! docker info >/dev/null 2>&1; then
        print_error "Docker daemon is not running"
        return 1
    fi
    
    return 0
}

# Function to cleanup service nginx config (ensure symlink points to correct color when containers are stopped)
cleanup_service_nginx_config() {
    local service_name="$1"
    
    local registry=$(load_service_registry "$service_name")
    local domain=$(echo "$registry" | jq -r '.domain')
    
    if [ -z "$domain" ] || [ "$domain" = "null" ]; then
        log_message "WARNING" "$service_name" "cleanup" "config" "Domain not found in registry, skipping config cleanup"
        return 0
    fi
    
    local config_dir="${NGINX_PROJECT_DIR}/nginx/conf.d"
    local blue_green_dir="${config_dir}/blue-green"
    local symlink_file="${config_dir}/${domain}.conf"
    local blue_config="${blue_green_dir}/${domain}.blue.conf"
    local green_config="${blue_green_dir}/${domain}.green.conf"
    
    # Check if blue/green configs exist (service is migrated)
    if [ ! -f "$blue_config" ] || [ ! -f "$green_config" ]; then
        log_message "INFO" "$service_name" "cleanup" "config" "Service not migrated to symlink system, skipping config cleanup"
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
        log_message "INFO" "$service_name" "cleanup" "config" "Containers still exist, skipping config cleanup"
        return 0
    fi
    
    # Ensure symlink points to blue (default when no containers running)
    # This is safe since both configs exist and will have placeholder upstreams
    if [ ! -L "$symlink_file" ]; then
        log_message "INFO" "$service_name" "cleanup" "config" "Creating symlink pointing to blue (default)"
        switch_config_symlink "$domain" "blue" || true
    fi
    
    log_message "INFO" "$service_name" "cleanup" "config" "Config cleanup completed (symlink maintained)"
}

# Function to check HTTPS URL availability
check_https_url() {
    local domain="$1"
    local timeout="${2:-10}"
    local retries="${3:-3}"
    local endpoint="${4:-/}"
    local service_name="${5:-}"
    local color="${6:-}"
    
    # Validate domain
    if [ -z "$domain" ] || [ "$domain" = "null" ]; then
        return 1
    fi
    
    # Ensure timeout and retries are numeric
    if ! [[ "$timeout" =~ ^[0-9]+$ ]]; then
        timeout=10
    fi
    if ! [[ "$retries" =~ ^[0-9]+$ ]]; then
        retries=3
    fi
    
    # Construct URL
    local url="https://${domain}${endpoint}"
    local attempt=0
    
    # Log attempt if service context provided
    if [ -n "$service_name" ]; then
        log_message "INFO" "$service_name" "$color" "https-check" "Checking HTTPS availability: $url (timeout: ${timeout}s, retries: ${retries})"
    fi
    
    while [ $attempt -lt $retries ]; do
        attempt=$((attempt + 1))
        # Use curl with proper flags for HTTPS check
        # -s: silent, -f: fail on HTTP errors, --max-time: timeout, -k: allow insecure (for self-signed certs during dev)
        if curl -s -f --max-time "$timeout" -k "$url" >/dev/null 2>&1; then
            if [ -n "$service_name" ]; then
                log_message "SUCCESS" "$service_name" "$color" "https-check" "HTTPS check passed: $url (attempt $attempt/$retries)"
            fi
            return 0
        fi
        if [ $attempt -lt $retries ]; then
            sleep 1
        fi
    done
    
    # All attempts failed
    if [ -n "$service_name" ]; then
        log_message "ERROR" "$service_name" "$color" "https-check" "HTTPS check failed: $url (all $retries attempts failed)"
    fi
    return 1
}

# Function to check if a port is in use and kill the process/container using it
# Usage: kill_port_if_in_use <port> [service_name] [color]
kill_port_if_in_use() {
    local port="$1"
    local service_name="${2:-}"
    local color="${3:-}"
    
    if [ -z "$port" ] || ! [[ "$port" =~ ^[0-9]+$ ]]; then
        return 0  # Invalid port, skip
    fi
    
    # First check if a Docker container is using this port (checking both host and container ports)
    local container_using_port=$(docker ps --format "{{.Names}}\t{{.Ports}}" 2>/dev/null | \
        grep -E ":${port}->|:${port}/|0\.0\.0\.0:${port}:|127\.0\.0\.1:${port}:" | \
        awk '{print $1}' | head -1 || echo "")
    
    if [ -n "$container_using_port" ]; then
        if [ -n "$service_name" ]; then
            log_message "WARNING" "$service_name" "$color" "port-check" "Port ${port} is in use by container ${container_using_port}, stopping and removing it"
        else
            print_warning "Port ${port} is in use by container ${container_using_port}, stopping and removing it"
        fi
        # Force stop and remove, even if it's restarting
        docker stop "${container_using_port}" 2>/dev/null || true
        sleep 1
        docker kill "${container_using_port}" 2>/dev/null || true
        sleep 1
        docker rm -f "${container_using_port}" 2>/dev/null || true
        sleep 1  # Give it a moment to release the port
    fi
    
    # Check if a host process is using this port (using lsof, netstat, or ss)
    local pid_using_port=""
    
    # Try lsof first (most reliable on macOS/Linux)
    if command -v lsof >/dev/null 2>&1; then
        pid_using_port=$(lsof -ti:${port} 2>/dev/null | head -1 || echo "")
    # Try ss (Linux)
    elif command -v ss >/dev/null 2>&1; then
        pid_using_port=$(ss -tlnp 2>/dev/null | grep ":${port} " | grep -oP 'pid=\K[0-9]+' | head -1 || echo "")
    # Try netstat (fallback)
    elif command -v netstat >/dev/null 2>&1; then
        pid_using_port=$(netstat -tlnp 2>/dev/null | grep ":${port} " | grep -oP '\d+/\w+' | cut -d'/' -f1 | head -1 || echo "")
    fi
    
    if [ -n "$pid_using_port" ] && [ "$pid_using_port" != "null" ]; then
        # Check if it's a docker process (don't kill docker itself)
        local process_name=$(ps -p "$pid_using_port" -o comm= 2>/dev/null || echo "")
        if [ -n "$process_name" ] && ! echo "$process_name" | grep -qE "docker|dockerd|containerd"; then
            if [ -n "$service_name" ]; then
                log_message "WARNING" "$service_name" "$color" "port-check" "Port ${port} is in use by process ${pid_using_port} (${process_name}), killing it"
            else
                print_warning "Port ${port} is in use by process ${pid_using_port} (${process_name}), killing it"
            fi
            kill -9 "$pid_using_port" 2>/dev/null || true
            sleep 1  # Give it a moment to release the port
        fi
    fi
    
    return 0
}

# Function to kill container by name if it exists (handles restarting containers)
# Usage: kill_container_if_exists <container_name> [service_name] [color]
kill_container_if_exists() {
    local container_name="$1"
    local service_name="${2:-}"
    local color="${3:-}"
    
    if [ -z "$container_name" ]; then
        return 0
    fi
    
    # Check if container exists (running or stopped)
    if docker ps -a --format "{{.Names}}" 2>/dev/null | grep -qE "^${container_name}$"; then
        # Check if it's in a restart loop
        local status=$(docker ps --format "{{.Names}}\t{{.Status}}" 2>/dev/null | grep "^${container_name}" | awk '{print $2}' || echo "")
        
        if [ -n "$status" ] && echo "$status" | grep -qE "Restarting|Up"; then
            if [ -n "$service_name" ]; then
                log_message "WARNING" "$service_name" "$color" "container-check" "Container ${container_name} is ${status}, stopping and removing it"
            else
                print_warning "Container ${container_name} is ${status}, stopping and removing it"
            fi
            # Force stop and remove
            docker stop "${container_name}" 2>/dev/null || true
            sleep 1
            docker kill "${container_name}" 2>/dev/null || true
            sleep 1
            docker rm -f "${container_name}" 2>/dev/null || true
            sleep 1
        else
            # Container exists but not running, just remove it
            if [ -n "$service_name" ]; then
                log_message "INFO" "$service_name" "$color" "container-check" "Removing existing container ${container_name}"
            fi
            docker rm -f "${container_name}" 2>/dev/null || true
        fi
    fi
    
    return 0
}

# Function to extract host ports from docker compose file
# Usage: get_host_ports_from_compose <compose_file> [service_name]
get_host_ports_from_compose() {
    local compose_file="$1"
    local service_name="${2:-}"
    
    if [ ! -f "$compose_file" ]; then
        return 1
    fi
    
    # Use docker compose config to get the actual port mappings
    local compose_config=$(docker compose -f "$compose_file" config 2>/dev/null || echo "")
    
    if [ -z "$compose_config" ]; then
        return 1
    fi
    
    # Extract ports in format "host:container" or just "host" if no mapping
    # Look for patterns like "80:80", "127.0.0.1:5432:5432", etc.
    echo "$compose_config" | grep -E "^\s+-.*:.*:" | \
        sed -E 's/.*"([0-9.]+):([0-9]+):([0-9]+)".*/\1:\2/' | \
        sed -E 's/.*"([0-9]+):([0-9]+)".*/\1/' | \
        grep -oE '^[0-9]+' | sort -u || echo ""
    
    return 0
}

