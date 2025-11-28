#!/bin/bash
# Central Service Status Script
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

# Function to check if service registry exists
service_exists() {
    local service_name="$1"
    [ -f "${REGISTRY_DIR}/${service_name}.json" ]
}

# Function to check if container is running
container_running() {
    local container_name="$1"
    docker ps --format "{{.Names}}" | grep -qE "^${container_name}$"
}

# Function to get container status
get_container_status() {
    local service_name="$1"
    local registry_file="${REGISTRY_DIR}/${service_name}.json"
    
    if [ ! -f "$registry_file" ]; then
        echo "not-registered"
        return
    fi
    
    local registry=$(cat "$registry_file" 2>/dev/null)
    local service_keys=$(echo "$registry" | jq -r '.services | keys[]' 2>/dev/null || echo "")
    
    if [ -z "$service_keys" ]; then
        echo "no-services"
        return
    fi
    
    local running_count=0
    local total_count=0
    
    while IFS= read -r service_key; do
        local container_base=$(echo "$registry" | jq -r ".services[\"$service_key\"].container_name_base // empty" 2>/dev/null)
        if [ -n "$container_base" ] && [ "$container_base" != "null" ]; then
            total_count=$((total_count + 1))
            # Check for blue, green, or base container name
            if docker ps --format "{{.Names}}" | grep -qE "^${container_base}(-blue|-green)?$"; then
                running_count=$((running_count + 1))
            fi
        fi
    done <<< "$service_keys"
    
    if [ $total_count -eq 0 ]; then
        echo "no-services"
    elif [ $running_count -eq $total_count ]; then
        echo "running"
    elif [ $running_count -gt 0 ]; then
        echo "partial"
    else
        echo "stopped"
    fi
}

# Function to check service health
check_service_health() {
    local service_name="$1"
    
    if ! service_exists "$service_name"; then
        return 1
    fi
    
    # Use health-check.sh if available
    if [ -f "${BLUE_GREEN_DIR}/health-check.sh" ]; then
        "${BLUE_GREEN_DIR}/health-check.sh" "$service_name" >/dev/null 2>&1
        return $?
    fi
    
    return 1
}

# Function to get domain from registry
get_service_domain() {
    local service_name="$1"
    local registry_file="${REGISTRY_DIR}/${service_name}.json"
    
    if [ -f "$registry_file" ] && command -v jq >/dev/null 2>&1; then
        jq -r '.domain // empty' "$registry_file" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# Main execution
print_status "=========================================="
print_status "Service Status Report"
print_status "=========================================="
print_status ""

# Infrastructure Services
print_status "=========================================="
print_status "Infrastructure Services"
print_status "=========================================="

for service in "${INFRASTRUCTURE_SERVICES[@]}"; do
    if [ "$service" = "nginx-microservice" ]; then
        if container_running "nginx-microservice"; then
            status=$(docker ps --filter "name=nginx-microservice" --format "{{.Status}}" | head -1)
            if echo "$status" | grep -qE "unhealthy"; then
                echo -e "  ${RED_X} nginx-microservice: $status"
            elif echo "$status" | grep -qE "healthy"; then
                echo -e "  ${GREEN_CHECK} nginx-microservice: $status"
            elif echo "$status" | grep -qE "Up"; then
                echo -e "  ${YELLOW}⚠${NC}  nginx-microservice: $status"
            else
                echo -e "  ${RED_X} nginx-microservice: $status"
            fi
        else
            echo -e "  ${RED_X} nginx-microservice: Not running"
        fi
        
        if container_running "nginx-certbot"; then
            status=$(docker ps --filter "name=nginx-certbot" --format "{{.Status}}" | head -1)
            if echo "$status" | grep -qE "unhealthy"; then
                echo -e "  ${RED_X} nginx-certbot: $status"
            elif echo "$status" | grep -qE "healthy|Up"; then
                echo -e "  ${GREEN_CHECK} nginx-certbot: $status"
            else
                echo -e "  ${RED_X} nginx-certbot: $status"
            fi
        else
            echo -e "  ${RED_X} nginx-certbot: Not running"
        fi
    elif [ "$service" = "database-server" ]; then
        if container_running "db-server-postgres"; then
            status=$(docker ps --filter "name=db-server-postgres" --format "{{.Status}}" | head -1)
            if echo "$status" | grep -qE "unhealthy"; then
                echo -e "  ${RED_X} db-server-postgres: $status"
            elif echo "$status" | grep -qE "healthy"; then
                echo -e "  ${GREEN_CHECK} db-server-postgres: $status"
            elif echo "$status" | grep -qE "Up"; then
                echo -e "  ${YELLOW}⚠${NC}  db-server-postgres: $status"
            else
                echo -e "  ${RED_X} db-server-postgres: $status"
            fi
        else
            echo -e "  ${RED_X} db-server-postgres: Not running"
        fi
        
        if container_running "db-server-redis"; then
            status=$(docker ps --filter "name=db-server-redis" --format "{{.Status}}" | head -1)
            if echo "$status" | grep -qE "unhealthy"; then
                echo -e "  ${RED_X} db-server-redis: $status"
            elif echo "$status" | grep -qE "healthy"; then
                echo -e "  ${GREEN_CHECK} db-server-redis: $status"
            elif echo "$status" | grep -qE "Up"; then
                echo -e "  ${YELLOW}⚠${NC}  db-server-redis: $status"
            else
                echo -e "  ${RED_X} db-server-redis: $status"
            fi
        else
            echo -e "  ${RED_X} db-server-redis: Not running"
        fi
    fi
done

print_status ""

# Microservices
print_status "=========================================="
print_status "Microservices"
print_status "=========================================="

for service in "${MICROSERVICES[@]}"; do
    container_status=$(get_container_status "$service")
    domain=$(get_service_domain "$service")
    
    case "$container_status" in
        "running")
            if check_service_health "$service"; then
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
done

print_status ""

# Applications
print_status "=========================================="
print_status "Applications"
print_status "=========================================="

for service in "${APPLICATIONS[@]}"; do
    container_status=$(get_container_status "$service")
    domain=$(get_service_domain "$service")
    
    case "$container_status" in
        "running")
            if check_service_health "$service"; then
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
done

print_status ""
print_status "=========================================="
print_status "Container Summary"
print_status "=========================================="
print_detail "All running containers:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" 2>&1 | head -30

print_status ""
print_detail "Container health status:"
docker ps --format "{{.Names}}\t{{.Status}}" 2>&1 | head -30 | while IFS=$'\t' read -r name status; do
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

# Check for unhealthy containers
print_status ""
print_detail "Checking for unhealthy containers..."
if docker ps --format "{{.Names}}\t{{.Status}}" 2>&1 | grep -qE "Restarting|Unhealthy|Exited"; then
    print_warning "Some containers are ${RED_X} not healthy:"
    docker ps --format "{{.Names}}\t{{.Status}}" 2>&1 | grep -E "Restarting|Unhealthy|Exited" | sed "s/^/  ${RED_X} /" || true
else
    print_success "All running containers appear ${GREEN_CHECK} healthy"
fi

# Check stopped containers
print_status ""
print_detail "Stopped containers:"
STOPPED_COUNT=$(docker ps -a --filter "status=exited" --format "{{.Names}}" | wc -l)
if [ "$STOPPED_COUNT" -gt 0 ]; then
    print_detail "$STOPPED_COUNT container(s) stopped:"
    docker ps -a --filter "status=exited" --format "  - {{.Names}}: {{.Status}}" 2>&1 | head -20
else
    print_success "No stopped containers"
fi

# Final Dashboard
print_status ""
print_status "=========================================="
print_status "Service Dashboard"
print_status "=========================================="
print_status ""

# Print table header
echo -e "SERVICE                             STATUS          DOMAIN"
echo -e "----------------------------------- --------------- ----------------------------------------"

# Infrastructure Services
for service in "${INFRASTRUCTURE_SERVICES[@]}"; do
    if [ "$service" = "nginx-microservice" ]; then
        if container_running "nginx-microservice"; then
            status=$(docker ps --filter "name=nginx-microservice" --format "{{.Status}}" | head -1)
            if echo "$status" | grep -qE "unhealthy"; then
                icon="${RED_X}"
                status_text="UNHEALTHY"
            elif echo "$status" | grep -qE "healthy"; then
                icon="${GREEN_CHECK}"
                status_text="HEALTHY"
            else
                icon="${YELLOW}⚠${NC}"
                status_text="RUNNING"
            fi
        else
            icon="${RED_X}"
            status_text="STOPPED"
        fi
        echo -e "$(printf '%-35s' 'nginx-microservice')$icon $(printf '%-12s' "$status_text")$(printf '%-40s' 'N/A')"
        
        if container_running "nginx-certbot"; then
            echo -e "$(printf '%-35s' 'nginx-certbot')${GREEN_CHECK} $(printf '%-12s' 'RUNNING')$(printf '%-40s' 'N/A')"
        else
            echo -e "$(printf '%-35s' 'nginx-certbot')${RED_X} $(printf '%-12s' 'STOPPED')$(printf '%-40s' 'N/A')"
        fi
    elif [ "$service" = "database-server" ]; then
        if container_running "db-server-postgres"; then
            status=$(docker ps --filter "name=db-server-postgres" --format "{{.Status}}" | head -1)
            if echo "$status" | grep -qE "unhealthy"; then
                icon="${RED_X}"
                status_text="UNHEALTHY"
            elif echo "$status" | grep -qE "healthy"; then
                icon="${GREEN_CHECK}"
                status_text="HEALTHY"
            else
                icon="${YELLOW}⚠${NC}"
                status_text="RUNNING"
            fi
        else
            icon="${RED_X}"
            status_text="STOPPED"
        fi
        echo -e "$(printf '%-35s' 'db-server-postgres')$icon $(printf '%-12s' "$status_text")$(printf '%-40s' 'N/A')"
        
        if container_running "db-server-redis"; then
            status=$(docker ps --filter "name=db-server-redis" --format "{{.Status}}" | head -1)
            if echo "$status" | grep -qE "unhealthy"; then
                icon="${RED_X}"
                status_text="UNHEALTHY"
            elif echo "$status" | grep -qE "healthy"; then
                icon="${GREEN_CHECK}"
                status_text="HEALTHY"
            else
                icon="${YELLOW}⚠${NC}"
                status_text="RUNNING"
            fi
        else
            icon="${RED_X}"
            status_text="STOPPED"
        fi
        echo -e "$(printf '%-35s' 'db-server-redis')$icon $(printf '%-12s' "$status_text")$(printf '%-40s' 'N/A')"
    fi
done

# Microservices
for service in "${MICROSERVICES[@]}"; do
    container_status=$(get_container_status "$service")
    domain=$(get_service_domain "$service")
    
    case "$container_status" in
        "running")
            if check_service_health "$service"; then
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

# Applications
for service in "${APPLICATIONS[@]}"; do
    container_status=$(get_container_status "$service")
    domain=$(get_service_domain "$service")
    
    case "$container_status" in
        "running")
            if check_service_health "$service"; then
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

