#!/bin/bash
# Wrapper script - delegates to blue-green/ensure-infrastructure.sh
# This ensures the script works from both locations

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BLUE_GREEN_SCRIPT="${SCRIPT_DIR}/../blue-green/ensure-infrastructure.sh"

if [ -f "$BLUE_GREEN_SCRIPT" ]; then
    exec "$BLUE_GREEN_SCRIPT" "$@"
else
    echo "Error: ensure-infrastructure.sh not found at: $BLUE_GREEN_SCRIPT" >&2
    exit 1
fi

