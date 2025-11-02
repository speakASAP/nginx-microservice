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
    local frontend_base=$(echo "$registry" | jq -r '.services.frontend.container_name_base')
    local backend_base=$(echo "$registry" | jq -r '.services.backend.container_name_base')
    local frontend_port=$(echo "$registry" | jq -r '.services.frontend.port')
    local backend_port=$(echo "$registry" | jq -r '.services.backend.port')
    
    # Backup original config
    cp "$config_file" "${config_file}.backup.$(date +%Y%m%d_%H%M%S)"
    
    # Check if containers exist (for inactive color - we need at least backup upstream)
    local blue_frontend_exists=false
    local blue_backend_exists=false
    local green_frontend_exists=false
    local green_backend_exists=false
    
    if docker ps --format "{{.Names}}" | grep -q "^${frontend_base}-blue$"; then
        blue_frontend_exists=true
    fi
    if docker ps --format "{{.Names}}" | grep -q "^${backend_base}-blue$"; then
        blue_backend_exists=true
    fi
    if docker ps --format "{{.Names}}" | grep -q "^${frontend_base}-green$"; then
        green_frontend_exists=true
    fi
    if docker ps --format "{{.Names}}" | grep -q "^${backend_base}-green$"; then
        green_backend_exists=true
    fi
    
    # Determine weights and backup status
    local blue_weight frontend_blue_backup backend_blue_backup
    local green_weight frontend_green_backup backend_green_backup
    local frontend_blue_enabled=true
    local frontend_green_enabled=true
    local backend_blue_enabled=true
    local backend_green_enabled=true
    
    if [ "$active_color" = "blue" ]; then
        blue_weight=100
        green_weight=""  # No weight means backup server (nginx default)
        frontend_blue_backup=""
        backend_blue_backup=""
        frontend_green_backup=" backup"
        backend_green_backup=" backup"
        
        # Disable inactive if containers don't exist
        if [ "$green_frontend_exists" = "false" ]; then
            frontend_green_enabled=false
        fi
        if [ "$green_backend_exists" = "false" ]; then
            backend_green_enabled=false
        fi
    else
        blue_weight=""  # No weight means backup server (nginx default)
        green_weight=100
        frontend_blue_backup=" backup"
        backend_blue_backup=" backup"
        frontend_green_backup=""
        backend_green_backup=""
        
        # Disable inactive if containers don't exist
        if [ "$blue_frontend_exists" = "false" ]; then
            frontend_blue_enabled=false
        fi
        if [ "$blue_backend_exists" = "false" ]; then
            backend_blue_enabled=false
        fi
    fi
    
    # Detect sed in-place edit flag (different for BSD/macOS vs GNU/Linux)
    if sed --version >/dev/null 2>&1; then
        # GNU sed (Linux)
        SED_IN_PLACE="sed -i"
    else
        # BSD sed (macOS)
        SED_IN_PLACE="sed -i ''"
    fi
    
    # Update frontend upstream blocks
    # First, uncomment any commented lines
    $SED_IN_PLACE -e "s|^[[:space:]]*# server ${frontend_base}-blue|    server ${frontend_base}-blue|g" "$config_file"
    $SED_IN_PLACE -e "s|^[[:space:]]*# server ${frontend_base}-green|    server ${frontend_base}-green|g" "$config_file"
    
    # Pattern: server crypto-ai-frontend-blue:3100 [weight=100] [backup] max_fails=3 fail_timeout=30s;
    if [ "$frontend_blue_enabled" = "true" ]; then
        if [ -n "$blue_weight" ]; then
            # Blue has weight, update it
            $SED_IN_PLACE \
                -e "s|server ${frontend_base}-blue:${frontend_port}[^;]*|server ${frontend_base}-blue:${frontend_port} weight=${blue_weight}${frontend_blue_backup} max_fails=3 fail_timeout=30s|g" \
                "$config_file"
        else
            # Blue is backup, remove weight
            $SED_IN_PLACE \
                -e "s|server ${frontend_base}-blue:${frontend_port}[^;]*|server ${frontend_base}-blue:${frontend_port}${frontend_blue_backup} max_fails=3 fail_timeout=30s|g" \
                "$config_file"
        fi
    else
        # Comment out blue if container doesn't exist
        $SED_IN_PLACE -e "s|^[[:space:]]*server ${frontend_base}-blue|    # server ${frontend_base}-blue|g" "$config_file"
    fi
    
    if [ "$frontend_green_enabled" = "true" ]; then
        if [ -n "$green_weight" ]; then
            # Green has weight, update it
            $SED_IN_PLACE \
                -e "s|server ${frontend_base}-green:${frontend_port}[^;]*|server ${frontend_base}-green:${frontend_port} weight=${green_weight}${frontend_green_backup} max_fails=3 fail_timeout=30s|g" \
                "$config_file"
        else
            # Green is backup, remove weight
            $SED_IN_PLACE \
                -e "s|server ${frontend_base}-green:${frontend_port}[^;]*|server ${frontend_base}-green:${frontend_port}${frontend_green_backup} max_fails=3 fail_timeout=30s|g" \
                "$config_file"
        fi
    else
        # Comment out green if container doesn't exist
        $SED_IN_PLACE -e "s|^[[:space:]]*server ${frontend_base}-green|    # server ${frontend_base}-green|g" "$config_file"
    fi
    
    # Update backend upstream blocks
    # First, uncomment any commented lines
    $SED_IN_PLACE -e "s|^[[:space:]]*# server ${backend_base}-blue|    server ${backend_base}-blue|g" "$config_file"
    $SED_IN_PLACE -e "s|^[[:space:]]*# server ${backend_base}-green|    server ${backend_base}-green|g" "$config_file"
    
    if [ "$backend_blue_enabled" = "true" ]; then
        if [ -n "$blue_weight" ]; then
            $SED_IN_PLACE \
                -e "s|server ${backend_base}-blue:${backend_port}[^;]*|server ${backend_base}-blue:${backend_port} weight=${blue_weight}${backend_blue_backup} max_fails=3 fail_timeout=30s|g" \
                "$config_file"
        else
            $SED_IN_PLACE \
                -e "s|server ${backend_base}-blue:${backend_port}[^;]*|server ${backend_base}-blue:${backend_port}${backend_blue_backup} max_fails=3 fail_timeout=30s|g" \
                "$config_file"
        fi
    else
        # Comment out blue if container doesn't exist
        $SED_IN_PLACE -e "s|^[[:space:]]*server ${backend_base}-blue|    # server ${backend_base}-blue|g" "$config_file"
    fi
    
    if [ "$backend_green_enabled" = "true" ]; then
        if [ -n "$green_weight" ]; then
            $SED_IN_PLACE \
                -e "s|server ${backend_base}-green:${backend_port}[^;]*|server ${backend_base}-green:${backend_port} weight=${green_weight}${backend_green_backup} max_fails=3 fail_timeout=30s|g" \
                "$config_file"
        else
            $SED_IN_PLACE \
                -e "s|server ${backend_base}-green:${backend_port}[^;]*|server ${backend_base}-green:${backend_port}${backend_green_backup} max_fails=3 fail_timeout=30s|g" \
                "$config_file"
        fi
    else
        # Comment out green if container doesn't exist
        $SED_IN_PLACE -e "s|^[[:space:]]*server ${backend_base}-green|    # server ${backend_base}-green|g" "$config_file"
    fi
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

