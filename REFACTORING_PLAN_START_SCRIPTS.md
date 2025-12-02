# Refactoring Plan: Split start-all-services.sh into 4 Manageable Scripts

## Overview

Refactor `scripts/start-all-services.sh` into 4 separate, focused scripts plus a master orchestrator script. Each script will be responsible for a specific phase of the startup sequence and will have strict error handling with zero tolerance for warnings or failures.

**Goal**: Simplify debugging process and make it easier to add new services and applications by splitting the monolithic script into manageable, independent parts.

## Script Structure

### 1. `scripts/start-nginx.sh` - Nginx Phase

**Purpose**: Start nginx-network and nginx-microservice  
**Dependencies**: None  
**Startup Order**: 1 (always runs first - mandatory)  
**What it does**:

- Creates/verifies nginx-network exists
- Starts nginx-microservice container
- Validates nginx is running (not restarting)
- Tests nginx configuration
- Performs health checks

**Key Principle**: Nginx is the primary service and must always work. It's not a problem to restart or reload it when new services are added - this serves as an additional test point.

### 2. `scripts/start-infrastructure.sh` - Infrastructure Phase  

**Purpose**: Start database-server (postgres + redis)  
**Dependencies**: nginx-network (from phase 1)  
**Startup Order**: 2  
**What it does**:

- Starts database-server containers
- Waits for PostgreSQL health check (pg_isready)
- Waits for Redis health check (redis-cli ping)
- Validates both are healthy

### 3. `scripts/start-microservices.sh` - Microservices Phase

**Purpose**: Start all microservices in dependency order  
**Dependencies**: nginx-network, database-server  
**Startup Order**: 3  
**What it does**:

- Starts: logging-microservice, auth-microservice, payment-microservice, notifications-microservice
- Uses deploy-smart.sh for each service
- Validates each service is running and healthy
- Performs health checks for each service

### 4. `scripts/start-applications.sh` - Applications Phase

**Purpose**: Start all applications  
**Dependencies**: nginx-network, database-server, microservices  
**Startup Order**: 4  
**What it does**:

- Starts: allegro, crypto-ai-agent, statex, e-commerce
- Uses deploy-smart.sh for each service
- Validates each service is running and healthy
- Performs health checks for each service

### 5. `scripts/start-all-services.sh` - Master Orchestrator (Refactored)

**Purpose**: Calls all 4 scripts in sequence  
**What it does**:

- Always calls start-nginx.sh first (nginx is primary and mandatory - no skip flag)
- Calls start-infrastructure.sh (if not skipped)
- Calls start-microservices.sh (if not skipped)
- Calls start-applications.sh (if not skipped)
- Provides summary at end
- Maintains backward compatibility with existing flags (--skip-infrastructure, --skip-microservices, --skip-applications)
- No --skip-nginx flag (nginx must always start - it's the primary service)
- Nginx will be restarted/reloaded when new services are added (this is expected and serves as a test point)
- Exit on first failure

## Key Requirements

### Zero Tolerance Policy

- **Stop on any warning**: Scripts must exit immediately if any warning is detected
- **Stop on restarting containers**: If any container is in "Restarting" state, run diagnostic and exit
- **Stop on failed health checks**: If any health check fails, run diagnostic and exit
- **Stop on not running containers**: If expected container is not running after startup, exit

### Error Handling Pattern

When any issue is detected:

1. Print error message with context
2. Run appropriate diagnostic script (e.g., `diagnose.sh <container-name> --check <type>`)
3. Exit with non-zero code
4. Provide clear instructions for user

### Health Check Requirements

- **Nginx**: Container must be running (not restarting), config test must pass
- **PostgreSQL**: `pg_isready -U dbadmin` must succeed
- **Redis**: `redis-cli ping` must return PONG
- **Services**: Must pass health checks via health-check.sh script

### Container State Checks

- Check for "Restarting" status - if found, run diagnostic and exit
- Check for "Exited" status - if found, show logs and exit
- Check for "Up" status - required before proceeding
- No tolerance for unstable containers

## Implementation Details

### Shared Functions

Create `scripts/startup-utils.sh` with common functions:

- `check_container_running()` - Verify container is running (not restarting)
- `check_container_healthy()` - Verify container health status
- `run_diagnostic_and_exit()` - Run appropriate diagnostic script and exit
- `wait_for_health_check()` - Wait for health check with timeout
- `validate_service_started()` - Validate service containers are running
- `print_status()`, `print_success()`, `print_warning()`, `print_error()`, `print_detail()` - Colored output functions
- `get_timestamp()` - Get formatted timestamp

### Script 1: start-nginx.sh

**Location**: `scripts/start-nginx.sh`  
**Key Functions**:

- `start_nginx_network()` - Create/verify network
- `start_nginx_microservice()` - Start nginx container
- `validate_nginx_running()` - Check container is running (not restarting)
- `test_nginx_config()` - Test nginx configuration
- `check_nginx_health()` - Verify nginx is responding

**Error Handling**:

- If nginx-network creation fails → exit
- If nginx container is restarting → run `diagnose.sh nginx-microservice --check restart`, exit
- If nginx config test fails → show error, exit
- If nginx not running after max attempts → run diagnostic, exit

**Source Code Location**: Extract from `scripts/start-all-services.sh` lines 123-278

### Script 2: start-infrastructure.sh

**Location**: `scripts/start-infrastructure.sh`  
**Key Functions**:

- `start_database_server()` - Start postgres + redis containers
- `wait_for_postgres()` - Wait for PostgreSQL health check
- `wait_for_redis()` - Wait for Redis health check
- `validate_database_health()` - Verify both databases are healthy

**Error Handling**:

- If database-server directory not found → exit
- If postgres container is restarting → show logs, exit
- If redis container is restarting → show logs, exit
- If postgres health check fails → show logs, exit
- If redis health check fails → show logs, exit

**Source Code Location**: Extract from `scripts/start-all-services.sh` lines 280-451

### Script 3: start-microservices.sh

**Location**: `scripts/start-microservices.sh`  
**Key Functions**:

- `start_microservice()` - Start individual microservice using deploy-smart.sh
- `validate_microservice_health()` - Check service health via health-check.sh
- `check_all_microservices_running()` - Verify all containers are running

**Services List**:

- logging-microservice
- auth-microservice
- payment-microservice
- notifications-microservice

**Error Handling**:

- If deploy-smart.sh fails → show error, exit
- If any container is restarting → show logs, exit
- If health check fails → show logs, exit
- If service not running after deployment → show logs, exit

**Source Code Location**: Extract from `scripts/start-all-services.sh` lines 453-570, 606-646

### Script 4: start-applications.sh

**Location**: `scripts/start-applications.sh`  
**Key Functions**:

- `start_application()` - Start individual application using deploy-smart.sh
- `validate_application_health()` - Check application health via health-check.sh
- `check_all_applications_running()` - Verify all containers are running

**Applications List**:

- allegro
- crypto-ai-agent
- statex
- e-commerce

**Error Handling**:

- Same pattern as microservices script

**Source Code Location**: Extract from `scripts/start-all-services.sh` lines 453-570, 648-688

### Script 5: start-all-services.sh (Refactored)

**Location**: `scripts/start-all-services.sh`  
**Changes**:

- Remove all phase-specific code (keep only orchestration logic)
- Always call start-nginx.sh first (nginx is primary and mandatory - no skip flag)
- Call start-infrastructure.sh (if not skipped)
- Call start-microservices.sh (if not skipped)
- Call start-applications.sh (if not skipped)
- Maintain existing command-line flags (--skip-infrastructure, --skip-microservices, --skip-applications)
- Maintain --service flag for single service startup
- Provide summary at end
- Exit on first failure

**New Structure**:

```bash
# Parse arguments (keep existing logic)
# Always start nginx
./scripts/start-nginx.sh || exit 1

# Start infrastructure (if not skipped)
if [ "$SKIP_INFRASTRUCTURE" = false ]; then
    ./scripts/start-infrastructure.sh || exit 1
fi

# Start microservices (if not skipped)
if [ "$SKIP_MICROSERVICES" = false ]; then
    ./scripts/start-microservices.sh || exit 1
fi

# Start applications (if not skipped)
if [ "$SKIP_APPLICATIONS" = false ]; then
    ./scripts/start-applications.sh || exit 1
fi

# Show final summary
```

## File Changes

### New Files

1. `scripts/start-nginx.sh` - New script for nginx phase
2. `scripts/start-infrastructure.sh` - New script for infrastructure phase
3. `scripts/start-microservices.sh` - New script for microservices phase
4. `scripts/start-applications.sh` - New script for applications phase
5. `scripts/startup-utils.sh` - Shared utility functions

### Modified Files

1. `scripts/start-all-services.sh` - Refactored to call 4 scripts sequentially

## Nginx Independence Principles

All scripts must respect nginx independence:

- Nginx can start even if containers are not running
- Configs are validated before being applied
- Invalid configs are rejected (handled by existing validation system)
- Nginx returns 502 errors until containers are available (acceptable)
- Nginx restart/reload when adding services is expected behavior and serves as a test point

## Testing Strategy

1. Test each script independently
2. Test master script calling all 4 scripts
3. Test error scenarios (restarting containers, failed health checks)
4. Test skip flags (--skip-infrastructure, --skip-microservices, --skip-applications)
5. Test diagnostic script execution
6. Verify backward compatibility
7. Test --service flag behavior

## Backward Compatibility

- Existing flags (--skip-infrastructure, --skip-microservices, --skip-applications) must work
- No --skip-nginx flag (nginx is primary service and must always start)
- --service flag behavior maintained (only start specific service)
- Output format should be similar for consistency
- Nginx restart/reload when adding services is expected behavior and serves as a test point

## Implementation Checklist

- [ ] Create `scripts/startup-utils.sh` with shared functions
- [ ] Create `scripts/start-nginx.sh` - Extract nginx logic from start-all-services.sh
- [ ] Create `scripts/start-infrastructure.sh` - Extract database-server logic
- [ ] Create `scripts/start-microservices.sh` - Extract microservices logic
- [ ] Create `scripts/start-applications.sh` - Extract applications logic
- [ ] Refactor `scripts/start-all-services.sh` to call 4 scripts sequentially
- [ ] Test each script independently
- [ ] Test master script with all combinations of skip flags
- [ ] Test error scenarios and diagnostic script execution
- [ ] Update documentation (README.md)
- [ ] Verify backward compatibility

## Notes

- Nginx is the primary service and must always start - no skip flag
- Each script should be independently executable for easier debugging
- Zero tolerance for warnings, restarting containers, or failed health checks
- Diagnostic scripts should be called automatically when issues are detected
- All scripts should use consistent error handling and output formatting
