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
    local state_file="${STATE_DIR}/${service_name}.json"
    
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
    local state_file="${STATE_DIR}/${service_name}.json"
    
    mkdir -p "$STATE_DIR"
    
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
    local registry=$(load_service_registry "$service_name")
    local service_keys=$(echo "$registry" | jq -r '.services | keys[]')
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
        
        # Always generate both blue and green servers in upstream blocks
        # This ensures nginx config is valid even if containers don't exist yet
        # Containers will be started later, and nginx will connect when they're ready
        local blue_container="${container_base}-blue"
        local green_container="${container_base}-green"
        
        # Build upstream block (always create, even if containers don't exist yet)
        upstream_blocks="${upstream_blocks}upstream ${container_base} {
"
        
        # Always add blue server (active or backup based on active_color)
        if [ -n "$blue_weight" ]; then
            upstream_blocks="${upstream_blocks}    server ${blue_container}:${service_port} weight=${blue_weight}${blue_backup} max_fails=3 fail_timeout=30s;
"
        else
            upstream_blocks="${upstream_blocks}    server ${blue_container}:${service_port}${blue_backup} max_fails=3 fail_timeout=30s;
"
        fi
        
        # Always add green server (active or backup based on active_color)
        if [ -n "$green_weight" ]; then
            upstream_blocks="${upstream_blocks}    server ${green_container}:${service_port} weight=${green_weight}${green_backup} max_fails=3 fail_timeout=30s;
"
        else
            upstream_blocks="${upstream_blocks}    server ${green_container}:${service_port}${green_backup} max_fails=3 fail_timeout=30s;
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
    local registry=$(load_service_registry "$service_name")
    local service_keys=$(echo "$registry" | jq -r '.services | keys[]')
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
    
    # Generate frontend location (root path)
    if [ "$has_frontend" = "true" ] && [ -n "$frontend_container" ] && [ "$frontend_container" != "null" ]; then
        proxy_locations="${proxy_locations}    # Frontend routes - using upstream
    location / {
        proxy_pass http://${frontend_container};
        include /etc/nginx/includes/common-proxy-settings.conf;
    }
    
"
    elif [ "$has_backend" = "true" ] && [ -n "$backend_container" ] && [ "$backend_container" != "null" ] && [ "$has_frontend" != "true" ]; then
        # If no frontend but backend exists, route root path to backend
        proxy_locations="${proxy_locations}    # Backend-only service - root path routes to backend
    location / {
        proxy_pass http://${backend_container};
        include /etc/nginx/includes/common-proxy-settings.conf;
    }
    
"
    fi
    
    # Generate backend/API location
    if [ "$has_backend" = "true" ] && [ -n "$backend_container" ] && [ "$backend_container" != "null" ]; then
        proxy_locations="${proxy_locations}    # API routes with stricter rate limiting - using upstream
    location /api/ {
        limit_req zone=api burst=20 nodelay;
        
        proxy_pass http://${backend_container}/api/;
        include /etc/nginx/includes/common-proxy-settings.conf;
    }
    
    # WebSocket support - using upstream
    location /ws {
        proxy_pass http://${backend_container}/ws;
        include /etc/nginx/includes/common-proxy-settings.conf;
    }
    
    # Health check endpoint - using upstream
    location /health {
        proxy_pass http://${backend_container}/health;
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
            proxy_locations="${proxy_locations}    # API Gateway routes - using upstream
    location /api/ {
        limit_req zone=api burst=20 nodelay;
        
        proxy_pass http://${api_gateway_container}/api/;
        include /etc/nginx/includes/common-proxy-settings.conf;
    }
    
"
        fi
    fi
    
    echo "$proxy_locations"
}

# Function to generate blue and green nginx configs from template
generate_blue_green_configs() {
    local service_name="$1"
    local domain="$2"
    local active_color="${3:-blue}"
    
    local registry=$(load_service_registry "$service_name")
    local template_file="${NGINX_PROJECT_DIR}/nginx/templates/domain-blue-green.conf.template"
    local config_dir="${NGINX_PROJECT_DIR}/nginx/conf.d"
    local blue_green_dir="${config_dir}/blue-green"
    # Ensure blue-green subdirectory exists
    mkdir -p "$blue_green_dir"
    local blue_config="${blue_green_dir}/${domain}.blue.conf"
    local green_config="${blue_green_dir}/${domain}.green.conf"
    
    if [ ! -f "$template_file" ]; then
        print_error "Template file not found: $template_file"
        return 1
    fi
    
    # Generate upstream blocks for blue config
    local blue_upstreams=$(generate_upstream_blocks "$service_name" "blue")
    
    # Generate upstream blocks for green config
    local green_upstreams=$(generate_upstream_blocks "$service_name" "green")
    
    # Generate proxy locations (same for both configs)
    local proxy_locations=$(generate_proxy_locations "$service_name")
    
    # Generate configs using Python for reliable multi-line replacement
    # Use temporary files to pass multi-line content to Python
    local temp_upstreams=$(mktemp)
    local temp_locations=$(mktemp)
    local temp_python=$(mktemp)
    
    echo "$blue_upstreams" > "$temp_upstreams"
    echo "$proxy_locations" > "$temp_locations"
    
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
    
    # Generate blue config
    if command -v python3 >/dev/null 2>&1; then
        python3 "$temp_python" "$template_file" "$blue_config" "$domain" "$temp_upstreams" "$temp_locations" || {
            print_error "Python3 failed, falling back to sed"
            # Fallback to sed (simple replacement, may have multi-line issues)
            sed -e "s|{{DOMAIN_NAME}}|$domain|g" \
                -e "s|{{UPSTREAM_BLOCKS}}|$blue_upstreams|g" \
                -e "s|{{PROXY_LOCATIONS}}|$proxy_locations|g" \
                "$template_file" > "$blue_config"
        }
    else
        print_warning "Python3 not found, using sed (may have issues with multi-line content)"
        sed -e "s|{{DOMAIN_NAME}}|$domain|g" \
            -e "s|{{UPSTREAM_BLOCKS}}|$blue_upstreams|g" \
            -e "s|{{PROXY_LOCATIONS}}|$proxy_locations|g" \
            "$template_file" > "$blue_config"
    fi
    
    # Update upstreams for green config
    echo "$green_upstreams" > "$temp_upstreams"
    
    # Generate green config
    if command -v python3 >/dev/null 2>&1; then
        python3 "$temp_python" "$template_file" "$green_config" "$domain" "$temp_upstreams" "$temp_locations" || {
            print_error "Python3 failed, falling back to sed"
            # Fallback to sed
            sed -e "s|{{DOMAIN_NAME}}|$domain|g" \
                -e "s|{{UPSTREAM_BLOCKS}}|$green_upstreams|g" \
                -e "s|{{PROXY_LOCATIONS}}|$proxy_locations|g" \
                "$template_file" > "$green_config"
        }
    else
        print_warning "Python3 not found, using sed (may have issues with multi-line content)"
        sed -e "s|{{DOMAIN_NAME}}|$domain|g" \
            -e "s|{{UPSTREAM_BLOCKS}}|$green_upstreams|g" \
            -e "s|{{PROXY_LOCATIONS}}|$proxy_locations|g" \
            "$template_file" > "$green_config"
    fi
    
    # Cleanup
    rm -f "$temp_upstreams" "$temp_locations" "$temp_python"
    
    log_message "SUCCESS" "$service_name" "config" "generate" "Generated blue and green configs for $domain"
    return 0
}

# Function to ensure blue and green configs exist
ensure_blue_green_configs() {
    local service_name="$1"
    local domain="$2"
    local active_color="${3:-blue}"
    
    local config_dir="${NGINX_PROJECT_DIR}/nginx/conf.d"
    local blue_green_dir="${config_dir}/blue-green"
    mkdir -p "$blue_green_dir"
    local blue_config="${blue_green_dir}/${domain}.blue.conf"
    local green_config="${blue_green_dir}/${domain}.green.conf"
    
    # Check if both configs exist
    if [ -f "$blue_config" ] && [ -f "$green_config" ]; then
        log_message "INFO" "$service_name" "config" "ensure" "Blue and green configs already exist for $domain"
        return 0
    fi
    
    # Generate configs if missing
    log_message "INFO" "$service_name" "config" "ensure" "Generating blue and green configs for $domain"
    if ! generate_blue_green_configs "$service_name" "$domain" "$active_color"; then
        log_message "ERROR" "$service_name" "config" "ensure" "Failed to generate configs for $domain"
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
        print_error "Nginx docker-compose.yml not found: $nginx_compose_file"
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
        print_error "Nginx container is not accessible after waiting (container may be in restart loop)"
        print_error "Check nginx logs: docker logs nginx-microservice"
        return 1
    fi
    
    # Now test the configuration
    if docker compose exec -T nginx nginx -t >/dev/null 2>&1; then
        return 0
    else
        print_error "Nginx configuration test failed"
        docker compose exec -T nginx nginx -t
        return 1
    fi
}

# Function to reload nginx
reload_nginx() {
    local nginx_compose_file="${NGINX_PROJECT_DIR}/docker-compose.yml"
    
    if [ ! -f "$nginx_compose_file" ]; then
        print_error "Nginx docker-compose.yml not found: $nginx_compose_file"
        return 1
    fi
    
    cd "$NGINX_PROJECT_DIR"
    
    # Test config first
    if ! test_nginx_config; then
        return 1
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

