#!/bin/bash
# Remove Domain Script
# Usage: remove-domain.sh <domain> [--remove-cert]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="${PROJECT_DIR}/nginx/conf.d"
CERT_DIR="${PROJECT_DIR}/certificates"

DOMAIN="$1"
REMOVE_CERT=false

if [ "$2" = "--remove-cert" ]; then
    REMOVE_CERT=true
fi

# Validate input
if [ -z "$DOMAIN" ]; then
    echo "Error: Domain name is required"
    echo "Usage: remove-domain.sh <domain> [--remove-cert]"
    echo ""
    echo "Example:"
    echo "  remove-domain.sh example.com"
    echo "  remove-domain.sh example.com --remove-cert"
    exit 1
fi

CONFIG_FILE="${CONFIG_DIR}/${DOMAIN}.conf"

# Check if config exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Configuration file not found: $CONFIG_FILE"
    exit 1
fi

echo "Removing domain: $DOMAIN"
echo ""

# Confirm removal
read -p "Are you sure you want to remove $DOMAIN? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

# Remove config file
echo "Removing configuration file..."
rm -f "$CONFIG_FILE"
echo "✅ Configuration file removed: $CONFIG_FILE"

# Remove certificate if requested
if [ "$REMOVE_CERT" = true ]; then
    CERT_DOMAIN_DIR="${CERT_DIR}/${DOMAIN}"
    if [ -d "$CERT_DOMAIN_DIR" ]; then
        echo "Removing certificate..."
        rm -rf "$CERT_DOMAIN_DIR"
        echo "✅ Certificate removed: $CERT_DOMAIN_DIR"
    else
        echo "⚠️  Certificate directory not found: $CERT_DOMAIN_DIR"
    fi
fi

# Test nginx configuration
echo ""
echo "Testing nginx configuration..."
if docker compose -f "${PROJECT_DIR}/docker-compose.yml" exec nginx nginx -t 2>&1 | grep -q "syntax is ok"; then
    echo "✅ Nginx configuration is valid"
else
    echo "❌ Nginx configuration test failed!"
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

echo ""
echo "✅ Domain $DOMAIN removed successfully!"

