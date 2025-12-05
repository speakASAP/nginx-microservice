#!/bin/bash

# File watcher script to automatically sync .env to .env.example
# Usage: ./scripts/watch-env-sync.sh [directory-to-watch]

set -e

WATCH_DIR="${1:-.}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_SCRIPT="${SCRIPT_DIR}/sync-env-example.sh"

# Check if sync script exists
if [ ! -f "$SYNC_SCRIPT" ]; then
    echo "Error: sync-env-example.sh not found at $SYNC_SCRIPT"
    exit 1
fi

echo "🔍 Watching for .env file changes in: $WATCH_DIR"
echo "Press Ctrl+C to stop"

# Check for fswatch (macOS) or inotifywait (Linux)
if command -v fswatch &> /dev/null; then
    # macOS: Use fswatch
    fswatch -o "$WATCH_DIR" -e ".*" -i "\\.env$" --exclude ".*\\.example$" | while read -r; do
        find "$WATCH_DIR" -name ".env" -type f -not -name "*.example" | while read -r env_file; do
            "$SYNC_SCRIPT" "$env_file"
        done
    done
elif command -v inotifywait &> /dev/null; then
    # Linux: Use inotifywait
    inotifywait -m -r -e modify,create,close_write --format '%w%f' "$WATCH_DIR" | while read -r file; do
        if [[ "$file" =~ \.env$ ]] && [[ ! "$file" =~ \.example$ ]]; then
            "$SYNC_SCRIPT" "$file"
        fi
    done
else
    echo "Error: fswatch (macOS) or inotifywait (Linux) not found"
    echo "Install fswatch: brew install fswatch"
    echo "Or install inotify-tools: sudo apt-get install inotify-tools"
    exit 1
fi

