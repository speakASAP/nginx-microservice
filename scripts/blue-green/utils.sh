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

# Function to update container_port in registry from docker-compose.yml
update_registry_ports() {
    local service_name="$1"
    local registry_file="${REGISTRY_DIR}/${service_name}.json"
    
    if [ ! -f "$registry_file" ]; then
        log_message "WARNING" "$service_name" "deploy" "update-ports" "Registry file not found, skipping port update"
        return 1
    fi
    
    local registry=$(load_service_registry "$service_name")
    local service_keys=$(echo "$registry" | jq -r '.services | keys[]' 2>/dev/null || echo "")
    
    if [ -z "$service_keys" ]; then
        log_message "WARNING" "$service_name" "deploy" "update-ports" "No services found in registry"
        return 0
    fi
    
    local updated_count=0
    local skipped_count=0
    local temp_file=$(mktemp)
    
    # Load current registry JSON
    if ! cp "$registry_file" "$temp_file"; then
        log_message "ERROR" "$service_name" "deploy" "update-ports" "Failed to create temporary file"
        return 1
    fi
    
    while IFS= read -r service_key; do
        local container_base=$(echo "$registry" | jq -r ".services[\"$service_key\"].container_name_base // empty" 2>/dev/null)
        if [ -z "$container_base" ] || [ "$container_base" = "null" ]; then
            skipped_count=$((skipped_count + 1))
            continue
        fi
        
        # Check if container_port already exists
        local existing_port=$(echo "$registry" | jq -r ".services[\"$service_key\"].container_port // empty" 2>/dev/null)
        
        # Detect port from docker-compose.yml
        local detected_port=""
        if type detect_container_port_from_compose >/dev/null 2>&1; then
            detected_port=$(detect_container_port_from_compose "$service_name" "$service_key" "$container_base" 2>/dev/null || echo "")
        fi
        
        if [ -z "$detected_port" ] || [ "$detected_port" = "null" ]; then
            if [ -z "$existing_port" ] || [ "$existing_port" = "null" ]; then
                log_message "WARNING" "$service_name" "deploy" "update-ports" "Could not detect container_port for $service_key, skipping"
                skipped_count=$((skipped_count + 1))
            else
                log_message "INFO" "$service_name" "deploy" "update-ports" "Keeping existing container_port=$existing_port for $service_key"
            fi
            continue
        fi
        
        # Update container_port in JSON
        if command -v jq >/dev/null 2>&1; then
            if ! jq ".services[\"$service_key\"].container_port = $detected_port" "$temp_file" > "${temp_file}.new" 2>/dev/null; then
                log_message "WARNING" "$service_name" "deploy" "update-ports" "Failed to update container_port for $service_key"
                rm -f "${temp_file}.new"
                skipped_count=$((skipped_count + 1))
                continue
            fi
            mv "${temp_file}.new" "$temp_file"
        elif command -v python3 >/dev/null 2>&1; then
            # Fallback to python3 for JSON manipulation
            # Use proper JSON encoding to prevent code injection
            # Pass variables via environment variables for safety
            if ! SERVICE_KEY_JSON=$(echo "$service_key" | python3 -c "import sys, json; print(json.dumps(sys.stdin.read().strip()))" 2>/dev/null) || \
               ! TEMP_FILE_JSON=$(echo "$temp_file" | python3 -c "import sys, json; print(json.dumps(sys.stdin.read().strip()))" 2>/dev/null) || \
               ! python3 -c "
import json
import os
import sys

# Read variables from environment (safely passed)
service_key = json.loads(os.environ.get('SERVICE_KEY_JSON', 'null'))
temp_file = json.loads(os.environ.get('TEMP_FILE_JSON', 'null'))
detected_port = int(os.environ.get('DETECTED_PORT', '0'))

if not service_key or not temp_file or detected_port <= 0:
    sys.exit(1)

try:
    with open(temp_file, 'r') as f:
        data = json.load(f)
    data['services'][service_key]['container_port'] = detected_port
    with open(temp_file, 'w') as f:
        json.dump(data, f, indent=2)
except (KeyError, ValueError, IOError, json.JSONDecodeError):
    sys.exit(1)
" \
                SERVICE_KEY_JSON="$SERVICE_KEY_JSON" \
                TEMP_FILE_JSON="$TEMP_FILE_JSON" \
                DETECTED_PORT="$detected_port" \
                2>/dev/null; then
                log_message "WARNING" "$service_name" "deploy" "update-ports" "Failed to update container_port for $service_key"
                skipped_count=$((skipped_count + 1))
                continue
            fi
        else
            log_message "ERROR" "$service_name" "deploy" "update-ports" "Neither jq nor python3 found. Cannot update registry."
            rm -f "$temp_file"
            return 1
        fi
        
        if [ "$existing_port" = "$detected_port" ]; then
            log_message "INFO" "$service_name" "deploy" "update-ports" "container_port=$detected_port already set for $service_key"
        else
            log_message "SUCCESS" "$service_name" "deploy" "update-ports" "Updated container_port=$detected_port for $service_key (was: ${existing_port:-not set})"
            updated_count=$((updated_count + 1))
        fi
    done <<< "$service_keys"
    
    # Validate JSON before writing
    if command -v jq >/dev/null 2>&1; then
        if ! jq empty "$temp_file" 2>/dev/null; then
            log_message "ERROR" "$service_name" "deploy" "update-ports" "Generated invalid JSON"
            rm -f "$temp_file"
            return 1
        fi
    elif command -v python3 >/dev/null 2>&1; then
        if ! python3 -m json.tool "$temp_file" >/dev/null 2>&1; then
            log_message "ERROR" "$service_name" "deploy" "update-ports" "Generated invalid JSON"
            rm -f "$temp_file"
            return 1
        fi
    fi
    
    # Write updated registry back
    if [ $updated_count -gt 0 ] || [ $skipped_count -eq 0 ]; then
        if ! mv "$temp_file" "$registry_file"; then
            log_message "ERROR" "$service_name" "deploy" "update-ports" "Failed to write updated registry"
            rm -f "$temp_file"
            return 1
        fi
        if [ $updated_count -gt 0 ]; then
            log_message "SUCCESS" "$service_name" "deploy" "update-ports" "Registry updated: $updated_count service(s) updated"
        fi
    else
        rm -f "$temp_file"
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
    
    # Auto-detect domain - try multiple sources in order of priority
    local domain=""
    
    # 1. Try to extract from .env file (SERVICE_NAME, DOMAIN, or FRONTEND_URL)
    if [ -f "${service_path}/.env" ]; then
        # Try SERVICE_NAME first (e.g., SERVICE_NAME=flipflop.statex.cz)
        domain=$(grep -E "^SERVICE_NAME=" "${service_path}/.env" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d '[:space:]' | sed 's|^https\?://||' | sed 's|/$||' || echo "")
        
        # If not found, try DOMAIN variable
        if [ -z "$domain" ]; then
            domain=$(grep -E "^DOMAIN=" "${service_path}/.env" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d '[:space:]' | sed 's|^https\?://||' | sed 's|/$||' || echo "")
        fi
        
        # If still not found, try FRONTEND_URL and extract domain
        if [ -z "$domain" ]; then
            local frontend_url=$(grep -E "^FRONTEND_URL=" "${service_path}/.env" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d '[:space:]' || echo "")
            if [ -n "$frontend_url" ]; then
                domain=$(echo "$frontend_url" | sed 's|^https\?://||' | sed 's|/.*$||' || echo "")
            fi
        fi
        
        if [ -n "$domain" ]; then
            log_message "INFO" "$service_name" "deploy" "auto-registry" "Detected domain from .env: ${domain}"
        fi
    fi
    
    # 2. Fallback: Auto-detect domain from service name
    if [ -z "$domain" ]; then
        # e.g., logging-microservice -> logging.statex.cz
        # Keep hyphens in domain names (don't convert to underscores)
        local domain_base=$(echo "$service_name" | sed 's/-microservice$//')
        domain="${domain_base}.statex.cz"
        if [ "$service_name" = "statex" ]; then
            domain="statex.cz"
        fi
        log_message "INFO" "$service_name" "deploy" "auto-registry" "Using auto-generated domain: ${domain}"
    fi
    
    # Auto-detect docker project base
    local docker_project_base=$(echo "$service_name" | tr '-' '_')
    
    # Try to extract services from docker-compose file
    local services_json=""
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 && [ -f "${service_path}/${compose_file}" ]; then
        # Use JSON format if jq is available, YAML if yq is available
        local compose_format=""
        if command -v jq >/dev/null 2>&1; then
            compose_format="--format json"
        fi
        local compose_config=$(cd "$service_path" && docker compose -f "$compose_file" config $compose_format 2>/dev/null || echo "")
        
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
                    
                    # Detect container_port from docker-compose.yml
                    local detected_port=""
                    if [ -n "$compose_config" ]; then
                        # Try to extract port using the same logic as detect_container_port_from_compose
                        if command -v yq >/dev/null 2>&1; then
                            # yq handles YAML format - ports can be string "HOST:CONTAINER" or number
                            detected_port=$(echo "$compose_config" | yq eval ".services[\"${service_key}\"].ports[]? | select(. != null) | if type == \"string\" then (if contains(\":\") then (split(\":\") | .[1]) else . end) elif type == \"number\" then . else .target end" - 2>/dev/null | grep -oE '^[0-9]+' | head -1 || echo "")
                        elif command -v jq >/dev/null 2>&1; then
                            # jq handles JSON format - ports are objects with "target" (container) and "published" (host)
                            detected_port=$(echo "$compose_config" | jq -r ".services[\"${service_key}\"].ports[]? | select(. != null) | if type == \"object\" then .target elif type == \"string\" then (if contains(\":\") then (split(\":\") | .[1]) else . end) elif type == \"number\" then . else empty end" 2>/dev/null | grep -oE '^[0-9]+' | head -1 || echo "")
                        fi
                        
                        # Fallback: try .env file
                        if [ -z "$detected_port" ] && [ -f "${service_path}/.env" ]; then
                            local service_key_upper="${service_key^^}"
                            local container_base_upper="${container_name_base^^}"
                            detected_port=$(grep -F "SERVICE_PORT=" "${service_path}/.env" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d '[:space:]' || echo "")
                            if [ -z "$detected_port" ]; then
                                detected_port=$(grep -F "${container_base_upper}_PORT=" "${service_path}/.env" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d '[:space:]' || echo "")
                            fi
                            if [ -z "$detected_port" ]; then
                                detected_port=$(grep -E "^PORT=" "${service_path}/.env" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d '[:space:]' || echo "")
                            fi
                        fi
                    fi
                    
                    # Detect health endpoint from docker-compose healthcheck
                    local health_endpoint="/health"
                    local healthcheck_found=false
                    if [ -n "$compose_config" ]; then
                        if command -v jq >/dev/null 2>&1; then
                            # Extract healthcheck test command and find URL endpoint
                            local healthcheck_test=$(echo "$compose_config" | jq -r ".services[\"${service_key}\"].healthcheck.test[]? // empty" 2>/dev/null | grep -E '^http://|^https://|^/' | head -1 || echo "")
                            if [ -n "$healthcheck_test" ] && [ "$healthcheck_test" != "null" ]; then
                                healthcheck_found=true
                                # Extract path from URL (e.g., http://localhost:3000/ -> /)
                                health_endpoint=$(echo "$healthcheck_test" | sed -E 's|^https?://[^/]+||' | sed 's|^/|/|' || echo "/")
                                if [ -z "$health_endpoint" ] || [ "$health_endpoint" = "null" ]; then
                                    health_endpoint="/"
                                fi
                            fi
                        elif command -v yq >/dev/null 2>&1; then
                            local healthcheck_test=$(echo "$compose_config" | yq eval ".services[\"${service_key}\"].healthcheck.test[]? // empty" - 2>/dev/null | grep -E '^http://|^https://|^/' | head -1 || echo "")
                            if [ -n "$healthcheck_test" ] && [ "$healthcheck_test" != "null" ]; then
                                healthcheck_found=true
                                health_endpoint=$(echo "$healthcheck_test" | sed -E 's|^https?://[^/]+||' | sed 's|^/|/|' || echo "/")
                                if [ -z "$health_endpoint" ] || [ "$health_endpoint" = "null" ]; then
                                    health_endpoint="/"
                                fi
                            fi
                        fi
                    fi
                    
                    # Default frontend services to "/" only if healthcheck was not found
                    # If healthcheck explicitly specifies "/health", we should respect that
                    if [ "$service_key" = "frontend" ] && [ "$healthcheck_found" = false ]; then
                        health_endpoint="/"
                    fi
                    
                    # Build service JSON (include container_port if detected)
                    local service_json="\"${service_key}\": {"
                    service_json="${service_json}\"container_name_base\": \"${container_name_base}\","
                    if [ -n "$detected_port" ] && [ "$detected_port" != "null" ]; then
                        service_json="${service_json}\"container_port\": ${detected_port},"
                    fi
                    service_json="${service_json}\"health_endpoint\": \"${health_endpoint}\","
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
        # Try to detect port for default backend service
        local detected_port=""
        if [ -n "$compose_config" ] && type detect_container_port_from_compose >/dev/null 2>&1; then
            # Try to detect from first service in compose or from .env
            if command -v yq >/dev/null 2>&1; then
                local first_service=$(echo "$compose_config" | yq eval '.services | keys | .[0]' - 2>/dev/null || echo "")
                if [ -n "$first_service" ] && [ "$first_service" != "null" ]; then
                    detected_port=$(echo "$compose_config" | yq eval ".services[\"${first_service}\"].ports[]? | select(. != null) | if type == \"string\" then (if contains(\":\") then (split(\":\") | .[1]) else . end) elif type == \"number\" then . else .target end" - 2>/dev/null | grep -oE '^[0-9]+' | head -1 || echo "")
                fi
            elif command -v jq >/dev/null 2>&1; then
                local first_service=$(echo "$compose_config" | jq -r '.services | keys[0]' 2>/dev/null || echo "")
                if [ -n "$first_service" ] && [ "$first_service" != "null" ]; then
                    detected_port=$(echo "$compose_config" | jq -r ".services[\"${first_service}\"].ports[]? | select(. != null) | if type == \"object\" then .target elif type == \"string\" then (if contains(\":\") then (split(\":\") | .[1]) else . end) elif type == \"number\" then . else empty end" 2>/dev/null | grep -oE '^[0-9]+' | head -1 || echo "")
                fi
            fi
            
            # Fallback: try .env file
            if [ -z "$detected_port" ] && [ -f "${service_path}/.env" ]; then
                detected_port=$(grep -F "SERVICE_PORT=" "${service_path}/.env" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d '[:space:]' || echo "")
                if [ -z "$detected_port" ]; then
                    local service_name_upper=$(echo "$service_name" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
                    detected_port=$(grep -F "${service_name_upper}_PORT=" "${service_path}/.env" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d '[:space:]' || echo "")
                fi
                if [ -z "$detected_port" ]; then
                    detected_port=$(grep -E "^PORT=" "${service_path}/.env" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d '[:space:]' || echo "")
                fi
            fi
        fi
        
        services_json="\"backend\": {"
        services_json="${services_json}\"container_name_base\": \"${service_name}\","
        if [ -n "$detected_port" ] && [ "$detected_port" != "null" ]; then
            services_json="${services_json}\"container_port\": ${detected_port},"
        fi
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

