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
    local retries="${3:-2}"
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
        retries=2
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
        local http_code=""
        
        # Try from nginx container if it exists and is on the network
        if docker ps --format "{{.Names}}" | grep -q "^${nginx_container}$" && \
           docker network inspect "${network_name}" --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null | grep -qE "(^| )${nginx_container}( |$)"; then
            # Check from inside nginx container (can reach localhost:443)
            # Use -w to capture HTTP code, don't use -f so we can check status codes
            curl_error=$(docker exec "${nginx_container}" curl -s -w "\nHTTP_CODE:%{http_code}" --max-time "$timeout" -k "$url" 2>&1)
            curl_exit_code=$?
            http_code=$(echo "$curl_error" | grep "HTTP_CODE:" | cut -d: -f2 || echo "")
            curl_error=$(echo "$curl_error" | grep -v "HTTP_CODE:" || echo "$curl_error")
        fi
        
        # Fallback to host-based check if container check failed or nginx not available
        if [ $curl_exit_code -ne 0 ] || [ -z "$http_code" ]; then
            # Use curl with proper flags for HTTPS check from host
            # -s: silent, -w: write HTTP code, --max-time: timeout, -k: allow insecure (for self-signed certs during dev)
            # Don't use -f so we can check status codes (4xx means service is reachable, just endpoint doesn't exist)
            curl_error=$(curl -s -w "\nHTTP_CODE:%{http_code}" --max-time "$timeout" -k "$url" 2>&1)
            curl_exit_code=$?
            http_code=$(echo "$curl_error" | grep "HTTP_CODE:" | cut -d: -f2 || echo "")
            curl_error=$(echo "$curl_error" | grep -v "HTTP_CODE:" || echo "$curl_error")
        fi
        
        # Consider 2xx and 4xx as success (service is reachable and responding)
        # 4xx means the endpoint doesn't exist, but the service is reachable (which is what we're checking)
        # 5xx means server error, which is a real failure
        if [ -n "$http_code" ]; then
            if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 500 ]; then
                curl_exit_code=0
                if [ -n "$service_name" ]; then
                    if type log_message >/dev/null 2>&1; then
                        if [ "$http_code" -ge 400 ]; then
                            log_message "SUCCESS" "$service_name" "$color" "https-check" "HTTPS check passed: $url (HTTP $http_code - service reachable, endpoint not found)"
                        else
                            log_message "SUCCESS" "$service_name" "$color" "https-check" "HTTPS check passed: $url (HTTP $http_code, attempt $attempt/$retries)"
                        fi
                    fi
                fi
                return 0
            fi
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
    
    # All external attempts failed - try internal check (localhost with Host header)
    # Fixes false failures when server cannot reach its own public URL (NAT hairpinning, firewall, DNS)
    local internal_response
    internal_response=$(curl -k -s -w "\nHTTP_CODE:%{http_code}" --max-time "$timeout" -H "Host: ${domain}" "https://127.0.0.1${endpoint}" 2>&1) || true
    local internal_code
    internal_code=$(echo "$internal_response" | grep "HTTP_CODE:" | cut -d: -f2 || echo "000")
    if [ -n "$internal_code" ] && [ "$internal_code" != "000" ] && [ "$internal_code" -ge 200 ] && [ "$internal_code" -lt 500 ]; then
        if [ -n "$service_name" ]; then
            if type log_message >/dev/null 2>&1; then
                log_message "SUCCESS" "$service_name" "$color" "https-check" "HTTPS check passed via internal fallback (Host: $domain): HTTP $internal_code (external check failed - NAT/firewall)"
            fi
        fi
        return 0
    fi

    # All attempts including internal fallback failed - add comprehensive diagnostics
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

