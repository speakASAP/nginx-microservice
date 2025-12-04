# Blue/Green Deployment Guide

This document explains how blue/green deployment works in the nginx-microservice ecosystem.

## Overview

Blue/green deployment allows zero-downtime updates by running two identical production environments (blue and green). Only one environment receives live traffic at a time.

## How It Works

1. **Two Environments**: Blue (current production) and Green (new deployment)
2. **Traffic Switching**: Nginx routes traffic to the active environment via symlinks
3. **Health Checks**: Services must pass health checks before traffic is switched
4. **Rollback**: Quick rollback by switching symlink back to previous environment

## Configuration Structure

Each domain has two nginx configuration files:

- `{domain}.{color}.conf` - Full nginx config for blue or green environment
- `{domain}.conf` - Symlink pointing to the active configuration

Example:

- `crypto-ai-agent.statex.cz.blue.conf` - Blue configuration
- `crypto-ai-agent.statex.cz.green.conf` - Green configuration  
- `crypto-ai-agent.statex.cz.conf` - Symlink (points to blue or green)

## Upstream Configuration

Each service has upstream blocks that define which containers receive traffic:

```nginx
# Blue config: crypto-ai-agent.statex.cz.blue.conf
upstream crypto-ai-frontend {
    server crypto-ai-frontend-blue:3100 weight=100;
    server crypto-ai-frontend-green:3100 backup;
}

upstream crypto-ai-backend {
    server crypto-ai-backend-blue:3102 weight=100;
    server crypto-ai-backend-green:3102 backup;
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
    server crypto-ai-backend-blue:3102 backup;
    server crypto-ai-backend-green:3102 weight=100;
}

# ... server blocks ...
```

### Switching Mechanism

When switching traffic:

1. **Symlink update**: `{domain}.conf` symlink is updated to point to the new color's config
2. **Nginx reload**: Nginx configuration is reloaded (graceful, no connection drops)
3. **Traffic flow**: New requests go to the new environment, existing connections complete on old environment

## Deployment Process

### 1. Prepare Green Environment

```bash
# Start green containers
cd /home/statex/{application}
docker-compose -f docker-compose.green.yml up -d

# Wait for health checks
./scripts/blue-green/health-check.sh green
```

### 2. Update Nginx Configuration

The deployment script automatically:

- Generates green nginx config
- Validates configuration
- Updates symlink to point to green config
- Reloads nginx

```bash
./scripts/blue-green/deploy-smart.sh {application} green
```

### 3. Verify Traffic

```bash
# Check which environment is active
ls -la nginx/conf.d/{domain}.conf

# Test endpoints
curl https://{domain}/health
```

### 4. Rollback (if needed)

```bash
./scripts/blue-green/rollback.sh {application}
```

## Service Registry

Each service defines its configuration in `service-registry/{service}.json`:

```json
{
  "service_name": "crypto-ai-agent",
  "services": {
    "backend": {
      "container_name_base": "crypto-ai-backend",
      "port": 3102,
      "health_endpoint": "/api/health"
    },
    "frontend": {
      "container_name_base": "crypto-ai-frontend",
      "port": 3100,
      "health_endpoint": "/"
    }
  }
}
```

The deployment scripts use this registry to:

- Generate correct nginx upstream blocks
- Determine health check endpoints
- Map container names to ports

## Health Checks

Before switching traffic, services must pass health checks:

```bash
# Health check script tests:
# 1. Container is running
# 2. Health endpoint responds
# 3. Service is ready to accept traffic

./scripts/blue-green/health-check.sh {color}
```

## Nginx Configuration Validation

All nginx configs go through validation:

1. **Generate to staging**: New config written to `nginx/conf.d/staging/`
2. **Validate**: Test config with `nginx -t`
3. **Apply**: Move to `nginx/conf.d/blue-green/` if valid
4. **Reject**: Move to `nginx/conf.d/rejected/` if invalid

This ensures nginx never breaks due to a bad configuration.

## Container Naming Convention

Containers follow this naming pattern:

- Blue: `{service-name}-{color}`
- Green: `{service-name}-{color}`

Examples:

- `crypto-ai-backend-blue`
- `crypto-ai-backend-green`
- `logging-microservice-blue`
- `logging-microservice-green`

## Network Requirements

All containers must be on the `nginx-network`:

```yaml
networks:
  nginx-network:
    external: true
    name: nginx-network
```

## Troubleshooting

### 502 Errors After Switch

1. Check containers are running:

   ```bash
   docker ps | grep {service-name}
   ```

2. Check health endpoints:

   ```bash
   docker exec {container} curl http://localhost:{port}/health
   ```

3. Check nginx upstream:

   ```bash
   docker exec nginx-microservice nginx -T | grep upstream
   ```

4. Check network connectivity:

   ```bash
   docker exec nginx-microservice ping {container-name}
   ```

### Configuration Not Applied

1. Check symlink:

   ```bash
   ls -la nginx/conf.d/{domain}.conf
   ```

2. Check validation:

   ```bash
   ls -la nginx/conf.d/rejected/
   ```

3. Test nginx config:

   ```bash
   docker exec nginx-microservice nginx -t
   ```

### Rollback Issues

If rollback fails:

1. Manually update symlink:

   ```bash
   cd nginx/conf.d
   ln -sf blue-green/{domain}.blue.conf {domain}.conf
   ```

2. Reload nginx:

   ```bash
   docker exec nginx-microservice nginx -s reload
   ```

## Best Practices

1. **Always test green before switching**: Run health checks
2. **Monitor after switch**: Watch logs and metrics
3. **Keep blue running**: Don't stop blue until green is confirmed stable
4. **Use health checks**: Never switch without passing health checks
5. **Validate configs**: All configs are validated before application

## Scripts Reference

- `deploy-smart.sh` - Smart deployment with health checks
- `health-check.sh` - Check service health
- `switch-traffic.sh` - Switch traffic between blue/green
- `rollback.sh` - Rollback to previous environment
- `prepare-green-smart.sh` - Prepare green environment

See individual script documentation for detailed usage.
