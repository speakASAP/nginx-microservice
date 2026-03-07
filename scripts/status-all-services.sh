#!/bin/bash
# Central Service Status Script (Fast - docker ps only by default)
# Shows status of all services and applications from docker ps (no health checks by default).
# Usage: status-all-services.sh [--health]
#   --health  Optional: run HTTP health checks (slower).

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTRY_DIR="${NGINX_PROJECT_DIR}/service-registry"
BLUE_GREEN_DIR="${SCRIPT_DIR}/blue-green"

# Fast mode: no health checks (default). Use --health to enable.
RUN_HEALTH_CHECKS=0
for arg in "$@"; do
    if [ "$arg" = "--health" ]; then
        RUN_HEALTH_CHECKS=1
        break
    fi
done

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

# Known ecosystem services (from shared/README.md) - show even if not in registry
ECOSYSTEM_MICROSERVICES=(
    "ai-microservice"
    "auth-microservice"
    "catalog-microservice"
    "leads-microservice"
    "logging-microservice"
    "minio-microservice"
    "notifications-microservice"
    "orders-microservice"
    "payments-microservice"
    "suppliers-microservice"
    "warehouse-microservice"
)
ECOSYSTEM_APPLICATIONS=(
    "agentic-email-processing-system"
    "allegro-service"
    "aukro-service"
    "bazos-service"
    "beauty"
    "crypto-ai-agent"
    "flipflop-service"
    "heureka-service"
    "marathon"
    "messenger"
    "shop-assistant"
    "sgiprealestate"
    "speakasap"
    "speakasap-portal"
    "statex"
)

# Derive service name from container name (e.g. flipflop-service-blue -> flipflop-service)
service_name_from_container() {
    local name="$1"
    echo "$name" | sed -E 's/-blue$|-green$//'
}

# Discover services from docker ps (container names) - fast
discover_services_from_docker() {
    local names="$1"
    local seen=""
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local svc=$(service_name_from_container "$line")
        if [ -n "$svc" ] && [[ " $seen " != *" $svc "* ]]; then
            seen="$seen $svc"
            echo "$svc"
        fi
    done <<< "$names"
}

# Dynamically discover services from service-registry directory
discover_services() {
    local registry_dir="$1"
    local services=()
    
    if [ ! -d "$registry_dir" ]; then
        return
    fi
    
    # Find all .json files in service-registry (excluding backups)
    while IFS= read -r registry_file; do
        local service_name=$(basename "$registry_file" .json)
        # Skip backup files
        if [[ "$service_name" != *".backup" ]] && [[ "$service_name" != *".bak" ]]; then
            services+=("$service_name")
        fi
    done < <(find "$registry_dir" -maxdepth 1 -name "*.json" -type f 2>/dev/null | sort)
    
    # Output services as newline-separated list
    printf '%s\n' "${services[@]}"
}

# Merge: registry + ecosystem only (one row per service/app; docker ps used only for status)
merge_all_services() {
    local registry_services=($(discover_services "$REGISTRY_DIR"))
    local combined=("${registry_services[@]}" "${ECOSYSTEM_MICROSERVICES[@]}" "${ECOSYSTEM_APPLICATIONS[@]}")
    printf '%s\n' "${combined[@]}" | sort -u
}

# Merge: registry + ecosystem + services from docker ps (no duplicates, sorted)
# Call with docker container names (e.g. DOCKER_PS_NAMES_CACHE) after initialize_caches
merge_all_services() {
    local docker_names="$1"
    local registry_services=($(discover_services "$REGISTRY_DIR"))
    local from_docker=($(discover_services_from_docker "$docker_names"))
    local combined=("${registry_services[@]}" "${ECOSYSTEM_MICROSERVICES[@]}" "${ECOSYSTEM_APPLICATIONS[@]}" "${from_docker[@]}")
    printf '%s\n' "${combined[@]}" | sort -u
}

# Categorize services (filled after merge_all_services in main)
MICROSERVICES=()
APPLICATIONS=()

# Initialize caches - call once at start (containers sorted by name)
initialize_caches() {
    print_detail "Initializing caches..."
    # Cache docker ps output, sorted by container name
    DOCKER_PS_CACHE=$(docker ps --format "{{.Names}}\t{{.Status}}\t{{.Image}}" 2>/dev/null | sort -t$'\t' -k1 || echo "")
    DOCKER_PS_NAMES_CACHE=$(echo "$DOCKER_PS_CACHE" | awk -F'\t' '{print $1}' || echo "")
    DOCKER_PS_STATUS_CACHE=$(docker ps --format "{{.Names}}\t{{.Status}}" 2>/dev/null | sort -t$'\t' -k1 || echo "")
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

# Optimized: Get container status using cached data (registry + docker ps)
get_container_status() {
    local service_name="$1"
    
    if [ -n "${SERVICE_STATUS_CACHE[$service_name]}" ]; then
        echo "${SERVICE_STATUS_CACHE[$service_name]}"
        return
    fi
    
    # Fast path: any container matching service name (from docker ps)?
    if echo "$DOCKER_PS_NAMES_CACHE" | grep -qE "^${service_name}(-blue|-green)?$"; then
        SERVICE_STATUS_CACHE[$service_name]="running"
        echo "running"
        return
    fi
    
    local registry=$(load_registry_cache "$service_name")
    if [ -z "$registry" ]; then
        SERVICE_STATUS_CACHE[$service_name]="stopped"
        echo "stopped"
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
    # Run in subshell to prevent script exit on failure
    if [ -f "${BLUE_GREEN_DIR}/health-check.sh" ]; then
        (set +e; "${BLUE_GREEN_DIR}/health-check.sh" "$service_name" >/dev/null 2>&1)
        local health_result=$?
        if [ $health_result -eq 0 ]; then
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
        echo -e "  ${GREEN_CHECK} $container_name: $status"
    else
        echo -e "  ${RED_X} $container_name: $status"
    fi
}

# Main execution
print_status "=========================================="
print_status "Service Status Report"
print_status "=========================================="
if [ "$RUN_HEALTH_CHECKS" -eq 0 ]; then
    print_detail "Fast mode: status from docker ps only. Use --health for HTTP health checks."
fi
print_status ""

# Initialize caches once at start
initialize_caches

# Build full service list from registry + ecosystem, then categorize and sort by name
ALL_DISCOVERED_SERVICES=($(merge_all_services))
for service in "${ALL_DISCOVERED_SERVICES[@]}"; do
    if [[ "$service" == *"-microservice" ]]; then
        MICROSERVICES+=("$service")
    else
        if [[ "$service" != "nginx-microservice" ]] && [[ "$service" != "database-server" ]]; then
            APPLICATIONS+=("$service")
        fi
    fi
done
# Sort microservices and applications by name
MICROSERVICES=($(printf '%s\n' "${MICROSERVICES[@]}" | sort))
APPLICATIONS=($(printf '%s\n' "${APPLICATIONS[@]}" | sort))

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

# Store results for dashboard reuse and grouping
declare -A MICROSERVICE_RESULTS
declare -A APPLICATION_RESULTS

# Temporarily disable exit on error for the loop
set +e
for service in "${MICROSERVICES[@]}"; do
    container_status=$(get_container_status "$service" || echo "not-registered")
    domain=$(get_service_domain "$service" || echo "")
    if [ "$RUN_HEALTH_CHECKS" -eq 1 ]; then
        check_service_health "$service" || true
        health_result=$?
    else
        [ "$container_status" = "running" ] && health_result=0 || health_result=1
    fi
    MICROSERVICE_RESULTS["${service}_status"]="$container_status"
    MICROSERVICE_RESULTS["${service}_domain"]="$domain"
    MICROSERVICE_RESULTS["${service}_health"]="$health_result"
done
for service in "${APPLICATIONS[@]}"; do
    container_status=$(get_container_status "$service" || echo "not-registered")
    domain=$(get_service_domain "$service" || echo "")
    if [ "$RUN_HEALTH_CHECKS" -eq 1 ]; then
        check_service_health "$service" || true
        health_result=$?
    else
        [ "$container_status" = "running" ] && health_result=0 || health_result=1
    fi
    APPLICATION_RESULTS["${service}_status"]="$container_status"
    APPLICATION_RESULTS["${service}_domain"]="$domain"
    APPLICATION_RESULTS["${service}_health"]="$health_result"
done
set -e

# Group services by status (running+healthy, unhealthy/partial, stopped)
RUNNING_HEALTHY=()
UNHEALTHY_PARTIAL=()
STOPPED_OTHER=()
for name in nginx-microservice nginx-certbot db-server-postgres db-server-redis "${MICROSERVICES[@]}" "${APPLICATIONS[@]}"; do
    if [ "$name" = "nginx-microservice" ]; then
        [ -n "$NGINX_STATUS" ] && RUNNING_HEALTHY+=("$name") || STOPPED_OTHER+=("$name")
    elif [ "$name" = "nginx-certbot" ]; then
        [ -n "$NGINX_CERTBOT_STATUS" ] && RUNNING_HEALTHY+=("$name") || STOPPED_OTHER+=("$name")
    elif [ "$name" = "db-server-postgres" ] || [ "$name" = "db-server-redis" ]; then
        s=$(get_container_status_from_cache "$name")
        [ -n "$s" ] && RUNNING_HEALTHY+=("$name") || STOPPED_OTHER+=("$name")
    else
        container_status="${MICROSERVICE_RESULTS["${name}_status"]}${APPLICATION_RESULTS["${name}_status"]}"
        health_result="${MICROSERVICE_RESULTS["${name}_health"]}${APPLICATION_RESULTS["${name}_health"]}"
        if [ "$container_status" = "running" ] && [ "$health_result" = "0" ]; then
            RUNNING_HEALTHY+=("$name")
        elif [ "$container_status" = "running" ] || [ "$container_status" = "partial" ]; then
            UNHEALTHY_PARTIAL+=("$name")
        else
            STOPPED_OTHER+=("$name")
        fi
    fi
done
RUNNING_HEALTHY=($(printf '%s\n' "${RUNNING_HEALTHY[@]}" | sort -u))
UNHEALTHY_PARTIAL=($(printf '%s\n' "${UNHEALTHY_PARTIAL[@]}" | sort -u))
STOPPED_OTHER=($(printf '%s\n' "${STOPPED_OTHER[@]}" | sort -u))

# Print services grouped by status
print_status "=========================================="
print_status "Services by status"
print_status "=========================================="

print_status ""
print_status "--- Running and healthy ---"
for service in "${RUNNING_HEALTHY[@]}"; do
    container_status="${MICROSERVICE_RESULTS["${service}_status"]}${APPLICATION_RESULTS["${service}_status"]}"
    domain="${MICROSERVICE_RESULTS["${service}_domain"]}${APPLICATION_RESULTS["${service}_domain"]}"
    if [ "$service" = "nginx-microservice" ] || [ "$service" = "nginx-certbot" ] || [ "$service" = "db-server-postgres" ] || [ "$service" = "db-server-redis" ]; then
        s=$(get_container_status_from_cache "$service")
        echo -e "  ${GREEN_CHECK} $service: Up"
    else
        echo -e "  ${GREEN_CHECK} $service: Running and healthy"
        [ -n "$domain" ] && [ "$domain" != "null" ] && echo -e "    Domain: $domain"
    fi
done

if [ ${#UNHEALTHY_PARTIAL[@]} -gt 0 ]; then
    print_status ""
    print_status "--- Unhealthy / Partial ---"
    for service in "${UNHEALTHY_PARTIAL[@]}"; do
        container_status="${MICROSERVICE_RESULTS["${service}_status"]}${APPLICATION_RESULTS["${service}_status"]}"
        domain="${MICROSERVICE_RESULTS["${service}_domain"]}${APPLICATION_RESULTS["${service}_domain"]}"
        if [ "$container_status" = "partial" ]; then
            echo -e "  ${RED_X} $service: Partially running"
        else
            echo -e "  ${RED_X} $service: Running but health check failed"
        fi
        [ -n "$domain" ] && [ "$domain" != "null" ] && echo -e "    Domain: $domain"
    done
fi

print_status ""
print_status "--- Stopped / Not running ---"
for service in "${STOPPED_OTHER[@]}"; do
    container_status="${MICROSERVICE_RESULTS["${service}_status"]}${APPLICATION_RESULTS["${service}_status"]}"
    domain="${MICROSERVICE_RESULTS["${service}_domain"]}${APPLICATION_RESULTS["${service}_domain"]}"
    if [ "$service" = "nginx-microservice" ] || [ "$service" = "nginx-certbot" ] || [ "$service" = "db-server-postgres" ] || [ "$service" = "db-server-redis" ]; then
        echo -e "  ${RED_X} $service: Not running"
    else
        echo -e "  ${RED_X} $service: Stopped"
        [ -n "$domain" ] && [ "$domain" != "null" ] && echo -e "    Domain: $domain"
    fi
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
    echo "$DOCKER_PS_STATUS_CACHE" | grep -E "Restarting|Unhealthy|Exited" | while IFS=$'\t' read -r name status; do
        echo -e "  ${RED_X} $name\t$status"
    done
else
    print_success "All running containers appear ${GREEN_CHECK} healthy"
fi

# Check stopped containers (still need docker ps -a for stopped)
print_status ""
print_detail "Stopped containers:"
STOPPED_COUNT=$(docker ps -a --filter "status=exited" --format "{{.Names}}" 2>/dev/null | wc -l)
if [ "$STOPPED_COUNT" -gt 0 ]; then
    print_detail "$STOPPED_COUNT container(s) stopped:"
    docker ps -a --filter "status=exited" --format "{{.Names}}: {{.Status}}" 2>/dev/null | sort | head -20 | sed 's/^/  - /'
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
        eval "$icon_var='${GREEN_CHECK}'"
        eval "$status_text_var='RUNNING'"
    else
        eval "$icon_var='${RED_X}'"
        eval "$status_text_var='STOPPED'"
    fi
}

# Final Dashboard - grouped by status (Healthy/Running, then Unhealthy/Partial, then Stopped), names sorted within each group
print_status ""
print_status "=========================================="
print_status "Service Dashboard (by status)"
print_status "=========================================="
print_status ""

# Helper: print dashboard rows for a list of names
print_dashboard_rows() {
    for name in "$@"; do
        domain="N/A"
        case "$name" in
            nginx-microservice)
                format_dashboard_status "$NGINX_STATUS" "icon" "status_text"
                ;;
            nginx-certbot)
                [ -n "$NGINX_CERTBOT_STATUS" ] && status_text="RUNNING" && icon="${GREEN_CHECK}" || { status_text="STOPPED"; icon="${RED_X}"; }
                ;;
            db-server-postgres)
                format_dashboard_status "$POSTGRES_STATUS" "icon" "status_text"
                ;;
            db-server-redis)
                format_dashboard_status "$REDIS_STATUS" "icon" "status_text"
                ;;
            *)
                if [ -n "${MICROSERVICE_RESULTS["${name}_status"]}" ]; then
                    container_status="${MICROSERVICE_RESULTS["${name}_status"]}"
                    domain="${MICROSERVICE_RESULTS["${name}_domain"]}"
                    health_result="${MICROSERVICE_RESULTS["${name}_health"]}"
                else
                    container_status="${APPLICATION_RESULTS["${name}_status"]}"
                    domain="${APPLICATION_RESULTS["${name}_domain"]}"
                    health_result="${APPLICATION_RESULTS["${name}_health"]}"
                fi
                case "$container_status" in
                    "running")
                        [ "$health_result" = "0" ] && { icon="${GREEN_CHECK}"; status_text="HEALTHY"; } || { icon="${RED_X}"; status_text="UNHEALTHY"; }
                        ;;
                    "partial") icon="${RED_X}"; status_text="PARTIAL" ;;
                    "stopped") icon="${RED_X}"; status_text="STOPPED" ;;
                    "not-registered") icon="${RED_X}"; status_text="NOT REGISTERED" ;;
                    "no-services") icon="${RED_X}"; status_text="NO SERVICES" ;;
                    *) icon="${RED_X}"; status_text="UNKNOWN" ;;
                esac
                [ -z "$domain" ] || [ "$domain" = "null" ] && domain="N/A"
                ;;
        esac
        echo -e "$(printf '%-35s' "$name")$icon $(printf '%-12s' "$status_text")$(printf '%-40s' "$domain")"
    done
}

echo -e "SERVICE                             STATUS          DOMAIN"
echo -e "----------------------------------- --------------- ----------------------------------------"
[ ${#RUNNING_HEALTHY[@]} -gt 0 ] && echo -e "${CYAN}--- Healthy / Running ---${NC}" && print_dashboard_rows "${RUNNING_HEALTHY[@]}"
[ ${#UNHEALTHY_PARTIAL[@]} -gt 0 ] && echo "" && echo -e "${CYAN}--- Unhealthy / Partial ---${NC}" && print_dashboard_rows "${UNHEALTHY_PARTIAL[@]}"
[ ${#STOPPED_OTHER[@]} -gt 0 ] && echo "" && echo -e "${CYAN}--- Stopped ---${NC}" && print_dashboard_rows "${STOPPED_OTHER[@]}"

print_status ""

exit 0

