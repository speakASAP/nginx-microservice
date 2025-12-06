#!/bin/bash
# Network Functions
# Functions for network-related operations

# Source base paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source dependencies
if [ -f "${SCRIPT_DIR}/output.sh" ]; then
    source "${SCRIPT_DIR}/output.sh"
else
    # Fallback output functions
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    NC='\033[0m'
    print_error() {
        echo -e "${RED}[ERROR]${NC} $1"
    }
    print_success() {
        echo -e "${GREEN}[SUCCESS]${NC} $1"
    }
    print_status() {
        echo -e "${BLUE}[INFO]${NC} $1"
    }
fi

# Note: log_message will be available from utils.sh when modules are sourced together

# Function to check HTTPS URL availability
check_https_url() {
    local domain="$1"
    local timeout="${2:-5}"
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
        timeout=5
    fi
    if ! [[ "$retries" =~ ^[0-9]+$ ]]; then
        retries=3
    fi
    
    # Construct URL
    local url="https://${domain}${endpoint}"
    local attempt=0
    
    # Log attempt if service context provided
    if [ -n "$service_name" ]; then
        if type log_message >/dev/null 2>&1; then
            log_message "INFO" "$service_name" "$color" "https-check" "Checking HTTPS availability: $url (timeout: ${timeout}s, retries: ${retries})"
        fi
    fi
    
    # Try to check from nginx container first (more reliable), fallback to host
    local network_name="${NETWORK_NAME:-nginx-network}"
    local health_check_image="${HEALTH_CHECK_IMAGE:-alpine/curl:latest}"
    local nginx_container="nginx-microservice"
    
    while [ $attempt -lt $retries ]; do
        attempt=$((attempt + 1))
        local curl_error=""
        local curl_exit_code=1
        
        # Try from nginx container if it exists and is on the network
        if docker ps --format "{{.Names}}" | grep -q "^${nginx_container}$" && \
           docker network inspect "${network_name}" --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null | grep -qE "(^| )${nginx_container}( |$)"; then
            # Check from inside nginx container (can reach localhost:443)
            curl_error=$(docker exec "${nginx_container}" curl -s -f --max-time "$timeout" -k "$url" 2>&1)
            curl_exit_code=$?
        fi
        
        # Fallback to host-based check if container check failed or nginx not available
        if [ $curl_exit_code -ne 0 ]; then
            # Use curl with proper flags for HTTPS check from host
            # -s: silent, -f: fail on HTTP errors, --max-time: timeout, -k: allow insecure (for self-signed certs during dev)
            curl_error=$(curl -s -f --max-time "$timeout" -k "$url" 2>&1)
            curl_exit_code=$?
        fi
        
        if [ $curl_exit_code -eq 0 ]; then
            if [ -n "$service_name" ]; then
                if type log_message >/dev/null 2>&1; then
                    log_message "SUCCESS" "$service_name" "$color" "https-check" "HTTPS check passed: $url (attempt $attempt/$retries)"
                fi
            fi
            return 0
        fi
        
        # Log error on final attempt for diagnostics
        if [ $attempt -eq $retries ] && [ -n "$service_name" ]; then
            if type log_message >/dev/null 2>&1; then
                log_message "WARNING" "$service_name" "$color" "https-check" "HTTPS check attempt $attempt/$retries failed: ${curl_error:-connection timeout or refused}"
            fi
        fi
        
        if [ $attempt -lt $retries ]; then
            sleep 1
        fi
    done
    
    # All attempts failed - add comprehensive diagnostics
    if [ -n "$service_name" ]; then
        if type log_message >/dev/null 2>&1; then
            log_message "ERROR" "$service_name" "$color" "https-check" "HTTPS check failed: $url (all $retries attempts failed)"
            
            # Add comprehensive diagnostics
            diagnose_https_failure "$domain" "$service_name" "$color" "$url"
        fi
    fi
    return 1
}

# Function to diagnose HTTPS check failures
diagnose_https_failure() {
    local domain="$1"
    local service_name="$2"
    local color="${3:-}"
    local url="$4"
    
    local network_name="${NETWORK_NAME:-nginx-network}"
    local nginx_container="nginx-microservice"
    
    # Check nginx container status
    if docker ps --format "{{.Names}}" | grep -q "^${nginx_container}$"; then
        local nginx_status=$(docker ps --filter "name=${nginx_container}" --format "{{.Status}}" 2>/dev/null || echo "unknown")
        log_message "INFO" "$service_name" "$color" "https-diagnose" "Nginx container status: ${nginx_status}"
        
        # Check nginx error logs for this domain (last 10 lines)
        local nginx_errors=$(docker logs --tail 10 "${nginx_container}" 2>&1 | grep -i "${domain}" | tail -5 || echo "no domain-specific errors found")
        if [ -n "$nginx_errors" ] && [ "$nginx_errors" != "no domain-specific errors found" ]; then
            log_message "WARNING" "$service_name" "$color" "https-diagnose" "Nginx errors for ${domain}: ${nginx_errors}"
        fi
    else
        log_message "WARNING" "$service_name" "$color" "https-diagnose" "Nginx container not running"
    fi
    
    # Check service container status if service_name provided
    if [ -n "$service_name" ]; then
        # Try to load service registry to get container names
        if type load_service_registry >/dev/null 2>&1; then
            local registry=$(load_service_registry "$service_name" 2>/dev/null)
            if [ -n "$registry" ]; then
                # Get active color from state if not provided
                if [ -z "$color" ] || [ "$color" = "null" ]; then
                    if type load_state >/dev/null 2>&1; then
                        local state=$(load_state "$service_name" "$domain" 2>/dev/null)
                        color=$(echo "$state" | jq -r '.active_color // "blue"' 2>/dev/null || echo "blue")
                    else
                        color="blue"
                    fi
                fi
                
                # Check backend service container
                local backend_container=$(echo "$registry" | jq -r '.services.backend.container_name_base // empty' 2>/dev/null)
                if [ -n "$backend_container" ] && [ "$backend_container" != "null" ]; then
                    local backend_container_name="${backend_container}-${color}"
                    if docker ps --format "{{.Names}}" | grep -q "^${backend_container_name}$"; then
                        local backend_status=$(docker ps --filter "name=${backend_container_name}" --format "{{.Status}}" 2>/dev/null || echo "unknown")
                        log_message "INFO" "$service_name" "$color" "https-diagnose" "Backend container ${backend_container_name} status: ${backend_status}"
                        
                        # Try to check backend health directly
                        local backend_port=$(echo "$registry" | jq -r '.services.backend.container_port // empty' 2>/dev/null)
                        if [ -n "$backend_port" ] && [ "$backend_port" != "null" ]; then
                            # Try HTTP health check from nginx container
                            if docker ps --format "{{.Names}}" | grep -q "^${nginx_container}$"; then
                                local health_response=$(docker exec "${nginx_container}" curl -s -w "\nHTTP_CODE:%{http_code}" --max-time 3 "http://${backend_container_name}:${backend_port}/health" 2>&1 || echo "connection failed")
                                local http_code=$(echo "$health_response" | grep "HTTP_CODE:" | cut -d: -f2 || echo "unknown")
                                log_message "INFO" "$service_name" "$color" "https-diagnose" "Backend health check (http://${backend_container_name}:${backend_port}/health): HTTP ${http_code}"
                            fi
                        fi
                    else
                        log_message "WARNING" "$service_name" "$color" "https-diagnose" "Backend container ${backend_container_name} not running"
                    fi
                fi
                
                # Check if service has frontend
                local frontend_container=$(echo "$registry" | jq -r '.services.frontend.container_name_base // empty' 2>/dev/null)
                if [ -n "$frontend_container" ] && [ "$frontend_container" != "null" ]; then
                    local frontend_container_name="${frontend_container}-${color}"
                    if docker ps --format "{{.Names}}" | grep -q "^${frontend_container_name}$"; then
                        local frontend_status=$(docker ps --filter "name=${frontend_container_name}" --format "{{.Status}}" 2>/dev/null || echo "unknown")
                        log_message "INFO" "$service_name" "$color" "https-diagnose" "Frontend container ${frontend_container_name} status: ${frontend_status}"
                    else
                        log_message "WARNING" "$service_name" "$color" "https-diagnose" "Frontend container ${frontend_container_name} not running"
                    fi
                fi
            fi
        fi
    fi
    
    # Try to get HTTP response code and headers from nginx container
    if docker ps --format "{{.Names}}" | grep -q "^${nginx_container}$"; then
        local http_response=$(docker exec "${nginx_container}" curl -s -w "\nHTTP_CODE:%{http_code}\nHTTP_STATUS:%{http_code}" --max-time 3 -k "$url" 2>&1 || echo "connection failed")
        local http_code=$(echo "$http_response" | grep "HTTP_CODE:" | cut -d: -f2 | head -1 || echo "unknown")
        log_message "INFO" "$service_name" "$color" "https-diagnose" "HTTP response code from nginx: ${http_code}"
        
        # If we got a response, show first line
        if [ "$http_code" != "unknown" ] && [ "$http_code" != "000" ]; then
            local response_preview=$(echo "$http_response" | head -1 | cut -c1-100)
            if [ -n "$response_preview" ] && [ "$response_preview" != "connection failed" ]; then
                log_message "INFO" "$service_name" "$color" "https-diagnose" "Response preview: ${response_preview}..."
            fi
        fi
    fi
}

