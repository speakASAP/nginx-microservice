#!/bin/bash
# Main Deployment Script - Full blue/green deployment
# DEPRECATED: Use deploy-smart.sh instead for better performance (only rebuilds changed services)
# This script is kept for backward compatibility but will always rebuild all services
# Usage: deploy.sh <service_name>

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

SERVICE_NAME="$1"

if [ -z "$SERVICE_NAME" ]; then
    print_error "Usage: deploy.sh <service_name>"
    exit 1
fi

log_message "INFO" "$SERVICE_NAME" "deploy" "deploy" "Starting blue/green deployment"

# Validate service exists in registry
REGISTRY_FILE="${REGISTRY_DIR}/${SERVICE_NAME}.json"
if [ ! -f "$REGISTRY_FILE" ]; then
    print_error "Service not found in registry: $SERVICE_NAME"
    print_error "Registry file not found: $REGISTRY_FILE"
    exit 1
fi

log_message "INFO" "$SERVICE_NAME" "deploy" "deploy" "Service validated in registry"

# Phase 0: Ensure shared infrastructure is running
log_message "INFO" "$SERVICE_NAME" "deploy" "deploy" "Phase 0: Ensuring shared infrastructure is running"

if ! "${SCRIPT_DIR}/ensure-infrastructure.sh" "$SERVICE_NAME"; then
    log_message "ERROR" "$SERVICE_NAME" "deploy" "deploy" "Phase 0 failed: Infrastructure check failed"
    exit 1
fi

log_message "SUCCESS" "$SERVICE_NAME" "deploy" "deploy" "Phase 0 completed: Infrastructure is ready"

# Phase 1: Prepare green
log_message "INFO" "$SERVICE_NAME" "deploy" "deploy" "Phase 1: Preparing green deployment"

if ! "${SCRIPT_DIR}/prepare-green.sh" "$SERVICE_NAME"; then
    log_message "ERROR" "$SERVICE_NAME" "deploy" "deploy" "Phase 1 failed: prepare-green.sh exited with error"
    exit 1
fi

log_message "SUCCESS" "$SERVICE_NAME" "deploy" "deploy" "Phase 1 completed: Green deployment prepared"

# Phase 2: Switch traffic
log_message "INFO" "$SERVICE_NAME" "deploy" "deploy" "Phase 2: Switching traffic to green"

if ! "${SCRIPT_DIR}/switch-traffic.sh" "$SERVICE_NAME"; then
    log_message "ERROR" "$SERVICE_NAME" "deploy" "deploy" "Phase 2 failed: switch-traffic.sh exited with error"
    log_message "INFO" "$SERVICE_NAME" "deploy" "deploy" "Initiating rollback"
    "${SCRIPT_DIR}/rollback.sh" "$SERVICE_NAME" || true
    exit 1
fi

log_message "SUCCESS" "$SERVICE_NAME" "deploy" "deploy" "Phase 2 completed: Traffic switched to green"

# Phase 3: Monitor health for 2 minutes
log_message "INFO" "$SERVICE_NAME" "deploy" "deploy" "Phase 3: Monitoring health for 5 minutes"

MONITOR_DURATION=120  # 2 minutes in seconds
CHECK_INTERVAL=30     # Check every 30 seconds
ELAPSED=0
HEALTHY_CHECKS=0
REQUIRED_HEALTHY_CHECKS=4  # 2 minutes / 30 seconds = 4 checks

while [ $ELAPSED -lt $MONITOR_DURATION ]; do
    if "${SCRIPT_DIR}/health-check.sh" "$SERVICE_NAME"; then
        HEALTHY_CHECKS=$((HEALTHY_CHECKS + 1))
        log_message "INFO" "$SERVICE_NAME" "deploy" "monitor" "Health check passed ($HEALTHY_CHECKS/$REQUIRED_HEALTHY_CHECKS)"
    else
        log_message "ERROR" "$SERVICE_NAME" "deploy" "monitor" "Health check failed, rollback already triggered"
        exit 1
    fi
    
    if [ $ELAPSED -lt $MONITOR_DURATION ]; then
        sleep $CHECK_INTERVAL
        ELAPSED=$((ELAPSED + CHECK_INTERVAL))
    fi
done

log_message "SUCCESS" "$SERVICE_NAME" "deploy" "deploy" "Phase 3 completed: Green deployment healthy for 5 minutes"

# Phase 4: Cleanup old color
log_message "INFO" "$SERVICE_NAME" "deploy" "deploy" "Phase 4: Cleaning up old blue deployment"

if ! "${SCRIPT_DIR}/cleanup.sh" "$SERVICE_NAME"; then
    log_message "WARNING" "$SERVICE_NAME" "deploy" "deploy" "Phase 4 warning: cleanup.sh had issues, but deployment is successful"
fi

log_message "SUCCESS" "$SERVICE_NAME" "deploy" "deploy" "Phase 4 completed: Old deployment cleaned up"

# Final success
log_message "SUCCESS" "$SERVICE_NAME" "deploy" "deploy" "=========================================="
log_message "SUCCESS" "$SERVICE_NAME" "deploy" "deploy" "Blue/Green deployment completed successfully!"
log_message "SUCCESS" "$SERVICE_NAME" "deploy" "deploy" "Active color: green"
log_message "SUCCESS" "$SERVICE_NAME" "deploy" "deploy" "=========================================="

exit 0

