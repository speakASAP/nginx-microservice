#!/bin/bash
# Fault Tolerance Utilities
# Provides functions for handling failures in a tiered manner
# Infrastructure and microservices: zero tolerance (exit on failure)
# Applications: fault tolerant (log and continue)

# Source output functions if available
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/output.sh" ]; then
    source "${SCRIPT_DIR}/output.sh"
else
    # Fallback output functions
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
    
    print_error() {
        echo -e "${RED}[ERROR]${NC} $1"
    }
    
    print_warning() {
        echo -e "${YELLOW}[WARNING]${NC} $1"
    }
    
    print_success() {
        echo -e "${GREEN}[SUCCESS]${NC} $1"
    }
    
    print_status() {
        echo -e "${BLUE}[INFO]${NC} $1"
    }
fi

# Function to check if service is infrastructure
is_infrastructure_service() {
    local service="$1"
    case "$service" in
        nginx-microservice|database-server|nginx)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Function to check if service is microservice
is_microservice() {
    local service="$1"
    case "$service" in
        *-microservice)
            return 0
            ;;
        auth-microservice|notifications-microservice|logging-microservice|payments-microservice)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Function to check if service is application
is_application() {
    local service="$1"
    case "$service" in
        flipflop|statex|crypto-ai-agent|allegro)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Function to handle service failure based on tier
handle_service_failure() {
    local service="$1"
    local error_message="$2"
    
    if is_infrastructure_service "$service" || is_microservice "$service"; then
        # Zero tolerance - exit immediately
        print_error "CRITICAL: $service failed - $error_message"
        print_error "Infrastructure/microservice failures are not tolerated"
        exit 1
    elif is_application "$service"; then
        # Fault tolerant - log and continue
        print_warning "Application $service failed - $error_message"
        print_warning "System will continue with other applications"
        return 1  # Don't exit
    else
        # Unknown service - default to fault tolerant
        print_warning "Service $service failed - $error_message"
        return 1
    fi
}

# Function to check service tier and return appropriate behavior
get_service_tier() {
    local service="$1"
    
    if is_infrastructure_service "$service"; then
        echo "infrastructure"
    elif is_microservice "$service"; then
        echo "microservice"
    elif is_application "$service"; then
        echo "application"
    else
        echo "unknown"
    fi
}

# Function to determine if service failure should exit
should_exit_on_failure() {
    local service="$1"
    local tier=$(get_service_tier "$service")
    
    case "$tier" in
        infrastructure|microservice)
            return 0  # Should exit
            ;;
        application|unknown)
            return 1  # Should not exit
            ;;
    esac
}

