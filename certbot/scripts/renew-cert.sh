#!/bin/bash
# Certificate Renewal Script
# Renews all certificates (webroot and DNS-01/wildcard) using their original challenge type

set -e

STAGING="${CERTBOT_STAGING:-false}"
STAGING_FLAG=""

if [ "$STAGING" = "true" ]; then
    STAGING_FLAG="--staging"
fi

CERT_DIR="/etc/letsencrypt/live"
# ./certificates/ on host is mounted to /etc/letsencrypt/ in certbot container
HOST_CERT_DIR="/etc/letsencrypt"

echo "Starting certificate renewal process..."
echo ""

# Single certbot renew: uses renewal config per cert (webroot for HTTP-01, dns-cloudflare for DNS-01)
if ! certbot renew \
    --non-interactive \
    --no-random-sleep-on-renew \
    $STAGING_FLAG \
    --logs-dir=/var/log/certbot \
    --config-dir=/etc/letsencrypt \
    --work-dir=/var/lib/letsencrypt; then
    echo "certbot renew reported failures (some certs may still have been renewed)"
fi

# Copy all live certs to host layout (so nginx sees them under certificates/<domain>/)
if [ -d "$CERT_DIR" ]; then
    for domain_dir in "$CERT_DIR"/*; do
        if [ -d "$domain_dir" ]; then
            DOMAIN=$(basename "$domain_dir")
            FULLCHAIN="${domain_dir}/fullchain.pem"
            PRIVKEY="${domain_dir}/privkey.pem"
            if [ -f "$FULLCHAIN" ] && [ -f "$PRIVKEY" ]; then
                mkdir -p "${HOST_CERT_DIR}/${DOMAIN}"
                cp -L "$FULLCHAIN" "${HOST_CERT_DIR}/${DOMAIN}/fullchain.pem"
                cp -L "$PRIVKEY" "${HOST_CERT_DIR}/${DOMAIN}/privkey.pem"
                chmod 644 "${HOST_CERT_DIR}/${DOMAIN}/fullchain.pem"
                chmod 600 "${HOST_CERT_DIR}/${DOMAIN}/privkey.pem"
            fi
        fi
    done
fi

# Reload nginx if running
if docker ps 2>/dev/null | grep -q nginx-microservice; then
    echo "Reloading nginx..."
    docker exec nginx-microservice nginx -s reload || true
fi

echo "Renewal complete."
exit 0

