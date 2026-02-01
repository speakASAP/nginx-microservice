#!/bin/bash
# Check Internet Access Setup
# Verifies DNS, port forwarding, firewall, and nginx configuration for internet access

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║     Internet Access Setup Verification                     ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Get server information
INTERNAL_IP=$(ip addr show | grep -E "inet 192\.168\." | head -1 | awk '{print $2}' | cut -d'/' -f1)
PUBLIC_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || curl -s --max-time 5 icanhazip.com 2>/dev/null || echo "Unable to determine")

echo -e "${BLUE}Server Information:${NC}"
echo "  Internal IP: ${INTERNAL_IP:-Not found}"
echo "  Public IP: ${PUBLIC_IP}"
echo ""

# Check 1: Nginx container status
echo -e "${BLUE}1. Checking Nginx Container...${NC}"
if docker ps --filter "name=nginx-microservice" --format "{{.Names}}" | grep -q "nginx-microservice"; then
    echo -e "  ${GREEN}✅ Nginx container is running${NC}"
    NGINX_PORTS=$(docker ps --filter "name=nginx-microservice" --format "{{.Ports}}")
    echo "  Ports: $NGINX_PORTS"
    
    # Check if ports are mapped correctly
    if echo "$NGINX_PORTS" | grep -qE "0\.0\.0\.0:80->|0\.0\.0\.0:443->"; then
        echo -e "  ${GREEN}✅ Ports are mapped to all interfaces (0.0.0.0)${NC}"
    else
        echo -e "  ${YELLOW}⚠️  Ports may not be mapped to all interfaces${NC}"
    fi
else
    echo -e "  ${RED}❌ Nginx container is not running${NC}"
    echo "  Start with: cd $NGINX_PROJECT_DIR && ./scripts/start-nginx.sh"
fi
echo ""

# Check 2: Port listening status
echo -e "${BLUE}2. Checking Port Listening Status...${NC}"
if command -v ss >/dev/null 2>&1; then
    PORT_80=$(sudo ss -tlnp 2>/dev/null | grep ":80 " | head -1 || echo "")
    PORT_443=$(sudo ss -tlnp 2>/dev/null | grep ":443 " | head -1 || echo "")
elif command -v netstat >/dev/null 2>&1; then
    PORT_80=$(sudo netstat -tlnp 2>/dev/null | grep ":80 " | head -1 || echo "")
    PORT_443=$(sudo netstat -tlnp 2>/dev/null | grep ":443 " | head -1 || echo "")
else
    PORT_80=""
    PORT_443=""
    echo -e "  ${YELLOW}⚠️  Cannot check ports (ss/netstat not available)${NC}"
fi

if [ -n "$PORT_80" ]; then
    if echo "$PORT_80" | grep -q "0.0.0.0:80"; then
        echo -e "  ${GREEN}✅ Port 80 is listening on all interfaces${NC}"
    else
        echo -e "  ${YELLOW}⚠️  Port 80: $PORT_80${NC}"
    fi
else
    echo -e "  ${RED}❌ Port 80 is not listening${NC}"
fi

if [ -n "$PORT_443" ]; then
    if echo "$PORT_443" | grep -q "0.0.0.0:443"; then
        echo -e "  ${GREEN}✅ Port 443 is listening on all interfaces${NC}"
    else
        echo -e "  ${YELLOW}⚠️  Port 443: $PORT_443${NC}"
    fi
else
    echo -e "  ${RED}❌ Port 443 is not listening${NC}"
fi
echo ""

# Check 3: Firewall status
echo -e "${BLUE}3. Checking Firewall Configuration...${NC}"
if command -v ufw >/dev/null 2>&1; then
    UFW_STATUS=$(sudo ufw status 2>/dev/null | head -1 || echo "")
    if echo "$UFW_STATUS" | grep -qi "active"; then
        echo "  UFW Status: Active"
        UFW_80=$(sudo ufw status 2>/dev/null | grep "80/tcp" || echo "")
        UFW_443=$(sudo ufw status 2>/dev/null | grep "443/tcp" || echo "")
        
        if [ -n "$UFW_80" ]; then
            echo -e "  ${GREEN}✅ Port 80 is allowed in UFW${NC}"
        else
            echo -e "  ${RED}❌ Port 80 is not allowed in UFW${NC}"
            echo "    Fix with: sudo ufw allow 80/tcp"
        fi
        
        if [ -n "$UFW_443" ]; then
            echo -e "  ${GREEN}✅ Port 443 is allowed in UFW${NC}"
        else
            echo -e "  ${RED}❌ Port 443 is not allowed in UFW${NC}"
            echo "    Fix with: sudo ufw allow 443/tcp"
        fi
    else
        echo -e "  ${YELLOW}⚠️  UFW is not active${NC}"
    fi
elif command -v firewall-cmd >/dev/null 2>&1; then
    if sudo firewall-cmd --state 2>/dev/null | grep -q "running"; then
        echo "  Firewalld Status: Running"
        FIREWALLD_HTTP=$(sudo firewall-cmd --list-services 2>/dev/null | grep -q "http" && echo "yes" || echo "no")
        FIREWALLD_HTTPS=$(sudo firewall-cmd --list-services 2>/dev/null | grep -q "https" && echo "yes" || echo "no")
        
        if [ "$FIREWALLD_HTTP" = "yes" ]; then
            echo -e "  ${GREEN}✅ HTTP service is allowed in firewalld${NC}"
        else
            echo -e "  ${RED}❌ HTTP service is not allowed in firewalld${NC}"
            echo "    Fix with: sudo firewall-cmd --permanent --add-service=http && sudo firewall-cmd --reload"
        fi
        
        if [ "$FIREWALLD_HTTPS" = "yes" ]; then
            echo -e "  ${GREEN}✅ HTTPS service is allowed in firewalld${NC}"
        else
            echo -e "  ${RED}❌ HTTPS service is not allowed in firewalld${NC}"
            echo "    Fix with: sudo firewall-cmd --permanent --add-service=https && sudo firewall-cmd --reload"
        fi
    else
        echo -e "  ${YELLOW}⚠️  Firewalld is not running${NC}"
    fi
else
    echo -e "  ${YELLOW}⚠️  Cannot check firewall (ufw/firewalld not available)${NC}"
fi
echo ""

# Check 4: DNS resolution (if domain provided)
if [ -n "$1" ]; then
    DOMAIN="$1"
    echo -e "${BLUE}4. Checking DNS Resolution for $DOMAIN...${NC}"
    
    if command -v dig >/dev/null 2>&1; then
        DNS_RESULT=$(dig +short "$DOMAIN" 2>/dev/null | head -1 || echo "")
    elif command -v nslookup >/dev/null 2>&1; then
        DNS_RESULT=$(nslookup "$DOMAIN" 2>/dev/null | grep -A 1 "Name:" | tail -1 | awk '{print $2}' || echo "")
    else
        DNS_RESULT=""
    fi
    
    if [ -n "$DNS_RESULT" ]; then
        echo "  DNS resolves to: $DNS_RESULT"
        if [ "$DNS_RESULT" = "$PUBLIC_IP" ]; then
            echo -e "  ${GREEN}✅ DNS points to your public IP${NC}"
        else
            echo -e "  ${YELLOW}⚠️  DNS points to different IP (expected: $PUBLIC_IP)${NC}"
        fi
    else
        echo -e "  ${RED}❌ Cannot resolve DNS for $DOMAIN${NC}"
    fi
    echo ""
fi

# Check 5: Port forwarding test (requires external network)
echo -e "${BLUE}5. Port Forwarding Test (External Access)...${NC}"
echo "  ${YELLOW}Note: This test requires external network access${NC}"
echo "  To test from external network:"
echo "    curl -I http://$PUBLIC_IP"
echo "    curl -I https://$PUBLIC_IP"
if [ -n "$1" ]; then
    echo "    curl -I http://$DOMAIN"
    echo "    curl -I https://$DOMAIN"
fi
echo ""

# Summary
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}Summary${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo ""
echo "To complete internet access setup:"
echo ""
echo "1. Configure DNS records:"
echo "   - Point your domains to: $PUBLIC_IP"
echo "   - Example: allegro.alfares.cz → $PUBLIC_IP"
echo ""
echo "2. Configure router port forwarding:"
echo "   - External Port 80 → Internal IP $INTERNAL_IP Port 80"
echo "   - External Port 443 → Internal IP $INTERNAL_IP Port 443"
echo ""
echo "3. Ensure firewall allows ports 80 and 443 (see above)"
echo ""
echo "4. Test from external network (use mobile hotspot)"
echo ""
echo "For detailed instructions, see:"
echo "  $NGINX_PROJECT_DIR/docs/INTERNET_ACCESS_SETUP.md"
echo ""

exit 0
