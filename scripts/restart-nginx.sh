#!/bin/bash
# Restart Nginx Script
# Tests configuration and restarts nginx container

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "Testing nginx configuration..."
if docker compose -f "${PROJECT_DIR}/docker-compose.yml" exec nginx nginx -t; then
    echo ""
    echo "✅ Configuration test passed"
    echo ""
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
