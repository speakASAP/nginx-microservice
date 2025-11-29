#!/bin/bash
# Restart Nginx Script
# Syncs containers and symlinks, tests configuration, and reloads/restarts nginx
# Prefers reload over restart to avoid breaking existing connections

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BLUE_GREEN_DIR="${SCRIPT_DIR}/blue-green"

# First, sync containers and symlinks to ensure everything is correct
echo "Syncing containers and nginx configuration..."
if [ -f "${SCRIPT_DIR}/sync-containers-and-nginx.sh" ]; then
    if ! "${SCRIPT_DIR}/sync-containers-and-nginx.sh"; then
        echo "❌ Failed to sync containers and configuration"
        exit 1
    fi
    echo ""
fi

echo "Testing nginx configuration..."
if docker compose -f "${PROJECT_DIR}/docker-compose.yml" exec nginx nginx -t 2>/dev/null || docker compose -f "${PROJECT_DIR}/docker-compose.yml" run --rm nginx nginx -t; then
    echo ""
    echo "✅ Configuration test passed"
    echo ""
    
    # Check if nginx container is running
    nginx_running=false
    if docker ps --format "{{.Names}}" 2>/dev/null | grep -qE "^nginx-microservice$"; then
        nginx_status=$(docker ps --format "{{.Names}}\t{{.Status}}" 2>/dev/null | grep "^nginx-microservice" | awk '{print $2}' || echo "")
        if [ -n "$nginx_status" ] && ! echo "$nginx_status" | grep -qE "Restarting"; then
            nginx_running=true
        fi
    fi
    
    if [ "$nginx_running" = "true" ]; then
        # Nginx is running - use reload to avoid breaking connections
        echo "Nginx is running - using reload (preserves existing connections)..."
        if docker compose -f "${PROJECT_DIR}/docker-compose.yml" exec nginx nginx -s reload; then
            echo "✅ Nginx reloaded successfully"
            exit 0
        else
            echo "⚠️  Reload failed, attempting restart..."
            # Fall through to restart logic
        fi
    fi
    
    # Nginx is not running or reload failed - use restart
    echo "Nginx is not running or reload failed - using restart..."
    
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
    nginx_status=$(docker ps --format "{{.Names}}\t{{.Status}}" 2>/dev/null | grep "^nginx-microservice" | awk '{print $2}' || echo "")
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
        
        # Check if container is restarting
        nginx_status=$(docker ps --format "{{.Names}}\t{{.Status}}" 2>/dev/null | grep "^nginx-microservice" | awk '{print $2}' || echo "")
        if [ -n "$nginx_status" ] && echo "$nginx_status" | grep -qE "Restarting"; then
            echo "⚠️  Nginx container is restarting after restart attempt"
            echo "   This indicates a restart loop. Running diagnostic..."
            echo ""
            if [ -f "${SCRIPT_DIR}/diagnose-nginx-restart.sh" ]; then
                "${SCRIPT_DIR}/diagnose-nginx-restart.sh"
            else
                echo "   Container logs:"
                docker logs --tail 30 nginx-microservice 2>&1 | sed 's/^/   /' || true
            fi
            exit 1
        fi
        
        if docker compose -f "${PROJECT_DIR}/docker-compose.yml" exec nginx nginx -t >/dev/null 2>&1; then
            echo "✅ Nginx is running and configuration is valid"
            exit 0
        else
            echo "⚠️  Nginx restarted but configuration test failed. Check logs:"
            echo "   docker compose logs nginx"
            echo ""
            echo "   Or run diagnostic script:"
            echo "   ./scripts/diagnose-nginx-restart.sh"
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
