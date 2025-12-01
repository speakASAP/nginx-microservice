#!/bin/bash
# Shared Utility Functions for Startup Scripts
# Provides common functions for start-nginx.sh, start-infrastructure.sh, start-microservices.sh, start-applications.sh

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

# Function to check if container is running (not restarting)
check_container_running() {
    local container_name="$1"
    
    if ! docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^${container_name}$"; then
        return 1
    fi
    
    local status=$(docker ps --format "{{.Names}}\t{{.Status}}" 2>/dev/null | grep "^${container_name}" | awk '{print $2}' || echo "")
    
    if [ -z "$status" ]; then
        return 1
    fi
    
    # Check if container is restarting
    if echo "$status" | grep -qE "Restarting"; then
        return 2  # Container is restarting
    fi
    
    # Check if container is running
    if echo "$status" | grep -qE "Up"; then
        return 0  # Container is running
    fi
    
    return 1  # Container is not running
}

# Function to check container health status
check_container_healthy() {
    local container_name="$1"
    
    local health_status=$(docker inspect --format='{{.State.Health.Status}}' "$container_name" 2>/dev/null || echo "none")
    
    if [ "$health_status" = "healthy" ]; then
        return 0
    fi
    
    return 1
}

# Function to run diagnostic script and exit
run_diagnostic_and_exit() {
    local diagnostic_script="$1"
    local container_name="${2:-}"
    local error_message="${3:-Error detected}"
    
    print_error "$error_message"
    
    if [ -f "$diagnostic_script" ]; then
        print_status "Running diagnostic script: $diagnostic_script"
        if [ -n "$container_name" ]; then
            bash "$diagnostic_script" "$container_name" || true
        else
            bash "$diagnostic_script" || true
        fi
    else
        print_warning "Diagnostic script not found: $diagnostic_script"
    fi
    
    exit 1
}

# Function to wait for health check with timeout
wait_for_health_check() {
    local check_command="$1"
    local max_attempts="${2:-30}"
    local attempt_interval="${3:-2}"
    local check_name="${4:-Health check}"
    
    local attempt=0
    while [ $attempt -lt $max_attempts ]; do
        attempt=$((attempt + 1))
        print_detail "${check_name} attempt $attempt/$max_attempts..."
        
        if eval "$check_command" >/dev/null 2>&1; then
            print_success "${check_name} ${GREEN_CHECK} passed"
            return 0
        fi
        
        if [ $attempt -lt $max_attempts ]; then
            sleep $attempt_interval
        fi
    done
    
    print_error "${check_name} ${RED_X} failed after $max_attempts attempts"
    return 1
}

# Function to validate service containers are running
validate_service_started() {
    local service_name="$1"
    local container_base="$2"
    
    if [ -z "$container_base" ]; then
        return 1
    fi
    
    # Check for blue, green, or base container name
    if docker ps --format "{{.Names}}" | grep -qE "^${container_base}(-blue|-green)?$"; then
        return 0
    fi
    
    return 1
}

# Function to check if network exists
network_exists() {
    local network_name="$1"
    docker network ls --format "{{.Name}}" | grep -q "^${network_name}$"
}

# Function to check if service registry exists
service_exists() {
    local service_name="$1"
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local nginx_project_dir="$(cd "$script_dir/.." && pwd)"
    local registry_dir="${nginx_project_dir}/service-registry"
    [ -f "${registry_dir}/${service_name}.json" ]
}

# Function to check if Docker daemon is running
check_docker_daemon() {
    if docker info >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Function to start Docker daemon
start_docker_daemon() {
    print_status "Docker daemon is not running, attempting to start it..."
    
    # Detect OS and start Docker accordingly
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS - try to start Docker Desktop
        print_detail "Detected macOS, starting Docker Desktop..."
        if command -v open >/dev/null 2>&1; then
            open -a Docker 2>/dev/null || {
                print_error "Failed to start Docker Desktop. Please start Docker Desktop manually."
                return 1
            }
        else
            print_error "Cannot start Docker Desktop - 'open' command not found"
            return 1
        fi
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Linux - try systemd or service
        print_detail "Detected Linux, starting Docker service..."
        if command -v systemctl >/dev/null 2>&1; then
            if systemctl start docker 2>/dev/null; then
                print_success "Docker service started via systemctl"
            else
                print_error "Failed to start Docker service via systemctl. Please start Docker manually: sudo systemctl start docker"
                return 1
            fi
        elif command -v service >/dev/null 2>&1; then
            if sudo service docker start 2>/dev/null; then
                print_success "Docker service started via service"
            else
                print_error "Failed to start Docker service. Please start Docker manually: sudo service docker start"
                return 1
            fi
        else
            print_error "Cannot start Docker service - neither systemctl nor service command found"
            return 1
        fi
    else
        print_error "Unsupported OS: $OSTYPE. Please start Docker manually."
        return 1
    fi
    
    # Wait for Docker daemon to be ready
    print_status "Waiting for Docker daemon to be ready (checking every 2 seconds)..."
    local max_attempts=30
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        attempt=$((attempt + 1))
        if check_docker_daemon; then
            print_success "Docker daemon is ${GREEN_CHECK} ready"
            return 0
        fi
        if [ $attempt -lt $max_attempts ]; then
            print_detail "Docker daemon not ready yet, waiting... (attempt $attempt/$max_attempts)"
            sleep 2
        fi
    done
    
    print_error "Docker daemon did not become ready after $max_attempts attempts"
    print_error "Please check Docker status manually and ensure it's running"
    return 1
}

# Function to ensure Docker daemon is running
ensure_docker_daemon() {
    if check_docker_daemon; then
        return 0
    fi
    
    if ! start_docker_daemon; then
        exit 1
    fi
    
    return 0
}

