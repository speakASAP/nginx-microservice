#!/bin/bash
# State Management Functions
# Functions for managing blue/green deployment state

# Source base paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
STATE_DIR="${NGINX_PROJECT_DIR}/state"

# Source output and registry
if [ -f "${SCRIPT_DIR}/output.sh" ]; then
    source "${SCRIPT_DIR}/output.sh"
else
    # Fallback output functions
    RED='\033[0;31m'
    YELLOW='\033[1;33m'
    NC='\033[0m'
    print_error() {
        echo -e "${RED}[ERROR]${NC} $1"
    }
    print_warning() {
        echo -e "${YELLOW}[WARNING]${NC} $1"
    }
fi

# Source registry functions (for get_registry_value)
if [ -f "${SCRIPT_DIR}/registry.sh" ]; then
    source "${SCRIPT_DIR}/registry.sh"
fi

# Function to load state
load_state() {
    local service_name="$1"
    local domain="${2:-}"
    local state_file="${STATE_DIR}/${service_name}.json"
    
    # For statex service, check if domain-specific state exists
    if [ "$service_name" = "statex" ] && [ -n "$domain" ]; then
        if [ -f "$state_file" ]; then
            # Check if domain-specific state exists
            local domain_state=$(jq -r ".domains[\"$domain\"] // empty" "$state_file" 2>/dev/null)
            if [ -n "$domain_state" ] && [ "$domain_state" != "null" ]; then
                # Return domain-specific state with service_name (with error handling)
                local domain_state_output=$(jq -r --arg domain "$domain" '{service_name: "statex", domain: $domain} + .domains[$domain]' "$state_file" 2>/dev/null)
                if [ -z "$domain_state_output" ] || ! echo "$domain_state_output" | jq . >/dev/null 2>&1; then
                    # Fallback: create domain state structure (matches initial state semantics)
                    echo "{\"service_name\": \"statex\", \"domain\": \"$domain\", \"active_color\": \"blue\", \"blue\": {\"status\": \"running\", \"deployed_at\": null, \"version\": null}, \"green\": {\"status\": \"stopped\", \"deployed_at\": null, \"version\": null}, \"last_deployment\": {\"color\": \"blue\", \"timestamp\": null, \"success\": true}}"
                else
                    echo "$domain_state_output"
                fi
                return
            fi
        fi
        # Create initial domain-specific state
        if [ ! -f "$state_file" ]; then
            mkdir -p "$STATE_DIR"
            echo "{\"service_name\": \"statex\", \"domains\": {}}" | jq '.' > "$state_file" 2>/dev/null || true
        fi
        # Add domain state if it doesn't exist
        local current_state=$(cat "$state_file" 2>/dev/null || echo "{}")
        local domain_state=$(echo "$current_state" | jq -r ".domains[\"$domain\"] // empty" 2>/dev/null)
        if [ -z "$domain_state" ] || [ "$domain_state" = "null" ]; then
            current_state=$(echo "$current_state" | jq --arg domain "$domain" '.domains[$domain] = {
                "active_color": "blue",
                "blue": {"status": "running", "deployed_at": null, "version": null},
                "green": {"status": "stopped", "deployed_at": null, "version": null},
                "last_deployment": {"color": "blue", "timestamp": null, "success": true}
            }' 2>/dev/null)
            echo "$current_state" | jq '.' > "$state_file" 2>/dev/null || true
        fi
        # Return domain-specific state (with error handling)
        local domain_state_output=$(jq -r --arg domain "$domain" '{service_name: "statex", domain: $domain} + .domains[$domain]' "$state_file" 2>/dev/null)
        if [ -z "$domain_state_output" ] || ! echo "$domain_state_output" | jq . >/dev/null 2>&1; then
            # Return default domain state if jq failed or returned invalid JSON (matches initial state semantics)
            echo "{\"service_name\": \"statex\", \"domain\": \"$domain\", \"active_color\": \"blue\", \"blue\": {\"status\": \"running\", \"deployed_at\": null, \"version\": null}, \"green\": {\"status\": \"stopped\", \"deployed_at\": null, \"version\": null}, \"last_deployment\": {\"color\": \"blue\", \"timestamp\": null, \"success\": true}}"
        else
            echo "$domain_state_output"
        fi
        return
    fi
    
    # Standard state loading for non-statex services or when domain not specified
    if [ ! -f "$state_file" ]; then
        print_warning "State file not found: $state_file. Creating initial state." >&2
        # Ensure state directory exists
        mkdir -p "$STATE_DIR"
        # Create initial state with blue as active
        cat > "$state_file" <<EOF
{
  "service_name": "$service_name",
  "active_color": "blue",
  "blue": {
    "status": "running",
    "deployed_at": null,
    "version": null
  },
  "green": {
    "status": "stopped",
    "deployed_at": null,
    "version": null
  },
  "last_deployment": {
    "color": "blue",
    "timestamp": null,
    "success": true
  }
}
EOF
    fi
    
    if command -v jq >/dev/null 2>&1; then
        # Validate and return state file, or return default state if file is invalid
        local state_content=$(cat "$state_file" 2>/dev/null || echo "")
        if [ -z "$state_content" ] || ! echo "$state_content" | jq . >/dev/null 2>&1; then
            # File is empty or invalid JSON, return default state (matches initial state semantics)
            echo "{\"service_name\": \"$service_name\", \"active_color\": \"blue\", \"blue\": {\"status\": \"running\", \"deployed_at\": null, \"version\": null}, \"green\": {\"status\": \"stopped\", \"deployed_at\": null, \"version\": null}, \"last_deployment\": {\"color\": \"blue\", \"timestamp\": null, \"success\": true}}"
        else
            echo "$state_content"
        fi
    else
        print_error "jq not found. Install jq: brew install jq"
        exit 1
    fi
}

# Function to save state
save_state() {
    local service_name="$1"
    local state_data="$2"
    local domain="${3:-}"
    local state_file="${STATE_DIR}/${service_name}.json"
    
    mkdir -p "$STATE_DIR"
    
    # For statex service with domain, save to domain-specific state
    if [ "$service_name" = "statex" ] && [ -n "$domain" ]; then
        if [ ! -f "$state_file" ]; then
            echo "{\"service_name\": \"statex\", \"domains\": {}}" | jq '.' > "$state_file" 2>/dev/null || true
        fi
        # Extract domain state from state_data (remove service_name and domain fields)
        local domain_state=$(echo "$state_data" | jq 'del(.service_name, .domain)' 2>/dev/null)
        # Update domain-specific state
        local current_state=$(cat "$state_file" 2>/dev/null || echo "{\"service_name\": \"statex\", \"domains\": {}}")
        echo "$current_state" | jq --arg domain "$domain" --argjson domain_state "$domain_state" '.domains[$domain] = $domain_state' > "$state_file" 2>/dev/null || {
            print_error "Failed to save domain-specific state"
            exit 1
        }
        return
    fi
    
    # Standard state saving for non-statex services or when domain not specified
    if command -v jq >/dev/null 2>&1; then
        echo "$state_data" | jq '.' > "$state_file"
    else
        print_error "jq not found. Install jq: brew install jq"
        exit 1
    fi
}

# Function to get active color
get_active_color() {
    local service_name="$1"
    if type get_registry_value >/dev/null 2>&1; then
        get_registry_value "$service_name" '.active_color' 2>/dev/null || \
        jq -r '.active_color' "${STATE_DIR}/${service_name}.json" 2>/dev/null || \
        echo "blue"
    else
        jq -r '.active_color' "${STATE_DIR}/${service_name}.json" 2>/dev/null || echo "blue"
    fi
}

# Function to get inactive color
get_inactive_color() {
    local service_name="$1"
    local active=$(get_active_color "$service_name")
    
    if [ "$active" = "blue" ]; then
        echo "green"
    else
        echo "blue"
    fi
}

