#!/bin/bash
# Setup script for Docker cleanup cron job
# This script sets up the cron job in the user's crontab (not root)
# The script runs without root privileges (user must be in docker group)

set -e

# Load .env file if it exists (for PRODUCTION_BASE_PATH)
SCRIPT_DIR_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_PROJECT_DIR="$(cd "$SCRIPT_DIR_SCRIPT/.." && pwd)"
if [ -f "${NGINX_PROJECT_DIR}/.env" ]; then
    set -a
    source "${NGINX_PROJECT_DIR}/.env" 2>/dev/null || true
    set +a
fi

# Use user's home directory for script location
USER_HOME="${HOME:-${PRODUCTION_BASE_PATH:-/home/statex}}"
SCRIPT_DIR="${USER_HOME}/bin"
SCRIPT_PATH="${SCRIPT_DIR}/docker-cleanup-images.sh"
CRON_SCHEDULE="0 */4 * * *"
LOG_FILE="${USER_HOME}/docker-cleanup.log"

echo "=== Docker Cleanup Cron Job Setup (User Crontab) ==="
echo ""

# Create bin directory if it doesn't exist
if [ ! -d "$SCRIPT_DIR" ]; then
    echo "Creating $SCRIPT_DIR directory..."
    mkdir -p "$SCRIPT_DIR"
fi

# Check if script exists in the repo
REPO_SCRIPT="nginx-microservice/scripts/docker-cleanup-images.sh"
if [ -f "$REPO_SCRIPT" ]; then
    echo "Copying script to $SCRIPT_PATH..."
    cp "$REPO_SCRIPT" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    echo "✅ Script deployed to $SCRIPT_PATH"
elif [ ! -f "$SCRIPT_PATH" ]; then
    echo "❌ Error: Script not found at $REPO_SCRIPT or $SCRIPT_PATH"
    echo "Please ensure the script exists in the repository."
    exit 1
fi

# Verify script is executable
if [ ! -x "$SCRIPT_PATH" ]; then
    echo "Making script executable..."
    chmod +x "$SCRIPT_PATH"
fi

# Verify user can run docker commands
if ! docker info >/dev/null 2>&1; then
    echo "⚠️  Warning: Cannot run docker commands. Make sure you're in the docker group:"
    echo "   sudo usermod -aG docker $USER"
    echo "   Then log out and log back in."
    echo ""
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Create the cron job entry
CRON_JOB="${CRON_SCHEDULE} ${SCRIPT_PATH} >> ${LOG_FILE} 2>&1"

echo ""
echo "Cron job to install:"
echo "  $CRON_JOB"
echo ""

# Get current user crontab
CURRENT_CRON=$(crontab -l 2>/dev/null || echo "")

# Check if cron job already exists
if echo "$CURRENT_CRON" | grep -q "docker-cleanup-images.sh"; then
    echo "⚠️  Cron job already exists"
    echo ""
    echo "Current crontab:"
    crontab -l | grep -E "(docker-cleanup|^#)" || crontab -l
    echo ""
    read -p "Do you want to replace it? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
    
    # Remove old cron job and add new one
    (echo "$CURRENT_CRON" | grep -v "docker-cleanup-images.sh"; echo "$CRON_JOB") | crontab -
    echo "✅ Cron job updated"
else
    # Add new cron job
    (echo "$CURRENT_CRON"; echo "$CRON_JOB") | crontab -
    echo "✅ Cron job created"
fi

echo ""
echo "Current crontab:"
crontab -l
echo ""

# Verify cron service is running
if systemctl is-active --quiet cron || systemctl is-active --quiet crond; then
    echo "✅ Cron service is running"
else
    echo "⚠️  Warning: Cron service might not be running"
    echo "   Check with: systemctl status cron"
fi

echo ""
echo "Cron job will run every 4 hours at: 00:00, 04:00, 08:00, 12:00, 16:00, 20:00"
echo ""
echo "To test the script manually:"
echo "  $SCRIPT_PATH"
echo ""
echo "To check logs:"
echo "  tail -f $LOG_FILE"
echo ""
echo "✅ Setup complete!"

