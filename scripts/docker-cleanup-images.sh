#!/bin/bash
# Comprehensive Docker cleanup script - runs every 4 hours via cron
# Removes: stopped containers, unused images, unused volumes, build cache, unused networks
# Preserves: running containers and their associated resources

# Set PATH for cron environment (Docker might not be in default PATH)
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Log file location (in user's home directory)
USER_HOME="${HOME:-/home/statex}"
LOG_FILE="${USER_HOME}/docker-cleanup.log"

# Function to log messages
log_message() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message" >> "$LOG_FILE" 2>&1
}

# Function to check disk space and return percentage used
get_disk_used_percent() {
    df / | tail -1 | awk '{print $5}' | sed 's/%//'
}

# Function to get reclaimable space from docker system df
get_reclaimable_space() {
    docker system df --format "{{.Reclaimable}}" 2>/dev/null | head -1 || echo "0B"
}

# Function to run cleanup command and log results
run_cleanup() {
    local cleanup_type="$1"
    local command="$2"
    log_message "Cleaning up $cleanup_type..."
    local output=$($command 2>&1)
    local exit_code=$?
    if [ $exit_code -eq 0 ]; then
        log_message "✓ $cleanup_type cleanup completed"
        # Extract reclaimed space from output (look for "Total reclaimed space" or similar)
        local reclaimed=$(echo "$output" | grep -iE "(Total reclaimed|reclaimed space)" | head -1 || echo "")
        if [ -n "$reclaimed" ]; then
            log_message "$reclaimed"
        fi
        # For build cache, show the detailed output
        if [ "$cleanup_type" = "build cache" ]; then
            echo "$output" >> "$LOG_FILE" 2>&1
        fi
    else
        log_message "✗ $cleanup_type cleanup failed (exit code: $exit_code)"
        echo "$output" >> "$LOG_FILE" 2>&1
    fi
    return $exit_code
}

# Ensure log file is writable (in user's home directory, no root needed)
if ! touch "$LOG_FILE" 2>/dev/null; then
    # Try to create log directory if it doesn't exist
    LOG_DIR=$(dirname "$LOG_FILE")
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    if ! touch "$LOG_FILE" 2>/dev/null; then
        # Last resort: use syslog if available, otherwise exit
        if command -v logger >/dev/null 2>&1; then
            logger -t docker-cleanup "ERROR: Cannot write to log file: $LOG_FILE"
        fi
        echo "ERROR: Cannot write to log file: $LOG_FILE" >&2
        exit 1
    fi
fi

# Set proper permissions on log file
chmod 644 "$LOG_FILE" 2>/dev/null || true

log_message "=== Docker Comprehensive Cleanup Started ==="

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
DISK_USED_PERCENT=$(get_disk_used_percent)
DISK_FREE_PERCENT=$((100 - DISK_USED_PERCENT))
log_message "Disk usage before: $DISK_BEFORE (${DISK_USED_PERCENT}% used, ${DISK_FREE_PERCENT}% free)"

# Show Docker system disk usage and reclaimable space
log_message "Docker system disk usage:"
docker system df >> "$LOG_FILE" 2>&1
RECLAIMABLE_BEFORE=$(get_reclaimable_space)
log_message "Total reclaimable space before cleanup: $RECLAIMABLE_BEFORE"

# Warn if disk space is critically low
if [ "$DISK_USED_PERCENT" -gt 90 ]; then
    log_message "WARNING: Disk space critically low (${DISK_USED_PERCENT}% used). Aggressive cleanup will be performed."
fi

# Get resource counts before cleanup
IMAGES_BEFORE=$(docker images -q 2>/dev/null | wc -l)
CONTAINERS_BEFORE=$(docker ps -a -q 2>/dev/null | wc -l)
VOLUMES_BEFORE=$(docker volume ls -q 2>/dev/null | wc -l)
log_message "Resources before cleanup: Images: $IMAGES_BEFORE, Containers: $CONTAINERS_BEFORE, Volumes: $VOLUMES_BEFORE"

# Cleanup stopped containers
run_cleanup "stopped containers" "docker container prune -f"

# Cleanup unused images (all unused images, not just dangling)
# If disk space is critically low, also remove dangling images more aggressively
if [ "$DISK_USED_PERCENT" -gt 85 ]; then
    log_message "Disk space low - performing aggressive image cleanup..."
    # First remove dangling images
    run_cleanup "dangling images" "docker image prune -f"
    # Then remove all unused images
    run_cleanup "unused images" "docker image prune -a -f"
else
    run_cleanup "unused images" "docker image prune -a -f"
fi

# Cleanup unused volumes (only truly unused volumes)
run_cleanup "unused volumes" "docker volume prune -f"

# Cleanup build cache (this can free significant space)
# Calculate build cache size before cleanup
BUILD_CACHE_BEFORE=$(docker system df --format "{{.Size}}" | grep -A 1 "Build Cache" | tail -1 || echo "0B")
log_message "Build cache size before cleanup: $BUILD_CACHE_BEFORE"
run_cleanup "build cache" "docker builder prune -a -f"
BUILD_CACHE_AFTER=$(docker system df --format "{{.Size}}" | grep -A 1 "Build Cache" | tail -1 || echo "0B")
log_message "Build cache size after cleanup: $BUILD_CACHE_AFTER"

# Cleanup unused networks
run_cleanup "unused networks" "docker network prune -f"

# Get resource counts after cleanup
IMAGES_AFTER=$(docker images -q 2>/dev/null | wc -l)
CONTAINERS_AFTER=$(docker ps -a -q 2>/dev/null | wc -l)
VOLUMES_AFTER=$(docker volume ls -q 2>/dev/null | wc -l)
log_message "Resources after cleanup: Images: $IMAGES_AFTER, Containers: $CONTAINERS_AFTER, Volumes: $VOLUMES_AFTER"

# Get disk usage after cleanup
DISK_AFTER=$(df -h / | tail -1 | awk '{print $3 " used, " $4 " free"}' 2>/dev/null || echo "unknown")
DISK_USED_PERCENT_AFTER=$(get_disk_used_percent)
DISK_FREE_PERCENT_AFTER=$((100 - DISK_USED_PERCENT_AFTER))
log_message "Disk usage after: $DISK_AFTER (${DISK_USED_PERCENT_AFTER}% used, ${DISK_FREE_PERCENT_AFTER}% free)"

# Show Docker system disk usage after cleanup
log_message "Docker system disk usage after cleanup:"
docker system df >> "$LOG_FILE" 2>&1
RECLAIMABLE_AFTER=$(get_reclaimable_space)
log_message "Total reclaimable space after cleanup: $RECLAIMABLE_AFTER"

# Show summary of remaining resources (limit to avoid huge logs)
log_message "Remaining images (showing first 10):"
docker images --format "{{.Repository}}:{{.Tag}} ({{.Size}})" 2>/dev/null | head -10 >> "$LOG_FILE" 2>&1

log_message "=== Docker Comprehensive Cleanup Completed ==="
log_message ""

