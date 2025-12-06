#!/bin/bash
# Add Service Registry Script
# Interactive script to create a service registry JSON file
# Usage: add-service-registry.sh [service-name]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTRY_DIR="${PROJECT_DIR}/service-registry"

# Source output functions
if [ -f "${SCRIPT_DIR}/common/output.sh" ]; then
    source "${SCRIPT_DIR}/common/output.sh"
else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
    print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
    print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
    print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
    print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
fi

# Ensure registry directory exists
mkdir -p "$REGISTRY_DIR"

# Get service name
SERVICE_NAME="$1"

if [ -z "$SERVICE_NAME" ]; then
    echo "Add Service Registry"
    echo "==================="
    echo ""
    read -p "Service name (e.g., logging-microservice): " SERVICE_NAME
fi

# Validate service name
if [ -z "$SERVICE_NAME" ]; then
    print_error "Service name is required"
    exit 1
fi

# Check if registry already exists
REGISTRY_FILE="${REGISTRY_DIR}/${SERVICE_NAME}.json"
if [ -f "$REGISTRY_FILE" ]; then
    print_warning "Registry file already exists: $REGISTRY_FILE"
    read -p "Do you want to overwrite it? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi
fi

echo ""
echo "Creating registry for: $SERVICE_NAME"
echo "====================================="
echo ""

# Collect required information
read -p "Domain (e.g., logging.statex.cz): " DOMAIN
read -p "Production path (e.g., /home/statex/${SERVICE_NAME}): " PRODUCTION_PATH
read -p "Docker compose file [docker-compose.blue.yml]: " DOCKER_COMPOSE_FILE
DOCKER_COMPOSE_FILE="${DOCKER_COMPOSE_FILE:-docker-compose.blue.yml}"

# Generate docker_project_base from service_name (replace - with _)
DOCKER_PROJECT_BASE=$(echo "$SERVICE_NAME" | tr '-' '_')
read -p "Docker project base [${DOCKER_PROJECT_BASE}]: " DOCKER_PROJECT_BASE_INPUT
DOCKER_PROJECT_BASE="${DOCKER_PROJECT_BASE_INPUT:-$DOCKER_PROJECT_BASE}"

# Collect service information
echo ""
echo "Service Configuration"
echo "--------------------"
echo "Enter service details. You can add multiple services (backend, frontend, etc.)"
echo "Press Enter with empty service key to finish adding services."
echo ""

SERVICES_JSON=""
while true; do
    # Reset variables for each iteration to prevent values from persisting
    CONTAINER_PORT=""
    
    read -p "Service key (e.g., backend, frontend) or Enter to finish: " SERVICE_KEY
    if [ -z "$SERVICE_KEY" ]; then
        break
    fi
    
    read -p "Container name base [${SERVICE_NAME}]: " CONTAINER_BASE
    CONTAINER_BASE="${CONTAINER_BASE:-$SERVICE_NAME}"
    
    read -p "Container port (optional, will auto-detect if empty): " CONTAINER_PORT
    read -p "Health endpoint [/health]: " HEALTH_ENDPOINT
    HEALTH_ENDPOINT="${HEALTH_ENDPOINT:-/health}"
    
    read -p "Health timeout [5]: " HEALTH_TIMEOUT
    HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-5}"
    
    read -p "Health retries [3]: " HEALTH_RETRIES
    HEALTH_RETRIES="${HEALTH_RETRIES:-3}"
    
    read -p "Startup time (seconds) [5]: " STARTUP_TIME
    STARTUP_TIME="${STARTUP_TIME:-5}"
    
    # Build service JSON
    SERVICE_JSON="\"${SERVICE_KEY}\": {"
    SERVICE_JSON="${SERVICE_JSON}\"container_name_base\": \"${CONTAINER_BASE}\","
    if [ -n "$CONTAINER_PORT" ]; then
        SERVICE_JSON="${SERVICE_JSON}\"container_port\": ${CONTAINER_PORT},"
    fi
    SERVICE_JSON="${SERVICE_JSON}\"health_endpoint\": \"${HEALTH_ENDPOINT}\","
    SERVICE_JSON="${SERVICE_JSON}\"health_timeout\": ${HEALTH_TIMEOUT},"
    SERVICE_JSON="${SERVICE_JSON}\"health_retries\": ${HEALTH_RETRIES},"
    SERVICE_JSON="${SERVICE_JSON}\"startup_time\": ${STARTUP_TIME}"
    SERVICE_JSON="${SERVICE_JSON}}"
    
    if [ -z "$SERVICES_JSON" ]; then
        SERVICES_JSON="$SERVICE_JSON"
    else
        SERVICES_JSON="${SERVICES_JSON},${SERVICE_JSON}"
    fi
    
    echo ""
done

# Collect shared services
echo ""
echo "Shared Services"
echo "---------------"
echo "Enter shared services (postgres, redis) separated by commas, or press Enter for postgres:"
read -p "Shared services [postgres]: " SHARED_SERVICES_INPUT
SHARED_SERVICES_INPUT="${SHARED_SERVICES_INPUT:-postgres}"

# Parse shared services into JSON array
if [ -n "$SHARED_SERVICES_INPUT" ]; then
    SHARED_SERVICES_JSON="["
    FIRST=true
    IFS=',' read -ra SERVICES <<< "$SHARED_SERVICES_INPUT"
    for service in "${SERVICES[@]}"; do
        service=$(echo "$service" | xargs) # trim whitespace
        if [ -n "$service" ]; then
            if [ "$FIRST" = true ]; then
                SHARED_SERVICES_JSON="${SHARED_SERVICES_JSON}\"${service}\""
                FIRST=false
            else
                SHARED_SERVICES_JSON="${SHARED_SERVICES_JSON}, \"${service}\""
            fi
        fi
    done
    SHARED_SERVICES_JSON="${SHARED_SERVICES_JSON}]"
else
    SHARED_SERVICES_JSON="[]"
fi

# Network
read -p "Network [nginx-network]: " NETWORK
NETWORK="${NETWORK:-nginx-network}"

# Validate required fields
if [ -z "$DOMAIN" ] || [ -z "$PRODUCTION_PATH" ] || [ -z "$SERVICES_JSON" ]; then
    print_error "Domain, production path, and at least one service are required"
    exit 1
fi

# Generate JSON file
JSON_CONTENT="{
  \"service_name\": \"${SERVICE_NAME}\",
  \"production_path\": \"${PRODUCTION_PATH}\",
  \"domain\": \"${DOMAIN}\",
  \"docker_compose_file\": \"${DOCKER_COMPOSE_FILE}\",
  \"docker_project_base\": \"${DOCKER_PROJECT_BASE}\",
  \"services\": {
    ${SERVICES_JSON}
  },
  \"shared_services\": ${SHARED_SERVICES_JSON},
  \"network\": \"${NETWORK}\"
}"

# Validate JSON syntax (mandatory - use jq or python3 as fallback)
if command -v jq >/dev/null 2>&1; then
    if ! echo "$JSON_CONTENT" | jq . > /dev/null 2>&1; then
        print_error "Generated JSON is invalid"
        exit 1
    fi
    # Format JSON nicely
    JSON_CONTENT=$(echo "$JSON_CONTENT" | jq .)
elif command -v python3 >/dev/null 2>&1; then
    # Use python3 as fallback for JSON validation
    if ! echo "$JSON_CONTENT" | python3 -m json.tool > /dev/null 2>&1; then
        print_error "Generated JSON is invalid"
        exit 1
    fi
    # Format JSON nicely using python3
    JSON_CONTENT=$(echo "$JSON_CONTENT" | python3 -m json.tool)
else
    print_error "Neither jq nor python3 found. JSON validation is required."
    print_error "Please install jq: brew install jq (or apt-get install jq)"
    exit 1
fi

# Write file
if ! echo "$JSON_CONTENT" > "$REGISTRY_FILE"; then
    print_error "Failed to write registry file: $REGISTRY_FILE"
    exit 1
fi

# Verify file was written successfully
if [ ! -f "$REGISTRY_FILE" ] || [ ! -s "$REGISTRY_FILE" ]; then
    print_error "Registry file was not created or is empty: $REGISTRY_FILE"
    exit 1
fi

print_success "Registry file created: $REGISTRY_FILE"
echo ""
echo "Next steps:"
echo "  1. Review the registry file: cat $REGISTRY_FILE"
echo "  2. Deploy the service: ./scripts/blue-green/deploy-smart.sh ${SERVICE_NAME}"
echo ""

