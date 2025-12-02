#!/bin/bash
# Container Management Functions
# Functions for managing Docker containers

# Source base paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source dependencies
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

# Note: log_message will be available from utils.sh when modules are sourced together

# Function to check if a port is in use and kill the process/container using it
# Usage: kill_port_if_in_use <port> [service_name] [color]
kill_port_if_in_use() {
    local port="$1"
    local service_name="${2:-}"
    local color="${3:-}"
    
    if [ -z "$port" ] || ! [[ "$port" =~ ^[0-9]+$ ]]; then
        return 0  # Invalid port, skip
    fi
    
    # First check if a Docker container is using this port (checking both host and container ports)
    local container_using_port=$(docker ps --format "{{.Names}}\t{{.Ports}}" 2>/dev/null | \
        grep -E ":${port}->|:${port}/|0\.0\.0\.0:${port}:|127\.0\.0\.1:${port}:" | \
        awk '{print $1}' | head -1 || echo "")
    
    if [ -n "$container_using_port" ]; then
        if [ -n "$service_name" ]; then
            if type log_message >/dev/null 2>&1; then
                log_message "WARNING" "$service_name" "$color" "port-check" "Port ${port} is in use by container ${container_using_port}, stopping and removing it"
            fi
        else
            print_warning "Port ${port} is in use by container ${container_using_port}, stopping and removing it"
        fi
        # Force stop and remove, even if it's restarting
        docker stop "${container_using_port}" 2>/dev/null || true
        sleep 1
        docker kill "${container_using_port}" 2>/dev/null || true
        sleep 1
        docker rm -f "${container_using_port}" 2>/dev/null || true
        sleep 1  # Give it a moment to release the port
    fi
    
    # Check if a host process is using this port (using lsof, netstat, or ss)
    local pid_using_port=""
    
    # Try lsof first (most reliable on macOS/Linux)
    if command -v lsof >/dev/null 2>&1; then
        pid_using_port=$(lsof -ti:${port} 2>/dev/null | head -1 || echo "")
    # Try ss (Linux)
    elif command -v ss >/dev/null 2>&1; then
        pid_using_port=$(ss -tlnp 2>/dev/null | grep ":${port} " | grep -oP 'pid=\K[0-9]+' | head -1 || echo "")
    # Try netstat (fallback)
    elif command -v netstat >/dev/null 2>&1; then
        pid_using_port=$(netstat -tlnp 2>/dev/null | grep ":${port} " | grep -oP '\d+/\w+' | cut -d'/' -f1 | head -1 || echo "")
    fi
    
    if [ -n "$pid_using_port" ] && [ "$pid_using_port" != "null" ]; then
        # Check if it's a docker process (don't kill docker itself)
        local process_name=$(ps -p "$pid_using_port" -o comm= 2>/dev/null || echo "")
        if [ -n "$process_name" ] && ! echo "$process_name" | grep -qE "docker|dockerd|containerd"; then
            if [ -n "$service_name" ]; then
                if type log_message >/dev/null 2>&1; then
                    log_message "WARNING" "$service_name" "$color" "port-check" "Port ${port} is in use by process ${pid_using_port} (${process_name}), killing it"
                fi
            else
                print_warning "Port ${port} is in use by process ${pid_using_port} (${process_name}), killing it"
            fi
            kill -9 "$pid_using_port" 2>/dev/null || true
            sleep 1  # Give it a moment to release the port
        fi
    fi
    
    return 0
}

# Function to kill container by name if it exists (handles restarting containers)
# Usage: kill_container_if_exists <container_name> [service_name] [color]
kill_container_if_exists() {
    local container_name="$1"
    local service_name="${2:-}"
    local color="${3:-}"
    
    if [ -z "$container_name" ]; then
        return 0
    fi
    
    # Check if container exists (running or stopped)
    if docker ps -a --format "{{.Names}}" 2>/dev/null | grep -qE "^${container_name}$"; then
        # Check if it's in a restart loop
        local status=$(docker ps --format "{{.Names}}\t{{.Status}}" 2>/dev/null | grep "^${container_name}" | awk '{print $2}' || echo "")
        
        if [ -n "$status" ] && echo "$status" | grep -qE "Restarting|Up"; then
            if [ -n "$service_name" ]; then
                if type log_message >/dev/null 2>&1; then
                    log_message "WARNING" "$service_name" "$color" "container-check" "Container ${container_name} is ${status}, stopping and removing it"
                fi
            else
                print_warning "Container ${container_name} is ${status}, stopping and removing it"
            fi
            # Force stop and remove
            docker stop "${container_name}" 2>/dev/null || true
            sleep 1
            docker kill "${container_name}" 2>/dev/null || true
            sleep 1
            docker rm -f "${container_name}" 2>/dev/null || true
            sleep 1
        else
            # Container exists but not running, just remove it
            if [ -n "$service_name" ]; then
                if type log_message >/dev/null 2>&1; then
                    log_message "INFO" "$service_name" "$color" "container-check" "Removing existing container ${container_name}"
                fi
            fi
            docker rm -f "${container_name}" 2>/dev/null || true
        fi
    fi
    
    return 0
}

# Function to extract host ports from docker compose file
# Usage: get_host_ports_from_compose <compose_file> [service_name]
get_host_ports_from_compose() {
    local compose_file="$1"
    local service_name="${2:-}"
    
    if [ ! -f "$compose_file" ]; then
        return 1
    fi
    
    # Use docker compose config to get the actual port mappings
    local compose_config=$(docker compose -f "$compose_file" config 2>/dev/null || echo "")
    
    if [ -z "$compose_config" ]; then
        return 1
    fi
    
    # Extract ports using yq or jq (prefer yq for YAML)
    if command -v yq >/dev/null 2>&1; then
        echo "$compose_config" | yq eval '.services.*.ports[]? | select(. != null) | .' - 2>/dev/null | grep -oE '[0-9]+:[0-9]+' | cut -d':' -f1 | sort -u || echo ""
    elif command -v jq >/dev/null 2>&1; then
        # jq can parse YAML if yq is not available (but this is less reliable)
        echo "$compose_config" | jq -r '.services | to_entries[] | .value.ports[]? | select(. != null) | .' 2>/dev/null | grep -oE '[0-9]+:[0-9]+' | cut -d':' -f1 | sort -u || echo ""
    else
        # Fallback: use grep/sed (less reliable but works)
        grep -E "^\s+- \"[0-9]+:[0-9]+\"" "$compose_file" | sed -E 's/.*"([0-9]+):[0-9]+".*/\1/' | sort -u || echo ""
    fi
}

