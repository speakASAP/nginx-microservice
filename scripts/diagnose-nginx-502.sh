#!/bin/bash

# Diagnose Nginx 502 Errors
# This script helps identify why nginx is returning 502 errors

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load environment variables from .env
if [ -f "${PROJECT_DIR}/.env" ]; then
    set -a
    source "${PROJECT_DIR}/.env" 2>/dev/null || true
    set +a
fi

# Set defaults if not in .env
NETWORK_NAME="${NETWORK_NAME:-nginx-network}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}🔍 Diagnosing Nginx 502 Errors${NC}\n"

# Check 1: Container names
echo -e "${YELLOW}1. Checking Container Names${NC}"
echo "----------------------------------------"
CONTAINERS=$(docker ps --format "{{.Names}}" | grep allegro || echo "")
if [ -z "$CONTAINERS" ]; then
    echo -e "${RED}❌ No Allegro containers found${NC}"
else
    echo -e "${GREEN}✅ Found containers:${NC}"
    echo "$CONTAINERS" | while read container; do
        echo "   - $container"
    done
fi
echo ""

# Check 2: Network connectivity
echo -e "${YELLOW}2. Checking Network Connectivity${NC}"
echo "----------------------------------------"
if docker network inspect "${NETWORK_NAME}" > /dev/null 2>&1; then
    echo -e "${GREEN}✅ ${NETWORK_NAME} exists${NC}"
    
    # Check if containers are on the network
    NETWORK_CONTAINERS=$(docker network inspect "${NETWORK_NAME}" --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null || echo "")
    if echo "$NETWORK_CONTAINERS" | grep -q "allegro"; then
        echo -e "${GREEN}✅ Allegro containers are on ${NETWORK_NAME}${NC}"
        echo "   Containers on network:"
        echo "$NETWORK_CONTAINERS" | tr ' ' '\n' | grep allegro | sed 's/^/   - /'
    else
        echo -e "${RED}❌ No Allegro containers found on ${NETWORK_NAME}${NC}"
        echo "   Available containers on network:"
        echo "$NETWORK_CONTAINERS" | tr ' ' '\n' | sed 's/^/   - /'
    fi
else
    echo -e "${RED}❌ ${NETWORK_NAME} does not exist${NC}"
    echo "   Create it with: docker network create ${NETWORK_NAME}"
fi
echo ""

# Check 3: Service health from within Docker network
echo -e "${YELLOW}3. Testing Service Health (from Docker network)${NC}"
echo "----------------------------------------"

# Test API Gateway
if docker ps --format "{{.Names}}" | grep -q "allegro-api-gateway"; then
    GATEWAY_CONTAINER=$(docker ps --format "{{.Names}}" | grep "allegro-api-gateway" | head -1)
    echo -n "Testing $GATEWAY_CONTAINER:3411/health ... "
    if docker exec "$GATEWAY_CONTAINER" curl -sf http://localhost:3411/health > /dev/null 2>&1; then
        echo -e "${GREEN}✅ OK${NC}"
    else
        echo -e "${RED}❌ FAILED${NC}"
    fi
else
    echo -e "${RED}❌ API Gateway container not found${NC}"
fi

# Test Frontend Service
if docker ps --format "{{.Names}}" | grep -q "allegro-frontend-service"; then
    FRONTEND_CONTAINER=$(docker ps --format "{{.Names}}" | grep "allegro-frontend-service" | head -1)
    echo -n "Testing $FRONTEND_CONTAINER:3410/health ... "
    if docker exec "$FRONTEND_CONTAINER" curl -sf http://localhost:3410/health > /dev/null 2>&1; then
        echo -e "${GREEN}✅ OK${NC}"
    else
        echo -e "${RED}❌ FAILED${NC}"
    fi
else
    echo -e "${RED}❌ Frontend Service container not found${NC}"
fi
echo ""

# Check 4: Nginx connectivity to services
echo -e "${YELLOW}4. Testing Nginx → Service Connectivity${NC}"
echo "----------------------------------------"
if docker ps --format "{{.Names}}" | grep -q "nginx-microservice\|nginx"; then
    NGINX_CONTAINER=$(docker ps --format "{{.Names}}" | grep -E "nginx-microservice|nginx" | head -1)
    echo "Nginx container: $NGINX_CONTAINER"
    
    # Test ping to API Gateway
    if docker ps --format "{{.Names}}" | grep -q "allegro-api-gateway"; then
        GATEWAY_NAME=$(docker ps --format "{{.Names}}" | grep "allegro-api-gateway" | head -1)
        echo -n "Ping $GATEWAY_NAME from nginx ... "
        if docker exec "$NGINX_CONTAINER" ping -c 1 -W 2 "$GATEWAY_NAME" > /dev/null 2>&1; then
            echo -e "${GREEN}✅ OK${NC}"
        else
            echo -e "${RED}❌ FAILED - Cannot reach from nginx${NC}"
        fi
        
        echo -n "HTTP test to $GATEWAY_NAME:3411/health ... "
        if docker exec "$NGINX_CONTAINER" curl -sf http://"$GATEWAY_NAME":3411/health > /dev/null 2>&1; then
            echo -e "${GREEN}✅ OK${NC}"
        else
            echo -e "${RED}❌ FAILED - Cannot reach HTTP endpoint${NC}"
        fi
    fi
    
    # Test ping to Frontend
    if docker ps --format "{{.Names}}" | grep -q "allegro-frontend-service"; then
        FRONTEND_NAME=$(docker ps --format "{{.Names}}" | grep "allegro-frontend-service" | head -1)
        echo -n "Ping $FRONTEND_NAME from nginx ... "
        if docker exec "$NGINX_CONTAINER" ping -c 1 -W 2 "$FRONTEND_NAME" > /dev/null 2>&1; then
            echo -e "${GREEN}✅ OK${NC}"
        else
            echo -e "${RED}❌ FAILED - Cannot reach from nginx${NC}"
        fi
        
        echo -n "HTTP test to $FRONTEND_NAME:3410/health ... "
        if docker exec "$NGINX_CONTAINER" curl -sf http://"$FRONTEND_NAME":3410/health > /dev/null 2>&1; then
            echo -e "${GREEN}✅ OK${NC}"
        else
            echo -e "${RED}❌ FAILED - Cannot reach HTTP endpoint${NC}"
        fi
    fi
else
    echo -e "${YELLOW}⚠️  Nginx container not found (may be in different repository)${NC}"
fi
echo ""

# Check 5: Nginx configuration
echo -e "${YELLOW}5. Nginx Configuration Check${NC}"
echo "----------------------------------------"
echo -e "${BLUE}Note: Nginx configuration is in nginx-microservice repository${NC}"
echo ""
echo "Required upstream blocks in nginx config:"
echo "  upstream allegro-api-gateway {"
echo "      server allegro-api-gateway-blue:3411;"
echo "  }"
echo ""
echo "  upstream allegro-frontend-service {"
echo "      server allegro-frontend-service-blue:3410;"
echo "  }"
echo ""
echo "Required location blocks:"
echo "  location /api/ {"
echo "      proxy_pass http://allegro-api-gateway;"
echo "  }"
echo ""
echo "  location / {"
echo "      proxy_pass http://allegro-frontend-service;"
echo "  }"
echo ""

# Summary
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Summary & Next Steps${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo "If services are running but nginx returns 502:"
echo "  1. Check nginx configuration in nginx-microservice repository"
echo "  2. Verify upstream blocks point to correct container names"
echo "  3. Ensure all services are on nginx-network"
echo "  4. Test connectivity from nginx container"
echo "  5. Check nginx error logs: docker exec nginx-microservice tail -f /var/log/nginx/error.log"
echo ""
echo "See docs/NGINX_CONFIGURATION.md for complete configuration guide"
echo ""

