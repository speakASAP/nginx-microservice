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

# Function to update nginx upstream
update_nginx_upstream() {
    local config_file="$1"
    local service_name="$2"
    local active_color="$3"
    local inactive_color
    
    if [ "$active_color" = "blue" ]; then
        inactive_color="green"
    else
        inactive_color="blue"
    fi
    
    local registry=$(load_service_registry "$service_name")
    
    # Backup original config
    cp "$config_file" "${config_file}.backup.$(date +%Y%m%d_%H%M%S)"
    
    # Detect sed in-place edit flag (different for BSD/macOS vs GNU/Linux)
    if sed --version >/dev/null 2>&1; then
        # GNU sed (Linux)
        SED_IN_PLACE="sed -i"
    else
        # BSD sed (macOS)
        SED_IN_PLACE="sed -i ''"
    fi
    
    # Determine weights and backup status
    local blue_weight green_weight
    if [ "$active_color" = "blue" ]; then
        blue_weight=100
        green_weight=""  # No weight means backup server (nginx default)
    else
        blue_weight=""  # No weight means backup server (nginx default)
        green_weight=100
    fi
    
    # Get all services from registry and update each upstream
    local service_keys=$(echo "$registry" | jq -r '.services | keys[]')
    
    while IFS= read -r service_key; do
        local container_base=$(echo "$registry" | jq -r ".services[\"$service_key\"].container_name_base")
        local service_port=$(echo "$registry" | jq -r ".services[\"$service_key\"].port")
        
        # Determine nginx upstream name (use container_base as upstream name)
        # For statex, upstreams are named like: statex-frontend, statex-user-portal, etc.
        local upstream_name="$container_base"
        
        # Check if containers exist
        local blue_exists=false
        local green_exists=false
        
        if docker ps --format "{{.Names}}" | grep -q "^${container_base}-blue$"; then
            blue_exists=true
        fi
        if docker ps --format "{{.Names}}" | grep -q "^${container_base}-green$"; then
            green_exists=true
        fi
        
        # Fallback: Check if container exists without color suffix (single-container deployment)
        local single_container_exists=false
        if [ "$blue_exists" = "false" ] && [ "$green_exists" = "false" ]; then
            if docker ps --format "{{.Names}}" | grep -q "^${container_base}$"; then
                single_container_exists=true
            fi
        fi
        
        # Determine backup status for this service
        local blue_backup green_backup
        if [ "$active_color" = "blue" ]; then
            blue_backup=""
            green_backup=" backup"
        else
            blue_backup=" backup"
            green_backup=""
        fi
        
        # Update upstream block for this service
        # First, remove placeholder line if it exists (simple pattern match)
        $SED_IN_PLACE -e "/server 127\.0\.0\.1:65535 down.*Placeholder/d" "$config_file"
        
        # Handle single-container deployment (no color suffix)
        if [ "$single_container_exists" = "true" ]; then
            # Remove any color-suffixed server lines
            $SED_IN_PLACE -e "/server ${container_base}-\(blue\|green\):/d" "$config_file"
            # Add single container server line
            if [ -n "$blue_weight" ]; then
                # Blue is active
                if ! grep -q "server ${container_base}:${service_port}" "$config_file"; then
                    $SED_IN_PLACE -e "/^upstream ${upstream_name} {/a\\
    server ${container_base}:${service_port} weight=${blue_weight} max_fails=3 fail_timeout=30s;
" "$config_file"
                else
                    $SED_IN_PLACE -e "s|server ${container_base}:${service_port}[^;]*|server ${container_base}:${service_port} weight=${blue_weight} max_fails=3 fail_timeout=30s|g" "$config_file"
                fi
            else
                # Green is active
                if ! grep -q "server ${container_base}:${service_port}" "$config_file"; then
                    $SED_IN_PLACE -e "/^upstream ${upstream_name} {/a\\
    server ${container_base}:${service_port} weight=${green_weight} max_fails=3 fail_timeout=30s;
" "$config_file"
                else
                    $SED_IN_PLACE -e "s|server ${container_base}:${service_port}[^;]*|server ${container_base}:${service_port} weight=${green_weight} max_fails=3 fail_timeout=30s|g" "$config_file"
                fi
            fi
        else
            # Standard blue/green deployment
            # Uncomment any commented lines
        $SED_IN_PLACE -e "s|^[[:space:]]*# server ${container_base}-blue|    server ${container_base}-blue|g" "$config_file"
        $SED_IN_PLACE -e "s|^[[:space:]]*# server ${container_base}-green|    server ${container_base}-green|g" "$config_file"
        
        # Update blue server
        if [ "$blue_exists" = "true" ]; then
            if [ -n "$blue_weight" ]; then
                # Blue has weight (active), update it
                $SED_IN_PLACE \
                    -e "s|server ${container_base}-blue:${service_port}[^;]*|server ${container_base}-blue:${service_port} weight=${blue_weight}${blue_backup} max_fails=3 fail_timeout=30s|g" \
                    "$config_file"
            else
                # Blue is backup, remove weight
                $SED_IN_PLACE \
                    -e "s|server ${container_base}-blue:${service_port}[^;]*|server ${container_base}-blue:${service_port}${blue_backup} max_fails=3 fail_timeout=30s|g" \
                    "$config_file"
            fi
        else
            # Comment out blue if container doesn't exist
            $SED_IN_PLACE -e "s|^[[:space:]]*server ${container_base}-blue|    # server ${container_base}-blue|g" "$config_file"
        fi
        
        # Update green server
        if [ "$green_exists" = "true" ]; then
            if [ -n "$green_weight" ]; then
                # Green has weight (active), update it
                $SED_IN_PLACE \
                    -e "s|server ${container_base}-green:${service_port}[^;]*|server ${container_base}-green:${service_port} weight=${green_weight}${green_backup} max_fails=3 fail_timeout=30s|g" \
                    "$config_file"
            else
                # Green is backup, remove weight
                $SED_IN_PLACE \
                    -e "s|server ${container_base}-green:${service_port}[^;]*|server ${container_base}-green:${service_port}${green_backup} max_fails=3 fail_timeout=30s|g" \
                    "$config_file"
            fi
        else
            # Comment out green if container doesn't exist
            $SED_IN_PLACE -e "s|^[[:space:]]*server ${container_base}-green|    # server ${container_base}-green|g" "$config_file"
            fi
        fi
        
        log_message "INFO" "$service_name" "$active_color" "switch" "Updated upstream for service: $service_key (${container_base})"
        
    done <<< "$service_keys"
    
    log_message "SUCCESS" "$service_name" "$active_color" "switch" "All nginx upstreams updated successfully"
}

# Function to test nginx config
test_nginx_config() {
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
    while [ $elapsed -lt $max_wait ]; do
        local container_status=$(docker compose ps nginx --format "{{.Status}}" 2>/dev/null || echo "")
        if echo "$container_status" | grep -qE "Up.*\(healthy\)|Up.*\(unhealthy\)"; then
            # Container is running (healthy or unhealthy, but running)
            break
        elif echo "$container_status" | grep -qE "Restarting|Starting"; then
            # Container is restarting or starting, wait
            sleep $wait_interval
            elapsed=$((elapsed + wait_interval))
        else
            # Container might not exist or be stopped
            sleep $wait_interval
            elapsed=$((elapsed + wait_interval))
        fi
    done
    
    # Additional check: ensure container is actually accessible
    local retries=0
    local max_retries=5
    while [ $retries -lt $max_retries ]; do
        if docker compose exec -T nginx echo >/dev/null 2>&1; then
            break
        fi
        sleep 1
        retries=$((retries + 1))
    done
    
    if [ $retries -eq $max_retries ]; then
        print_error "Nginx container is not accessible after waiting"
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

