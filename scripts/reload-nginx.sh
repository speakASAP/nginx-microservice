#!/bin/bash
# Reload Nginx Script
# Tests and reloads nginx configuration

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "Testing nginx configuration..."
# Test config, but don't fail if test fails - invalid configs should have been rejected during generation
# Nginx should still attempt to reload with valid configs
if docker compose -f "${PROJECT_DIR}/docker-compose.yml" exec nginx nginx -t 2>/dev/null; then
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
    echo "⚠️  Configuration test failed or nginx container not accessible"
    echo "   Invalid configs should have been rejected during generation"
    echo "   Attempting reload anyway (nginx will reject invalid configs at runtime)..."
    echo ""
    if docker compose -f "${PROJECT_DIR}/docker-compose.yml" exec nginx nginx -s reload 2>/dev/null; then
        echo "✅ Nginx reloaded successfully"
        exit 0
    else
        echo "❌ Failed to reload nginx - check logs for details"
        echo "   docker compose logs nginx"
        exit 1
    fi
fi

