#!/bin/bash
# Remove crypto-ai-postgres and crypto-ai-redis containers
# These containers should not exist as crypto-ai-agent uses shared database-server
# Usage: remove-crypto-ai-containers.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

print_info() {
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

CONTAINERS=("crypto-ai-postgres" "crypto-ai-redis")

print_header "Removing crypto-ai-postgres and crypto-ai-redis containers"
echo ""

# Check if containers exist
FOUND_CONTAINERS=()
for container in "${CONTAINERS[@]}"; do
    if docker ps -a --format "{{.Names}}" 2>/dev/null | grep -q "^${container}$"; then
        FOUND_CONTAINERS+=("$container")
        print_info "Found container: $container"
        
        # Get container status
        status=$(docker ps -a --format "{{.Names}}\t{{.Status}}" 2>/dev/null | grep "^${container}" | awk '{print $2}' || echo "")
        print_info "  Status: $status"
    fi
done

if [ ${#FOUND_CONTAINERS[@]} -eq 0 ]; then
    print_success "No crypto-ai-postgres or crypto-ai-redis containers found"
    print_info "These containers should not exist as crypto-ai-agent uses shared database-server"
    exit 0
fi

echo ""
print_warning "The following containers will be stopped and removed:"
for container in "${FOUND_CONTAINERS[@]}"; do
    echo "  - $container"
done

echo ""
read -p "Continue? (y/N): " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    print_info "Aborted by user"
    exit 0
fi

echo ""
print_header "Stopping and removing containers"

# Stop and remove each container
for container in "${FOUND_CONTAINERS[@]}"; do
    print_info "Processing container: $container"
    
    # Stop container if running
    if docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^${container}$"; then
        print_info "  Stopping container..."
        if docker stop "$container" 2>/dev/null; then
            print_success "  Container stopped"
        else
            print_warning "  Failed to stop container, trying force kill..."
            docker kill "$container" 2>/dev/null || true
        fi
        sleep 1
    fi
    
    # Remove container
    print_info "  Removing container..."
    if docker rm -f "$container" 2>/dev/null; then
        print_success "  Container removed: $container"
    else
        print_error "  Failed to remove container: $container"
    fi
done

echo ""
print_header "Verification"

# Verify containers are removed
ALL_REMOVED=true
for container in "${CONTAINERS[@]}"; do
    if docker ps -a --format "{{.Names}}" 2>/dev/null | grep -q "^${container}$"; then
        print_error "Container still exists: $container"
        ALL_REMOVED=false
    else
        print_success "Container removed: $container"
    fi
done

echo ""
if [ "$ALL_REMOVED" = "true" ]; then
    print_success "All crypto-ai-postgres and crypto-ai-redis containers have been removed"
    print_info ""
    print_info "Note: crypto-ai-agent should use shared database-server:"
    print_info "  - db-server-postgres (shared PostgreSQL)"
    print_info "  - db-server-redis (shared Redis)"
    print_info ""
    print_info "Verify shared database-server is running:"
    print_info "  docker ps | grep db-server"
    exit 0
else
    print_error "Some containers could not be removed"
    exit 1
fi

