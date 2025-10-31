#!/bin/bash
# Certbot Certificate Request Script
# Usage: request-cert.sh <domain> [email]

set -e

DOMAIN="$1"
EMAIL="${2:-${CERTBOT_EMAIL:-admin@statex.cz}}"
STAGING="${CERTBOT_STAGING:-false}"

if [ -z "$DOMAIN" ]; then
    echo "Error: Domain name required"
    echo "Usage: request-cert.sh <domain> [email]"
    exit 1
fi

# Certificate paths
CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"
HOST_CERT_DIR="/certificates/${DOMAIN}"
FULLCHAIN="${CERT_DIR}/fullchain.pem"
PRIVKEY="${CERT_DIR}/privkey.pem"

# Check if certificate already exists and is valid
if [ -f "$FULLCHAIN" ] && [ -f "$PRIVKEY" ]; then
    # Check expiration (30 days threshold)
    EXPIRY_DATE=$(openssl x509 -enddate -noout -in "$FULLCHAIN" | cut -d= -f2)
    EXPIRY_EPOCH=$(date -d "$EXPIRY_DATE" +%s)
    CURRENT_EPOCH=$(date +%s)
    DAYS_UNTIL_EXPIRY=$(( ($EXPIRY_EPOCH - $CURRENT_EPOCH) / 86400 ))
    
    if [ $DAYS_UNTIL_EXPIRY -gt 30 ]; then
        echo "Certificate for ${DOMAIN} exists and is valid for ${DAYS_UNTIL_EXPIRY} more days"
        echo "Copying to host filesystem..."
        mkdir -p "$HOST_CERT_DIR"
        cp "$FULLCHAIN" "${HOST_CERT_DIR}/fullchain.pem"
        cp "$PRIVKEY" "${HOST_CERT_DIR}/privkey.pem"
        echo "Certificate already exists and is valid. Skipping request."
        exit 0
    else
        echo "Certificate for ${DOMAIN} expires in ${DAYS_UNTIL_EXPIRY} days. Will renew."
    fi
fi

# Prepare staging flag
STAGING_FLAG=""
if [ "$STAGING" = "true" ]; then
    STAGING_FLAG="--staging"
    echo "Using Let's Encrypt staging environment"
fi

# Request certificate
echo "Requesting certificate for ${DOMAIN}..."
certbot certonly \
    --webroot \
    --webroot-path=/var/www/html \
    --email "$EMAIL" \
    --agree-tos \
    --no-eff-email \
    --non-interactive \
    --keep-until-expiring \
    $STAGING_FLAG \
    -d "$DOMAIN" \
    --logs-dir=/var/log/certbot \
    --config-dir=/etc/letsencrypt \
    --work-dir=/var/lib/letsencrypt

# Check if certificate was created successfully
if [ -f "$FULLCHAIN" ] && [ -f "$PRIVKEY" ]; then
    echo "Certificate created successfully for ${DOMAIN}"
    
    # Copy to host filesystem
    echo "Copying certificate to host filesystem..."
    mkdir -p "$HOST_CERT_DIR"
    cp "$FULLCHAIN" "${HOST_CERT_DIR}/fullchain.pem"
    cp "$PRIVKEY" "${HOST_CERT_DIR}/privkey.pem"
    
    # Set permissions
    chmod 644 "${HOST_CERT_DIR}/fullchain.pem"
    chmod 600 "${HOST_CERT_DIR}/privkey.pem"
    
    echo "Certificate for ${DOMAIN} is ready"
    exit 0
else
    echo "Error: Certificate creation failed for ${DOMAIN}"
    exit 1
fi

