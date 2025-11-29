#!/bin/bash
# Verify crypto-ai-agent database configuration
# Checks if crypto-ai-agent is configured to use shared database-server
# Usage: verify-crypto-ai-db-config.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTRY_DIR="${PROJECT_DIR}/service-registry"

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

SERVICE_NAME="crypto-ai-agent"

print_header "Verifying crypto-ai-agent Database Configuration"
echo ""

# 1. Check service registry
print_header "1. Service Registry Configuration"
REGISTRY_FILE="${REGISTRY_DIR}/${SERVICE_NAME}.json"
if [ ! -f "$REGISTRY_FILE" ]; then
    print_error "Service registry not found: $REGISTRY_FILE"
    exit 1
fi

print_success "Service registry found: $REGISTRY_FILE"

# Check shared_services
SHARED_SERVICES=$(jq -r '.shared_services[]?' "$REGISTRY_FILE" 2>/dev/null || echo "")
if echo "$SHARED_SERVICES" | grep -q "postgres"; then
    print_success "Service uses shared PostgreSQL (postgres in shared_services)"
else
    print_error "Service does NOT use shared PostgreSQL"
fi

if echo "$SHARED_SERVICES" | grep -q "redis"; then
    print_success "Service uses shared Redis (redis in shared_services)"
else
    print_warning "Service does NOT use shared Redis"
fi

echo ""

# 2. Check shared database-server status
print_header "2. Shared Database-Server Status"

# Check PostgreSQL
if docker ps --format "{{.Names}}" | grep -q "^db-server-postgres$"; then
    print_success "db-server-postgres is running"
    
    # Check if it's healthy
    if docker exec db-server-postgres pg_isready -U ${DB_SERVER_ADMIN_USER:-dbadmin} >/dev/null 2>&1; then
        print_success "db-server-postgres is accepting connections"
    else
        print_error "db-server-postgres is not accepting connections"
    fi
    
    # Get network info
    NETWORK=$(docker inspect db-server-postgres --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}}{{end}}' 2>/dev/null | head -1)
    if [ "$NETWORK" = "nginx-network" ]; then
        print_success "db-server-postgres is on nginx-network"
    else
        print_warning "db-server-postgres is on network: $NETWORK (expected: nginx-network)"
    fi
else
    print_error "db-server-postgres is NOT running"
    print_info "Start it with: cd $PROJECT_DIR && docker compose -f docker-compose.db-server.yml up -d"
fi

echo ""

# Check Redis
if docker ps --format "{{.Names}}" | grep -q "^db-server-redis$"; then
    print_success "db-server-redis is running"
    
    # Check if it's healthy
    if docker exec db-server-redis redis-cli ping >/dev/null 2>&1; then
        print_success "db-server-redis is accepting connections"
    else
        print_error "db-server-redis is not accepting connections"
    fi
    
    # Get network info
    NETWORK=$(docker inspect db-server-redis --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}}{{end}}' 2>/dev/null | head -1)
    if [ "$NETWORK" = "nginx-network" ]; then
        print_success "db-server-redis is on nginx-network"
    else
        print_warning "db-server-redis is on network: $NETWORK (expected: nginx-network)"
    fi
else
    print_error "db-server-redis is NOT running"
    print_info "Start it with: cd $PROJECT_DIR && docker compose -f docker-compose.db-server.yml up -d"
fi

echo ""

# 3. Check crypto-ai-agent containers
print_header "3. crypto-ai-agent Container Configuration"

CRYPTO_CONTAINERS=("crypto-ai-backend-blue" "crypto-ai-backend-green" "crypto-ai-frontend-blue" "crypto-ai-frontend-green")
FOUND_CONTAINERS=()

for container in "${CRYPTO_CONTAINERS[@]}"; do
    if docker ps -a --format "{{.Names}}" 2>/dev/null | grep -q "^${container}$"; then
        FOUND_CONTAINERS+=("$container")
    fi
done

if [ ${#FOUND_CONTAINERS[@]} -eq 0 ]; then
    print_warning "No crypto-ai-agent containers found"
    print_info "Containers may not be deployed yet"
else
    print_info "Found ${#FOUND_CONTAINERS[@]} container(s)"
    
    for container in "${FOUND_CONTAINERS[@]}"; do
        print_info "Checking container: $container"
        
        # Check network
        NETWORK=$(docker inspect "$container" --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}}{{end}}' 2>/dev/null | head -1)
        if [ "$NETWORK" = "nginx-network" ]; then
            print_success "  $container is on nginx-network"
        else
            print_error "  $container is on network: $NETWORK (expected: nginx-network)"
        fi
        
        # Check environment variables (if container is running)
        if docker ps --format "{{.Names}}" | grep -q "^${container}$"; then
            print_info "  Environment variables:"
            
            # Check for database host configuration
            DB_HOST=$(docker inspect "$container" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep -E "DB_HOST|POSTGRES_HOST|DATABASE_HOST" | head -1 || echo "")
            if [ -n "$DB_HOST" ]; then
                if echo "$DB_HOST" | grep -qE "db-server-postgres|localhost|127.0.0.1"; then
                    print_success "    $DB_HOST (correct)"
                else
                    print_warning "    $DB_HOST (should be db-server-postgres)"
                fi
            else
                print_warning "    No DB_HOST/POSTGRES_HOST found (may use default or connection string)"
            fi
            
            # Check for Redis host configuration
            REDIS_HOST=$(docker inspect "$container" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep -E "REDIS_HOST|REDIS_URL" | head -1 || echo "")
            if [ -n "$REDIS_HOST" ]; then
                if echo "$REDIS_HOST" | grep -qE "db-server-redis|localhost|127.0.0.1"; then
                    print_success "    $REDIS_HOST (correct)"
                else
                    print_warning "    $REDIS_HOST (should be db-server-redis)"
                fi
            else
                print_warning "    No REDIS_HOST/REDIS_URL found (may use default)"
            fi
        fi
        echo ""
    done
fi

echo ""

# 4. Check for service-specific containers (should not exist)
print_header "4. Service-Specific Database Containers (Should NOT Exist)"

if docker ps -a --format "{{.Names}}" 2>/dev/null | grep -q "^crypto-ai-postgres$"; then
    print_error "crypto-ai-postgres container exists (should be removed)"
    print_info "Remove it with: ./scripts/remove-crypto-ai-containers.sh"
else
    print_success "crypto-ai-postgres container does not exist (correct)"
fi

if docker ps -a --format "{{.Names}}" 2>/dev/null | grep -q "^crypto-ai-redis$"; then
    print_error "crypto-ai-redis container exists (should be removed)"
    print_info "Remove it with: ./scripts/remove-crypto-ai-containers.sh"
else
    print_success "crypto-ai-redis container does not exist (correct)"
fi

echo ""

# 5. Recommendations
print_header "5. Configuration Recommendations"

print_info "For crypto-ai-agent to use shared database-server, ensure:"
echo ""
echo "  1. Environment variables in docker-compose files should use:"
echo "     - DB_HOST=db-server-postgres (or POSTGRES_HOST=db-server-postgres)"
echo "     - REDIS_HOST=db-server-redis (or REDIS_URL=redis://db-server-redis:6379)"
echo ""
echo "  2. Connection strings should use container names:"
echo "     - PostgreSQL: postgresql://user:pass@db-server-postgres:5432/dbname"
echo "     - Redis: redis://db-server-redis:6379"
echo ""
echo "  3. All containers must be on nginx-network:"
echo "     - db-server-postgres: nginx-network"
echo "     - db-server-redis: nginx-network"
echo "     - crypto-ai-backend-*: nginx-network"
echo "     - crypto-ai-frontend-*: nginx-network"
echo ""
print_info "To check docker-compose files in crypto-ai-agent repository:"
echo "  cd /home/statex/crypto-ai-agent"
echo "  grep -r 'DB_HOST\|POSTGRES_HOST\|DATABASE_URL' docker-compose*.yml"
echo "  grep -r 'REDIS_HOST\|REDIS_URL' docker-compose*.yml"

echo ""
print_header "Verification Complete"

