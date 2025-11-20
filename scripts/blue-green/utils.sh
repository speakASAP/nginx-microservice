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

# Function to generate nginx config from template based on state and container existence
generate_nginx_config() {
    local service_name="$1"
    local active_color="$2"
    local config_file="$3"
    
    local registry=$(load_service_registry "$service_name")
    
    # Read existing config to preserve non-upstream content
    if [ ! -f "$config_file" ]; then
        print_error "Config file not found: $config_file"
        return 1
    fi
    
    local existing_config=$(cat "$config_file")
    
    # Find where upstream blocks end and server blocks begin
    local server_block_line=$(echo "$existing_config" | grep -n "^# HTTP Server" | head -1 | cut -d: -f1)
    
    if [ -z "$server_block_line" ]; then
        print_error "Cannot find server block in config file: $config_file"
        return 1
    fi
    
    # Extract server blocks (everything from "# HTTP Server" onwards)
    local server_blocks=$(echo "$existing_config" | sed -n "${server_block_line},\$p")
    
    # Generate upstream blocks for each service
    local service_keys=$(echo "$registry" | jq -r '.services | keys[]')
    local upstream_blocks="# Upstream blocks for blue/green deployment
"
    
    while IFS= read -r service_key; do
        local container_base=$(echo "$registry" | jq -r ".services[\"$service_key\"].container_name_base")
        local service_port=$(echo "$registry" | jq -r ".services[\"$service_key\"].port")
        
        if [ -z "$container_base" ] || [ "$container_base" = "null" ] || [ -z "$service_port" ] || [ "$service_port" = "null" ]; then
            continue
        fi
        
        # Check if containers exist
        local blue_exists=false
        local green_exists=false
        
        if docker ps --format "{{.Names}}" | grep -q "^${container_base}-blue$"; then
            blue_exists=true
        fi
        if docker ps --format "{{.Names}}" | grep -q "^${container_base}-green$"; then
            green_exists=true
        fi
        
        # Determine weights and backup status
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
        
        # Build upstream block
        upstream_blocks="${upstream_blocks}upstream ${container_base} {
"
        
        # Add blue server if exists
        if [ "$blue_exists" = "true" ]; then
            if [ -n "$blue_weight" ]; then
                upstream_blocks="${upstream_blocks}    server ${container_base}-blue:${service_port} weight=${blue_weight}${blue_backup} max_fails=3 fail_timeout=30s;
"
            else
                upstream_blocks="${upstream_blocks}    server ${container_base}-blue:${service_port}${blue_backup} max_fails=3 fail_timeout=30s;
"
            fi
        fi
        
        # Add green server if exists
        if [ "$green_exists" = "true" ]; then
            if [ -n "$green_weight" ]; then
                upstream_blocks="${upstream_blocks}    server ${container_base}-green:${service_port} weight=${green_weight}${green_backup} max_fails=3 fail_timeout=30s;
"
            else
                upstream_blocks="${upstream_blocks}    server ${container_base}-green:${service_port}${green_backup} max_fails=3 fail_timeout=30s;
"
            fi
        fi
        
        # Add placeholder if no containers exist
        if [ "$blue_exists" = "false" ] && [ "$green_exists" = "false" ]; then
            upstream_blocks="${upstream_blocks}    server 127.0.0.1:65535 down max_fails=3 fail_timeout=10s; # Placeholder - will be replaced when containers exist
"
        fi
        
        upstream_blocks="${upstream_blocks}}
"
    done <<< "$service_keys"
    
    # Combine upstream blocks with server blocks
    local config_content="${upstream_blocks}${server_blocks}"
    
    # Output the generated config
    echo "$config_content"
}

# Function to update nginx upstream
update_nginx_upstream() {
    local config_file="$1"
    local service_name="$2"
    local active_color="$3"
    
    # Backup original config
    cp "$config_file" "${config_file}.backup.$(date +%Y%m%d_%H%M%S)"
    
    # Generate new config
    local new_config
    if ! new_config=$(generate_nginx_config "$service_name" "$active_color" "$config_file"); then
        log_message "ERROR" "$service_name" "$active_color" "switch" "Failed to generate nginx configuration"
        return 1
    fi
    
    # Write generated config to temporary file first
    local temp_config="${config_file}.tmp.$$"
    echo "$new_config" > "$temp_config"
    
    # Write to actual config file
    mv "$temp_config" "$config_file"
    
    log_message "SUCCESS" "$service_name" "$active_color" "switch" "All nginx upstreams updated successfully"
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

# Function to cleanup service nginx config (set to placeholders when containers are stopped)
cleanup_service_nginx_config() {
    local service_name="$1"
    
    local registry=$(load_service_registry "$service_name")
    local domain=$(echo "$registry" | jq -r '.domain')
    
    if [ -z "$domain" ] || [ "$domain" = "null" ]; then
        log_message "WARNING" "$service_name" "cleanup" "config" "Domain not found in registry, skipping config cleanup"
        return 0
    fi
    
    local config_file="${NGINX_PROJECT_DIR}/nginx/conf.d/${domain}.conf"
    
    if [ ! -f "$config_file" ]; then
        log_message "WARNING" "$service_name" "cleanup" "config" "Config file not found: $config_file, skipping cleanup"
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
    
    # Generate config with placeholders (no active color since no containers)
    # Use "blue" as default, but all upstreams will be placeholders
    local cleaned_config
    if ! cleaned_config=$(generate_nginx_config "$service_name" "blue" "$config_file"); then
        log_message "WARNING" "$service_name" "cleanup" "config" "Failed to generate cleanup config, skipping"
        return 0
    fi
    
    # Backup original config
    cp "$config_file" "${config_file}.backup.cleanup.$(date +%Y%m%d_%H%M%S)"
    
    # Write cleaned config
    echo "$cleaned_config" > "$config_file"
    
    log_message "INFO" "$service_name" "cleanup" "config" "Config cleaned up (set to placeholders)"
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

