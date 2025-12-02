#!/bin/bash
# Generic Diagnostic Tool
# Usage: diagnose.sh <container-name> [--check <check-type>]
#        diagnose.sh nginx-microservice
#        diagnose.sh nginx-microservice --check restart
#        diagnose.sh allegro-api-gateway-blue --check 502

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMMON_DIR="${SCRIPT_DIR}/common"

# Source common utilities
if [ -f "${COMMON_DIR}/output.sh" ]; then
    source "${COMMON_DIR}/output.sh"
else
    echo "Error: output.sh not found at ${COMMON_DIR}/output.sh"
    exit 1
fi

if [ -f "${COMMON_DIR}/diagnostics.sh" ]; then
    source "${COMMON_DIR}/diagnostics.sh"
else
    echo "Error: diagnostics.sh not found at ${COMMON_DIR}/diagnostics.sh"
    exit 1
fi

# Parse arguments
CONTAINER_NAME=""
CHECK_TYPE="all"

while [[ $# -gt 0 ]]; do
    case $1 in
        --check)
            CHECK_TYPE="$2"
            shift 2
            ;;
        *)
            if [ -z "$CONTAINER_NAME" ]; then
                CONTAINER_NAME="$1"
            else
                print_error "Unknown argument: $1"
                echo "Usage: diagnose.sh <container-name> [--check <check-type>]"
                echo "Check types: all, restart, 502, health, logs, network, config"
                exit 1
            fi
            shift
            ;;
    esac
done

if [ -z "$CONTAINER_NAME" ]; then
    print_error "Container name is required"
    echo "Usage: diagnose.sh <container-name> [--check <check-type>]"
    echo "Check types: all, restart, 502, health, logs, network, config"
    echo ""
    echo "Examples:"
    echo "  diagnose.sh nginx-microservice"
    echo "  diagnose.sh nginx-microservice --check restart"
    echo "  diagnose.sh allegro-api-gateway-blue --check 502"
    exit 1
fi

print_header "Diagnosing Container: $CONTAINER_NAME"
echo ""

# Run diagnostic checks based on type
case "$CHECK_TYPE" in
    restart)
        check_container_restart "$CONTAINER_NAME"
        ;;
    502)
        check_502_errors "$CONTAINER_NAME"
        ;;
    health)
        check_container_health "$CONTAINER_NAME"
        ;;
    logs)
        show_container_logs "$CONTAINER_NAME"
        ;;
    network)
        check_network_connectivity "$CONTAINER_NAME"
        ;;
    config)
        check_nginx_config "$CONTAINER_NAME"
        ;;
    all)
        # Run all checks
        check_container_restart "$CONTAINER_NAME"
        echo ""
        check_502_errors "$CONTAINER_NAME"
        echo ""
        check_container_health "$CONTAINER_NAME"
        echo ""
        check_network_connectivity "$CONTAINER_NAME"
        echo ""
        check_nginx_config "$CONTAINER_NAME" 2>/dev/null || true
        echo ""
        show_container_logs "$CONTAINER_NAME" 30
        ;;
    *)
        print_error "Unknown check type: $CHECK_TYPE"
        echo "Available check types: all, restart, 502, health, logs, network, config"
        exit 1
        ;;
esac

echo ""
print_header "Diagnosis Complete"

