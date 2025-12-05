#!/bin/bash
# Add Domain Script
# Usage: add-domain.sh <domain> <container-name> [port] [email]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="${PROJECT_DIR}/nginx/conf.d"
TEMPLATE_FILE="${PROJECT_DIR}/nginx/templates/domain.conf.template"
BLUE_GREEN_DIR="${SCRIPT_DIR}/blue-green"

# Load environment variables from .env
if [ -f "${PROJECT_DIR}/.env" ]; then
    set -a
    source "${PROJECT_DIR}/.env" 2>/dev/null || true
    set +a
fi

# Set defaults if not in .env
NETWORK_NAME="${NETWORK_NAME:-nginx-network}"

# Source blue/green utilities for validation and safe reload
if [ -f "${BLUE_GREEN_DIR}/utils.sh" ]; then
    # shellcheck disable=SC1090
    source "${BLUE_GREEN_DIR}/utils.sh"
else
    echo "Error: Blue/Green utils not found: ${BLUE_GREEN_DIR}/utils.sh"
    echo "Nginx config validation system is required for safe domain addition."
    exit 1
fi

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
    echo "  add-domain.sh subdomain.example.com my-app 3602 admin@example.com"
    exit 1
fi

# Validate domain format
if ! echo "$DOMAIN" | grep -qE '^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'; then
    echo "Error: Invalid domain format: $DOMAIN"
    exit 1
fi

# Check if config already exists (symlink or file)
SYMLINK_FILE="${CONFIG_DIR}/${DOMAIN}.conf"
if [ -L "$SYMLINK_FILE" ] || [ -f "$SYMLINK_FILE" ]; then
    echo "Warning: Nginx configuration already exists for domain: $SYMLINK_FILE"
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

# Ensure validation directories exist
ensure_config_directories

STAGING_DIR="${CONFIG_DIR}/staging"
BLUE_GREEN_CONF_DIR="${CONFIG_DIR}/blue-green"
STAGING_CONFIG_FILE="${STAGING_DIR}/${DOMAIN}.blue.conf"
VALIDATED_CONFIG_FILE="${BLUE_GREEN_CONF_DIR}/${DOMAIN}.blue.conf"

# Prevent accidental overwrite of an existing validated config
if [ -f "$VALIDATED_CONFIG_FILE" ]; then
    echo "Warning: Validated config already exists: $VALIDATED_CONFIG_FILE"
    read -p "Do you want to regenerate and re-validate it? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi
fi

echo "Adding domain: $DOMAIN"
echo "  Container: $CONTAINER_NAME"
echo "  Port: $PORT"
echo "  Email: $EMAIL"
echo ""

# Generate config file from template into staging (blue config)
echo "Generating nginx configuration file into staging (validation-first)..."
mkdir -p "$STAGING_DIR"
sed -e "s|{{DOMAIN_NAME}}|$DOMAIN|g" \
    -e "s|{{CONTAINER_NAME}}|$CONTAINER_NAME|g" \
    -e "s|{{CONTAINER_PORT}}|$PORT|g" \
    "$TEMPLATE_FILE" > "$STAGING_CONFIG_FILE"

echo "✅ Staging configuration file created: $STAGING_CONFIG_FILE"

# Validate and apply config using central validation system
echo ""
echo "Validating nginx configuration in isolation..."
if validate_and_apply_config "$DOMAIN" "$DOMAIN" "blue" "$STAGING_CONFIG_FILE"; then
    echo "✅ Configuration validated and applied to blue-green directory:"
    echo "   $VALIDATED_CONFIG_FILE"
else
    echo "❌ Configuration validation failed for domain: $DOMAIN"
    echo "   Invalid config has been moved to nginx/conf.d/rejected/ with a timestamp."
    echo "   Nginx continues running with existing valid configs."
    exit 1
fi

# Ensure symlink points to the validated config
echo ""
echo "Updating nginx symlink for domain..."
if switch_config_symlink "$DOMAIN" "blue"; then
    echo "✅ Symlink updated: ${CONFIG_DIR}/${DOMAIN}.conf -> blue-green/${DOMAIN}.blue.conf"
else
    echo "❌ Failed to update nginx config symlink for domain: $DOMAIN"
    exit 1
fi

# Certificate Management
# Certificates are stored in ./certificates/<domain>/ on the host filesystem
# This directory is mounted to:
# - /etc/letsencrypt/ in certbot container (for certificate management)
# - /etc/nginx/certs/ in nginx container (for SSL configuration)
#
# Certificate files:
# - fullchain.pem: Certificate chain (domain cert + intermediate certs)
# - privkey.pem: Private key (must be kept secure)
#
# IMPORTANT: After requesting a certificate, it's automatically copied to ./certificates/<domain>/
# by the request-cert.sh script. The nginx config should reference:
# ssl_certificate /etc/nginx/certs/<domain>/fullchain.pem;
# ssl_certificate_key /etc/nginx/certs/<domain>/privkey.pem;
echo ""
echo "Checking certificate status..."
CERT_DIR="${PROJECT_DIR}/certificates/${DOMAIN}"
FULLCHAIN="${CERT_DIR}/fullchain.pem"
PRIVKEY="${CERT_DIR}/privkey.pem"

if [ -f "$FULLCHAIN" ] && [ -f "$PRIVKEY" ]; then
    echo "✅ Certificate found locally"
    
    # Check expiration
    # Let's Encrypt certificates are valid for 90 days
    # We check if renewal is needed (< 30 days remaining)
    EXPIRY_DATE=$(openssl x509 -enddate -noout -in "$FULLCHAIN" | cut -d= -f2)
    EXPIRY_EPOCH=$(date -d "$EXPIRY_DATE" +%s 2>/dev/null || date -j -f "%b %d %H:%M:%S %Y %Z" "$EXPIRY_DATE" +%s 2>/dev/null || echo "0")
    
    if [ "$EXPIRY_EPOCH" != "0" ]; then
        CURRENT_EPOCH=$(date +%s)
        DAYS_UNTIL_EXPIRY=$(( ($EXPIRY_EPOCH - $CURRENT_EPOCH) / 86400 ))
        
        if [ $DAYS_UNTIL_EXPIRY -lt 30 ]; then
            echo "⚠️  Certificate expires in ${DAYS_UNTIL_EXPIRY} days. Consider renewing."
            echo "   Run: docker compose run --rm certbot /scripts/renew-cert.sh"
        fi
    fi
else
    echo "⚠️  Certificate not found. Requesting new certificate..."
    echo "   This will use Let's Encrypt webroot validation."
    echo "   Make sure the domain DNS points to this server and port 80 is accessible."
    
    # Request certificate via certbot container
    # The request-cert.sh script will:
    # 1. Request certificate from Let's Encrypt
    # 2. Validate domain ownership via webroot challenge
    # 3. Copy certificate files to ./certificates/<domain>/ on host
    # 4. Set proper file permissions
    if docker compose -f "${PROJECT_DIR}/docker-compose.yml" run --rm certbot /scripts/request-cert.sh "$DOMAIN" "$EMAIL"; then
        echo "✅ Certificate requested successfully"
        echo "   Certificate location: ${CERT_DIR}/"
        echo "   Update nginx config to use: /etc/nginx/certs/${DOMAIN}/fullchain.pem"
    else
        echo "⚠️  Certificate request failed. You can request it manually later."
        echo "   Run: docker compose run --rm certbot /scripts/request-cert.sh $DOMAIN $EMAIL"
        echo "   Troubleshooting:"
        echo "   - Check DNS: dig $DOMAIN"
        echo "   - Check port 80: curl http://$DOMAIN/.well-known/acme-challenge/test"
        echo "   - Check certbot logs: docker compose logs certbot"
    fi
fi

# Reload nginx safely using shared helper
echo ""
echo "Reloading nginx (safe reload via validation-aware helper)..."
if reload_nginx; then
    echo "✅ Nginx reloaded (or started) successfully"
else
    echo "⚠️  Nginx reload helper reported an issue. Please inspect logs:"
    echo "   docker compose logs nginx"
fi

# Verify container accessibility
echo ""
echo "Verifying container accessibility..."
    local health_check_image="${HEALTH_CHECK_IMAGE:-alpine/curl:latest}"
    if docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
        if docker run --rm --network "${NETWORK_NAME}" "${health_check_image}" curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://${CONTAINER_NAME}:${PORT}" >/dev/null 2>&1; then
        echo "✅ Container ${CONTAINER_NAME}:${PORT} is accessible"
    else
        echo "⚠️  Warning: Could not verify container ${CONTAINER_NAME}:${PORT} accessibility"
        echo "   Make sure the container is running and on the ${NETWORK_NAME}"
    fi
else
    echo "⚠️  Warning: ${NETWORK_NAME} not found. Create it with:"
    echo "   docker network create ${NETWORK_NAME}"
fi

echo ""
echo "✅ Domain $DOMAIN added successfully!"
echo ""
echo "Next steps:"
echo "  1. Ensure your container '${CONTAINER_NAME}' is running and connected to ${NETWORK_NAME}"
echo "  2. Test the domain: curl -I https://${DOMAIN}"
echo "  3. View logs: docker compose logs nginx"

