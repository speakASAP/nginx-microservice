#!/bin/bash
# Default Landing Page Setup
# Automatically sets up default landing page with SSL certificate for new deployments
# Usage: setup_default_landing.sh [domain]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Load environment variables from .env
if [ -f "${NGINX_PROJECT_DIR}/.env" ]; then
    set -a
    source "${NGINX_PROJECT_DIR}/.env" 2>/dev/null || true
    set +a
fi

# Source blue/green utilities if available
BLUE_GREEN_DIR="${SCRIPT_DIR}/../blue-green"
if [ -f "${BLUE_GREEN_DIR}/utils.sh" ]; then
    source "${BLUE_GREEN_DIR}/utils.sh" 2>/dev/null || true
fi

# Function to detect default domain
detect_default_domain() {
    local domain="$1"
    
    # If domain provided, use it
    if [ -n "$domain" ]; then
        echo "$domain"
        return 0
    fi
    
    # Try to get from DEFAULT_DOMAIN_SUFFIX
    if [ -n "${DEFAULT_DOMAIN_SUFFIX:-}" ]; then
        # Use root domain if DEFAULT_DOMAIN_SUFFIX is set
        echo "${DEFAULT_DOMAIN_SUFFIX}"
        return 0
    fi
    
    # Try to detect from hostname
    local hostname=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "")
    if [ -n "$hostname" ] && echo "$hostname" | grep -qE '\.'; then
        # Hostname has domain part, use it
        echo "$hostname"
        return 0
    fi
    
    # Last resort: try to get from system
    local fqdn=$(hostname -f 2>/dev/null || echo "")
    if [ -n "$fqdn" ] && [ "$fqdn" != "$(hostname)" ]; then
        echo "$fqdn"
        return 0
    fi
    
    return 1
}

# Function to setup default landing page
setup_default_landing() {
    local domain="${1:-}"
    
    # Detect default domain
    if ! domain=$(detect_default_domain "$domain"); then
        if type print_warning >/dev/null 2>&1; then
            print_warning "Could not detect default domain. Skipping default landing page setup." >&2
        else
            echo "Warning: Could not detect default domain. Skipping default landing page setup." >&2
        fi
        return 0  # Not a fatal error
    fi
    
    if type print_status >/dev/null 2>&1; then
        print_status "Setting up default landing page for domain: $domain"
    else
        echo "Setting up default landing page for domain: $domain"
    fi
    
    # Check if default landing config already exists
    local config_dir="${NGINX_PROJECT_DIR}/nginx/conf.d"
    local blue_green_dir="${config_dir}/blue-green"
    local default_config="${blue_green_dir}/${domain}.blue.conf"
    local symlink="${config_dir}/${domain}.conf"
    
    if [ -f "$default_config" ] && [ -L "$symlink" ]; then
        if type print_success >/dev/null 2>&1; then
            print_success "Default landing page already configured for $domain"
        else
            echo "Default landing page already configured for $domain"
        fi
        return 0
    fi
    
    # Create service registry entry for default landing (no services)
    local registry_dir="${NGINX_PROJECT_DIR}/service-registry"
    mkdir -p "$registry_dir"
    local registry_file="${registry_dir}/default-landing.json"
    
    if [ ! -f "$registry_file" ]; then
        cat > "$registry_file" <<EOF
{
  "service_name": "default-landing",
  "production_path": "${NGINX_PROJECT_DIR}",
  "domain": "${domain}",
  "docker_compose_file": "docker-compose.yml",
  "docker_project_base": "nginx_microservice",
  "services": {},
  "network": "nginx-network"
}
EOF
        if type print_detail >/dev/null 2>&1; then
            print_detail "Created service registry: $registry_file"
        fi
    fi
    
    # Ensure SSL certificate exists
    if type ensure_ssl_certificate >/dev/null 2>&1; then
        if type print_status >/dev/null 2>&1; then
            print_status "Ensuring SSL certificate for $domain..."
        fi
        ensure_ssl_certificate "$domain" "default-landing" || {
            if type print_warning >/dev/null 2>&1; then
                print_warning "Failed to ensure SSL certificate, will retry after nginx starts" >&2
            fi
        }
    fi
    
    # Generate nginx configs
    if type ensure_blue_green_configs >/dev/null 2>&1; then
        if type print_status >/dev/null 2>&1; then
            print_status "Generating nginx configuration for $domain..."
        fi
        if ensure_blue_green_configs "default-landing" "$domain" "blue"; then
            # Create symlink to blue config
            if [ -f "$default_config" ]; then
                ln -sf "blue-green/${domain}.blue.conf" "$symlink" 2>/dev/null || true
                if type print_success >/dev/null 2>&1; then
                    print_success "Default landing page configured for $domain"
                else
                    echo "Default landing page configured for $domain"
                fi
            fi
        else
            if type print_warning >/dev/null 2>&1; then
                print_warning "Failed to generate config, will retry after nginx starts" >&2
            fi
        fi
    fi
    
    # If certificate doesn't exist yet, request it (after nginx is running)
    local cert_dir="${NGINX_PROJECT_DIR}/certificates/${domain}"
    if [ ! -f "${cert_dir}/fullchain.pem" ] || [ ! -f "${cert_dir}/privkey.pem" ]; then
        # Check if nginx is running before requesting certificate
        if docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^nginx-microservice$"; then
            if type print_status >/dev/null 2>&1; then
                print_status "Requesting SSL certificate for $domain..."
            fi
            # Request certificate via certbot container
            if docker compose -f "${NGINX_PROJECT_DIR}/docker-compose.yml" run --rm certbot /scripts/request-cert.sh "$domain" 2>&1 | grep -q "Certificate created successfully"; then
                if type print_success >/dev/null 2>&1; then
                    print_success "SSL certificate obtained for $domain"
                fi
                # Reload nginx to use new certificate
                docker exec nginx-microservice nginx -s reload 2>/dev/null || true
            else
                if type print_warning >/dev/null 2>&1; then
                    print_warning "SSL certificate request may have failed, will retry later" >&2
                fi
            fi
        else
            if type print_status >/dev/null 2>&1; then
                print_status "SSL certificate will be requested after nginx starts"
            fi
        fi
    fi
}

# Main execution
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    setup_default_landing "$@"
fi
