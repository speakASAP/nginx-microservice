#!/bin/bash
# List Domains Script
# Lists all configured domains with their status

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="${PROJECT_DIR}/nginx/conf.d"
CERT_DIR="${PROJECT_DIR}/certificates"

echo "Configured Domains:"
echo "==================="
echo ""

if [ ! -d "$CONFIG_DIR" ] || [ -z "$(ls -A $CONFIG_DIR/*.conf 2>/dev/null)" ]; then
    echo "No domains configured"
    exit 0
fi

# Get container name and port from config
get_container_info() {
    local config_file="$1"
    local container=$(grep -E "proxy_pass.*http://" "$config_file" | head -1 | sed -E 's|.*http://([^:]+):([0-9]+).*|\1:\2|')
    echo "$container"
}

# Check certificate status
check_cert_status() {
    local domain="$1"
    local cert_path="${CERT_DIR}/${domain}/fullchain.pem"
    
    if [ -f "$cert_path" ]; then
        EXPIRY_DATE=$(openssl x509 -enddate -noout -in "$cert_path" | cut -d= -f2)
        EXPIRY_EPOCH=$(date -d "$EXPIRY_DATE" +%s 2>/dev/null || date -j -f "%b %d %H:%M:%S %Y %Z" "$EXPIRY_DATE" +%s 2>/dev/null || echo "0")
        
        if [ "$EXPIRY_EPOCH" != "0" ]; then
            CURRENT_EPOCH=$(date +%s)
            DAYS_UNTIL_EXPIRY=$(( ($EXPIRY_EPOCH - $CURRENT_EPOCH) / 86400 ))
            
            if [ $DAYS_UNTIL_EXPIRY -lt 0 ]; then
                echo "❌ EXPIRED"
            elif [ $DAYS_UNTIL_EXPIRY -lt 30 ]; then
                echo "⚠️  Expires in ${DAYS_UNTIL_EXPIRY} days"
            else
                echo "✅ Valid for ${DAYS_UNTIL_EXPIRY} days"
            fi
        else
            echo "⚠️  Certificate found but expiry date invalid"
        fi
    else
        echo "❌ Not found"
    fi
}

# Check container accessibility
check_container() {
    local container_port="$1"
    local container=$(echo "$container_port" | cut -d: -f1)
    local port=$(echo "$container_port" | cut -d: -f2)
    
    if [ -z "$container" ] || [ -z "$port" ]; then
        echo "N/A"
        return
    fi
    
    local network_name="${NETWORK_NAME:-nginx-network}"
    if docker network inspect "${network_name}" >/dev/null 2>&1; then
        if docker run --rm --network "${network_name}" alpine/curl:latest curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://${container}:${port}" >/dev/null 2>&1; then
            echo "✅ Online"
        else
            echo "❌ Offline"
        fi
    else
        echo "⚠️  Network not found"
    fi
}

printf "%-40s %-25s %-25s %-20s\n" "DOMAIN" "CONTAINER" "CERTIFICATE" "STATUS"
printf "%-40s %-25s %-25s %-20s\n" "$(printf '=%.0s' {1..40})" "$(printf '=%.0s' {1..25})" "$(printf '=%.0s' {1..25})" "$(printf '=%.0s' {1..20})"

for config_file in "$CONFIG_DIR"/*.conf; do
    if [ -f "$config_file" ]; then
        domain=$(basename "$config_file" .conf)
        container_info=$(get_container_info "$config_file")
        cert_status=$(check_cert_status "$domain")
        container_status=$(check_container "$container_info")
        
        printf "%-40s %-25s %-25s %-20s\n" "$domain" "$container_info" "$cert_status" "$container_status"
    fi
done

echo ""

