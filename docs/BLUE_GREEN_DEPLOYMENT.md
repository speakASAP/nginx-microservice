# Blue/Green Deployment Guide

## Overview

This guide explains how to use the blue/green deployment system for zero-downtime deployments. The system uses Nginx upstream blocks with weighted routing to switch traffic between blue and green environments.

## Architecture

The blue/green deployment system consists of:

1. **Service Registry**: JSON metadata files defining service structure
2. **State Management**: Tracks active color (blue/green) per service
3. **Nginx Upstream Configuration**: Blue/green upstream blocks with backup servers
4. **Deployment Scripts**: Centralized scripts for orchestration
5. **Health Check Monitoring**: Continuous health checks with auto-rollback

## Prerequisites

- Docker and docker compose installed
- Nginx microservice running
- Service registered in `/nginx-microservice/service-registry/`
- Service has blue/green docker-compose files (`docker-compose.blue.yml`, `docker-compose.green.yml`)
- Service has health check endpoints configured (`/health` for backend, `/` for frontend)
- `jq` installed: `brew install jq` (macOS) or `apt-get install jq` (Linux)
- **Infrastructure**: Either:
  - Shared `database-server` running (recommended), OR
  - Service-specific `docker-compose.infrastructure.yml` file exists

## Quick Start

### Deploy a Service (Full Cycle)

```bash
cd /path/to/nginx-microservice
./scripts/blue-green/deploy-smart.sh crypto-ai-agent
```

This will:

1. Build and start green containers
2. Run health checks
3. Switch traffic to green
4. Monitor for 5 minutes
5. Clean up old blue containers if healthy

### Manual Rollback

```bash
./scripts/blue-green/rollback.sh crypto-ai-agent
```

### Check Deployment Status

```bash
cat /nginx-microservice/state/crypto-ai-agent.json | jq .
```

## Service Registry Format

Each service needs a registry file: `/nginx-microservice/service-registry/{service-name}.json`

### Example: `crypto-ai-agent.json`

```json
{
  "service_name": "crypto-ai-agent",
  "service_path": "/Users/sergiystashok/Documents/GitHub/crypto-ai-agent",
  "production_path": "/home/statex/crypto-ai-agent",
  "domain": "crypto-ai-agent.statex.cz",
  "docker_compose_file": "docker-compose.yml",
  "docker_project_base": "crypto_ai_agent",
  "services": {
    "backend": {
      "container_name_base": "crypto-ai-backend",
      "port": 8100,
      "health_endpoint": "/health",
      "health_timeout": 5,
      "health_retries": 3,
      "startup_time": 30
    },
    "frontend": {
      "container_name_base": "crypto-ai-frontend",
      "port": 3100,
      "health_endpoint": "/",
      "health_timeout": 5,
      "health_retries": 3,
      "startup_time": 40
    }
  },
  "shared_services": ["postgres", "redis"],
  "infrastructure_compose_file": "docker-compose.infrastructure.yml",
  "infrastructure_project_name": "crypto_ai_agent_infrastructure",
  "network": "nginx-network"
}
```

### Field Descriptions

- `service_name`: Unique identifier for the service
- `service_path`: Local development path (optional)
- `production_path`: Production server path
- `domain`: Domain name for nginx routing
- `docker_compose_file`: Base docker-compose filename (used as reference)
- `docker_project_base`: Base name for docker compose projects
- `services`: Map of services (backend, frontend, etc.)
  - `container_name_base`: Base container name (will get `-blue` or `-green` suffix)
  - `port`: Internal container port
  - `health_endpoint`: Health check endpoint path
  - `health_timeout`: Timeout in seconds for health checks
  - `health_retries`: Number of retry attempts
  - `startup_time`: Seconds to wait after container start before health checks
- `shared_services`: List of services that are managed as shared infrastructure (postgres, redis)
- `infrastructure_compose_file`: Docker compose file for shared infrastructure (default: `docker-compose.infrastructure.yml`)
- `infrastructure_project_name`: Docker compose project name for infrastructure containers

## State Management

State is stored in: `/nginx-microservice/state/{service-name}.json`

### Example State File

```json
{
  "service_name": "crypto-ai-agent",
  "active_color": "blue",
  "blue": {
    "status": "running",
    "deployed_at": "2025-01-XX...",
    "version": null
  },
  "green": {
    "status": "stopped",
    "deployed_at": null,
    "version": null
  },
  "last_deployment": {
    "color": "blue",
    "timestamp": "2025-01-XX...",
    "success": true
  }
}
```

### Status Values

- `running`: Active and serving traffic
- `backup`: Standby (receiving no traffic)
- `ready`: Prepared and healthy, ready to switch
- `stopped`: Not running

## Available Scripts

### `deploy-smart.sh` - Full Deployment (recommended)

**Usage**: `./scripts/blue-green/deploy-smart.sh <service_name>`

**What it does**:

1. Validates service exists in registry
2. Prepares green deployment
3. Switches traffic to green
4. Monitors health for 5 minutes
5. Cleans up old deployment if healthy

**Example**:

```bash
./scripts/blue-green/deploy-smart.sh crypto-ai-agent
```

### `prepare-green-smart.sh` - Prepare New Deployment

**Usage**: `./scripts/blue-green/prepare-green-smart.sh <service_name>`

**What it does**:

1. Builds new color containers
2. Starts containers
3. Waits for startup
4. Runs health checks
5. Marks as ready if healthy

**When to use**: Testing or manual preparation before switching

### `switch-traffic.sh` - Switch Traffic

**Usage**: `./scripts/blue-green/switch-traffic.sh <service_name>`

**What it does**:

1. Ensures blue and green configs exist (generates if missing)
2. Updates symlink to point to new color's config
3. Tests nginx configuration
4. Reloads nginx configuration
5. Updates state file

**When to use**: After prepare-green.sh if you want manual control

**Note**: Uses modern symlink-based switching (no file modifications)

### `health-check.sh` - Check Service Health

**Usage**: `./scripts/blue-green/health-check.sh <service_name>`

**What it does**:

1. Checks all service health endpoints
2. Triggers automatic rollback if all fail
3. Returns success if any service is healthy

**When to use**: Manual health verification

### `rollback.sh` - Rollback to Previous Color

**Usage**: `./scripts/blue-green/rollback.sh <service_name>`

**What it does**:

1. Switches traffic back to previous color
2. Stops failed color containers
3. Updates state file

**When to use**: Manual rollback or triggered automatically on health failure

### `cleanup.sh` - Remove Old Deployment

**Usage**: `./scripts/blue-green/cleanup.sh <service_name>`

**What it does**:

1. Stops and removes inactive color containers
2. Updates state file

**When to use**: Manual cleanup or automatically after successful deployment

### `migrate-to-symlinks.sh` - Migrate to Symlink System

**Usage**: `./scripts/blue-green/migrate-to-symlinks.sh [service_name]`

**What it does**:

1. For each service (or specified service):
   - Checks if blue/green configs exist
   - Generates configs from template if missing
   - Creates symlink pointing to active color
   - Backs up old config files
   - Tests nginx configuration
2. Reports migration status for all services

**When to use**:

- Initial migration from legacy file-modification system
- Adding new services to blue/green system
- Regenerating configs after service registry changes

**Examples**:

```bash
# Migrate all services
./scripts/blue-green/migrate-to-symlinks.sh

# Migrate single service
./scripts/blue-green/migrate-to-symlinks.sh crypto-ai-agent
```

**Note**: Safe to run multiple times - skips already-migrated services.

### `ensure-infrastructure.sh` - Ensure Shared Infrastructure Running

**Usage**: `./scripts/blue-green/ensure-infrastructure.sh <service_name>`

**What it does**:

1. Checks if shared infrastructure (postgres, redis) is running
2. Starts infrastructure if not running
3. Waits for health checks
4. Exits with error if infrastructure fails

**When to use**: Automatically called by deployment scripts, or manually to verify infrastructure

**Note**: This script ensures database and Redis are always available before blue/green deployments, preventing data corruption from multiple instances.

## Shared Infrastructure Architecture

### Why Separate Infrastructure?

Database (PostgreSQL) and Redis are managed as **shared infrastructure** (singleton services) rather than being part of blue/green deployments. This ensures:

- ✅ **Zero Data Loss**: Only one database instance prevents data corruption
- ✅ **Always Online**: Database survives blue/green container restarts
- ✅ **No Conflicts**: No volume conflicts during deployments
- ✅ **Zero Fault Tolerance**: Database automatically restarts on failure

### Infrastructure Models

The deployment system supports **two infrastructure models**:

#### Model 1: Shared Database-Server (Recommended for Production)

**Container Names:**

- PostgreSQL: `db-server-postgres`
- Redis: `db-server-redis`

**Setup:**

```bash
# Start shared database-server
cd /path/to/database-server
./scripts/start.sh

# Verify running
./scripts/status.sh
```

**Advantages:**

- Centralized database management
- Single source of truth
- Easier backup/restore
- Multiple services can share

**Automatic Detection:**
The `ensure-infrastructure.sh` script automatically detects `db-server-postgres` and uses it if available.

#### Model 2: Service-Specific Infrastructure

**Container Names:**

- PostgreSQL: `{service}-postgres` (e.g., `crypto-ai-postgres`)
- Redis: `{service}-redis` (e.g., `crypto-ai-redis`)

**Setup:**

```bash
cd /path/to/service
docker compose -f docker-compose.infrastructure.yml -p {service}_infrastructure up -d
```

**Advantages:**

- Isolated infrastructure per service
- Good for development/testing
- Service-specific configurations

**Requirement:**
Must have `docker-compose.infrastructure.yml` in service directory.

### Infrastructure Management

**Automatic Detection Flow:**

1. **First Check**: Script looks for `docker-compose.infrastructure.yml` in service directory
2. **If Found**: Starts/stops service-specific infrastructure
3. **If Not Found**: Checks for shared `db-server-postgres` container
4. **If Found**: Uses shared infrastructure (exits successfully)
5. **If Neither**: Reports error with helpful message

**Manual Start (Shared Database-Server):**

```bash
cd /path/to/database-server
./scripts/start.sh
```

**Manual Start (Service-Specific):**

```bash
cd /path/to/service
docker compose -f docker-compose.infrastructure.yml -p crypto_ai_agent_infrastructure up -d
```

**Automatic Management:**

- Infrastructure is automatically checked before each deployment
- Shared infrastructure is detected and used if available
- Service-specific infrastructure is started if not running
- Uses `restart: always` policy for automatic recovery

**Important**: Infrastructure containers are **never stopped** during blue/green deployments. Only application containers (backend, frontend) are managed by blue/green.

## Deployment Workflow

### Standard Deployment Flow

```text
1. deploy-smart.sh called
   ↓
0. ensure-infrastructure.sh (NEW)
   - Check shared infrastructure (postgres, redis)
   - Start if not running
   - Wait for health checks
   ↓
2. prepare-green-smart.sh
   - Ensure infrastructure is running
   - Build green containers (backend, frontend only)
   - Start green containers
   - Health checks
   ↓
3. switch-traffic.sh
   - Ensure blue/green configs exist (generated to staging/, validated, then applied to blue-green/)
   - Update symlink to point to new color
   - Reload nginx
   ↓
4. Monitor (5 minutes)
   - health-check.sh every 30s
   - Auto-rollback on failure
   ↓
5. cleanup.sh (if healthy)
   - Remove old blue containers
   - Infrastructure stays running (never stopped)
```

### Rollback Flow

```text
1. Health check failure detected
   ↓
2. rollback.sh called automatically
   - Switch nginx back to blue
   - Stop green containers
   - Update state
```

## Nginx Configuration

The nginx configuration uses a **symlink-based architecture** for zero-downtime switching and a **validated config pipeline** to ensure nginx always runs safely:

### File Structure

Each service has nginx config files in the following locations:

- `conf.d/staging/{domain}.{color}.conf` - New configs before validation
- `conf.d/blue-green/{domain}.blue.conf` - Blue environment configuration (validated)
- `conf.d/blue-green/{domain}.green.conf` - Green environment configuration (validated)
- `conf.d/{domain}.conf` - **Symlink** pointing to the active environment (`blue-green/{domain}.blue.conf` or `blue-green/{domain}.green.conf`)

**Note**:

- Blue and green configs are stored in the `blue-green/` subdirectory to prevent nginx from reading both files simultaneously (which would cause duplicate upstream definitions). Only the symlinks in `conf.d/` are included by nginx.
- New configs are always generated into `staging/`, validated in isolation with existing configs, and only then moved into `blue-green/` or rejected into `rejected/`.

### Configuration Generation and Validation

Configs are auto-generated from the service registry using the template system and always pass through the validation pipeline:

1. **Template**: `nginx/templates/domain-blue-green.conf.template`
2. **Auto-detection**: Services are automatically detected from the service registry JSON
3. **Upstream blocks**: Generated for each service with proper blue/green container names and Docker DNS-based resolution
4. **Generation to staging**: Blue and green configs are written to `nginx/conf.d/staging/{domain}.blue.conf` and `.green.conf`.
5. **Isolated validation**: Each staging config is validated in isolation together with all existing validated configs using the shared `utils.sh` helpers.
6. **Promotion or rejection**:
   - If validation succeeds, configs are moved to `nginx/conf.d/blue-green/`.
   - If validation fails, configs are moved to `nginx/conf.d/rejected/` and nginx continues running with existing configs.
7. **Independence**: Configs are generated from registry, not container state - nginx can start even if containers are not running.

**Important**: Nginx resolves hostnames at runtime via DNS, not at startup. This means:

- Nginx can start with upstreams pointing to non-existent containers
- Nginx will return 502 errors until containers are available (acceptable behavior)
- When containers start, nginx automatically connects to them

### Example Configuration

```nginx
# Blue config: crypto-ai-agent.statex.cz.blue.conf
upstream crypto-ai-frontend {
    server crypto-ai-frontend-blue:3100 weight=100;
    server crypto-ai-frontend-green:3100 backup;
}

upstream crypto-ai-backend {
    server crypto-ai-backend-blue:8100 weight=100;
    server crypto-ai-backend-green:8100 backup;
}

# ... server blocks ...
```

```nginx
# Green config: crypto-ai-agent.statex.cz.green.conf
upstream crypto-ai-frontend {
    server crypto-ai-frontend-blue:3100 backup;
    server crypto-ai-frontend-green:3100 weight=100;
}

upstream crypto-ai-backend {
    server crypto-ai-backend-blue:8100 backup;
    server crypto-ai-backend-green:8100 weight=100;
}

# ... server blocks ...
```

### Switching Mechanism

When switching traffic:

1. **Symlink update**: `{domain}.conf` symlink is updated to point to the new color's config
2. **Nginx reload**: Nginx reloads with the new configuration
3. **Zero downtime**: Switching takes < 2 seconds

**Traffic routing**:

- Active color: `weight=100` (receives all traffic)
- Inactive color: `backup` (standby, only used if active fails)

### Migration

Existing services can be migrated to the symlink system:

```bash
# Migrate all services
./scripts/blue-green/migrate-to-symlinks.sh

# Migrate single service
./scripts/blue-green/migrate-to-symlinks.sh crypto-ai-agent
```

The migration script:

- Generates blue and green configs from template
- Creates symlink pointing to current active color
- Backs up old config files
- Tests nginx configuration

## Logging

All deployment actions are logged to:

- `/nginx-microservice/logs/blue-green/deploy.log`

### Log Format

```text
[TIMESTAMP] [LEVEL] [SERVICE] [COLOR] [ACTION] [MESSAGE]
2025-01-XX 10:30:15 INFO crypto-ai-agent green prepare Starting green deployment
2025-01-XX 10:32:00 SUCCESS crypto-ai-agent green switch Traffic switched to green
```

### View Logs

```bash
tail -f /nginx-microservice/logs/blue-green/deploy.log
```

## Troubleshooting

### Deployment Fails During Prepare

**Symptom**: `prepare-green-smart.sh` exits with error

**Possible causes**:

- Containers fail to build
- Containers fail to start
- Health checks fail

**Solution**:

1. Check container logs: `docker compose -f docker-compose.green.yml -p crypto_ai_agent_green logs`
2. Verify health endpoints are accessible
3. Check service registry configuration

### Health Check Fails After Switch

**Symptom**: Automatic rollback triggered

**Possible causes**:

- Application errors in new code
- Database connection issues
- Missing environment variables

**Solution**:

1. Check logs: `tail -f /nginx-microservice/logs/blue-green/deploy.log`
2. Verify green containers: `docker ps | grep green`
3. Test health endpoints manually
4. Review rollback logs

### Nginx Reload Fails

**Symptom**: `switch-traffic.sh` fails during nginx reload

**Possible causes**:

- Invalid nginx configuration
- Nginx container not running
- Syntax error in upstream blocks

**Solution**:

1. Test nginx config: `docker compose exec nginx nginx -t`
2. Check nginx logs: `docker compose logs nginx`
3. Verify nginx container: `docker ps | grep nginx`

### State File Issues

**Symptom**: Scripts report incorrect active color

**Solution**:

1. Check state file: `cat /nginx-microservice/state/{service}.json | jq .`
2. Verify active_color field
3. Manually fix if needed (restart scripts will reload)

### Containers Not Accessible

**Symptom**: Health checks fail, containers appear running

**Possible causes**:

- Containers not on nginx-network
- Port conflicts
- Firewall issues

**Solution**:

1. Verify network: `docker network inspect nginx-network`
2. Check containers on network: `docker network inspect nginx-network | grep {service}`
3. Connect container: `docker network connect nginx-network {container-name}`

## Best Practices

1. **Always test prepare-green-smart.sh first** before full deployment
2. **Monitor logs** during first deployments
3. **Keep blue running** until green is verified healthy
4. **Use health checks** that test actual functionality, not just "is running"
5. **Test rollback procedure** in staging before production
6. **Document service-specific health check requirements**

## Advanced Usage

### Manual Step-by-Step Deployment

For more control, run scripts individually:

```bash
# 1. Prepare green (validated configs generated to staging/ and promoted to blue-green/)
./scripts/blue-green/prepare-green-smart.sh crypto-ai-agent

# 2. Verify green is ready
cat /nginx-microservice/state/crypto-ai-agent.json | jq .green.status

# 3. Switch traffic
./scripts/blue-green/switch-traffic.sh crypto-ai-agent

# 4. Monitor health
./scripts/blue-green/health-check.sh crypto-ai-agent

# 5. Cleanup when ready
./scripts/blue-green/cleanup.sh crypto-ai-agent
```

### Adding a New Service

1. Create service registry file in `/nginx-microservice/service-registry/`
2. Create initial state file in `/nginx-microservice/state/`
3. Create `docker-compose.blue.yml` and `docker-compose.green.yml` in service repo
4. Run migration to generate blue/green configs: `./scripts/blue-green/migrate-to-symlinks.sh {service-name}`
5. Test deployment: `./scripts/blue-green/deploy-smart.sh {service-name}`

**Note**: The migration script automatically generates blue and green nginx configs from the template based on your service registry, routes them through the staging + validation + blue/green pipeline, and never applies invalid configs. No manual nginx config editing is required or recommended.

## Performance

- **Prepare time**: ~2-3 minutes (build + start + health checks)
- **Switch time**: < 2 seconds (nginx reload)
- **Health check**: < 5 seconds per service
- **Rollback time**: < 5 seconds total
- **Cleanup time**: ~30 seconds

## Security Considerations

1. State files contain deployment metadata (no secrets)
2. Service registry files are readable (configuration only)
3. Scripts require proper permissions (755)
4. Logs may contain container names and paths (no secrets)

## Support

For issues or questions:

1. Check logs: `/nginx-microservice/logs/blue-green/deploy.log`
2. Verify state: `/nginx-microservice/state/{service}.json`
3. Review service registry: `/nginx-microservice/service-registry/{service}.json`
