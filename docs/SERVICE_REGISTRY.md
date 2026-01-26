# Service Registry Documentation

## Overview

Service registry files define how nginx-microservice routes traffic to your services. They are **automatically created and managed** by the deployment system - **DO NOT** create or modify them manually in individual service codebases.

## Important Rules

### ❌ DO NOT

- **DO NOT** create `service-registry.json` files in individual service codebases
- **DO NOT** manually edit service registry files on production
- **DO NOT** commit service registry files to service repositories

### ✅ DO

- Let the deployment script automatically create/update service registry files
- View service registry files in `nginx-microservice/service-registry/` directory
- Use deployment scripts to manage service configurations

## How Service Registry Works

### Automatic Creation

Service registry files are automatically created during deployment:

```bash
# On production server
cd ~/nginx-microservice
./scripts/remove-microservice.sh <service-name> # Remove service completelly if needed
./scripts/blue-green/deploy-smart.sh <service-name>
```

The deployment script (`deploy-smart.sh`) will:

1. **Auto-detect** service configuration from:
   - Docker compose files (`docker-compose.blue.yml`, `docker-compose.green.yml`)
   - Environment variables (`.env` file)
   - Running containers
   - Container port mappings

2. **Create/update** service registry file in:
   - `nginx-microservice/service-registry/<service-name>.json`

3. **Generate** nginx configuration from service registry:
   - Upstream blocks with correct container names
   - Proxy locations for frontend/backend services
   - Health check endpoints

4. **Deploy** the service using blue/green deployment pattern

### Service Registry Location

All service registry files are stored in:

```text
nginx-microservice/service-registry/
├── allegro-service.json
├── flipflop-service.json
├── crypto-ai-agent.json
└── ...
```

### Viewing Service Registry

```bash
# On production server
ls -la ~/nginx-microservice/service-registry/

# View a specific service registry
cat ~/nginx-microservice/service-registry/allegro-service.json
```

## Service Registry Structure

Service registry files are automatically generated with the following structure:

```json
{
  "service_name": "allegro-service",
  "production_path": "/home/statex/allegro-service",
  "domain": "allegro.statex.cz",
  "docker_compose_file": "docker-compose.green.yml",
  "docker_project_base": "allegro_service",
  "services": {
    "frontend": {
      "container_name_base": "allegro-service-frontend",
      "container_port": 3410,
      "health_endpoint": "/health",
      "health_timeout": 10,
      "health_retries": 2,
      "startup_time": 10,
      "path": "/",
      "api_path": "/api/"
    }
  },
  "domains": {
    "allegro.statex.cz": {
      "active_color": "green",
      "services": ["frontend"]
    }
  },
  "shared_services": [],
  "network": "nginx-network"
}
```

## Nginx Configuration Generation

Nginx configurations are automatically generated from service registry files:

1. **Upstream blocks** are created for each service (blue and green)
2. **Proxy locations** are generated for frontend and backend services
3. **Health check endpoints** are configured
4. **Container names** are automatically resolved using Docker DNS

Example generated nginx config:

```nginx
upstream allegro-service-frontend-green {
    server allegro-service-frontend-blue:3410 backup;
    server allegro-service-frontend-green:3410 weight=100;
}

location / {
    proxy_pass http://allegro-service-frontend-green:3410;
}
```

## Deployment Process

### Step 1: Pull Latest Code

```bash
# On production server
cd ~/allegro-service
git pull
```

### Step 2: Deploy Service

```bash
# On production server
cd ~/nginx-microservice
./scripts/remove-microservice.sh allegro-service # Remove service completelly if needed
./scripts/blue-green/deploy-smart.sh allegro-service
```

The deployment script will:

1. Auto-create/update service registry file
2. Generate nginx configuration
3. Build and start containers
4. Switch traffic to new deployment
5. Monitor health and rollback if needed

### Step 3: Verify

```bash
# Test the service
curl https://allegro.statex.cz/health
```

## Production-Ready Services

The following services are **production-ready** and should **NOT** be modified:

- **database-server** - Shared PostgreSQL and Redis database
- **auth-microservice** - Authentication and user management
- **nginx-microservice** - Reverse proxy and SSL management
- **logging-microservice** - Centralized logging service

### Rules for Production-Ready Services

1. **✅ Allowed**: Use scripts from these services' directories
2. **❌ NOT Allowed**: Modify code, configuration, or infrastructure directly
3. **⚠️ Permission Required**: If you need to modify something, **ask for permission first**

### Using Scripts

You can use scripts from production-ready services:

```bash
# Example: Use nginx-microservice scripts
cd ~/nginx-microservice
./scripts/remove-microservice.sh <service-name>
./scripts/blue-green/deploy-smart.sh <service-name>
./scripts/add-domain.sh <domain> <container> <port>
```

### Requesting Modifications

If you need to modify a production-ready service:

1. **Document** the need for modification
2. **Explain** why the modification is necessary
3. **Request permission** before making any changes
4. **Wait for approval** before proceeding

## Troubleshooting

### Service Registry Not Found

If deployment fails with "Service registry not found":

1. Check if service directory exists: `ls -la ~/<service-name>`
2. Check if docker-compose files exist: `ls -la ~/<service-name>/docker-compose.*.yml`
3. Run deployment script - it will auto-create the registry

### Nginx Config Not Generated

If nginx config is not generated:

1. Check service registry exists: `cat ~/nginx-microservice/service-registry/<service-name>.json`
2. Check deployment logs: `tail -f ~/nginx-microservice/logs/blue-green/*.log`
3. Verify container names match registry: `docker ps | grep <service-name>`

### Container Names Mismatch

If nginx can't reach containers:

1. Verify container names in registry match actual containers
2. Check containers are on `nginx-network`: `docker network inspect nginx-network`
3. Verify container ports match registry: `docker ps --format 'table {{.Names}}\t{{.Ports}}'`

## Best Practices

1. **Never create service registry files manually** - let the deployment script handle it
2. **Always use deployment scripts** - they ensure consistency and correctness
3. **Check service registry after deployment** - verify it was created correctly
4. **Document any special requirements** - if your service needs special configuration, document it in your service's README.md
5. **Use environment variables** - configure ports and settings via `.env` files, not hardcoded values

## Related Documentation

- [Blue/Green Deployment Guide](BLUE_GREEN_DEPLOYMENT.md)
- [Adding Microservices](ADDING_MICROSERVICES.md)
- [Service Dependencies](SERVICE_DEPENDENCIES.md)
