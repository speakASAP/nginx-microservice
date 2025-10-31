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
ssh "$SSH_HOST" bash <<EOF
set -e

# Navigate to project directory
echo "📁 Navigating to project directory: $PROJECT_DIR"
cd "$PROJECT_DIR" || {
    echo "❌ Error: Project directory not found: $PROJECT_DIR"
    echo "   Please ensure nginx-microservice is cloned to this location"
    exit 1
}

echo "✅ Project directory found"
echo ""

# Check if docker-compose.yml exists
if [ ! -f "docker-compose.yml" ]; then
    echo "❌ Error: docker-compose.yml not found in $PROJECT_DIR"
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
if docker compose ps | grep -q "Up"; then
    echo "⚠️  Warning: Some containers are already running"
    echo "   Current status:"
    docker compose ps
    echo ""
    read -p "Do you want to restart the service? (y/N): " -n 1 -r
    echo
    if [[ \$REPLY =~ ^[Yy]$ ]]; then
        echo "Stopping existing containers..."
        docker compose down
        echo "✅ Containers stopped"
    else
        echo "Aborted. Containers remain running."
        exit 0
    fi
    echo ""
fi

# Start services
echo "🚀 Starting nginx-microservice..."
docker compose up -d

echo ""
echo "✅ Services started successfully!"
echo ""

# Show container status
echo "📊 Container status:"
docker compose ps

echo ""
echo "📝 Useful commands:"
echo "   View logs: docker compose logs -f"
echo "   Stop service: docker compose down"
echo "   Restart service: docker compose restart"
echo "   Check nginx config: docker compose exec nginx nginx -t"

EOF

echo ""
echo "✅ nginx-microservice started on production server!"
echo ""
echo "To view logs, run:"
echo "  ssh statex 'cd $PROJECT_DIR && docker compose logs -f'"

