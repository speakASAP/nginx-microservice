#!/bin/bash
# Remove Microservice Script
# Completely removes a microservice and all its artifacts from the system
# Usage: remove-microservice.sh <service-name> [--remove-cert] [--force]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTRY_DIR="${NGINX_PROJECT_DIR}/service-registry"
STATE_DIR="${NGINX_PROJECT_DIR}/state"
CONFIG_DIR="${NGINX_PROJECT_DIR}/nginx/conf.d"
CERT_DIR="${NGINX_PROJECT_DIR}/certificates"

# Load .env file if it exists
if [ -f "${NGINX_PROJECT_DIR}/.env" ]; then
    set -a
    source "${NGINX_PROJECT_DIR}/.env" 2>/dev/null || true
    set +a
fi

# Source common modules
COMMON_DIR="${SCRIPT_DIR}/common"
if [ -f "${COMMON_DIR}/output.sh" ]; then
    source "${COMMON_DIR}/output.sh"
fi

if [ -f "${COMMON_DIR}/registry.sh" ]; then
    source "${COMMON_DIR}/registry.sh"
fi

if [ -f "${COMMON_DIR}/state.sh" ]; then
    source "${COMMON_DIR}/state.sh"
fi

# Parse arguments
SERVICE_NAME=""
REMOVE_CERT=false
FORCE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --remove-cert)
            REMOVE_CERT=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        *)
            if [ -z "$SERVICE_NAME" ]; then
                SERVICE_NAME="$1"
            else
                print_error "Unknown argument: $1"
                echo "Usage: remove-microservice.sh <service-name> [--remove-cert] [--force]"
                exit 1
            fi
            shift
            ;;
    esac
done

# Check for required tools
if ! command -v jq >/dev/null 2>&1; then
    print_error "jq is required but not found. Please install jq: brew install jq (or apt-get install jq)"
    exit 1
fi

# Validate input
if [ -z "$SERVICE_NAME" ]; then
    print_error "Service name is required"
    echo ""
    echo "Usage: remove-microservice.sh <service-name> [--remove-cert] [--force]"
    echo ""
    echo "Options:"
    echo "  --remove-cert    Also remove SSL certificates for the service domain"
    echo "  --force          Skip confirmation prompt"
    echo ""
    echo "Example:"
    echo "  remove-microservice.sh logging-microservice"
    echo "  remove-microservice.sh logging-microservice --remove-cert"
    echo "  remove-microservice.sh logging-microservice --remove-cert --force"
    exit 1
fi

# Check if service registry exists
REGISTRY_FILE="${REGISTRY_DIR}/${SERVICE_NAME}.json"
if [ ! -f "$REGISTRY_FILE" ]; then
    print_error "Service registry not found: $REGISTRY_FILE"
    print_info "The service '$SERVICE_NAME' does not exist in the registry."
    exit 1
fi

# Load service registry
print_status "Loading service registry for: $SERVICE_NAME"
REGISTRY=$(load_service_registry "$SERVICE_NAME")

# Extract service information
DOMAIN=$(echo "$REGISTRY" | jq -r '.domain // empty')
PRODUCTION_PATH=$(echo "$REGISTRY" | jq -r '.production_path // empty')
SERVICE_PATH=$(echo "$REGISTRY" | jq -r '.service_path // empty')
DOCKER_PROJECT_BASE=$(echo "$REGISTRY" | jq -r '.docker_project_base // empty')
DOCKER_COMPOSE_FILE=$(echo "$REGISTRY" | jq -r '.docker_compose_file // "docker-compose.yml"')

# Determine actual path
if [ -n "$PRODUCTION_PATH" ] && [ "$PRODUCTION_PATH" != "null" ] && [ -d "$PRODUCTION_PATH" ]; then
    ACTUAL_PATH="$PRODUCTION_PATH"
elif [ -n "$SERVICE_PATH" ] && [ "$SERVICE_PATH" != "null" ] && [ -d "$SERVICE_PATH" ]; then
    ACTUAL_PATH="$SERVICE_PATH"
else
    ACTUAL_PATH=""
fi

# Get container names from registry
CONTAINER_NAMES=()
if echo "$REGISTRY" | jq -e '.services' >/dev/null 2>&1; then
    SERVICE_KEYS=$(echo "$REGISTRY" | jq -r '.services | keys[]' 2>/dev/null || echo "")
    while IFS= read -r service_key; do
        if [ -n "$service_key" ] && [ "$service_key" != "null" ]; then
            CONTAINER_BASE=$(echo "$REGISTRY" | jq -r ".services[\"$service_key\"].container_name_base" 2>/dev/null || echo "")
            if [ -n "$CONTAINER_BASE" ] && [ "$CONTAINER_BASE" != "null" ]; then
                CONTAINER_NAMES+=("${CONTAINER_BASE}-blue")
                CONTAINER_NAMES+=("${CONTAINER_BASE}-green")
            fi
        fi
    done <<< "$SERVICE_KEYS"
fi

# Display service information
print_header "Remove Microservice: $SERVICE_NAME"
echo ""
print_info "Service Information:"
echo "  Domain: ${DOMAIN:-N/A}"
echo "  Path: ${ACTUAL_PATH:-N/A}"
echo "  Docker Project Base: ${DOCKER_PROJECT_BASE:-N/A}"
echo "  Containers: ${#CONTAINER_NAMES[@]} container(s) will be removed"
echo ""

# Show what will be removed
print_warning "The following will be removed:"
echo "  ✓ Service registry: $REGISTRY_FILE"
echo "  ✓ State file: ${STATE_DIR}/${SERVICE_NAME}.json"
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "null" ]; then
    echo "  ✓ Nginx configs:"
    echo "    - ${CONFIG_DIR}/blue-green/${DOMAIN}.blue.conf"
    echo "    - ${CONFIG_DIR}/blue-green/${DOMAIN}.green.conf"
    echo "    - ${CONFIG_DIR}/${DOMAIN}.conf (symlink)"
    echo "    - ${CONFIG_DIR}/staging/${DOMAIN}.*.conf (if any)"
    echo "    - ${CONFIG_DIR}/rejected/${DOMAIN}.*.conf (if any)"
    if [ "$REMOVE_CERT" = true ]; then
        echo "  ✓ SSL certificates: ${CERT_DIR}/${DOMAIN}/"
    fi
fi
if [ ${#CONTAINER_NAMES[@]} -gt 0 ]; then
    echo "  ✓ Docker containers:"
    for container in "${CONTAINER_NAMES[@]}"; do
        echo "    - $container"
    done
fi
echo ""

# Confirmation
if [ "$FORCE" != true ]; then
    read -p "Are you sure you want to remove $SERVICE_NAME? This cannot be undone! (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Aborted."
        exit 0
    fi
fi

echo ""
print_status "Starting removal process..."
echo ""

# Track removal results
REMOVED_ITEMS=()
FAILED_ITEMS=()

# Step 1: Stop and remove containers
print_section "Step 1: Stopping and Removing Containers"

if [ -n "$ACTUAL_PATH" ] && [ -d "$ACTUAL_PATH" ]; then
    cd "$ACTUAL_PATH"
    print_detail "Working directory: $(pwd)"

    # Stop blue deployment
    if [ -f "docker-compose.blue.yml" ]; then
        print_detail "Stopping blue deployment..."
        if docker compose -f docker-compose.blue.yml -p "${DOCKER_PROJECT_BASE}_blue" down 2>&1; then
            REMOVED_ITEMS+=("Blue deployment containers")
            print_success "Blue deployment stopped"
        else
            FAILED_ITEMS+=("Blue deployment stop")
            print_warning "Failed to stop blue deployment (may not exist)"
        fi
    fi

    # Stop green deployment
    if [ -f "docker-compose.green.yml" ]; then
        print_detail "Stopping green deployment..."
        if docker compose -f docker-compose.green.yml -p "${DOCKER_PROJECT_BASE}_green" down 2>&1; then
            REMOVED_ITEMS+=("Green deployment containers")
            print_success "Green deployment stopped"
        else
            FAILED_ITEMS+=("Green deployment stop")
            print_warning "Failed to stop green deployment (may not exist)"
        fi
    fi

    # Stop infrastructure
    if [ -f "docker-compose.infrastructure.yml" ]; then
        print_detail "Stopping infrastructure..."
        INFRA_PROJECT="${DOCKER_PROJECT_BASE}_infrastructure"
        if docker compose -f docker-compose.infrastructure.yml -p "$INFRA_PROJECT" down 2>&1; then
            REMOVED_ITEMS+=("Infrastructure containers")
            print_success "Infrastructure stopped"
        else
            FAILED_ITEMS+=("Infrastructure stop")
            print_warning "Failed to stop infrastructure (may not exist)"
        fi
    fi

    # Try default compose file
    if [ -f "$DOCKER_COMPOSE_FILE" ]; then
        print_detail "Stopping with $DOCKER_COMPOSE_FILE..."
        if docker compose -f "$DOCKER_COMPOSE_FILE" down 2>&1; then
            REMOVED_ITEMS+=("Default deployment containers")
            print_success "Default deployment stopped"
        else
            FAILED_ITEMS+=("Default deployment stop")
            print_warning "Failed to stop default deployment (may not exist)"
        fi
    fi
else
    print_warning "Service path not found, skipping container stop (containers may still exist)"
fi

# Force remove any remaining containers by name
for container_name in "${CONTAINER_NAMES[@]}"; do
    if docker ps -a --format "{{.Names}}" 2>/dev/null | grep -qE "^${container_name}$"; then
        print_detail "Force removing container: $container_name"
        
        # Attempt to stop and remove container
        docker stop "$container_name" 2>/dev/null || print_warning "Failed to stop container: $container_name"
        docker rm -f "$container_name" 2>/dev/null || print_warning "Failed to remove container: $container_name"
        
        # Verify container was actually removed
        if docker ps -a --format "{{.Names}}" 2>/dev/null | grep -qE "^${container_name}$"; then
            # Container still exists - removal failed
            FAILED_ITEMS+=("Container: $container_name (still exists after removal attempt)")
            print_error "Container $container_name still exists after removal attempt"
        else
            # Container successfully removed
            REMOVED_ITEMS+=("Container: $container_name")
            print_success "Removed container: $container_name"
        fi
    fi
done

# Step 2: Remove nginx configurations
print_section "Step 2: Removing Nginx Configurations"

if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "null" ]; then
    # Remove blue config
    BLUE_CONFIG="${CONFIG_DIR}/blue-green/${DOMAIN}.blue.conf"
    if [ -f "$BLUE_CONFIG" ]; then
        rm -f "$BLUE_CONFIG"
        REMOVED_ITEMS+=("Blue config: $BLUE_CONFIG")
        print_success "Removed blue config"
    fi

    # Remove green config
    GREEN_CONFIG="${CONFIG_DIR}/blue-green/${DOMAIN}.green.conf"
    if [ -f "$GREEN_CONFIG" ]; then
        rm -f "$GREEN_CONFIG"
        REMOVED_ITEMS+=("Green config: $GREEN_CONFIG")
        print_success "Removed green config"
    fi

    # Remove symlink
    SYMLINK_FILE="${CONFIG_DIR}/${DOMAIN}.conf"
    if [ -L "$SYMLINK_FILE" ] || [ -f "$SYMLINK_FILE" ]; then
        rm -f "$SYMLINK_FILE"
        REMOVED_ITEMS+=("Symlink: $SYMLINK_FILE")
        print_success "Removed symlink"
    fi

    # Remove staging configs (created during config generation)
    STAGING_DIR="${CONFIG_DIR}/staging"
    if [ -d "$STAGING_DIR" ]; then
        # Remove both blue and green staging configs
        STAGING_BLUE="${STAGING_DIR}/${DOMAIN}.blue.conf"
        STAGING_GREEN="${STAGING_DIR}/${DOMAIN}.green.conf"
        REMOVED_STAGING=false
        
        if [ -f "$STAGING_BLUE" ]; then
            rm -f "$STAGING_BLUE"
            REMOVED_STAGING=true
        fi
        if [ -f "$STAGING_GREEN" ]; then
            rm -f "$STAGING_GREEN"
            REMOVED_STAGING=true
        fi
        
        # Also remove any other staging configs matching the pattern (for safety)
        find "$STAGING_DIR" -name "${DOMAIN}.*.conf" -delete 2>/dev/null || true
        
        if [ "$REMOVED_STAGING" = true ]; then
            REMOVED_ITEMS+=("Staging configs for $DOMAIN")
            print_success "Removed staging configs"
        fi
    fi

    # Remove rejected configs (created if validation fails)
    REJECTED_DIR="${CONFIG_DIR}/rejected"
    if [ -d "$REJECTED_DIR" ]; then
        # Remove any rejected configs matching the domain pattern
        REJECTED_COUNT=$(find "$REJECTED_DIR" -name "${DOMAIN}.*.conf" 2>/dev/null | wc -l || echo "0")
        if [ "$REJECTED_COUNT" -gt 0 ]; then
            find "$REJECTED_DIR" -name "${DOMAIN}.*.conf" -delete 2>/dev/null || true
            REMOVED_ITEMS+=("Rejected configs for $DOMAIN ($REJECTED_COUNT file(s))")
            print_success "Removed rejected configs"
        fi
    fi
else
    print_warning "Domain not found in registry, skipping nginx config removal"
fi

# Step 3: Remove state file
print_section "Step 3: Removing State File"

STATE_FILE="${STATE_DIR}/${SERVICE_NAME}.json"
if [ -f "$STATE_FILE" ]; then
    rm -f "$STATE_FILE"
    REMOVED_ITEMS+=("State file: $STATE_FILE")
    print_success "Removed state file"
else
    print_info "State file not found (may not exist)"
fi

# Step 4: Remove service registry
print_section "Step 4: Removing Service Registry"

if [ -f "$REGISTRY_FILE" ]; then
    rm -f "$REGISTRY_FILE"
    REMOVED_ITEMS+=("Service registry: $REGISTRY_FILE")
    print_success "Removed service registry"
else
    print_warning "Service registry file not found (already removed?)"
fi

# Step 5: Remove SSL certificates (optional)
if [ "$REMOVE_CERT" = true ]; then
    print_section "Step 5: Removing SSL Certificates"

    if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "null" ]; then
        CERT_DOMAIN_DIR="${CERT_DIR}/${DOMAIN}"
        if [ -d "$CERT_DOMAIN_DIR" ]; then
            rm -rf "$CERT_DOMAIN_DIR"
            REMOVED_ITEMS+=("SSL certificates: $CERT_DOMAIN_DIR")
            print_success "Removed SSL certificates"
        else
            print_info "Certificate directory not found (may not exist)"
        fi
    else
        print_warning "Domain not found in registry, skipping certificate removal"
    fi
fi

# Step 6: Validate and reload nginx
print_section "Step 6: Validating and Reloading Nginx"

# Check if nginx container is running
if docker compose -f "${NGINX_PROJECT_DIR}/docker-compose.yml" ps nginx 2>/dev/null | grep -q "Up"; then
    print_detail "Testing nginx configuration..."
    if docker compose -f "${NGINX_PROJECT_DIR}/docker-compose.yml" exec nginx nginx -t 2>&1 | grep -q "syntax is ok"; then
        print_success "Nginx configuration is valid"
        
        print_detail "Reloading nginx..."
        if docker compose -f "${NGINX_PROJECT_DIR}/docker-compose.yml" exec nginx nginx -s reload 2>&1; then
            REMOVED_ITEMS+=("Nginx reloaded successfully")
            print_success "Nginx reloaded successfully"
        else
            FAILED_ITEMS+=("Nginx reload")
            print_warning "Failed to reload nginx. Please reload manually:"
            echo "   docker compose -f ${NGINX_PROJECT_DIR}/docker-compose.yml exec nginx nginx -s reload"
        fi
    else
        FAILED_ITEMS+=("Nginx config test")
        print_error "Nginx configuration test failed!"
        print_warning "Nginx was not reloaded. Please fix configuration issues manually."
    fi
else
    print_warning "Nginx container is not running. Skipping nginx validation and reload."
    print_info "You may need to start nginx and reload manually after removal."
    FAILED_ITEMS+=("Nginx container not running")
fi

# Summary
echo ""
print_header "Removal Summary"
echo ""

if [ ${#REMOVED_ITEMS[@]} -gt 0 ]; then
    print_success "Successfully removed:"
    for item in "${REMOVED_ITEMS[@]}"; do
        echo "  ✓ $item"
    done
    echo ""
fi

if [ ${#FAILED_ITEMS[@]} -gt 0 ]; then
    print_warning "Failed or skipped:"
    for item in "${FAILED_ITEMS[@]}"; do
        echo "  ⚠ $item"
    done
    echo ""
fi

if [ ${#FAILED_ITEMS[@]} -eq 0 ]; then
    print_success "Microservice '$SERVICE_NAME' has been completely removed from the system!"
else
    print_warning "Microservice '$SERVICE_NAME' removal completed with some warnings."
    print_info "Please review the failed items above and handle them manually if needed."
fi

echo ""

