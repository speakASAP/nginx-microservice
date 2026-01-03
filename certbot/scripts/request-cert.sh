#!/bin/bash
# Certbot Certificate Request Script
# Usage: request-cert.sh <domain> [email]
#
# This script requests SSL certificates from Let's Encrypt using webroot validation.
# It handles certificate creation, validation, and copying to the host filesystem.
#
# Certificate Storage Locations:
# - Inside certbot container: /etc/letsencrypt/live/<domain>/ (symlinks to archive/)
# - Host filesystem: ./certificates/<domain>/ (mounted at /certificates/ in container)
# - Nginx access: ./certificates/<domain>/ (mounted at /etc/nginx/certs/ in nginx container)
#
# IMPORTANT: The certificate files must be copied to /certificates/<domain>/ so that:
# 1. They persist on the host filesystem (not just in container volumes)
# 2. Nginx container can access them via the volume mount
# 3. They survive container restarts and recreations

set -e

DOMAIN="$1"
EMAIL="${2:-${CERTBOT_EMAIL:-admin@example.com}}"
STAGING="${CERTBOT_STAGING:-false}"

if [ -z "$DOMAIN" ]; then
    echo "Error: Domain name required"
    echo "Usage: request-cert.sh <domain> [email]"
    exit 1
fi

# Certificate paths
# CERT_DIR: Location where certbot stores certificates (with symlinks to archive)
# HOST_CERT_DIR: Location on host filesystem where nginx can access certificates
# Note: /certificates/ is mounted from ./certificates/ on host
CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"
HOST_CERT_DIR="/certificates/${DOMAIN}"
FULLCHAIN="${CERT_DIR}/fullchain.pem"
PRIVKEY="${CERT_DIR}/privkey.pem"

# Check if certificate already exists and is valid
# This prevents unnecessary certificate requests and respects Let's Encrypt rate limits
if [ -f "$FULLCHAIN" ] && [ -f "$PRIVKEY" ]; then
    # Check expiration (30 days threshold)
    # Let's Encrypt recommends renewing certificates when they have < 30 days remaining
    EXPIRY_DATE=$(openssl x509 -enddate -noout -in "$FULLCHAIN" | cut -d= -f2)
    EXPIRY_EPOCH=$(date -d "$EXPIRY_DATE" +%s)
    CURRENT_EPOCH=$(date +%s)
    DAYS_UNTIL_EXPIRY=$(( ($EXPIRY_EPOCH - $CURRENT_EPOCH) / 86400 ))
    
    if [ $DAYS_UNTIL_EXPIRY -gt 30 ]; then
        echo "Certificate for ${DOMAIN} exists and is valid for ${DAYS_UNTIL_EXPIRY} more days"
        echo "Copying to host filesystem..."
        # Ensure host directory exists and copy certificate files
        # This is critical: certificates in /etc/letsencrypt/live/ are symlinks that may break
        # Copying actual files ensures nginx can access them reliably
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

# Request certificate from Let's Encrypt
# Uses webroot validation: certbot places challenge files in /var/www/html/.well-known/acme-challenge/
# Nginx serves these files to prove domain ownership
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
    
    # CRITICAL: Copy to host filesystem
    # The certificates in /etc/letsencrypt/live/ are symlinks pointing to archive/
    # We need to copy the actual files to /certificates/ which is mounted to ./certificates/ on host
    # This ensures:
    # 1. Nginx container can access them via volume mount (./certificates -> /etc/nginx/certs)
    # 2. Files persist on host filesystem (not just in container volumes)
    # 3. Certificates survive container restarts
    echo "Copying certificate to host filesystem..."
    mkdir -p "$HOST_CERT_DIR"
    # Use cp -L to follow symlinks and copy actual files (not symlinks)
    cp -L "$FULLCHAIN" "${HOST_CERT_DIR}/fullchain.pem"
    cp -L "$PRIVKEY" "${HOST_CERT_DIR}/privkey.pem"
    
    # Set proper permissions
    # fullchain.pem: readable by nginx (644 = rw-r--r--)
    # privkey.pem: only readable by owner (600 = rw-------) for security
    chmod 644 "${HOST_CERT_DIR}/fullchain.pem"
    chmod 600 "${HOST_CERT_DIR}/privkey.pem"
    
    echo "Certificate for ${DOMAIN} is ready"
    echo "Certificate location: ${HOST_CERT_DIR}/"
    echo "Nginx will access it at: /etc/nginx/certs/${DOMAIN}/"
    exit 0
else
    echo "Error: Certificate creation failed for ${DOMAIN}"
    echo "Check certbot logs: docker compose logs certbot"
    exit 1
fi

