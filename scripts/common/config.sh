#!/bin/bash
# Config Generation Functions
# Functions for generating nginx configuration files

# Source base paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source dependencies
if [ -f "${SCRIPT_DIR}/output.sh" ]; then
    source "${SCRIPT_DIR}/output.sh"
else
    # Fallback output functions
    RED='\033[0;31m'
    YELLOW='\033[1;33m'
    NC='\033[0m'
    print_error() {
        echo -e "${RED}[ERROR]${NC} $1"
    }
    print_warning() {
        echo -e "${YELLOW}[WARNING]${NC} $1"
    }
fi

# Source registry and state functions (required dependencies)
if [ -f "${SCRIPT_DIR}/registry.sh" ]; then
    source "${SCRIPT_DIR}/registry.sh"
fi

if [ -f "${SCRIPT_DIR}/state.sh" ]; then
    source "${SCRIPT_DIR}/state.sh"
fi

# Note: validate_and_apply_config and log_message will be available from nginx.sh and utils.sh
# when these modules are sourced together

# Function to generate upstream blocks for a specific color
generate_upstream_blocks() {
    local service_name="$1"
    local active_color="$2"
    local domain="${3:-}"
    local registry=$(load_service_registry "$service_name")
    
    # Get service keys - filter by domain if specified
    local service_keys=""
    if [ -n "$domain" ]; then
        # Check if domain-specific service list exists
        local domain_services=$(echo "$registry" | jq -r ".domains[\"$domain\"].services[]? // empty" 2>/dev/null)
        if [ -n "$domain_services" ]; then
            # Use domain-specific services
            service_keys="$domain_services"
        else
            # Fallback to all services
            service_keys=$(echo "$registry" | jq -r '.services | keys[]')
        fi
    else
        # Use all services
        service_keys=$(echo "$registry" | jq -r '.services | keys[]')
    fi
    
    local upstream_blocks=""
    
    while IFS= read -r service_key; do
        local container_base=$(echo "$registry" | jq -r ".services[\"$service_key\"].container_name_base")
        local service_port=$(echo "$registry" | jq -r ".services[\"$service_key\"].port")
        
        if [ -z "$container_base" ] || [ "$container_base" = "null" ] || [ -z "$service_port" ] || [ "$service_port" = "null" ]; then
            continue
        fi
        
        # Determine weights and backup status based on active color
        local blue_weight green_weight blue_backup green_backup
        if [ "$active_color" = "blue" ]; then
            blue_weight=100
            green_weight=""
            blue_backup=""
            green_backup=" backup"
        else
            blue_weight=""
            green_weight=100
            blue_backup=" backup"
            green_backup=""
        fi
        
        # Always generate upstream blocks - nginx will use resolver for runtime DNS resolution
        # This allows nginx to start even when containers are not running
        # Nginx will return 502 errors until containers become available, which is acceptable
        local blue_container="${container_base}-blue"
        local green_container="${container_base}-green"
        
        # Use zone for shared memory when using resolve directive (required for runtime DNS resolution)
        upstream_blocks="${upstream_blocks}upstream ${container_base} {
    zone ${container_base}_zone 64k;
"

        # Always include blue server with resolve directive (nginx will resolve at runtime via resolver)
        # The 'resolve' directive tells nginx to resolve hostnames at runtime, not at startup
        # This allows nginx to start even when containers don't exist yet
        if [ -n "$blue_weight" ]; then
            # Active server
            upstream_blocks="${upstream_blocks}    server ${blue_container}:${service_port} weight=${blue_weight}${blue_backup} max_fails=3 fail_timeout=30s resolve;
"
        else
            # Backup server
            upstream_blocks="${upstream_blocks}    server ${blue_container}:${service_port}${blue_backup} max_fails=3 fail_timeout=30s resolve;
"
        fi
        
        # Always include green server with resolve directive (nginx will resolve at runtime via resolver)
        if [ -n "$green_weight" ]; then
            # Active server
            upstream_blocks="${upstream_blocks}    server ${green_container}:${service_port} weight=${green_weight}${green_backup} max_fails=3 fail_timeout=30s resolve;
"
        else
            # Backup server
            upstream_blocks="${upstream_blocks}    server ${green_container}:${service_port}${green_backup} max_fails=3 fail_timeout=30s resolve;
"
        fi
        
        upstream_blocks="${upstream_blocks}}
"
    done <<< "$service_keys"
    
    echo "$upstream_blocks"
}

# Function to generate proxy locations from service registry
generate_proxy_locations() {
    local service_name="$1"
    local domain="${2:-}"
    local active_color="${3:-blue}"
    local registry=$(load_service_registry "$service_name")
    
    # Get service keys - filter by domain if specified
    local service_keys=""
    if [ -n "$domain" ]; then
        # Check if domain-specific service list exists
        local domain_services=$(echo "$registry" | jq -r ".domains[\"$domain\"].services[]? // empty" 2>/dev/null)
        if [ -n "$domain_services" ]; then
            # Use domain-specific services
            service_keys="$domain_services"
        else
            # Fallback to all services
            service_keys=$(echo "$registry" | jq -r '.services | keys[]')
        fi
    else
        # Use all services
        service_keys=$(echo "$registry" | jq -r '.services | keys[]')
    fi
    
    local proxy_locations=""
    
    # Check if frontend service exists
    local has_frontend=false
    local has_backend=false
    local frontend_container=""
    local backend_container=""
    
    while IFS= read -r service_key; do
        if [ "$service_key" = "frontend" ]; then
            has_frontend=true
            frontend_container=$(echo "$registry" | jq -r ".services.frontend.container_name_base")
        elif [ "$service_key" = "backend" ]; then
            has_backend=true
            backend_container=$(echo "$registry" | jq -r ".services.backend.container_name_base")
        fi
    done <<< "$service_keys"
    
    # Generate frontend location (root path) - using shared include
    if [ "$has_frontend" = "true" ] && [ -n "$frontend_container" ] && [ "$frontend_container" != "null" ]; then
        # Use upstream block name (container_base without color) - upstream block includes port and resolve directive
        # The upstream block is named after container_base and includes both blue and green servers with ports
        proxy_locations="${proxy_locations}    # Frontend service - root path
    set \$FRONTEND_UPSTREAM ${frontend_container};
    include /etc/nginx/includes/frontend-location.conf;
    
"
    elif [ "$has_backend" = "true" ] && [ -n "$backend_container" ] && [ "$backend_container" != "null" ] && [ "$has_frontend" != "true" ]; then
        # If no frontend but backend exists, route root path to backend
        local backend_container_name="${backend_container}-${active_color}"
        proxy_locations="${proxy_locations}    # Backend-only service - root path routes to backend (using variables with resolver for runtime DNS resolution)
    location / {
        set \$BACKEND_UPSTREAM ${backend_container_name};
        proxy_pass http://\$BACKEND_UPSTREAM;
        include /etc/nginx/includes/common-proxy-settings.conf;
    }
    
"
    fi
    
    # Generate backend/API location
    if [ "$has_backend" = "true" ] && [ -n "$backend_container" ] && [ "$backend_container" != "null" ]; then
        local backend_container_name="${backend_container}-${active_color}"
        proxy_locations="${proxy_locations}    # API routes with stricter rate limiting - using variables with resolver for runtime DNS resolution
    location /api/ {
        limit_req zone=api burst=20 nodelay;
        set \$BACKEND_UPSTREAM ${backend_container_name};
        proxy_pass http://\$BACKEND_UPSTREAM/api/;
        include /etc/nginx/includes/common-proxy-settings.conf;
    }
    
    # WebSocket support - using variables with resolver for runtime DNS resolution
    location /ws {
        set \$BACKEND_UPSTREAM ${backend_container_name};
        proxy_pass http://\$BACKEND_UPSTREAM/ws;
        include /etc/nginx/includes/common-proxy-settings.conf;
    }
    
    # Health check endpoint - using variables with resolver for runtime DNS resolution
    location /health {
        set \$BACKEND_UPSTREAM ${backend_container_name};
        proxy_pass http://\$BACKEND_UPSTREAM/health;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        access_log off;
        limit_req zone=api burst=5 nodelay;
    }
    
"
    fi
    
    # For services with api-gateway (like e-commerce), route /api/ to api-gateway
    local api_gateway_container=$(echo "$registry" | jq -r '.services["api-gateway"].container_name_base // empty')
    if [ -n "$api_gateway_container" ] && [ "$api_gateway_container" != "null" ]; then
        # If api-gateway exists and we haven't added /api/ yet, add it
        if [ "$has_backend" != "true" ] || [ -z "$(echo "$proxy_locations" | grep "location /api/")" ]; then
            # Get port for api-gateway
            local api_gateway_port=$(echo "$registry" | jq -r '.services["api-gateway"].port // "80"')
            # Use container name with color suffix for runtime DNS resolution
            local api_gateway_container_name="${api_gateway_container}-${active_color}"
            proxy_locations="${proxy_locations}    # API Gateway routes - using variables with resolver for runtime DNS resolution
    location /api/ {
        limit_req zone=api burst=20 nodelay;
        set \$API_GATEWAY_UPSTREAM ${api_gateway_container_name};
        proxy_pass http://\$API_GATEWAY_UPSTREAM:${api_gateway_port}/api/;
        include /etc/nginx/includes/common-proxy-settings.conf;
    }
    
"
        fi
    fi
    
    echo "$proxy_locations"
}

# Function to ensure staging and rejected directories exist
ensure_config_directories() {
    local config_dir="${NGINX_PROJECT_DIR}/nginx/conf.d"
    local staging_dir="${config_dir}/staging"
    local rejected_dir="${config_dir}/rejected"
    local blue_green_dir="${config_dir}/blue-green"
    
    mkdir -p "$staging_dir"
    mkdir -p "$rejected_dir"
    mkdir -p "$blue_green_dir"
}

# Function to generate blue and green nginx configs from template
generate_blue_green_configs() {
    local service_name="$1"
    local domain="$2"
    local active_color="${3:-blue}"
    
    local registry=$(load_service_registry "$service_name")
    local template_file="${NGINX_PROJECT_DIR}/nginx/templates/domain-blue-green.conf.template"
    local config_dir="${NGINX_PROJECT_DIR}/nginx/conf.d"
    local staging_dir="${config_dir}/staging"
    local blue_green_dir="${config_dir}/blue-green"
    
    # Ensure directories exist
    ensure_config_directories
    
    # Generate to staging first, then validate and apply
    local blue_staging="${staging_dir}/${domain}.blue.conf"
    local green_staging="${staging_dir}/${domain}.green.conf"
    local blue_config="${blue_green_dir}/${domain}.blue.conf"
    local green_config="${blue_green_dir}/${domain}.green.conf"
    
    if [ ! -f "$template_file" ]; then
        print_error "Template file not found: $template_file"
        return 1
    fi
    
    # Generate proxy locations for blue config - uses variables with resolver
    local blue_proxy_locations=$(generate_proxy_locations "$service_name" "$domain" "blue")
    
    # Generate proxy locations for green config - uses variables with resolver
    local green_proxy_locations=$(generate_proxy_locations "$service_name" "$domain" "green")
    
    # Generate upstream blocks for blue and green configs
    # Upstream blocks are required by nginx even if we use variables in proxy_pass
    # This allows nginx to start even when containers are not running (will return 502 until containers start)
    # Function signature: generate_upstream_blocks service_name active_color domain
    local blue_upstreams=$(generate_upstream_blocks "$service_name" "blue" "$domain")
    local green_upstreams=$(generate_upstream_blocks "$service_name" "green" "$domain")
    
    # Generate configs using Python for reliable multi-line replacement
    # Use temporary files to pass multi-line content to Python
    local temp_upstreams=$(mktemp)
    local temp_locations=$(mktemp)
    local temp_python=$(mktemp)
    
    echo "$blue_upstreams" > "$temp_upstreams"
    echo "$blue_proxy_locations" > "$temp_locations"
    
    # Create Python script
    cat > "$temp_python" <<'PYTHON_SCRIPT'
import sys
import os

template_file = sys.argv[1]
output_file = sys.argv[2]
domain = sys.argv[3]
upstreams_file = sys.argv[4]
locations_file = sys.argv[5]

try:
    # Read template
    with open(template_file, 'r') as f:
        template = f.read()
    
    # Read upstream blocks and proxy locations
    with open(upstreams_file, 'r') as f:
        upstreams = f.read()
    
    with open(locations_file, 'r') as f:
        locations = f.read()
    
    # Replace placeholders
    template = template.replace('{{DOMAIN_NAME}}', domain)
    template = template.replace('{{UPSTREAM_BLOCKS}}', upstreams)
    template = template.replace('{{PROXY_LOCATIONS}}', locations)
    
    # Write output
    with open(output_file, 'w') as f:
        f.write(template)
    
except Exception as e:
    sys.stderr.write(f"Error generating config: {e}\n")
    sys.exit(1)
PYTHON_SCRIPT
    
    # Generate blue config to staging
    if command -v python3 >/dev/null 2>&1; then
        python3 "$temp_python" "$template_file" "$blue_staging" "$domain" "$temp_upstreams" "$temp_locations" || {
            print_error "Python3 failed, falling back to sed"
            # Fallback to sed (simple replacement, may have multi-line issues)
            sed -e "s|{{DOMAIN_NAME}}|$domain|g" \
                -e "s|{{UPSTREAM_BLOCKS}}|$blue_upstreams|g" \
                -e "s|{{PROXY_LOCATIONS}}|$blue_proxy_locations|g" \
                "$template_file" > "$blue_staging"
        }
    else
        print_warning "Python3 not found, using sed (may have issues with multi-line content)"
        sed -e "s|{{DOMAIN_NAME}}|$domain|g" \
            -e "s|{{UPSTREAM_BLOCKS}}|$blue_upstreams|g" \
            -e "s|{{PROXY_LOCATIONS}}|$blue_proxy_locations|g" \
            "$template_file" > "$blue_staging"
    fi
    
    # Update upstreams and locations for green config
    echo "$green_upstreams" > "$temp_upstreams"
    echo "$green_proxy_locations" > "$temp_locations"
    
    # Generate green config to staging
    if command -v python3 >/dev/null 2>&1; then
        python3 "$temp_python" "$template_file" "$green_staging" "$domain" "$temp_upstreams" "$temp_locations" || {
            print_error "Python3 failed, falling back to sed"
            # Fallback to sed
            sed -e "s|{{DOMAIN_NAME}}|$domain|g" \
                -e "s|{{UPSTREAM_BLOCKS}}|$green_upstreams|g" \
                -e "s|{{PROXY_LOCATIONS}}|$green_proxy_locations|g" \
                "$template_file" > "$green_staging"
        }
    else
        print_warning "Python3 not found, using sed (may have issues with multi-line content)"
        sed -e "s|{{DOMAIN_NAME}}|$domain|g" \
            -e "s|{{UPSTREAM_BLOCKS}}|$green_upstreams|g" \
            -e "s|{{PROXY_LOCATIONS}}|$green_proxy_locations|g" \
            "$template_file" > "$green_staging"
    fi
    
    # Cleanup temp files
    rm -f "$temp_upstreams" "$temp_locations" "$temp_python"
    
    # Validate and apply blue config
    # Note: validate_and_apply_config must be available (from nginx.sh)
    local blue_validated=false
    if [ -f "$blue_staging" ]; then
        if type validate_and_apply_config >/dev/null 2>&1; then
            if validate_and_apply_config "$service_name" "$domain" "blue" "$blue_staging"; then
                blue_validated=true
            else
                if type log_message >/dev/null 2>&1; then
                    log_message "WARNING" "$service_name" "blue" "generate" "Blue config validation failed, but continuing with green"
                fi
            fi
        else
            print_warning "validate_and_apply_config not available - skipping validation"
            # Move directly to blue-green (unsafe, but allows basic functionality)
            mv "$blue_staging" "$blue_config" 2>/dev/null || true
            blue_validated=true
        fi
    fi
    
    # Validate and apply green config
    local green_validated=false
    if [ -f "$green_staging" ]; then
        if type validate_and_apply_config >/dev/null 2>&1; then
            if validate_and_apply_config "$service_name" "$domain" "green" "$green_staging"; then
                green_validated=true
            else
                if type log_message >/dev/null 2>&1; then
                    log_message "WARNING" "$service_name" "green" "generate" "Green config validation failed, but continuing"
                fi
            fi
        else
            print_warning "validate_and_apply_config not available - skipping validation"
            # Move directly to blue-green (unsafe, but allows basic functionality)
            mv "$green_staging" "$green_config" 2>/dev/null || true
            green_validated=true
        fi
    fi
    
    # Check if at least one config was validated successfully
    if [ "$blue_validated" = "true" ] || [ "$green_validated" = "true" ]; then
        if type log_message >/dev/null 2>&1; then
            if [ "$blue_validated" = "true" ] && [ "$green_validated" = "true" ]; then
                log_message "SUCCESS" "$service_name" "config" "generate" "Generated and validated both blue and green configs for $domain"
            elif [ "$blue_validated" = "true" ]; then
                log_message "SUCCESS" "$service_name" "config" "generate" "Generated and validated blue config for $domain (green config rejected)"
            else
                log_message "SUCCESS" "$service_name" "config" "generate" "Generated and validated green config for $domain (blue config rejected)"
            fi
        fi
        return 0
    else
        if type log_message >/dev/null 2>&1; then
            log_message "ERROR" "$service_name" "config" "generate" "Both blue and green configs failed validation for $domain"
        fi
        return 1
    fi
}

# Function to ensure blue and green configs exist
ensure_blue_green_configs() {
    local service_name="$1"
    local domain="$2"
    local active_color="${3:-blue}"
    
    # For statex service, generate configs for all domains defined in registry
    if [ "$service_name" = "statex" ]; then
        local registry=$(load_service_registry "$service_name")
        local domains=$(echo "$registry" | jq -r '.domains | keys[]' 2>/dev/null)
        
        if [ -n "$domains" ]; then
            # Generate configs for all statex domains
            while IFS= read -r statex_domain; do
                local domain_state=$(load_state "$service_name" "$statex_domain" 2>/dev/null)
                local domain_active_color=$(echo "$domain_state" | jq -r '.active_color // "blue"')
                
                local config_dir="${NGINX_PROJECT_DIR}/nginx/conf.d"
                local blue_green_dir="${config_dir}/blue-green"
                mkdir -p "$blue_green_dir"
                local blue_config="${blue_green_dir}/${statex_domain}.blue.conf"
                local green_config="${blue_green_dir}/${statex_domain}.green.conf"
                
                # Check if both configs exist and are valid (no template variables)
                local needs_regeneration=false
                if [ -f "$blue_config" ] && [ -f "$green_config" ]; then
                    # Check for template variables that indicate invalid configs
                    if grep -qE "^(blue_weight|green_weight|blue_backup|green_backup)=" "$blue_config" "$green_config" 2>/dev/null; then
                        if type log_message >/dev/null 2>&1; then
                            log_message "WARNING" "$service_name" "config" "ensure" "Configs contain template variables, forcing regeneration for $statex_domain"
                        fi
                        needs_regeneration=true
                    elif ! grep -qE "resolve;" "$blue_config" "$green_config" 2>/dev/null; then
                        if type log_message >/dev/null 2>&1; then
                            log_message "WARNING" "$service_name" "config" "ensure" "Configs missing resolve directive, forcing regeneration for $statex_domain"
                        fi
                        needs_regeneration=true
                    else
                        if type log_message >/dev/null 2>&1; then
                            log_message "INFO" "$service_name" "config" "ensure" "Blue and green configs already exist for $statex_domain"
                        fi
                        continue
                    fi
                else
                    needs_regeneration=true
                fi
                
                # Remove invalid configs if regeneration is needed
                if [ "$needs_regeneration" = true ]; then
                    if [ -f "$blue_config" ]; then
                        rm -f "$blue_config"
                        if type log_message >/dev/null 2>&1; then
                            log_message "INFO" "$service_name" "config" "ensure" "Removed invalid blue config for $statex_domain"
                        fi
                    fi
                    if [ -f "$green_config" ]; then
                        rm -f "$green_config"
                        if type log_message >/dev/null 2>&1; then
                            log_message "INFO" "$service_name" "config" "ensure" "Removed invalid green config for $statex_domain"
                        fi
                    fi
                fi
                
                # Generate configs if missing
                if type log_message >/dev/null 2>&1; then
                    log_message "INFO" "$service_name" "config" "ensure" "Generating blue and green configs for $statex_domain"
                fi
                if ! generate_blue_green_configs "$service_name" "$statex_domain" "$domain_active_color"; then
                    if type log_message >/dev/null 2>&1; then
                        log_message "ERROR" "$service_name" "config" "ensure" "Failed to generate configs for $statex_domain"
                    fi
                    return 1
                fi
            done <<< "$domains"
            return 0
        fi
    fi
    
    # For non-statex services or when domain is explicitly provided, use standard logic
    # For statex service, get active_color from domain-specific state
    if [ "$service_name" = "statex" ]; then
        local state=$(load_state "$service_name" "$domain" 2>/dev/null)
        if [ -n "$state" ]; then
            active_color=$(echo "$state" | jq -r '.active_color // "blue"')
        fi
    fi
    
    local config_dir="${NGINX_PROJECT_DIR}/nginx/conf.d"
    local blue_green_dir="${config_dir}/blue-green"
    mkdir -p "$blue_green_dir"
    local blue_config="${blue_green_dir}/${domain}.blue.conf"
    local green_config="${blue_green_dir}/${domain}.green.conf"
    
    # Check if both configs exist and are valid (no template variables)
    local needs_regeneration=false
    if [ -f "$blue_config" ] && [ -f "$green_config" ]; then
        # Check for template variables that indicate invalid configs
        if grep -qE "^(blue_weight|green_weight|blue_backup|green_backup)=" "$blue_config" "$green_config" 2>/dev/null; then
            if type log_message >/dev/null 2>&1; then
                log_message "WARNING" "$service_name" "config" "ensure" "Configs contain template variables, forcing regeneration for $domain"
            fi
            needs_regeneration=true
        elif ! grep -qE "resolve;" "$blue_config" "$green_config" 2>/dev/null; then
            if type log_message >/dev/null 2>&1; then
                log_message "WARNING" "$service_name" "config" "ensure" "Configs missing resolve directive, forcing regeneration for $domain"
            fi
            needs_regeneration=true
        else
            if type log_message >/dev/null 2>&1; then
                log_message "INFO" "$service_name" "config" "ensure" "Blue and green configs already exist and validated for $domain"
            fi
            return 0
        fi
    else
        needs_regeneration=true
    fi
    
    # Remove invalid configs if regeneration is needed
    if [ "$needs_regeneration" = true ]; then
        if [ -f "$blue_config" ]; then
            rm -f "$blue_config"
            if type log_message >/dev/null 2>&1; then
                log_message "INFO" "$service_name" "config" "ensure" "Removed invalid blue config for $domain"
            fi
        fi
        if [ -f "$green_config" ]; then
            rm -f "$green_config"
            if type log_message >/dev/null 2>&1; then
                log_message "INFO" "$service_name" "config" "ensure" "Removed invalid green config for $domain"
            fi
        fi
    fi
    
    # Generate configs if missing (will validate before applying)
    if type log_message >/dev/null 2>&1; then
        log_message "INFO" "$service_name" "config" "ensure" "Generating and validating blue and green configs for $domain"
    fi
    if ! generate_blue_green_configs "$service_name" "$domain" "$active_color"; then
        if type log_message >/dev/null 2>&1; then
            log_message "ERROR" "$service_name" "config" "ensure" "Failed to generate or validate configs for $domain"
        fi
        # Check if at least one config exists
        if [ -f "$blue_config" ] || [ -f "$green_config" ]; then
            if type log_message >/dev/null 2>&1; then
                log_message "WARNING" "$service_name" "config" "ensure" "Partial configs exist for $domain, nginx may have limited functionality"
            fi
            return 0  # Don't fail if at least one config exists
        fi
        return 1
    fi
    
    return 0
}

# Function to clean up upstreams for non-existent containers in a config file
cleanup_upstreams() {
    local config_file="$1"
    
    if [ ! -f "$config_file" ]; then
        return 1
    fi
    
    # Extract all upstream server lines and check if containers exist
    local temp_config=$(mktemp)
    local in_upstream=false
    local upstream_name=""
    
    while IFS= read -r line; do
        # Detect upstream block start
        if echo "$line" | grep -qE "^upstream\s+\S+\s*\{$"; then
            upstream_name=$(echo "$line" | sed -E 's/^upstream\s+(\S+)\s*\{$/\1/')
            in_upstream=true
            echo "$line" >> "$temp_config"
            continue
        fi
        
        # Detect upstream block end
        if [ "$in_upstream" = "true" ] && echo "$line" | grep -qE "^\s*\}$"; then
            in_upstream=false
            echo "$line" >> "$temp_config"
            continue
        fi
        
        # Process server lines within upstream block
        if [ "$in_upstream" = "true" ] && echo "$line" | grep -qE "^\s*server\s+"; then
            # Extract container name from server line (format: container-name:port)
            local container_name=$(echo "$line" | sed -E 's/^\s*server\s+([^:]+):.*/\1/')
            
            # Check if container exists (running or stopped)
            if docker ps -a --format "{{.Names}}" 2>/dev/null | grep -qE "^${container_name}$"; then
                echo "$line" >> "$temp_config"
            else
                # Skip this server line (container doesn't exist)
                if type log_message >/dev/null 2>&1; then
                    log_message "INFO" "cleanup" "upstream" "Removing non-existent upstream server: $container_name" 2>/dev/null || true
                fi
            fi
        else
            # Not an upstream block or server line, keep as-is
            echo "$line" >> "$temp_config"
        fi
    done < "$config_file"
    
    # Replace original file with cleaned version
    mv "$temp_config" "$config_file"
}

