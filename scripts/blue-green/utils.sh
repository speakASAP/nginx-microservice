#!/bin/bash
# Blue/Green Deployment Utility Functions
# Shared functions for all blue/green deployment scripts
# This file now acts as a module loader and provides blue-green specific logging

set -e

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
REGISTRY_DIR="${NGINX_PROJECT_DIR}/service-registry"
STATE_DIR="${NGINX_PROJECT_DIR}/state"
LOG_DIR="${NGINX_PROJECT_DIR}/logs/blue-green"

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Source output functions (for print_* functions)
COMMON_DIR="${SCRIPT_DIR}/../common"
if [ -f "${COMMON_DIR}/output.sh" ]; then
    source "${COMMON_DIR}/output.sh"
else
    # Fallback print functions if output.sh not found
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
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
fi

# Source all modular functions
if [ -f "${COMMON_DIR}/registry.sh" ]; then
    source "${COMMON_DIR}/registry.sh"
fi

if [ -f "${COMMON_DIR}/state.sh" ]; then
    source "${COMMON_DIR}/state.sh"
fi

if [ -f "${COMMON_DIR}/config.sh" ]; then
    source "${COMMON_DIR}/config.sh"
fi

if [ -f "${COMMON_DIR}/nginx.sh" ]; then
    source "${COMMON_DIR}/nginx.sh"
fi

if [ -f "${COMMON_DIR}/containers.sh" ]; then
    source "${COMMON_DIR}/containers.sh"
fi

if [ -f "${COMMON_DIR}/network.sh" ]; then
    source "${COMMON_DIR}/network.sh"
fi

# Function to log message (blue-green specific logging)
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

# Function to auto-create service registry from service directory
# This is called when registry file doesn't exist during deployment
auto_create_service_registry() {
    local service_name="$1"
    local registry_file="${REGISTRY_DIR}/${service_name}.json"
    
    # Ensure registry directory exists
    mkdir -p "$REGISTRY_DIR"
    
    # Try to find service directory
    local production_path="/home/statex/${service_name}"
    local service_path=""
    local compose_file=""
    
    # Check if production path exists
    if [ -d "$production_path" ]; then
        service_path="$production_path"
    else
        # Try to find in common locations
        for path in "/home/statex/${service_name}" "/opt/${service_name}" "$HOME/${service_name}"; do
            if [ -d "$path" ]; then
                service_path="$path"
                break
            fi
        done
    fi
    
    if [ -z "$service_path" ] || [ ! -d "$service_path" ]; then
        log_message "WARNING" "$service_name" "deploy" "auto-registry" "Service directory not found, cannot auto-create registry"
        return 1
    fi
    
    # Find docker-compose file
    for file in "docker-compose.blue.yml" "docker-compose.yml" "docker-compose.yaml"; do
        if [ -f "${service_path}/${file}" ]; then
            compose_file="$file"
            break
        fi
    done
    
    if [ -z "$compose_file" ]; then
        log_message "WARNING" "$service_name" "deploy" "auto-registry" "Docker compose file not found in ${service_path}, cannot auto-create registry"
        return 1
    fi
    
    log_message "INFO" "$service_name" "deploy" "auto-registry" "Found service at ${service_path} with ${compose_file}"
    
    # Auto-detect domain from service name
    # e.g., logging-microservice -> logging.statex.cz
    # Keep hyphens in domain names (don't convert to underscores)
    local domain_base=$(echo "$service_name" | sed 's/-microservice$//')
    local domain="${domain_base}.statex.cz"
    
    # Auto-detect docker project base
    local docker_project_base=$(echo "$service_name" | tr '-' '_')
    
    # Try to extract services from docker-compose file
    local services_json=""
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 && [ -f "${service_path}/${compose_file}" ]; then
        local compose_config=$(cd "$service_path" && docker compose -f "$compose_file" config 2>/dev/null || echo "")
        
        if [ -n "$compose_config" ]; then
            # Extract service keys from docker-compose
            local service_keys=""
            if command -v yq >/dev/null 2>&1; then
                service_keys=$(echo "$compose_config" | yq eval '.services | keys | .[]' - 2>/dev/null || echo "")
            elif command -v jq >/dev/null 2>&1; then
                service_keys=$(echo "$compose_config" | jq -r '.services | keys[]' 2>/dev/null || echo "")
            fi
            
            if [ -n "$service_keys" ]; then
                local first=true
                while IFS= read -r service_key; do
                    if [ -z "$service_key" ]; then
                        continue
                    fi
                    
                    # Get container name from compose or use service_key
                    local container_name_base="$service_key"
                    if command -v yq >/dev/null 2>&1; then
                        local container_name=$(echo "$compose_config" | yq eval ".services[\"${service_key}\"].container_name // empty" - 2>/dev/null || echo "")
                        if [ -n "$container_name" ] && [ "$container_name" != "null" ]; then
                            # Remove -blue or -green suffix if present
                            container_name_base=$(echo "$container_name" | sed 's/-blue$//' | sed 's/-green$//')
                        fi
                    elif command -v jq >/dev/null 2>&1; then
                        local container_name=$(echo "$compose_config" | jq -r ".services[\"${service_key}\"].container_name // empty" 2>/dev/null || echo "")
                        if [ -n "$container_name" ] && [ "$container_name" != "null" ]; then
                            container_name_base=$(echo "$container_name" | sed 's/-blue$//' | sed 's/-green$//')
                        fi
                    fi
                    
                    # Build service JSON (port will be auto-detected, so we don't include it)
                    local service_json="\"${service_key}\": {"
                    service_json="${service_json}\"container_name_base\": \"${container_name_base}\","
                    service_json="${service_json}\"health_endpoint\": \"/health\","
                    service_json="${service_json}\"health_timeout\": 5,"
                    service_json="${service_json}\"health_retries\": 2,"
                    service_json="${service_json}\"startup_time\": 5"
                    service_json="${service_json}}"
                    
                    if [ "$first" = true ]; then
                        services_json="$service_json"
                        first=false
                    else
                        services_json="${services_json},${service_json}"
                    fi
                done <<< "$service_keys"
            fi
        fi
    fi
    
    # If no services found, create a default backend service
    if [ -z "$services_json" ]; then
        services_json="\"backend\": {"
        services_json="${services_json}\"container_name_base\": \"${service_name}\","
        services_json="${services_json}\"health_endpoint\": \"/health\","
        services_json="${services_json}\"health_timeout\": 5,"
        services_json="${services_json}\"health_retries\": 2,"
        services_json="${services_json}\"startup_time\": 5"
        services_json="${services_json}}"
        log_message "WARNING" "$service_name" "deploy" "auto-registry" "Could not detect services from docker-compose, using default 'backend' service"
    fi
    
    # Create JSON content
    local json_content="{
  \"service_name\": \"${service_name}\",
  \"production_path\": \"${service_path}\",
  \"domain\": \"${domain}\",
  \"docker_compose_file\": \"${compose_file}\",
  \"docker_project_base\": \"${docker_project_base}\",
  \"services\": {
    ${services_json}
  },
  \"shared_services\": [\"postgres\"],
  \"network\": \"nginx-network\"
}"
    
    # Validate and format JSON (mandatory - use jq or python3 as fallback)
    if command -v jq >/dev/null 2>&1; then
        if ! echo "$json_content" | jq . > /dev/null 2>&1; then
            log_message "ERROR" "$service_name" "deploy" "auto-registry" "Generated JSON is invalid"
            return 1
        fi
        json_content=$(echo "$json_content" | jq .)
    elif command -v python3 >/dev/null 2>&1; then
        # Use python3 as fallback for JSON validation
        if ! echo "$json_content" | python3 -m json.tool > /dev/null 2>&1; then
            log_message "ERROR" "$service_name" "deploy" "auto-registry" "Generated JSON is invalid"
            return 1
        fi
        # Format JSON nicely using python3
        json_content=$(echo "$json_content" | python3 -m json.tool)
    else
        log_message "ERROR" "$service_name" "deploy" "auto-registry" "Neither jq nor python3 found. JSON validation is required."
        return 1
    fi
    
    # Write registry file
    if ! echo "$json_content" > "$registry_file"; then
        log_message "ERROR" "$service_name" "deploy" "auto-registry" "Failed to write registry file: ${registry_file}"
        return 1
    fi
    
    # Verify file was written successfully
    if [ ! -f "$registry_file" ] || [ ! -s "$registry_file" ]; then
        log_message "ERROR" "$service_name" "deploy" "auto-registry" "Registry file was not created or is empty: ${registry_file}"
        return 1
    fi
    
    log_message "SUCCESS" "$service_name" "deploy" "auto-registry" "Registry file auto-created: ${registry_file}"
    log_message "INFO" "$service_name" "deploy" "auto-registry" "Please review and update the registry file if needed, especially:"
    log_message "INFO" "$service_name" "deploy" "auto-registry" "  - Domain: ${domain}"
    log_message "INFO" "$service_name" "deploy" "auto-registry" "  - Health endpoints (defaulted to /health)"
    log_message "INFO" "$service_name" "deploy" "auto-registry" "  - Shared services (defaulted to [\"postgres\"])"
    
    return 0
}

