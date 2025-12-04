#!/bin/bash
# Comprehensive Docker cleanup script - runs every 4 hours via cron
# Removes: stopped containers, unused images, unused volumes, build cache, unused networks
# Preserves: running containers and their associated resources

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

# Function to check disk space and return percentage free
get_disk_free_percent() {
    df / | tail -1 | awk '{print $5}' | sed 's/%//'
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
        echo "$output" >> "$LOG_FILE" 2>&1
        # Extract reclaimed space if available
        local reclaimed=$(echo "$output" | grep -i "reclaimed" || echo "")
        if [ -n "$reclaimed" ]; then
            log_message "$reclaimed"
        fi
    else
        log_message "✗ $cleanup_type cleanup failed (exit code: $exit_code)"
        echo "$output" >> "$LOG_FILE" 2>&1
    fi
    return $exit_code
}

# Ensure log file is writable (fix permissions if needed)
touch "$LOG_FILE" 2>/dev/null || {
    LOG_FILE="/var/log/docker-cleanup.log"
    touch "$LOG_FILE" 2>/dev/null || {
        logger -t docker-cleanup "ERROR: Cannot write to log file"
        exit 1
    }
}

# Set proper permissions on log file (readable by statex user)
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
DISK_FREE_PERCENT=$(get_disk_free_percent)
log_message "Disk usage before: $DISK_BEFORE (${DISK_FREE_PERCENT}% free)"

# Warn if disk space is critically low
if [ "$DISK_FREE_PERCENT" -gt 90 ]; then
    log_message "WARNING: Disk space critically low (${DISK_FREE_PERCENT}% used). Aggressive cleanup will be performed."
fi

# Get resource counts before cleanup
IMAGES_BEFORE=$(docker images -q 2>/dev/null | wc -l)
CONTAINERS_BEFORE=$(docker ps -a -q 2>/dev/null | wc -l)
VOLUMES_BEFORE=$(docker volume ls -q 2>/dev/null | wc -l)
log_message "Resources before cleanup: Images: $IMAGES_BEFORE, Containers: $CONTAINERS_BEFORE, Volumes: $VOLUMES_BEFORE"

# Cleanup stopped containers
run_cleanup "stopped containers" "docker container prune -f"

# Cleanup unused images (all unused images, not just dangling)
run_cleanup "unused images" "docker image prune -a -f"

# Cleanup unused volumes (only truly unused volumes)
run_cleanup "unused volumes" "docker volume prune -f"

# Cleanup build cache
run_cleanup "build cache" "docker builder prune -a -f"

# Cleanup unused networks
run_cleanup "unused networks" "docker network prune -f"

# Get resource counts after cleanup
IMAGES_AFTER=$(docker images -q 2>/dev/null | wc -l)
CONTAINERS_AFTER=$(docker ps -a -q 2>/dev/null | wc -l)
VOLUMES_AFTER=$(docker volume ls -q 2>/dev/null | wc -l)
log_message "Resources after cleanup: Images: $IMAGES_AFTER, Containers: $CONTAINERS_AFTER, Volumes: $VOLUMES_AFTER"

# Get disk usage after cleanup
DISK_AFTER=$(df -h / | tail -1 | awk '{print $3 " used, " $4 " free"}' 2>/dev/null || echo "unknown")
DISK_FREE_PERCENT_AFTER=$(get_disk_free_percent)
log_message "Disk usage after: $DISK_AFTER (${DISK_FREE_PERCENT_AFTER}% free)"

# Show summary of remaining resources (limit to avoid huge logs)
log_message "Remaining images (showing first 10):"
docker images --format "{{.Repository}}:{{.Tag}} ({{.Size}})" 2>/dev/null | head -10 >> "$LOG_FILE" 2>&1

log_message "=== Docker Comprehensive Cleanup Completed ==="
log_message ""

