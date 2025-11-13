#!/bin/bash
# Setup Git on Production Server (Read-Only Access)
# This script configures git on production server to use HTTPS (read-only)
# Usage: Run this script on production server or via SSH

set -e

PROJECT_DIR="${1:-/home/statex/nginx-microservice}"

echo "🔧 Setting up Git read-only access on production server..."
echo ""

# Navigate to project directory
if [ ! -d "$PROJECT_DIR" ]; then
    echo "❌ Error: Project directory not found: $PROJECT_DIR"
    exit 1
fi

cd "$PROJECT_DIR"

# Check if it's a git repository
if [ ! -d ".git" ]; then
    echo "❌ Error: Not a git repository: $PROJECT_DIR"
    exit 1
fi

echo "📁 Project directory: $PROJECT_DIR"
echo ""

# Configure git to use HTTPS (read-only)
echo "🔐 Configuring git remote to use HTTPS (read-only)..."
git remote set-url origin https://github.com/speakASAP/nginx-microservice.git

# Verify configuration
echo ""
echo "✅ Git remote configured:"
git remote -v

# Test read access
echo ""
echo "🧪 Testing git fetch (read access)..."
if git fetch --dry-run >/dev/null 2>&1; then
    echo "✅ Git read access working correctly"
else
    echo "⚠️  Warning: Git fetch test failed (this is normal if repository is private)"
    echo "   HTTPS will work for public repos or with personal access token"
fi

# Disable push (safety measure)
echo ""
echo "🔒 Disabling push capability..."
git config --local remote.origin.pushurl "no_push"
git config --local --add remote.origin.pushurl ""

echo ""
echo "✅ Production server git configuration complete!"
echo ""
echo "📝 Configuration summary:"
echo "   - Remote URL: HTTPS (read-only)"
echo "   - Push disabled: Yes"
echo "   - Pull enabled: Yes"
echo ""
echo "💡 To pull latest changes:"
echo "   cd $PROJECT_DIR && git pull origin main"

