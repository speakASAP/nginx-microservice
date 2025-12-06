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
    
    # All attempts failed
    if [ -n "$service_name" ]; then
        if type log_message >/dev/null 2>&1; then
            log_message "ERROR" "$service_name" "$color" "https-check" "HTTPS check failed: $url (all $retries attempts failed)"
        fi
    fi
    return 1
}

