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
- Service has blue/green docker-compose files
- Service has health check endpoints configured
- `jq` installed: `brew install jq` (macOS) or `apt-get install jq` (Linux)

## Quick Start

### Deploy a Service (Full Cycle)

```bash
cd /path/to/nginx-microservice
./scripts/blue-green/deploy.sh crypto-ai-agent
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

### `deploy.sh` - Full Deployment

**Usage**: `./scripts/blue-green/deploy.sh <service_name>`

**What it does**:

1. Validates service exists in registry
2. Prepares green deployment
3. Switches traffic to green
4. Monitors health for 5 minutes
5. Cleans up old deployment if healthy

**Example**:

```bash
./scripts/blue-green/deploy.sh crypto-ai-agent
```

### `prepare-green.sh` - Prepare New Deployment

**Usage**: `./scripts/blue-green/prepare-green.sh <service_name>`

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

1. Updates nginx upstream weights
2. Reloads nginx configuration
3. Updates state file

**When to use**: After prepare-green.sh if you want manual control

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

## Deployment Workflow

### Standard Deployment Flow

```text
1. deploy.sh called
   ↓
2. prepare-green.sh
   - Build green containers
   - Start green containers
   - Health checks
   ↓
3. switch-traffic.sh
   - Update nginx config
   - Reload nginx
   ↓
4. Monitor (5 minutes)
   - health-check.sh every 30s
   - Auto-rollback on failure
   ↓
5. cleanup.sh (if healthy)
   - Remove old blue containers
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

The nginx configuration uses upstream blocks:

```nginx
upstream crypto-ai-frontend {
    server crypto-ai-frontend-blue:3100 weight=100;
    server crypto-ai-frontend-green:3100 weight=0 backup;
}

upstream crypto-ai-backend {
    server crypto-ai-backend-blue:8100 weight=100;
    server crypto-ai-backend-green:8100 weight=0 backup;
}
```

When switching:

- Active color: `weight=100` (receives all traffic)
- Inactive color: `weight=0 backup` (standby, only used if active fails)

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

**Symptom**: `prepare-green.sh` exits with error

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

1. **Always test prepare-green.sh first** before full deployment
2. **Monitor logs** during first deployments
3. **Keep blue running** until green is verified healthy
4. **Use health checks** that test actual functionality, not just "is running"
5. **Test rollback procedure** in staging before production
6. **Document service-specific health check requirements**

## Advanced Usage

### Manual Step-by-Step Deployment

For more control, run scripts individually:

```bash
# 1. Prepare green
./scripts/blue-green/prepare-green.sh crypto-ai-agent

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
3. Update nginx config to use upstream blocks (or use blue-green template)
4. Create `docker-compose.blue.yml` and `docker-compose.green.yml` in service repo
5. Test deployment: `./scripts/blue-green/deploy.sh {service-name}`

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
