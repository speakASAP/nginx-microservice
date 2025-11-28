#!/bin/bash
# Migration Script - Move blue/green configs to blue-green subdirectory
# This fixes the issue where nginx reads both .blue.conf and .green.conf files
# causing duplicate upstream definitions

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

CONFIG_DIR="${NGINX_PROJECT_DIR}/nginx/conf.d"
BLUE_GREEN_DIR="${CONFIG_DIR}/blue-green"

log_message "INFO" "migration" "config-move" "Starting migration of blue/green configs to subdirectory"

# Create blue-green subdirectory
mkdir -p "$BLUE_GREEN_DIR"

# Find all blue and green config files
moved_count=0
skipped_count=0
error_count=0

for config_file in "${CONFIG_DIR}"/*.blue.conf "${CONFIG_DIR}"/*.green.conf; do
    # Skip if no files match the pattern
    [ -f "$config_file" ] || continue
    
    filename=$(basename "$config_file")
    target="${BLUE_GREEN_DIR}/${filename}"
    
    # Skip if already in subdirectory
    if [[ "$config_file" == "${BLUE_GREEN_DIR}/"* ]]; then
        skipped_count=$((skipped_count + 1))
        continue
    fi
    
    # Move file to subdirectory
    if mv "$config_file" "$target" 2>/dev/null; then
        log_message "SUCCESS" "migration" "config-move" "Moved $filename to blue-green subdirectory"
        moved_count=$((moved_count + 1))
    else
        log_message "ERROR" "migration" "config-move" "Failed to move $filename"
        error_count=$((error_count + 1))
    fi
done

# Update all symlinks to point to blue-green subdirectory
log_message "INFO" "migration" "config-move" "Updating symlinks to point to blue-green subdirectory"

for symlink in "${CONFIG_DIR}"/*.conf; do
    # Skip if not a symlink
    [ -L "$symlink" ] || continue
    
    current_target=$(readlink "$symlink")
    filename=$(basename "$symlink" .conf)
    
    # Check if target is a blue or green config
    if [[ "$current_target" == *.blue.conf ]] || [[ "$current_target" == *.green.conf ]]; then
        # Extract color from target
        if [[ "$current_target" == *.blue.conf ]]; then
            new_target="blue-green/${filename}.blue.conf"
        else
            new_target="blue-green/${filename}.green.conf"
        fi
        
        # Update symlink
        if ln -sf "$new_target" "$symlink" 2>/dev/null; then
            log_message "SUCCESS" "migration" "config-move" "Updated symlink $(basename $symlink) -> $new_target"
        else
            log_message "ERROR" "migration" "config-move" "Failed to update symlink $(basename $symlink)"
            error_count=$((error_count + 1))
        fi
    elif [[ "$current_target" == "blue-green/"* ]]; then
        # Already pointing to subdirectory
        skipped_count=$((skipped_count + 1))
    fi
done

log_message "SUCCESS" "migration" "config-move" "Migration completed: $moved_count moved, $skipped_count skipped, $error_count errors"

if [ "$error_count" -gt 0 ]; then
    exit 1
fi

exit 0

