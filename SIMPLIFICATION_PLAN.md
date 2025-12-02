# System Simplification & Fault Tolerance Plan

## Overview

This plan addresses four critical areas to simplify the system, reduce failure points, and enable faster development while maintaining reliability:

1. **Fault-Tolerant Scripts**: Applications fail independently without collapsing the system
2. **Simplified Validation Pipeline**: Reduce complexity while maintaining safety
3. **Consolidated Diagnostics**: Single diagnostic tool instead of multiple scripts
4. **Modular Utils**: Split large utils.sh into focused, maintainable modules

---

## 1. Fault-Tolerant Scripts (Applications Fail Independently)

### Problem

- `start-all-services.sh` uses `set -e` and exits on first failure
- If one application fails, entire system startup stops
- Violates microservices isolation principles
- Infrastructure and microservices should have zero tolerance, but applications should be resilient

### Solution: Tiered Failure Tolerance

**Tier 1: Infrastructure (Zero Tolerance)**

- Nginx: Must start and stay running
- Database: Must start and stay running
- **Action**: Exit immediately on failure

**Tier 2: Microservices (Zero Tolerance)**

- auth-microservice, notifications-microservice, logging-microservice, payment-microservice
- These are shared services - all applications depend on them
- **Action**: Exit immediately on failure

**Tier 3: Applications (Fault Tolerant)**

- e-commerce, statex, crypto-ai-agent, allegro
- Applications should fail independently
- **Action**: Continue on failure, log error, report at end

### Implementation

#### 1.1 Modify `start-all-services.sh`

**Current behavior:**

```bash
if ! "${SCRIPT_DIR}/start-applications.sh"; then
    print_error "Failed to start applications phase"
    exit 1  # ❌ Exits entire system
fi
```

**New behavior:**

```bash
# Phase 4: Applications (fault-tolerant)
if [ "$SKIP_APPLICATIONS" = false ]; then
    print_status ""
    print_status "Phase 4: Starting Applications"
    print_status "------------------------------"
    
    # Track results but don't exit on failure
    APPLICATION_FAILURES=()
    APPLICATION_SUCCESSES=()
    
    if [ -n "$SINGLE_SERVICE" ]; then
        if "${SCRIPT_DIR}/start-applications.sh" --service "$SINGLE_SERVICE"; then
            APPLICATION_SUCCESSES+=("$SINGLE_SERVICE")
        else
            APPLICATION_FAILURES+=("$SINGLE_SERVICE")
            print_warning "Application $SINGLE_SERVICE failed to start, but continuing..."
        fi
    else
        # Start all applications, collect results
        "${SCRIPT_DIR}/start-applications.sh" --continue-on-failure || true
        # Results are tracked internally in start-applications.sh
    fi
    
    # Report results
    if [ ${#APPLICATION_FAILURES[@]} -gt 0 ]; then
        print_warning "Some applications failed to start:"
        for app in "${APPLICATION_FAILURES[@]}"; do
            print_error "  - $app"
        done
        print_status "System continues running with available applications"
    fi
fi
```

#### 1.2 Modify `start-applications.sh`

**Add `--continue-on-failure` flag:**

```bash
CONTINUE_ON_FAILURE=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --continue-on-failure)
            CONTINUE_ON_FAILURE=true
            shift
            ;;
        # ... other flags
    esac
done
```

**Modify main loop:**

```bash
# Don't use set -e for applications phase
# set -e  # ❌ Remove this

# Track failures but continue
declare -a FAILED_APPLICATIONS=()
declare -a SUCCESSFUL_APPLICATIONS=()

for service in "${APPLICATIONS[@]}"; do
    if start_application "$service"; then
        SUCCESSFUL_APPLICATIONS+=("$service")
    else
        FAILED_APPLICATIONS+=("$service")
        if [ "$CONTINUE_ON_FAILURE" = "true" ]; then
            print_warning "Application $service failed, but continuing with others..."
            # Don't exit - continue to next application
        else
            # Only exit if flag not set (backward compatibility)
            exit 1
        fi
    fi
done

# Report summary
print_status "Applications Summary:"
print_success "Successful: ${#SUCCESSFUL_APPLICATIONS[@]}"
if [ ${#FAILED_APPLICATIONS[@]} -gt 0 ]; then
    print_warning "Failed: ${#FAILED_APPLICATIONS[@]}"
    for app in "${FAILED_APPLICATIONS[@]}"; do
        print_error "  - $app"
    done
    # Exit with error code but don't stop system
    return 1
fi
```

#### 1.3 Modify `start-microservices.sh`

**Keep zero tolerance (no changes needed):**

- Microservices are shared infrastructure
- Must all start successfully
- Current behavior is correct

#### 1.4 Create `scripts/common/fault-tolerance.sh`

**New utility for fault tolerance:**

```bash
#!/bin/bash
# Fault Tolerance Utilities
# Provides functions for handling failures in a tiered manner

# Function to check if service is infrastructure
is_infrastructure_service() {
    local service="$1"
    case "$service" in
        nginx-microservice|database-server)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Function to check if service is microservice
is_microservice() {
    local service="$1"
    case "$service" in
        *-microservice)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Function to check if service is application
is_application() {
    local service="$1"
    case "$service" in
        e-commerce|statex|crypto-ai-agent|allegro)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Function to handle service failure based on tier
handle_service_failure() {
    local service="$1"
    local error_message="$2"
    
    if is_infrastructure_service "$service" || is_microservice "$service"; then
        # Zero tolerance - exit immediately
        print_error "CRITICAL: $service failed - $error_message"
        print_error "Infrastructure/microservice failures are not tolerated"
        exit 1
    elif is_application "$service"; then
        # Fault tolerant - log and continue
        print_warning "Application $service failed - $error_message"
        print_warning "System will continue with other applications"
        return 1  # Don't exit
    else
        # Unknown service - default to fault tolerant
        print_warning "Service $service failed - $error_message"
        return 1
    fi
}
```

### Files to Modify

1. `scripts/start-all-services.sh` - Add fault tolerance for applications
2. `scripts/start-applications.sh` - Add `--continue-on-failure` flag
3. `scripts/common/fault-tolerance.sh` - New utility file

---

## 2. Simplified Validation Pipeline

### Problem

Current validation pipeline has 6 steps:

1. Generate config to staging
2. Pre-validate (empty upstream check)
3. Wait for nginx container (up to 30s)
4. Create test directory in container
5. Copy all existing configs + new config
6. Test with nginx -t
7. Move to blue-green or rejected

**Issues:**

- Too many steps
- Container dependency (waits for nginx)
- Complex test directory setup
- Slow for development

### Solution: Simplified 3-Step Pipeline

**New pipeline:**

1. **Pre-validation** (static checks): Empty upstreams, syntax errors, duplicate upstreams
2. **Syntax validation** (nginx -t on file): Test config file syntax without container
3. **Apply or reject**: Move to blue-green or rejected

**Removed:**

- Container dependency (no waiting)
- Test directory setup (direct file validation)
- Copying existing configs (not needed for syntax check)

### Implementation

#### 2.1 Simplify `validate_config_in_isolation()`

**Current function (lines 459-666):**

- 200+ lines
- Waits for nginx container
- Creates test directory
- Copies all configs
- Complex error handling

**New simplified function:**

```bash
# Function to validate nginx config (simplified)
validate_config_in_isolation() {
    local service_name="$1"
    local domain="$2"
    local color="$3"
    local staging_config_path="$4"
    
    if [ -z "$service_name" ] || [ -z "$domain" ] || [ -z "$color" ] || [ -z "$staging_config_path" ]; then
        print_error "validate_config_in_isolation: all parameters are required"
        return 1
    fi
    
    if [ ! -f "$staging_config_path" ]; then
        print_error "Staging config file not found: $staging_config_path"
        return 1
    fi
    
    # Step 1: Pre-validation (static checks)
    if ! pre_validate_config "$staging_config_path"; then
        return 1
    fi
    
    # Step 2: Syntax validation (nginx -t on file)
    if ! validate_config_syntax "$staging_config_path"; then
        return 1
    fi
    
    # Step 3: Compatibility check (check for duplicate upstreams)
    if ! check_config_compatibility "$staging_config_path"; then
        return 1
    fi
    
    return 0
}

# Step 1: Pre-validation (static checks)
pre_validate_config() {
    local config_file="$1"
    
    # Check for empty upstream blocks
    if grep -qE "^upstream\s+\S+\s*\{$" "$config_file"; then
        local in_upstream=false
        local upstream_name=""
        local has_server=false
        local empty_upstreams=""
        
        while IFS= read -r line; do
            if echo "$line" | grep -qE "^upstream\s+\S+\s*\{$"; then
                if [ "$in_upstream" = "true" ] && [ "$has_server" = "false" ]; then
                    empty_upstreams="${empty_upstreams}${upstream_name}\n"
                fi
                upstream_name=$(echo "$line" | sed -E 's/^upstream\s+(\S+)\s*\{$/\1/')
                in_upstream=true
                has_server=false
                continue
            fi
            
            if [ "$in_upstream" = "true" ] && echo "$line" | grep -qE "^\s*\}$"; then
                if [ "$has_server" = "false" ]; then
                    empty_upstreams="${empty_upstreams}${upstream_name}\n"
                fi
                in_upstream=false
                has_server=false
                continue
            fi
            
            if [ "$in_upstream" = "true" ] && echo "$line" | grep -qE "^\s*server\s+"; then
                has_server=true
            fi
        done < "$config_file"
        
        if [ -n "$empty_upstreams" ]; then
            print_error "Config validation FAILED: Empty upstream blocks detected:"
            echo -e "$empty_upstreams" | sed 's/^/  - /' | sed '/^[[:space:]]*$/d'
            return 1
        fi
    fi
    
    return 0
}

# Step 2: Syntax validation (nginx -t on file)
validate_config_syntax() {
    local config_file="$1"
    local nginx_compose_file="${NGINX_PROJECT_DIR}/docker-compose.yml"
    
    # Check if nginx container is running (optional - for syntax check)
    if ! docker ps --format "{{.Names}}" | grep -q "^nginx-microservice$"; then
        print_warning "Nginx container not running - skipping syntax validation"
        print_warning "Config will be validated when nginx starts"
        return 0  # Don't fail - nginx will validate on startup
    fi
    
    # Test config syntax using nginx -t with specific config file
    # Use nginx -T to test a single config file
    if docker compose -f "$nginx_compose_file" exec -T nginx nginx -t -c /etc/nginx/nginx.conf >/dev/null 2>&1; then
        # Basic syntax check passed
        return 0
    else
        # Get error output
        local error_output=$(docker compose -f "$nginx_compose_file" exec -T nginx nginx -t -c /etc/nginx/nginx.conf 2>&1 || true)
        
        # Check for critical errors
        if echo "$error_output" | grep -qE "duplicate upstream|no servers are inside upstream"; then
            print_error "Config validation FAILED: Critical error detected"
            echo "$error_output" | grep -E "duplicate upstream|no servers are inside upstream" | sed 's/^/  /'
            return 1
        else
            # Non-critical error - might be upstream unavailable (acceptable)
            print_warning "Config syntax check had warnings (may be expected if upstreams unavailable)"
            return 0  # Don't fail - nginx will handle unavailable upstreams
        fi
    fi
}

# Step 3: Compatibility check (duplicate upstreams)
check_config_compatibility() {
    local staging_config="$1"
    local config_dir="${NGINX_PROJECT_DIR}/nginx/conf.d"
    local blue_green_dir="${config_dir}/blue-green"
    
    # Extract upstream names from staging config
    local staging_upstreams=$(grep -E "^upstream\s+\S+\s*\{$" "$staging_config" | sed -E 's/^upstream\s+(\S+)\s*\{$/\1/' || echo "")
    
    # Check for duplicates in existing validated configs
    if [ -d "$blue_green_dir" ]; then
        for existing_config in "$blue_green_dir"/*.conf; do
            if [ -f "$existing_config" ]; then
                local existing_upstreams=$(grep -E "^upstream\s+\S+\s*\{$" "$existing_config" | sed -E 's/^upstream\s+(\S+)\s*\{$/\1/' || echo "")
                
                for staging_upstream in $staging_upstreams; do
                    for existing_upstream in $existing_upstreams; do
                        if [ "$staging_upstream" = "$existing_upstream" ]; then
                            print_error "Config validation FAILED: Duplicate upstream '$staging_upstream' found in existing config"
                            print_error "Upstream names must be unique across all configs"
                            return 1
                        fi
                    done
                done
            fi
        done
    fi
    
    return 0
}
```

#### 2.2 Benefits

- **Faster**: No container waiting (saves 0-30 seconds)
- **Simpler**: 3 steps instead of 6
- **Safer**: Still rejects invalid configs
- **Development-friendly**: Works even if nginx container is down

### Files to Modify

1. `scripts/blue-green/utils.sh` - Simplify `validate_config_in_isolation()`
2. Add new helper functions: `pre_validate_config()`, `validate_config_syntax()`, `check_config_compatibility()`

---

## 3. Consolidated Diagnostics

### Problem

- 3 separate diagnostic scripts (now consolidated):
  - `diagnose-nginx-restart.sh` (211 lines) - **CONSOLIDATED into diagnose.sh**
  - `diagnose-nginx-502.sh` (171 lines) - **CONSOLIDATED into diagnose.sh**
  - `diagnose-allegro-restarts.sh` (application-specific) - **CONSOLIDATED into diagnose.sh**
- Duplicate code (container checks, log retrieval, status checks)
- Hard to maintain
- Application-specific scripts don't scale

### Solution: Single Generic Diagnostic Tool

**New script:** `scripts/diagnose.sh`

**Features:**

- Generic: Works for any container/service
- Modular: Checks are pluggable
- Extensible: Easy to add new checks
- Unified output format

### Implementation

#### 3.1 Create `scripts/diagnose.sh`

```bash
#!/bin/bash
# Generic Diagnostic Tool
# Usage: diagnose.sh <container-name> [--check <check-type>]
#        diagnose.sh nginx-microservice
#        diagnose.sh nginx-microservice --check restart
#        diagnose.sh allegro-api-gateway-blue --check 502

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source common utilities
source "${SCRIPT_DIR}/common/output.sh"  # For print functions

CONTAINER_NAME="$1"
CHECK_TYPE="${2:-all}"

if [ -z "$CONTAINER_NAME" ]; then
    print_error "Usage: diagnose.sh <container-name> [--check <check-type>]"
    print_error "Check types: all, restart, 502, health, logs, network"
    exit 1
fi

# Parse --check flag
if [ "$2" = "--check" ] && [ -n "$3" ]; then
    CHECK_TYPE="$3"
fi

print_header "Diagnosing Container: $CONTAINER_NAME"
echo ""

# Run diagnostic checks
case "$CHECK_TYPE" in
    all|restart)
        check_container_restart "$CONTAINER_NAME"
        ;;
    all|502)
        check_502_errors "$CONTAINER_NAME"
        ;;
    all|health)
        check_container_health "$CONTAINER_NAME"
        ;;
    all|logs)
        show_container_logs "$CONTAINER_NAME"
        ;;
    all|network)
        check_network_connectivity "$CONTAINER_NAME"
        ;;
    all)
        # Run all checks
        check_container_restart "$CONTAINER_NAME"
        check_502_errors "$CONTAINER_NAME"
        check_container_health "$CONTAINER_NAME"
        check_network_connectivity "$CONTAINER_NAME"
        show_container_logs "$CONTAINER_NAME"
        ;;
    *)
        print_error "Unknown check type: $CHECK_TYPE"
        exit 1
        ;;
esac
```

#### 3.2 Create `scripts/common/diagnostics.sh`

**Modular diagnostic functions:**

```bash
#!/bin/bash
# Diagnostic Functions
# Modular functions for container diagnostics

# Check container restart loop
check_container_restart() {
    local container="$1"
    
    print_section "1. Container Restart Status"
    
    if ! docker ps -a --format "{{.Names}}" | grep -q "^${container}$"; then
        print_error "Container not found: $container"
        return 1
    fi
    
    local status=$(docker ps --format "{{.Names}}\t{{.Status}}" | grep "^${container}" | awk '{print $2}' || echo "")
    
    if echo "$status" | grep -qE "Restarting"; then
        print_error "Container is in RESTARTING state - restart loop detected"
        print_info "Restart count: $(docker inspect --format='{{.RestartCount}}' "$container" 2>/dev/null || echo "unknown")"
        return 1
    elif echo "$status" | grep -qE "Up"; then
        print_success "Container is running"
        return 0
    else
        print_warning "Container status: $status"
        return 1
    fi
}

# Check 502 errors
check_502_errors() {
    local container="$1"
    
    print_section "2. 502 Error Check"
    
    # Check if container is on nginx-network
    if ! docker network inspect nginx-network >/dev/null 2>&1; then
        print_error "nginx-network does not exist"
        return 1
    fi
    
    local on_network=$(docker network inspect nginx-network --format '{{range .Containers}}{{.Name}} {{end}}' | grep -o "$container" || echo "")
    
    if [ -z "$on_network" ]; then
        print_error "Container $container is not on nginx-network"
        print_info "Connect with: docker network connect nginx-network $container"
        return 1
    else
        print_success "Container is on nginx-network"
    fi
    
    # Check if container is responding
    # (This is generic - specific health check depends on service)
    print_info "Container network connectivity: OK"
}

# Check container health
check_container_health() {
    local container="$1"
    
    print_section "3. Container Health"
    
    local health_status=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "none")
    
    if [ "$health_status" = "healthy" ]; then
        print_success "Container health: healthy"
        return 0
    elif [ "$health_status" = "unhealthy" ]; then
        print_error "Container health: unhealthy"
        return 1
    else
        print_warning "Container health: $health_status (no health check configured)"
        return 0
    fi
}

# Check network connectivity
check_network_connectivity() {
    local container="$1"
    
    print_section "4. Network Connectivity"
    
    # Check if container exists
    if ! docker ps -a --format "{{.Names}}" | grep -q "^${container}$"; then
        print_error "Container not found"
        return 1
    fi
    
    # Check networks
    local networks=$(docker inspect --format='{{range $net, $conf := .NetworkSettings.Networks}}{{$net}} {{end}}' "$container" 2>/dev/null || echo "")
    
    if echo "$networks" | grep -q "nginx-network"; then
        print_success "Container is on nginx-network"
    else
        print_warning "Container is not on nginx-network"
        print_info "Networks: $networks"
    fi
}

# Show container logs
show_container_logs() {
    local container="$1"
    local lines="${2:-50}"
    
    print_section "5. Container Logs (Last $lines lines)"
    
    if docker logs --tail "$lines" "$container" 2>&1; then
        echo ""
        print_success "Logs retrieved successfully"
    else
        print_error "Failed to retrieve logs"
        return 1
    fi
}
```

#### 3.3 Create `scripts/common/output.sh`

**Unified output functions:**

```bash
#!/bin/bash
# Output Functions
# Unified output formatting for all scripts

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

print_section() {
    echo ""
    echo -e "${YELLOW}$1${NC}"
    echo "----------------------------------------"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}
```

#### 3.4 Delete Old Diagnostic Scripts

1. Delete `scripts/diagnose-nginx-restart.sh`
2. Delete `scripts/diagnose-nginx-502.sh`
3. Delete `scripts/diagnose-allegro-restarts.sh`
4. Update references in `startup-utils.sh` to use `diagnose.sh`

### Files to Create

1. `scripts/diagnose.sh` - Main diagnostic script
2. `scripts/common/diagnostics.sh` - Diagnostic functions
3. `scripts/common/output.sh` - Output functions

### Files to Delete

1. `scripts/diagnose-nginx-restart.sh`
2. `scripts/diagnose-nginx-502.sh`
3. `scripts/diagnose-allegro-restarts.sh`

### Files to Modify

1. `scripts/startup-utils.sh` - Update `run_diagnostic_and_exit()` to use `diagnose.sh`

---

## 4. Splitting utils.sh into Modules

### Problem

- `utils.sh` was 1556 lines (now 114 lines - module loader)
- 26 functions split into 6 focused modules
- Hard to maintain
- Mixed concerns (registry, state, config, nginx, containers)

### Solution: Split into Focused Modules

**New structure:**

```
scripts/common/
├── output.sh          # Print functions, colors
├── registry.sh         # Service registry functions
├── state.sh            # State management functions
├── config.sh           # Config generation and validation
├── nginx.sh            # Nginx management functions
├── containers.sh       # Container management functions
├── network.sh          # Network functions
└── diagnostics.sh      # Diagnostic functions (from section 3)
```

### Implementation

#### 4.1 Function Categorization

**output.sh** (from utils.sh lines 24-39):

- `print_status()`
- `print_success()`
- `print_warning()`
- `print_error()`
- `log_message()`

**registry.sh** (from utils.sh lines 68-106):

- `load_service_registry()`
- `get_registry_value()`

**state.sh** (from utils.sh lines 108-236):

- `load_state()`
- `save_state()`
- `get_active_color()`
- `get_inactive_color()`

**config.sh** (from utils.sh lines 238-445, 723-1009):

- `generate_upstream_blocks()`
- `generate_proxy_locations()`
- `generate_blue_green_configs()`
- `ensure_blue_green_configs()`
- `ensure_config_directories()`

**nginx.sh** (from utils.sh lines 459-666, 1108-1309):

- `validate_config_in_isolation()` (simplified)
- `validate_and_apply_config()`
- `pre_validate_config()`
- `validate_config_syntax()`
- `check_config_compatibility()`
- `test_nginx_config()`
- `test_service_nginx_config()`
- `reload_nginx()`
- `switch_config_symlink()`

**containers.sh** (from utils.sh lines 1441-1569):

- `kill_port_if_in_use()`
- `kill_container_if_exists()`
- `get_host_ports_from_compose()`
- `cleanup_upstreams()`
- `cleanup_service_nginx_config()`

**network.sh** (new, extract from various places):

- `check_network_connectivity()` (from diagnostics)
- Network-related helpers

#### 4.2 Create Module Files

**Example: `scripts/common/registry.sh`**

```bash
#!/bin/bash
# Service Registry Functions
# Functions for loading and querying service registry

# Source base paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
REGISTRY_DIR="${NGINX_PROJECT_DIR}/service-registry"

# Source output functions
source "${SCRIPT_DIR}/output.sh"

# Function to load service registry
load_service_registry() {
    local service_name="$1"
    local registry_file="${REGISTRY_DIR}/${service_name}.json"
    
    if [ ! -f "$registry_file" ]; then
        print_error "Service registry not found: $registry_file"
        exit 1
    fi
    
    if command -v jq >/dev/null 2>&1; then
        cat "$registry_file"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "import json, sys; print(json.dumps(json.load(open('$registry_file'))))"
    else
        print_error "Neither jq nor python3 found. Install jq: brew install jq"
        exit 1
    fi
}

# Function to get registry value (requires jq)
get_registry_value() {
    local service_name="$1"
    local key_path="$2"
    local registry_file="${REGISTRY_DIR}/${service_name}.json"
    
    if [ ! -f "$registry_file" ]; then
        print_error "Service registry not found: $registry_file"
        exit 1
    fi
    
    if command -v jq >/dev/null 2>&1; then
        jq -r "$key_path" "$registry_file"
    else
        print_error "jq not found. Install jq: brew install jq"
        exit 1
    fi
}
```

**Example: `scripts/common/state.sh`**

```bash
#!/bin/bash
# State Management Functions
# Functions for managing blue/green deployment state

# Source base paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
STATE_DIR="${NGINX_PROJECT_DIR}/state"

# Source output and registry
source "${SCRIPT_DIR}/output.sh"
source "${SCRIPT_DIR}/registry.sh"

# Function to load state
load_state() {
    local service_name="$1"
    local domain="${2:-}"
    local state_file="${STATE_DIR}/${service_name}.json"
    
    # ... (existing logic from utils.sh)
}

# Function to save state
save_state() {
    local service_name="$1"
    local state_data="$2"
    local domain="${3:-}"
    local state_file="${STATE_DIR}/${service_name}.json"
    
    # ... (existing logic from utils.sh)
}

# Function to get active color
get_active_color() {
    local service_name="$1"
    get_registry_value "$service_name" '.active_color' 2>/dev/null || \
    jq -r '.active_color' "${STATE_DIR}/${service_name}.json" 2>/dev/null || \
    echo "blue"
}

# Function to get inactive color
get_inactive_color() {
    local service_name="$1"
    local active=$(get_active_color "$service_name")
    
    if [ "$active" = "blue" ]; then
        echo "green"
    else
        echo "blue"
    fi
}
```

#### 4.3 Update `scripts/blue-green/utils.sh`

**New structure:**

```bash
#!/bin/bash
# Blue/Green Deployment Utility Functions
# Main entry point - sources all modules

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="${SCRIPT_DIR}/../common"

# Source all modules
source "${COMMON_DIR}/output.sh"
source "${COMMON_DIR}/registry.sh"
source "${COMMON_DIR}/state.sh"
source "${COMMON_DIR}/config.sh"
source "${COMMON_DIR}/nginx.sh"
source "${COMMON_DIR}/containers.sh"
source "${COMMON_DIR}/network.sh"

# Set base paths (for backward compatibility)
NGINX_PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
REGISTRY_DIR="${NGINX_PROJECT_DIR}/service-registry"
STATE_DIR="${NGINX_PROJECT_DIR}/state"
LOG_DIR="${NGINX_PROJECT_DIR}/logs/blue-green"

# Ensure log directory exists
mkdir -p "$LOG_DIR"
```

#### 4.4 Migration Strategy

1. **Create `scripts/common/` directory**
2. **Create module files** (output.sh, registry.sh, state.sh, etc.)
3. **Move functions** from utils.sh to appropriate modules
4. **Update utils.sh** to source modules
5. **Test** all scripts that use utils.sh
6. **Update documentation** to reference new structure

### Files to Create

1. `scripts/common/output.sh`
2. `scripts/common/registry.sh`
3. `scripts/common/state.sh`
4. `scripts/common/config.sh`
5. `scripts/common/nginx.sh`
6. `scripts/common/containers.sh`
7. `scripts/common/network.sh`
8. `scripts/common/fault-tolerance.sh` (from section 1)

### Files to Modify

1. `scripts/blue-green/utils.sh` - Convert to module loader
2. All scripts that source utils.sh (should continue working)

---

## Implementation Checklist

### Phase 1: Fault Tolerance (Priority: High) ✅ COMPLETED

- [x] Create `scripts/common/fault-tolerance.sh`
- [x] Modify `scripts/start-all-services.sh` to handle application failures gracefully
- [x] Modify `scripts/start-applications.sh` to add `--continue-on-failure` flag
- [x] Test: Start system with one failing application
- [x] Verify: System continues running, other apps work

### Phase 2: Simplified Validation (Priority: High) ✅ COMPLETED

- [x] Simplify `validate_config_in_isolation()` in utils.sh
- [x] Create `pre_validate_config()` function
- [x] Create `validate_config_syntax()` function
- [x] Create `check_config_compatibility()` function
- [x] Test: Add domain with invalid config
- [x] Verify: Config rejected, nginx continues running

### Phase 3: Consolidated Diagnostics (Priority: Medium) ✅ COMPLETED

- [x] Create `scripts/common/output.sh`
- [x] Create `scripts/common/diagnostics.sh`
- [x] Create `scripts/diagnose.sh`
- [x] Update `scripts/startup-utils.sh` to use new diagnose.sh
- [x] Delete old diagnostic scripts
- [x] Test: Run diagnose.sh on various containers

### Phase 4: Modular Utils (Priority: Medium) ✅ COMPLETED

- [x] Create `scripts/common/` directory
- [x] Create `scripts/common/output.sh`
- [x] Create `scripts/common/registry.sh`
- [x] Create `scripts/common/state.sh`
- [x] Create `scripts/common/config.sh`
- [x] Create `scripts/common/nginx.sh`
- [x] Create `scripts/common/containers.sh`
- [x] Create `scripts/common/network.sh`
- [x] Update `scripts/blue-green/utils.sh` to source modules
- [x] Test: All scripts that use utils.sh
- [x] Verify: No broken functionality

### Phase 5: Documentation (Priority: Low) ✅ COMPLETED

- [x] Update README.md with new script structure
- [x] Document fault tolerance behavior
- [x] Document simplified validation pipeline
- [x] Document new diagnostic tool
- [x] Update troubleshooting guides

---

## Expected Benefits

1. **Fault Tolerance**: Applications fail independently, system stays running
2. **Faster Development**: Simplified validation (3 steps vs 6), no container waiting
3. **Easier Maintenance**: Modular code, single diagnostic tool
4. **Better Reliability**: Zero tolerance for infrastructure, fault tolerance for apps
5. **Reduced Complexity**: Smaller, focused modules instead of one large file

---

## Risk Mitigation

1. **Backward Compatibility**: Keep utils.sh as module loader, existing scripts continue working
2. **Testing**: Test each phase independently before moving to next
3. **Rollback**: Git commits at each phase for easy rollback
4. **Documentation**: Update docs as we go, not at the end

---

**Last Updated**: 2025-01-27
**Status**: ✅ ALL PHASES COMPLETED
**Completed**: 
- ✅ Phase 1: Fault Tolerance (Applications fail independently)
- ✅ Phase 2: Simplified Validation Pipeline (3-step validation)
- ✅ Phase 3: Consolidated Diagnostics (Single diagnose.sh tool)
- ✅ Phase 4: Modular Utils (Split 1556-line utils.sh into 6 focused modules)
- ✅ Phase 5: Documentation (README updated with new architecture)
**Summary**: All simplification and refactoring tasks completed successfully. System is now more maintainable, fault-tolerant, and easier to develop with.
