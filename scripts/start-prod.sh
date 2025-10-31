#!/bin/bash
# Start nginx-microservice on production server
# Usage: ./start-prod.sh

set -e

SSH_HOST="statex"
PROJECT_DIR="/home/statex/nginx-microservice"

echo "🚀 Starting nginx-microservice on production server..."
echo ""

# Check if we can connect to production server
echo "Checking SSH connection..."
if ! ssh -o ConnectTimeout=5 "$SSH_HOST" exit 2>/dev/null; then
    echo "❌ Error: Cannot connect to production server via SSH 'statex'"
    echo "   Make sure SSH alias 'statex' is configured in ~/.ssh/config"
    exit 1
fi

echo "✅ SSH connection successful"
echo ""

# Execute commands on production server
# Capture exit code properly
if ssh "$SSH_HOST" bash <<'REMOTE_SCRIPT'
set -e

# Navigate to project directory
echo "📁 Navigating to project directory: /home/statex/nginx-microservice"
cd /home/statex/nginx-microservice || {
    echo "❌ Error: Project directory not found: /home/statex/nginx-microservice"
    echo "   Please ensure nginx-microservice is cloned to this location"
    exit 1
}

echo "✅ Project directory found"
echo ""

# Check if docker-compose.yml exists
if [ ! -f "docker-compose.yml" ]; then
    echo "❌ Error: docker-compose.yml not found"
    exit 1
fi

echo "✅ docker-compose.yml found"
echo ""

# Check/create docker network
echo "🔍 Checking docker network 'nginx-network'..."
if ! docker network inspect nginx-network >/dev/null 2>&1; then
    echo "Creating docker network 'nginx-network'..."
    docker network create nginx-network
    echo "✅ Docker network 'nginx-network' created"
else
    echo "✅ Docker network 'nginx-network' already exists"
fi
echo ""

# Check if containers are already running
echo "🔍 Checking current container status..."
CONTAINERS_RUNNING=false
if docker compose ps 2>/dev/null | grep -q "Up"; then
    CONTAINERS_RUNNING=true
    echo "⚠️  Warning: Some containers are already running"
    echo "   Current status:"
    docker compose ps
    echo ""
    read -p "Do you want to restart the service? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Stopping existing containers..."
        docker compose down
        echo "✅ Containers stopped"
        CONTAINERS_RUNNING=false
    else
        echo "Aborted. Containers remain running."
        exit 0
    fi
    echo ""
fi

# Start services only if not running or if restarted
if [ "$CONTAINERS_RUNNING" = "false" ]; then
    echo "🚀 Starting nginx-microservice..."
    docker compose up -d

    echo ""
    echo "✅ Services started successfully!"
    echo ""
    
    # Wait a moment for containers to initialize
    sleep 2
fi

# Show container status
echo "📊 Container status:"
docker compose ps

# Check for unhealthy containers
if docker compose ps 2>/dev/null | grep -qE "Restarting|Unhealthy"; then
    echo ""
    echo "⚠️  Warning: Some containers are not healthy!"
    echo "   Check logs with: docker compose logs"
    exit 1
fi

echo ""
echo "📝 Useful commands:"
echo "   View logs: docker compose logs -f"
echo "   Stop service: docker compose down"
echo "   Restart service: docker compose restart"
echo "   Check nginx config: docker compose exec nginx nginx -t"

REMOTE_SCRIPT
then
    EXIT_CODE=0
else
    EXIT_CODE=$?
fi

if [ $EXIT_CODE -eq 0 ]; then
    echo ""
    echo "✅ nginx-microservice operation completed on production server!"
    echo ""
    echo "To view logs, run:"
    echo "  ssh statex 'cd $PROJECT_DIR && docker compose logs -f'"
else
    echo ""
    echo "❌ Operation failed or was aborted (exit code: $EXIT_CODE)"
    exit $EXIT_CODE
fi

