#!/bin/bash
# Migration Script - Convert existing services to symlink-based blue/green system
# Usage: migrate-to-symlinks.sh [service_name]
# If service_name is provided, only migrate that service. Otherwise, migrate all services.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

SERVICE_NAME="$1"

# Function to migrate a single service
migrate_service() {
    local service_name="$1"
    
    log_message "INFO" "$service_name" "migrate" "migrate" "Starting migration for service: $service_name"
    
    # Load service registry
    local registry
    if ! registry=$(load_service_registry "$service_name" 2>/dev/null); then
        log_message "WARNING" "$service_name" "migrate" "migrate" "Service registry not found, skipping: $service_name"
        return 1
    fi
    
    # Get domain name
    local domain=$(echo "$registry" | jq -r '.domain // empty')
    if [ -z "$domain" ] || [ "$domain" = "null" ]; then
        log_message "WARNING" "$service_name" "migrate" "migrate" "Domain not found in registry, skipping: $service_name"
        return 1
    fi
    
    local config_dir="${NGINX_PROJECT_DIR}/nginx/conf.d"
    local old_config="${config_dir}/${domain}.conf"
    local blue_config="${config_dir}/${domain}.blue.conf"
    local green_config="${config_dir}/${domain}.green.conf"
    
    # Check if old config exists
    if [ ! -f "$old_config" ] && [ ! -L "$old_config" ]; then
        log_message "INFO" "$service_name" "migrate" "migrate" "No existing config found for $domain, generating new configs"
        
        # Generate blue and green configs
        if ! generate_blue_green_configs "$service_name" "$domain" "blue"; then
            log_message "ERROR" "$service_name" "migrate" "migrate" "Failed to generate configs for $domain"
            return 1
        fi
        
        # Get active color from state or default to blue
        local state
        local active_color="blue"
        if state=$(load_state "$service_name" 2>/dev/null); then
            active_color=$(echo "$state" | jq -r '.active_color // "blue"')
        fi
        
        # Create symlink pointing to active color
        if ! switch_config_symlink "$domain" "$active_color"; then
            log_message "ERROR" "$service_name" "migrate" "migrate" "Failed to create symlink for $domain"
            return 1
        fi
        
        log_message "SUCCESS" "$service_name" "migrate" "migrate" "Migration completed for $domain (new configs generated)"
        return 0
    fi
    
    # Check if already migrated (blue and green configs exist)
    if [ -f "$blue_config" ] && [ -f "$green_config" ]; then
        log_message "INFO" "$service_name" "migrate" "migrate" "Service $domain already migrated (blue and green configs exist)"
        
        # Ensure symlink exists and points to correct color
        if [ ! -L "$old_config" ]; then
            log_message "INFO" "$service_name" "migrate" "migrate" "Creating symlink for already-migrated service: $domain"
            
            # Get active color from state or default to blue
            local state
            local active_color="blue"
            if state=$(load_state "$service_name" 2>/dev/null); then
                active_color=$(echo "$state" | jq -r '.active_color // "blue"')
            fi
            
            if ! switch_config_symlink "$domain" "$active_color"; then
                log_message "ERROR" "$service_name" "migrate" "migrate" "Failed to create symlink for $domain"
                return 1
            fi
        fi
        
        return 0
    fi
    
    # Backup old config
    local backup_file="${old_config}.backup.$(date +%Y%m%d_%H%M%S)"
    log_message "INFO" "$service_name" "migrate" "migrate" "Backing up old config to: $backup_file"
    cp "$old_config" "$backup_file"
    
    # Generate blue and green configs
    log_message "INFO" "$service_name" "migrate" "migrate" "Generating blue and green configs for $domain"
    if ! generate_blue_green_configs "$service_name" "$domain" "blue"; then
        log_message "ERROR" "$service_name" "migrate" "migrate" "Failed to generate configs for $domain"
        return 1
    fi
    
    # Get active color from state or try to determine from old config
    local state
    local active_color="blue"
    if state=$(load_state "$service_name" 2>/dev/null); then
        active_color=$(echo "$state" | jq -r '.active_color // "blue"')
    else
        # Try to determine from old config (check for blue or green in upstream blocks)
        if grep -q "blue.*weight=100" "$backup_file" 2>/dev/null; then
            active_color="blue"
        elif grep -q "green.*weight=100" "$backup_file" 2>/dev/null; then
            active_color="green"
        fi
    fi
    
    # Remove old config file (we'll create symlink)
    rm -f "$old_config"
    
    # Create symlink pointing to active color
    log_message "INFO" "$service_name" "migrate" "migrate" "Creating symlink pointing to $active_color config"
    if ! switch_config_symlink "$domain" "$active_color"; then
        log_message "ERROR" "$service_name" "migrate" "migrate" "Failed to create symlink for $domain"
        # Restore backup
        cp "$backup_file" "$old_config"
        return 1
    fi
    
    # Test nginx config
    log_message "INFO" "$service_name" "migrate" "migrate" "Testing nginx configuration"
    if ! test_service_nginx_config "$service_name"; then
        log_message "WARNING" "$service_name" "migrate" "migrate" "Nginx config test failed, but migration completed. Please review configs."
    fi
    
    log_message "SUCCESS" "$service_name" "migrate" "migrate" "Migration completed for $domain (backup: $backup_file)"
    return 0
}

# Main migration logic
if [ -n "$SERVICE_NAME" ]; then
    # Migrate single service
    if migrate_service "$SERVICE_NAME"; then
        log_message "SUCCESS" "$SERVICE_NAME" "migrate" "migrate" "Migration completed successfully for $SERVICE_NAME"
        exit 0
    else
        log_message "ERROR" "$SERVICE_NAME" "migrate" "migrate" "Migration failed for $SERVICE_NAME"
        exit 1
    fi
else
    # Migrate all services
    log_message "INFO" "all" "migrate" "migrate" "Starting migration for all services"
    
    registry_dir="${NGINX_PROJECT_DIR}/service-registry"
    migrated_count=0
    failed_count=0
    skipped_count=0
    
    for registry_file in "${registry_dir}"/*.json; do
        if [ ! -f "$registry_file" ]; then
            continue
        fi
        
        service_name=$(basename "$registry_file" .json)
        
        if migrate_service "$service_name"; then
            migrated_count=$((migrated_count + 1))
        else
            # Check if it was skipped (not an error)
            registry=""
            if registry=$(load_service_registry "$service_name" 2>/dev/null); then
                domain=$(echo "$registry" | jq -r '.domain // empty')
                if [ -n "$domain" ] && [ "$domain" != "null" ]; then
                    config_dir="${NGINX_PROJECT_DIR}/nginx/conf.d"
                    blue_config="${config_dir}/${domain}.blue.conf"
                    green_config="${config_dir}/${domain}.green.conf"
                    
                    if [ -f "$blue_config" ] && [ -f "$green_config" ]; then
                        skipped_count=$((skipped_count + 1))
                    else
                        failed_count=$((failed_count + 1))
                    fi
                else
                    skipped_count=$((skipped_count + 1))
                fi
            else
                skipped_count=$((skipped_count + 1))
            fi
        fi
    done
    
    log_message "SUCCESS" "all" "migrate" "migrate" "Migration completed: $migrated_count migrated, $failed_count failed, $skipped_count skipped"
    
    if [ $failed_count -gt 0 ]; then
        exit 1
    fi
    
    exit 0
fi
