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
        # First, uncomment any commented lines
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
        
        log_message "INFO" "$service_name" "$active_color" "switch" "Updated upstream for service: $service_key (${container_base})"
        
    done <<< "$service_keys"
    
    log_message "SUCCESS" "$service_name" "$active_color" "switch" "All nginx upstreams updated successfully"
}

# Function to test nginx config
test_nginx_config() {
    local nginx_compose_file="${NGINX_PROJECT_DIR}/docker-compose.yml"
    
    if [ ! -f "$nginx_compose_file" ]; then
        print_error "Nginx docker-compose.yml not found: $nginx_compose_file"
        return 1
    fi
    
    cd "$NGINX_PROJECT_DIR"
    if docker compose exec nginx nginx -t >/dev/null 2>&1; then
        return 0
    else
        print_error "Nginx configuration test failed"
        docker compose exec nginx nginx -t
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

