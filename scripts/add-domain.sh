#!/bin/bash
# Add Domain Script
# Usage: add-domain.sh <domain> <container-name> [port] [email]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="${PROJECT_DIR}/nginx/conf.d"
TEMPLATE_FILE="${PROJECT_DIR}/nginx/templates/domain.conf.template"

DOMAIN="$1"
CONTAINER_NAME="$2"
PORT="${3:-3000}"
EMAIL="${4:-${CERTBOT_EMAIL:-admin@statex.cz}}"

# Validate inputs
if [ -z "$DOMAIN" ] || [ -z "$CONTAINER_NAME" ]; then
    echo "Error: Domain and container name are required"
    echo "Usage: add-domain.sh <domain> <container-name> [port] [email]"
    echo ""
    echo "Example:"
    echo "  add-domain.sh example.com my-app 3000"
    echo "  add-domain.sh subdomain.example.com my-app 8080 admin@example.com"
    exit 1
fi

# Validate domain format
if ! echo "$DOMAIN" | grep -qE '^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'; then
    echo "Error: Invalid domain format: $DOMAIN"
    exit 1
fi

# Check if config already exists
CONFIG_FILE="${CONFIG_DIR}/${DOMAIN}.conf"
if [ -f "$CONFIG_FILE" ]; then
    echo "Warning: Configuration file already exists: $CONFIG_FILE"
    read -p "Do you want to overwrite it? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi
fi

# Check if template exists
if [ ! -f "$TEMPLATE_FILE" ]; then
    echo "Error: Template file not found: $TEMPLATE_FILE"
    exit 1
fi

echo "Adding domain: $DOMAIN"
echo "  Container: $CONTAINER_NAME"
echo "  Port: $PORT"
echo "  Email: $EMAIL"
echo ""

# Generate config file from template
echo "Generating configuration file..."
sed -e "s|{{DOMAIN_NAME}}|$DOMAIN|g" \
    -e "s|{{CONTAINER_NAME}}|$CONTAINER_NAME|g" \
    -e "s|{{CONTAINER_PORT}}|$PORT|g" \
    "$TEMPLATE_FILE" > "$CONFIG_FILE"

echo "✅ Configuration file created: $CONFIG_FILE"

# Check certificate
echo ""
echo "Checking certificate status..."
CERT_DIR="${PROJECT_DIR}/certificates/${DOMAIN}"
FULLCHAIN="${CERT_DIR}/fullchain.pem"
PRIVKEY="${CERT_DIR}/privkey.pem"

if [ -f "$FULLCHAIN" ] && [ -f "$PRIVKEY" ]; then
    echo "✅ Certificate found locally"
    
    # Check expiration
    EXPIRY_DATE=$(openssl x509 -enddate -noout -in "$FULLCHAIN" | cut -d= -f2)
    EXPIRY_EPOCH=$(date -d "$EXPIRY_DATE" +%s 2>/dev/null || date -j -f "%b %d %H:%M:%S %Y %Z" "$EXPIRY_DATE" +%s 2>/dev/null || echo "0")
    
    if [ "$EXPIRY_EPOCH" != "0" ]; then
        CURRENT_EPOCH=$(date +%s)
        DAYS_UNTIL_EXPIRY=$(( ($EXPIRY_EPOCH - $CURRENT_EPOCH) / 86400 ))
        
        if [ $DAYS_UNTIL_EXPIRY -lt 30 ]; then
            echo "⚠️  Certificate expires in ${DAYS_UNTIL_EXPIRY} days. Consider renewing."
        fi
    fi
else
    echo "⚠️  Certificate not found. Requesting new certificate..."
    
    # Request certificate via certbot container
    if docker compose -f "${PROJECT_DIR}/docker-compose.yml" run --rm certbot /scripts/request-cert.sh "$DOMAIN" "$EMAIL"; then
        echo "✅ Certificate requested successfully"
    else
        echo "⚠️  Certificate request failed. You can request it manually later."
        echo "   Run: docker compose run --rm certbot /scripts/request-cert.sh $DOMAIN $EMAIL"
    fi
fi

# Test nginx configuration
echo ""
echo "Testing nginx configuration..."
if docker compose -f "${PROJECT_DIR}/docker-compose.yml" exec nginx nginx -t 2>&1 | grep -q "syntax is ok"; then
    echo "✅ Nginx configuration is valid"
else
    echo "❌ Nginx configuration test failed!"
    echo "Please check the configuration file: $CONFIG_FILE"
    exit 1
fi

# Reload nginx
echo ""
echo "Reloading nginx..."
if docker compose -f "${PROJECT_DIR}/docker-compose.yml" exec nginx nginx -s reload; then
    echo "✅ Nginx reloaded successfully"
else
    echo "⚠️  Failed to reload nginx. Please reload manually:"
    echo "   docker compose exec nginx nginx -s reload"
fi

# Verify container accessibility
echo ""
echo "Verifying container accessibility..."
if docker network inspect nginx-network >/dev/null 2>&1; then
    if docker run --rm --network nginx-network alpine/curl:latest curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://${CONTAINER_NAME}:${PORT}" >/dev/null 2>&1; then
        echo "✅ Container ${CONTAINER_NAME}:${PORT} is accessible"
    else
        echo "⚠️  Warning: Could not verify container ${CONTAINER_NAME}:${PORT} accessibility"
        echo "   Make sure the container is running and on the nginx-network"
    fi
else
    echo "⚠️  Warning: nginx-network not found. Create it with:"
    echo "   docker network create nginx-network"
fi

echo ""
echo "✅ Domain $DOMAIN added successfully!"
echo ""
echo "Next steps:"
echo "  1. Ensure your container '${CONTAINER_NAME}' is running and connected to nginx-network"
echo "  2. Test the domain: curl -I https://${DOMAIN}"
echo "  3. View logs: docker compose logs nginx"

