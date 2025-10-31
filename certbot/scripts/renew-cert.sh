#!/bin/bash
# Certificate Renewal Script
# Renews certificates expiring within 30 days

set -e

STAGING="${CERTBOT_STAGING:-false}"
STAGING_FLAG=""

if [ "$STAGING" = "true" ]; then
    STAGING_FLAG="--staging"
fi

CERT_DIR="/etc/letsencrypt/live"
HOST_CERT_DIR="/certificates"
CURRENT_EPOCH=$(date +%s)
THRESHOLD_DAYS=30
RENEWED=0
FAILED=0

echo "Starting certificate renewal process..."
echo ""

if [ ! -d "$CERT_DIR" ]; then
    echo "No certificates found"
    exit 0
fi

# Find certificates needing renewal
for domain_dir in "$CERT_DIR"/*; do
    if [ -d "$domain_dir" ]; then
        DOMAIN=$(basename "$domain_dir")
        FULLCHAIN="${domain_dir}/fullchain.pem"
        
        if [ -f "$FULLCHAIN" ]; then
            EXPIRY_DATE=$(openssl x509 -enddate -noout -in "$FULLCHAIN" | cut -d= -f2)
            EXPIRY_EPOCH=$(date -d "$EXPIRY_DATE" +%s 2>/dev/null || date -j -f "%b %d %H:%M:%S %Y %Z" "$EXPIRY_DATE" +%s 2>/dev/null || echo "0")
            
            if [ "$EXPIRY_EPOCH" != "0" ]; then
                DAYS_UNTIL_EXPIRY=$(( ($EXPIRY_EPOCH - $CURRENT_EPOCH) / 86400 ))
                
                if [ $DAYS_UNTIL_EXPIRY -lt $THRESHOLD_DAYS ]; then
                    echo "Renewing certificate for ${DOMAIN} (expires in ${DAYS_UNTIL_EXPIRY} days)..."
                    
                    # Renew certificate
                    if certbot renew \
                        --cert-name "$DOMAIN" \
                        --webroot \
                        --webroot-path=/var/www/html \
                        --non-interactive \
                        --no-random-sleep-on-renew \
                        $STAGING_FLAG \
                        --logs-dir=/var/log/certbot \
                        --config-dir=/etc/letsencrypt \
                        --work-dir=/var/lib/letsencrypt; then
                        
                        # Copy renewed certificate to host filesystem
                        echo "Copying renewed certificate to host filesystem..."
                        mkdir -p "${HOST_CERT_DIR}/${DOMAIN}"
                        cp "${FULLCHAIN}" "${HOST_CERT_DIR}/${DOMAIN}/fullchain.pem"
                        cp "${domain_dir}/privkey.pem" "${HOST_CERT_DIR}/${DOMAIN}/privkey.pem"
                        
                        # Set permissions
                        chmod 644 "${HOST_CERT_DIR}/${DOMAIN}/fullchain.pem"
                        chmod 600 "${HOST_CERT_DIR}/${DOMAIN}/privkey.pem"
                        
                        echo "✅ Successfully renewed certificate for ${DOMAIN}"
                        RENEWED=$((RENEWED + 1))
                        
                        # Reload nginx if running
                        if docker ps | grep -q nginx-microservice; then
                            echo "Reloading nginx..."
                            docker exec nginx-microservice nginx -s reload || true
                        fi
                    else
                        echo "❌ Failed to renew certificate for ${DOMAIN}"
                        FAILED=$((FAILED + 1))
                    fi
                    echo ""
                fi
            fi
        fi
    fi
done

echo "Renewal summary:"
echo "  Renewed: ${RENEWED}"
echo "  Failed: ${FAILED}"

if [ $FAILED -gt 0 ]; then
    exit 1
fi

exit 0

