#!/bin/bash
# Service Registry Functions
# Functions for loading and querying service registry

# Source base paths (SCRIPT_DIR always set for output.sh; REGISTRY_DIR only if not set by caller e.g. utils.sh)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${REGISTRY_DIR:-}" ]; then
    NGINX_PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
    REGISTRY_DIR="${NGINX_PROJECT_DIR}/service-registry"
fi

# Source output functions
if [ -f "${SCRIPT_DIR}/output.sh" ]; then
    source "${SCRIPT_DIR}/output.sh"
else
    # Fallback output functions
    RED='\033[0;31m'
    NC='\033[0m'
    print_error() {
        echo -e "${RED}[ERROR]${NC} $1"
    }
fi

# Resolve service name: if argument is a domain (e.g. sgipreal.com), find registry whose .domain matches
# and return that service name (e.g. sgiprealestate). Otherwise return argument unchanged.
resolve_service_name() {
    local arg="$1"
    if [ -z "$arg" ]; then
        echo "$arg"
        return
    fi
    local registry_file="${REGISTRY_DIR}/${arg}.json"
    if [ -f "$registry_file" ]; then
        echo "$arg"
        return
    fi
    if [[ "$arg" == *.* ]]; then
        for f in "${REGISTRY_DIR}"/*.json; do
            [ -f "$f" ] || continue
            local domain=""
            domain=$(jq -r '.domain // empty' "$f" 2>/dev/null) || true
            if [ "$domain" = "$arg" ]; then
                echo "$(basename "$f" .json)"
                return
            fi
        done
    fi
    echo "$arg"
}

# Function to load service registry
load_service_registry() {
    local service_name="$1"
    local registry_file="${REGISTRY_DIR}/${service_name}.json"
    
    if [ ! -f "$registry_file" ]; then
        print_error "Service registry not found: $registry_file"
        exit 1
    fi
    
    if command -v jq >/dev/null 2>&1; then
        local content
        content=$(cat "$registry_file")
        if ! echo "$content" | jq -e . >/dev/null 2>&1; then
            print_error "Registry file contains invalid JSON: $registry_file"
            exit 1
        fi
        echo "$content"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "import json, sys; print(json.dumps(json.load(open('$registry_file'))))"
    else
        print_error "Neither jq nor python3 found. Install jq: brew install jq"
        exit 1
    fi
}

# Function to get registry value (requires jq)
get_registry_value() {
    local service_name="$1"
    local key_path="$2"
    local registry_file="${REGISTRY_DIR}/${service_name}.json"
    
    if [ ! -f "$registry_file" ]; then
        print_error "Service registry not found: $registry_file"
        exit 1
    fi
    
    if command -v jq >/dev/null 2>&1; then
        jq -r "$key_path" "$registry_file"
    else
        print_error "jq not found. Install jq: brew install jq"
        exit 1
    fi
}

