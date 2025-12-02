#!/bin/bash
# Clean up unused Docker images every 4 hours
# This script removes only unused images, keeps running containers and volumes intact

# Set PATH for cron environment (Docker might not be in default PATH)
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Log file location
LOG_FILE="/home/statex/docker-cleanup.log"

# Function to log messages
log_message() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message" >> "$LOG_FILE" 2>&1
}

# Ensure log file is writable (fix permissions if needed)
touch "$LOG_FILE" 2>/dev/null || {
    # If we can't write to the log file, try to create it in /var/log instead
    LOG_FILE="/var/log/docker-cleanup.log"
    touch "$LOG_FILE" 2>/dev/null || {
        # Last resort: use syslog
        logger -t docker-cleanup "ERROR: Cannot write to log file"
        exit 1
    }
}

# Set proper permissions on log file (readable by statex user)
chmod 644 "$LOG_FILE" 2>/dev/null || true

log_message "=== Docker Image Cleanup Started ==="

# Check if Docker is available
if ! command -v docker >/dev/null 2>&1; then
    log_message "ERROR: Docker command not found in PATH"
    exit 1
fi

# Check if Docker daemon is accessible
if ! docker info >/dev/null 2>&1; then
    log_message "ERROR: Cannot connect to Docker daemon. Check permissions and Docker service status."
    exit 1
fi

# Get disk usage before cleanup
DISK_BEFORE=$(df -h / | tail -1 | awk '{print $3 " used, " $4 " free"}' 2>/dev/null || echo "unknown")
log_message "Disk usage before: $DISK_BEFORE"

# Get image count before cleanup
IMAGES_BEFORE=$(docker images -q 2>/dev/null | wc -l)
log_message "Images before cleanup: $IMAGES_BEFORE"

# Get list of images used by running containers
RUNNING_CONTAINER_IMAGES=$(docker ps --format "{{.Image}}" 2>/dev/null | sort -u)
RUNNING_COUNT=$(echo "$RUNNING_CONTAINER_IMAGES" | grep -v '^$' | wc -l)
log_message "Images in use by running containers: $RUNNING_COUNT"

# Remove unused images (not used by any container)
# docker image prune -a removes all images not associated with a container
# -f flag forces removal without confirmation
log_message "Removing unused images..."

PRUNE_OUTPUT=$(docker image prune -a -f 2>&1)
PRUNE_EXIT=$?

if [ $PRUNE_EXIT -eq 0 ]; then
    log_message "✓ Image cleanup completed successfully"
    echo "$PRUNE_OUTPUT" >> "$LOG_FILE" 2>&1
    
    # Extract reclaimed space from output
    RECLAIMED=$(echo "$PRUNE_OUTPUT" | grep -i "reclaimed" || echo "Space reclaimed: unknown")
    log_message "$RECLAIMED"
else
    log_message "✗ Image cleanup failed with exit code: $PRUNE_EXIT"
    echo "$PRUNE_OUTPUT" >> "$LOG_FILE" 2>&1
fi

# Get image count after cleanup
IMAGES_AFTER=$(docker images -q 2>/dev/null | wc -l)
IMAGES_REMOVED=$((IMAGES_BEFORE - IMAGES_AFTER))
log_message "Images after cleanup: $IMAGES_AFTER (removed: $IMAGES_REMOVED)"

# Get disk usage after cleanup
DISK_AFTER=$(df -h / | tail -1 | awk '{print $3 " used, " $4 " free"}' 2>/dev/null || echo "unknown")
log_message "Disk usage after: $DISK_AFTER"

# Show current images (limit to first 20 to avoid huge logs)
log_message "Remaining images (showing first 20):"
docker images --format "{{.Repository}}:{{.Tag}} ({{.Size}})" 2>/dev/null | head -20 >> "$LOG_FILE" 2>&1

log_message "=== Docker Image Cleanup Completed ==="
log_message ""

