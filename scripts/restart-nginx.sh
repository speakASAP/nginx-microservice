#!/bin/bash
# Restart Nginx Script
# Tests configuration and restarts nginx container

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BLUE_GREEN_DIR="${SCRIPT_DIR}/blue-green"

echo "Testing nginx configuration..."
if docker compose -f "${PROJECT_DIR}/docker-compose.yml" exec nginx nginx -t; then
    echo ""
    echo "✅ Configuration test passed"
    echo ""
    
    # Check for restarting containers and port conflicts before restarting
    echo "Checking for port conflicts and restarting containers..."
    if [ -f "${BLUE_GREEN_DIR}/utils.sh" ]; then
        source "${BLUE_GREEN_DIR}/utils.sh" 2>/dev/null || true
        if type kill_port_if_in_use >/dev/null 2>&1; then
            kill_port_if_in_use "80" "nginx" "restart"
            kill_port_if_in_use "443" "nginx" "restart"
        fi
        # Kill any restarting nginx containers
        if type kill_container_if_exists >/dev/null 2>&1; then
            kill_container_if_exists "nginx-microservice" "nginx" "restart"
            kill_container_if_exists "nginx-certbot" "nginx" "restart"
        fi
    fi
    
    # Fallback: manual check for restarting containers
    local nginx_status=$(docker ps --format "{{.Names}}\t{{.Status}}" 2>/dev/null | grep "^nginx-microservice" | awk '{print $2}' || echo "")
    if [ -n "$nginx_status" ] && echo "$nginx_status" | grep -qE "Restarting"; then
        echo "⚠️  Nginx container is restarting, force killing it first..."
        docker kill nginx-microservice 2>/dev/null || true
        docker rm -f nginx-microservice 2>/dev/null || true
        sleep 2
    fi
    
    echo "Restarting nginx container..."
    if docker compose -f "${PROJECT_DIR}/docker-compose.yml" restart nginx; then
        echo "✅ Nginx restarted successfully"
        echo ""
        echo "Waiting for nginx to be ready..."
        sleep 3
        if docker compose -f "${PROJECT_DIR}/docker-compose.yml" exec nginx nginx -t >/dev/null 2>&1; then
            echo "✅ Nginx is running and configuration is valid"
            exit 0
        else
            echo "⚠️  Nginx restarted but configuration test failed. Check logs:"
            echo "   docker compose logs nginx"
            exit 1
        fi
    else
        echo "❌ Failed to restart nginx"
        exit 1
    fi
else
    echo ""
    echo "❌ Configuration test failed!"
    echo "Please fix the errors above before restarting."
    exit 1
fi
