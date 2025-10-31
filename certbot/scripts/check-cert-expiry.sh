#!/bin/bash
# Check Certificate Expiry Script
# Usage: check-cert-expiry.sh [domain]

set -e

CERT_DIR="/etc/letsencrypt/live"
CURRENT_EPOCH=$(date +%s)
THRESHOLD_DAYS=30

if [ -n "$1" ]; then
    # Check specific domain
    DOMAIN="$1"
    FULLCHAIN="${CERT_DIR}/${DOMAIN}/fullchain.pem"
    
    if [ ! -f "$FULLCHAIN" ]; then
        echo "Certificate not found for ${DOMAIN}"
        exit 1
    fi
    
    EXPIRY_DATE=$(openssl x509 -enddate -noout -in "$FULLCHAIN" | cut -d= -f2)
    EXPIRY_EPOCH=$(date -d "$EXPIRY_DATE" +%s 2>/dev/null || date -j -f "%b %d %H:%M:%S %Y %Z" "$EXPIRY_DATE" +%s 2>/dev/null || echo "0")
    
    if [ "$EXPIRY_EPOCH" = "0" ]; then
        echo "Error: Could not parse expiration date for ${DOMAIN}"
        exit 1
    fi
    
    DAYS_UNTIL_EXPIRY=$(( ($EXPIRY_EPOCH - $CURRENT_EPOCH) / 86400 ))
    
    if [ $DAYS_UNTIL_EXPIRY -lt 0 ]; then
        echo "❌ ${DOMAIN}: EXPIRED"
        exit 1
    elif [ $DAYS_UNTIL_EXPIRY -lt $THRESHOLD_DAYS ]; then
        echo "⚠️  ${DOMAIN}: Expires in ${DAYS_UNTIL_EXPIRY} days (needs renewal)"
        exit 1
    else
        echo "✅ ${DOMAIN}: Valid for ${DAYS_UNTIL_EXPIRY} more days"
        exit 0
    fi
else
    # Check all certificates
    echo "Checking all certificates..."
    echo ""
    
    if [ ! -d "$CERT_DIR" ]; then
        echo "No certificates found"
        exit 0
    fi
    
    EXPIRING=0
    VALID=0
    EXPIRED=0
    
    for domain_dir in "$CERT_DIR"/*; do
        if [ -d "$domain_dir" ]; then
            DOMAIN=$(basename "$domain_dir")
            FULLCHAIN="${domain_dir}/fullchain.pem"
            
            if [ -f "$FULLCHAIN" ]; then
                EXPIRY_DATE=$(openssl x509 -enddate -noout -in "$FULLCHAIN" | cut -d= -f2)
                EXPIRY_EPOCH=$(date -d "$EXPIRY_DATE" +%s 2>/dev/null || date -j -f "%b %d %H:%M:%S %Y %Z" "$EXPIRY_DATE" +%s 2>/dev/null || echo "0")
                
                if [ "$EXPIRY_EPOCH" != "0" ]; then
                    DAYS_UNTIL_EXPIRY=$(( ($EXPIRY_EPOCH - $CURRENT_EPOCH) / 86400 ))
                    
                    if [ $DAYS_UNTIL_EXPIRY -lt 0 ]; then
                        echo "❌ ${DOMAIN}: EXPIRED"
                        EXPIRED=$((EXPIRED + 1))
                    elif [ $DAYS_UNTIL_EXPIRY -lt $THRESHOLD_DAYS ]; then
                        echo "⚠️  ${DOMAIN}: Expires in ${DAYS_UNTIL_EXPIRY} days"
                        EXPIRING=$((EXPIRING + 1))
                    else
                        echo "✅ ${DOMAIN}: Valid for ${DAYS_UNTIL_EXPIRY} days"
                        VALID=$((VALID + 1))
                    fi
                fi
            fi
        fi
    done
    
    echo ""
    echo "Summary:"
    echo "  Valid: ${VALID}"
    echo "  Expiring soon: ${EXPIRING}"
    echo "  Expired: ${EXPIRED}"
    
    if [ $EXPIRING -gt 0 ] || [ $EXPIRED -gt 0 ]; then
        exit 1
    fi
fi

