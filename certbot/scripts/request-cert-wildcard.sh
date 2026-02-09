#!/bin/bash
# Request wildcard certificate via DNS-01 challenge (Let's Encrypt).
# Usage: request-cert-wildcard.sh <base_domain> [email]
# Example: request-cert-wildcard.sh sgipreal.com
# Issues: *.sgipreal.com + sgipreal.com (one cert, DNS-01 only).
#
# Prerequisites:
# - Cloudflare API token in /etc/letsencrypt/secrets/cloudflare.ini (mount ./secrets)
#   Content: dns_cloudflare_api_token = YOUR_TOKEN
# - Domain DNS managed by Cloudflare (or use another certbot DNS plugin and adapt script)

set -e

BASE_DOMAIN="$1"
EMAIL="${2:-${CERTBOT_EMAIL:-admin@example.com}}"
STAGING="${CERTBOT_STAGING:-false}"

if [ -z "$BASE_DOMAIN" ]; then
    echo "Error: Base domain required (e.g. sgipreal.com)"
    echo "Usage: request-cert-wildcard.sh <base_domain> [email]"
    exit 1
fi

# Certbot stores wildcard cert under the base domain name
CERT_DIR="/etc/letsencrypt/live/${BASE_DOMAIN}"
HOST_CERT_DIR="/etc/letsencrypt/${BASE_DOMAIN}"
FULLCHAIN="${CERT_DIR}/fullchain.pem"
PRIVKEY="${CERT_DIR}/privkey.pem"
CF_CREDENTIALS="/etc/letsencrypt/secrets/cloudflare.ini"

if [ ! -f "$CF_CREDENTIALS" ]; then
    echo "Error: Cloudflare credentials not found at $CF_CREDENTIALS"
    echo "Create secrets/cloudflare.ini with: dns_cloudflare_api_token = YOUR_TOKEN"
    echo "And mount secrets/ to /etc/letsencrypt/secrets in the certbot container."
    exit 1
fi

# Check if wildcard cert already exists and is valid (> 30 days)
# Use openssl -checkend (portable; avoids date -d which fails on Alpine/busybox)
SECONDS_30_DAYS=2592000
if [ -f "$FULLCHAIN" ] && [ -f "$PRIVKEY" ]; then
    if openssl x509 -in "$FULLCHAIN" -noout -checkend "$SECONDS_30_DAYS" 2>/dev/null; then
        DAYS_UNTIL_EXPIRY=$(( SECONDS_30_DAYS / 86400 ))
        echo "Wildcard certificate for *.${BASE_DOMAIN} exists and is valid for ${DAYS_UNTIL_EXPIRY} more days"
        mkdir -p "$HOST_CERT_DIR"
        cp -L "$FULLCHAIN" "${HOST_CERT_DIR}/fullchain.pem"
        cp -L "$PRIVKEY" "${HOST_CERT_DIR}/privkey.pem"
        chmod 644 "${HOST_CERT_DIR}/fullchain.pem"
        chmod 600 "${HOST_CERT_DIR}/privkey.pem"
        echo "Certificate already exists and is valid. Skipping request."
        exit 0
    fi
fi

STAGING_FLAG=""
if [ "$STAGING" = "true" ]; then
    STAGING_FLAG="--staging"
    echo "Using Let's Encrypt staging environment"
fi

echo "Requesting wildcard certificate for *.${BASE_DOMAIN} and ${BASE_DOMAIN} (DNS-01)..."
certbot certonly \
    --dns-cloudflare \
    --dns-cloudflare-credentials "$CF_CREDENTIALS" \
    --dns-cloudflare-propagation-seconds 30 \
    --email "$EMAIL" \
    --agree-tos \
    --no-eff-email \
    --non-interactive \
    --expand \
    $STAGING_FLAG \
    -d "*.${BASE_DOMAIN}" \
    -d "${BASE_DOMAIN}" \
    --logs-dir=/var/log/certbot \
    --config-dir=/etc/letsencrypt \
    --work-dir=/var/lib/letsencrypt

if [ -f "$FULLCHAIN" ] && [ -f "$PRIVKEY" ]; then
    echo "Wildcard certificate created successfully for *.${BASE_DOMAIN}"
    mkdir -p "$HOST_CERT_DIR"
    cp -L "$FULLCHAIN" "${HOST_CERT_DIR}/fullchain.pem"
    cp -L "$PRIVKEY" "${HOST_CERT_DIR}/privkey.pem"
    chmod 644 "${HOST_CERT_DIR}/fullchain.pem"
    chmod 600 "${HOST_CERT_DIR}/privkey.pem"
    echo "Certificate location: ${HOST_CERT_DIR}/"
    echo "Use this cert for all subdomains (e.g. database-server.${BASE_DOMAIN}) via symlink or same path."
    exit 0
else
    echo "Error: Wildcard certificate creation failed for *.${BASE_DOMAIN}"
    exit 1
fi
