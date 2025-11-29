#!/bin/bash
# Central Service Status Script (Optimized)
# Shows status of all services and applications
# Usage: status-all-services.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTRY_DIR="${NGINX_PROJECT_DIR}/service-registry"
BLUE_GREEN_DIR="${SCRIPT_DIR}/blue-green"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Status symbols
GREEN_CHECK='\033[0;32m✓\033[0m'
RED_X='\033[0;31m✗\033[0m'

# Performance optimization: Cache docker ps output
DOCKER_PS_CACHE=""
DOCKER_PS_NAMES_CACHE=""
DOCKER_PS_STATUS_CACHE=""

# Performance optimization: Cache registry JSON files
declare -A REGISTRY_CACHE

# Performance optimization: Cache service status results
declare -A SERVICE_STATUS_CACHE
declare -A SERVICE_DOMAIN_CACHE
declare -A SERVICE_HEALTH_CACHE

# Function to get timestamp
get_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

print_status() {
    echo -e "${BLUE}[INFO]${NC} [$(get_timestamp)] $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} [$(get_timestamp)] $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} [$(get_timestamp)] $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} [$(get_timestamp)] $1"
}

print_detail() {
    echo -e "${CYAN}[DETAIL]${NC} [$(get_timestamp)] $1"
}

# Service categories
INFRASTRUCTURE_SERVICES=(
    "nginx-microservice"
    "database-server"
)

MICROSERVICES=(
    "logging-microservice"
    "auth-microservice"
    "payment-microservice"
    "notifications-microservice"
)

APPLICATIONS=(
    "crypto-ai-agent"
    "statex"
    "e-commerce"
)

# Initialize caches - call once at start
initialize_caches() {
    print_detail "Initializing caches..."
    # Cache docker ps output (all containers)
    DOCKER_PS_CACHE=$(docker ps --format "{{.Names}}\t{{.Status}}\t{{.Image}}" 2>/dev/null || echo "")
    DOCKER_PS_NAMES_CACHE=$(echo "$DOCKER_PS_CACHE" | awk '{print $1}' || echo "")
    DOCKER_PS_STATUS_CACHE=$(docker ps --format "{{.Names}}\t{{.Status}}" 2>/dev/null || echo "")
}

# Optimized: Check if container is running using cache
container_running() {
    local container_name="$1"
    echo "$DOCKER_PS_NAMES_CACHE" | grep -qE "^${container_name}$"
}

# Optimized: Get container status from cache
get_container_status_from_cache() {
    local container_name="$1"
    echo "$DOCKER_PS_STATUS_CACHE" | grep -E "^${container_name}" | awk '{print $2}' || echo ""
}

# Function to check if service registry exists
service_exists() {
    local service_name="$1"
    [ -f "${REGISTRY_DIR}/${service_name}.json" ]
}

# Optimized: Load and cache registry JSON
load_registry_cache() {
    local service_name="$1"
    
    if [ -z "${REGISTRY_CACHE[$service_name]}" ]; then
        local registry_file="${REGISTRY_DIR}/${service_name}.json"
        if [ -f "$registry_file" ]; then
            REGISTRY_CACHE[$service_name]=$(cat "$registry_file" 2>/dev/null || echo "")
        else
            REGISTRY_CACHE[$service_name]=""
        fi
    fi
    echo "${REGISTRY_CACHE[$service_name]}"
}

# Optimized: Get container status using cached data
get_container_status() {
    local service_name="$1"
    
    # Check cache first
    if [ -n "${SERVICE_STATUS_CACHE[$service_name]}" ]; then
        echo "${SERVICE_STATUS_CACHE[$service_name]}"
        return
    fi
    
    local registry=$(load_registry_cache "$service_name")
    
    if [ -z "$registry" ]; then
        SERVICE_STATUS_CACHE[$service_name]="not-registered"
        echo "not-registered"
        return
    fi
    
    local service_keys=$(echo "$registry" | jq -r '.services | keys[]' 2>/dev/null || echo "")
    
    if [ -z "$service_keys" ]; then
        SERVICE_STATUS_CACHE[$service_name]="no-services"
        echo "no-services"
        return
    fi
    
    local running_count=0
    local total_count=0
    
    while IFS= read -r service_key; do
        local container_base=$(echo "$registry" | jq -r ".services[\"$service_key\"].container_name_base // empty" 2>/dev/null)
        if [ -n "$container_base" ] && [ "$container_base" != "null" ]; then
            total_count=$((total_count + 1))
            # Check for blue, green, or base container name using cache
            if echo "$DOCKER_PS_NAMES_CACHE" | grep -qE "^${container_base}(-blue|-green)?$"; then
                running_count=$((running_count + 1))
            fi
        fi
    done <<< "$service_keys"
    
    local result
    if [ $total_count -eq 0 ]; then
        result="no-services"
    elif [ $running_count -eq $total_count ]; then
        result="running"
    elif [ $running_count -gt 0 ]; then
        result="partial"
    else
        result="stopped"
    fi
    
    SERVICE_STATUS_CACHE[$service_name]="$result"
    echo "$result"
}

# Function to check service health (kept as-is, but results cached)
check_service_health() {
    local service_name="$1"
    
    # Check cache first
    if [ -n "${SERVICE_HEALTH_CACHE[$service_name]}" ]; then
        return "${SERVICE_HEALTH_CACHE[$service_name]}"
    fi
    
    if ! service_exists "$service_name"; then
        SERVICE_HEALTH_CACHE[$service_name]=1
        return 1
    fi
    
    # Use health-check.sh if available
    if [ -f "${BLUE_GREEN_DIR}/health-check.sh" ]; then
        if "${BLUE_GREEN_DIR}/health-check.sh" "$service_name" >/dev/null 2>&1; then
            SERVICE_HEALTH_CACHE[$service_name]=0
            return 0
        else
            SERVICE_HEALTH_CACHE[$service_name]=1
            return 1
        fi
    fi
    
    SERVICE_HEALTH_CACHE[$service_name]=1
    return 1
}

# Optimized: Get domain from registry using cache
get_service_domain() {
    local service_name="$1"
    
    # Check cache first
    if [ -n "${SERVICE_DOMAIN_CACHE[$service_name]}" ]; then
        echo "${SERVICE_DOMAIN_CACHE[$service_name]}"
        return
    fi
    
    local registry=$(load_registry_cache "$service_name")
    
    if [ -z "$registry" ]; then
        SERVICE_DOMAIN_CACHE[$service_name]=""
        echo ""
        return
    fi
    
    local domain=$(echo "$registry" | jq -r '.domain // empty' 2>/dev/null || echo "")
    SERVICE_DOMAIN_CACHE[$service_name]="$domain"
    echo "$domain"
}

# Helper function to format infrastructure container status
format_infrastructure_status() {
    local container_name="$1"
    local status="$2"
    
    if [ -z "$status" ]; then
        echo -e "  ${RED_X} $container_name: Not running"
        return
    fi
    
    if echo "$status" | grep -qE "unhealthy"; then
        echo -e "  ${RED_X} $container_name: $status"
    elif echo "$status" | grep -qE "healthy"; then
        echo -e "  ${GREEN_CHECK} $container_name: $status"
    elif echo "$status" | grep -qE "Up"; then
        echo -e "  ${YELLOW}⚠${NC}  $container_name: $status"
    else
        echo -e "  ${RED_X} $container_name: $status"
    fi
}

# Main execution
print_status "=========================================="
print_status "Service Status Report"
print_status "=========================================="
print_status ""

# Initialize caches once at start
initialize_caches

# Infrastructure Services
print_status "=========================================="
print_status "Infrastructure Services"
print_status "=========================================="

# Cache infrastructure container statuses
NGINX_STATUS=$(get_container_status_from_cache "nginx-microservice")
NGINX_CERTBOT_STATUS=$(get_container_status_from_cache "nginx-certbot")
POSTGRES_STATUS=$(get_container_status_from_cache "db-server-postgres")
REDIS_STATUS=$(get_container_status_from_cache "db-server-redis")

for service in "${INFRASTRUCTURE_SERVICES[@]}"; do
    if [ "$service" = "nginx-microservice" ]; then
        format_infrastructure_status "nginx-microservice" "$NGINX_STATUS"
        format_infrastructure_status "nginx-certbot" "$NGINX_CERTBOT_STATUS"
    elif [ "$service" = "database-server" ]; then
        format_infrastructure_status "db-server-postgres" "$POSTGRES_STATUS"
        format_infrastructure_status "db-server-redis" "$REDIS_STATUS"
    fi
done

print_status ""

# Helper function to display service status
display_service_status() {
    local service="$1"
    local container_status="$2"
    local domain="$3"
    local is_healthy="$4"
    
    case "$container_status" in
        "running")
            if [ "$is_healthy" = "0" ]; then
                echo -e "  ${GREEN_CHECK} $service: Running and healthy"
                if [ -n "$domain" ] && [ "$domain" != "null" ]; then
                    echo -e "    Domain: $domain"
                fi
            else
                echo -e "  ${RED_X} $service: Running but health check failed"
                if [ -n "$domain" ] && [ "$domain" != "null" ]; then
                    echo -e "    Domain: $domain"
                fi
            fi
            ;;
        "partial")
            echo -e "  ${RED_X} $service: Partially running"
            ;;
        "stopped")
            echo -e "  ${RED_X} $service: Stopped"
            ;;
        "not-registered")
            echo -e "  ${RED_X} $service: Not registered"
            ;;
        "no-services")
            echo -e "  ${RED_X} $service: No services defined"
            ;;
    esac
}

# Microservices
print_status "=========================================="
print_status "Microservices"
print_status "=========================================="

# Store results for dashboard reuse
declare -A MICROSERVICE_RESULTS

for service in "${MICROSERVICES[@]}"; do
    container_status=$(get_container_status "$service")
    domain=$(get_service_domain "$service")
    
    # Check health and store result
    check_service_health "$service"
    health_result=$?
    
    # Store for dashboard
    MICROSERVICE_RESULTS["${service}_status"]="$container_status"
    MICROSERVICE_RESULTS["${service}_domain"]="$domain"
    MICROSERVICE_RESULTS["${service}_health"]="$health_result"
    
    display_service_status "$service" "$container_status" "$domain" "$health_result"
done

print_status ""

# Applications
print_status "=========================================="
print_status "Applications"
print_status "=========================================="

# Store results for dashboard reuse
declare -A APPLICATION_RESULTS

for service in "${APPLICATIONS[@]}"; do
    container_status=$(get_container_status "$service")
    domain=$(get_service_domain "$service")
    
    # Check health and store result
    check_service_health "$service"
    health_result=$?
    
    # Store for dashboard
    APPLICATION_RESULTS["${service}_status"]="$container_status"
    APPLICATION_RESULTS["${service}_domain"]="$domain"
    APPLICATION_RESULTS["${service}_health"]="$health_result"
    
    display_service_status "$service" "$container_status" "$domain" "$health_result"
done

print_status ""
print_status "=========================================="
print_status "Container Summary"
print_status "=========================================="
print_detail "All running containers:"
echo "$DOCKER_PS_CACHE" | head -30

print_status ""
print_detail "Container health status:"
echo "$DOCKER_PS_STATUS_CACHE" | head -30 | while IFS=$'\t' read -r name status; do
    if echo "$status" | grep -qE "unhealthy"; then
        echo -e "  ${RED_X} $name: $status"
    elif echo "$status" | grep -qE "healthy"; then
        echo -e "  ${GREEN_CHECK} $name: $status"
    elif echo "$status" | grep -qE "Up"; then
        echo -e "  ${YELLOW}⚠${NC}  $name: $status"
    else
        echo -e "  ${RED_X} $name: $status"
    fi
done

# Check for unhealthy containers using cache
print_status ""
print_detail "Checking for unhealthy containers..."
if echo "$DOCKER_PS_STATUS_CACHE" | grep -qE "Restarting|Unhealthy|Exited"; then
    print_warning "Some containers are ${RED_X} not healthy:"
    echo "$DOCKER_PS_STATUS_CACHE" | grep -E "Restarting|Unhealthy|Exited" | sed "s/^/  ${RED_X} /" || true
else
    print_success "All running containers appear ${GREEN_CHECK} healthy"
fi

# Check stopped containers (still need docker ps -a for stopped)
print_status ""
print_detail "Stopped containers:"
STOPPED_COUNT=$(docker ps -a --filter "status=exited" --format "{{.Names}}" 2>/dev/null | wc -l)
if [ "$STOPPED_COUNT" -gt 0 ]; then
    print_detail "$STOPPED_COUNT container(s) stopped:"
    docker ps -a --filter "status=exited" --format "  - {{.Names}}: {{.Status}}" 2>&1 | head -20
else
    print_success "No stopped containers"
fi

# Helper function to format dashboard status
format_dashboard_status() {
    local status="$1"
    local icon_var="$2"
    local status_text_var="$3"
    
    if [ -z "$status" ]; then
        eval "$icon_var='${RED_X}'"
        eval "$status_text_var='STOPPED'"
        return
    fi
    
    if echo "$status" | grep -qE "unhealthy"; then
        eval "$icon_var='${RED_X}'"
        eval "$status_text_var='UNHEALTHY'"
    elif echo "$status" | grep -qE "healthy"; then
        eval "$icon_var='${GREEN_CHECK}'"
        eval "$status_text_var='HEALTHY'"
    elif echo "$status" | grep -qE "Up"; then
        eval "$icon_var='${YELLOW}⚠${NC}'"
        eval "$status_text_var='RUNNING'"
    else
        eval "$icon_var='${RED_X}'"
        eval "$status_text_var='STOPPED'"
    fi
}

# Final Dashboard
print_status ""
print_status "=========================================="
print_status "Service Dashboard"
print_status "=========================================="
print_status ""

# Print table header
echo -e "SERVICE                             STATUS          DOMAIN"
echo -e "----------------------------------- --------------- ----------------------------------------"

# Infrastructure Services (using cached statuses)
for service in "${INFRASTRUCTURE_SERVICES[@]}"; do
    if [ "$service" = "nginx-microservice" ]; then
        format_dashboard_status "$NGINX_STATUS" "icon" "status_text"
        echo -e "$(printf '%-35s' 'nginx-microservice')$icon $(printf '%-12s' "$status_text")$(printf '%-40s' 'N/A')"
        
        if [ -n "$NGINX_CERTBOT_STATUS" ]; then
            echo -e "$(printf '%-35s' 'nginx-certbot')${GREEN_CHECK} $(printf '%-12s' 'RUNNING')$(printf '%-40s' 'N/A')"
        else
            echo -e "$(printf '%-35s' 'nginx-certbot')${RED_X} $(printf '%-12s' 'STOPPED')$(printf '%-40s' 'N/A')"
        fi
    elif [ "$service" = "database-server" ]; then
        format_dashboard_status "$POSTGRES_STATUS" "icon" "status_text"
        echo -e "$(printf '%-35s' 'db-server-postgres')$icon $(printf '%-12s' "$status_text")$(printf '%-40s' 'N/A')"
        
        format_dashboard_status "$REDIS_STATUS" "icon" "status_text"
        echo -e "$(printf '%-35s' 'db-server-redis')$icon $(printf '%-12s' "$status_text")$(printf '%-40s' 'N/A')"
    fi
done

# Microservices (using stored results)
for service in "${MICROSERVICES[@]}"; do
    container_status="${MICROSERVICE_RESULTS["${service}_status"]}"
    domain="${MICROSERVICE_RESULTS["${service}_domain"]}"
    health_result="${MICROSERVICE_RESULTS["${service}_health"]}"
    
    case "$container_status" in
        "running")
            if [ "$health_result" = "0" ]; then
                icon="${GREEN_CHECK}"
                status_text="HEALTHY"
            else
                icon="${RED_X}"
                status_text="UNHEALTHY"
            fi
            ;;
        "partial")
            icon="${RED_X}"
            status_text="PARTIAL"
            ;;
        "stopped")
            icon="${RED_X}"
            status_text="STOPPED"
            ;;
        "not-registered")
            icon="${RED_X}"
            status_text="NOT REGISTERED"
            ;;
        "no-services")
            icon="${RED_X}"
            status_text="NO SERVICES"
            ;;
        *)
            icon="${RED_X}"
            status_text="UNKNOWN"
            ;;
    esac
    
    if [ -z "$domain" ] || [ "$domain" = "null" ]; then
        domain="N/A"
    fi
    
    echo -e "$(printf '%-35s' "$service")$icon $(printf '%-12s' "$status_text")$(printf '%-40s' "$domain")"
done

# Applications (using stored results)
for service in "${APPLICATIONS[@]}"; do
    container_status="${APPLICATION_RESULTS["${service}_status"]}"
    domain="${APPLICATION_RESULTS["${service}_domain"]}"
    health_result="${APPLICATION_RESULTS["${service}_health"]}"
    
    case "$container_status" in
        "running")
            if [ "$health_result" = "0" ]; then
                icon="${GREEN_CHECK}"
                status_text="HEALTHY"
            else
                icon="${RED_X}"
                status_text="UNHEALTHY"
            fi
            ;;
        "partial")
            icon="${RED_X}"
            status_text="PARTIAL"
            ;;
        "stopped")
            icon="${RED_X}"
            status_text="STOPPED"
            ;;
        "not-registered")
            icon="${RED_X}"
            status_text="NOT REGISTERED"
            ;;
        "no-services")
            icon="${RED_X}"
            status_text="NO SERVICES"
            ;;
        *)
            icon="${RED_X}"
            status_text="UNKNOWN"
            ;;
    esac
    
    if [ -z "$domain" ] || [ "$domain" = "null" ]; then
        domain="N/A"
    fi
    
    echo -e "$(printf '%-35s' "$service")$icon $(printf '%-12s' "$status_text")$(printf '%-40s' "$domain")"
done

print_status ""

exit 0

