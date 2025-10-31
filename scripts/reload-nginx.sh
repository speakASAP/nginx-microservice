#!/bin/bash
# Reload Nginx Script
# Tests and reloads nginx configuration

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "Testing nginx configuration..."
if docker compose -f "${PROJECT_DIR}/docker-compose.yml" exec nginx nginx -t; then
    echo ""
    echo "✅ Configuration test passed"
    echo ""
    echo "Reloading nginx..."
    if docker compose -f "${PROJECT_DIR}/docker-compose.yml" exec nginx nginx -s reload; then
        echo "✅ Nginx reloaded successfully"
        exit 0
    else
        echo "❌ Failed to reload nginx"
        exit 1
    fi
else
    echo ""
    echo "❌ Configuration test failed!"
    echo "Please fix the errors above before reloading."
    exit 1
fi

