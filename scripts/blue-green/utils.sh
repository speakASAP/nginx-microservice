#!/bin/bash
# Blue/Green Deployment Utility Functions
# Shared functions for all blue/green deployment scripts
# This file now acts as a module loader and provides blue-green specific logging

set -e

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
REGISTRY_DIR="${NGINX_PROJECT_DIR}/service-registry"
STATE_DIR="${NGINX_PROJECT_DIR}/state"
LOG_DIR="${NGINX_PROJECT_DIR}/logs/blue-green"

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Source output functions (for print_* functions)
COMMON_DIR="${SCRIPT_DIR}/../common"
if [ -f "${COMMON_DIR}/output.sh" ]; then
    source "${COMMON_DIR}/output.sh"
else
    # Fallback print functions if output.sh not found
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
    print_status() {
        echo -e "${BLUE}[INFO]${NC} $1"
    }
    print_success() {
        echo -e "${GREEN}[SUCCESS]${NC} $1"
    }
    print_warning() {
        echo -e "${YELLOW}[WARNING]${NC} $1"
    }
    print_error() {
        echo -e "${RED}[ERROR]${NC} $1"
    }
fi

# Source all modular functions
if [ -f "${COMMON_DIR}/registry.sh" ]; then
    source "${COMMON_DIR}/registry.sh"
fi

if [ -f "${COMMON_DIR}/state.sh" ]; then
    source "${COMMON_DIR}/state.sh"
fi

if [ -f "${COMMON_DIR}/config.sh" ]; then
    source "${COMMON_DIR}/config.sh"
fi

if [ -f "${COMMON_DIR}/nginx.sh" ]; then
    source "${COMMON_DIR}/nginx.sh"
fi

if [ -f "${COMMON_DIR}/containers.sh" ]; then
    source "${COMMON_DIR}/containers.sh"
fi

if [ -f "${COMMON_DIR}/network.sh" ]; then
    source "${COMMON_DIR}/network.sh"
fi

# Function to log message (blue-green specific logging)
log_message() {
    local level="$1"
    local service="$2"
    local color="$3"
    local action="$4"
    local message="$5"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "[$timestamp] [$level] [$service] [$color] [$action] $message" >> "${LOG_DIR}/deploy.log"
    
    case "$level" in
        "ERROR")
            print_error "$message"
            ;;
        "WARNING")
            print_warning "$message"
            ;;
        "SUCCESS")
            print_success "$message"
            ;;
        *)
            print_status "$message"
            ;;
    esac
}

# Function to check docker compose availability
check_docker_compose_available() {
    if ! command -v docker >/dev/null 2>&1; then
        print_error "Docker is not installed"
        return 1
    fi
    
    if ! docker compose version >/dev/null 2>&1; then
        print_error "docker compose is not available"
        return 1
    fi
    
    if ! docker info >/dev/null 2>&1; then
        print_error "Docker daemon is not running"
        return 1
    fi
    
    return 0
}

