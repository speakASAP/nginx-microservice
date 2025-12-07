# How to Add Microservices

This guide explains how to add a new microservice to the system.

## Overview

To add a microservice, you need to:

1. **Create a service registry file** in `service-registry/` directory
2. **Ensure your microservice is set up** with docker-compose files
3. **Deploy the microservice** using the deployment scripts

## Step 1: Create Service Registry File

Create a JSON file in `service-registry/{service-name}.json` with the following structure:

### Basic Structure (Backend-only service)

**Simplified version** (port auto-detected):

```json
{
  "service_name": "my-microservice",
  "production_path": "/home/statex/my-microservice",
  "domain": "my-service.statex.cz",
  "docker_compose_file": "docker-compose.blue.yml",
  "docker_project_base": "my_microservice",
  "services": {
    "backend": {
      "container_name_base": "my-microservice",
      "health_endpoint": "/health",
      "health_timeout": 5,
      "health_retries": 3,
      "startup_time": 5
    }
  },
  "shared_services": ["postgres"],
  "network": "nginx-network"
}
```

**With explicit port** (recommended for clarity):

```json
{
  "service_name": "my-microservice",
  "production_path": "/home/statex/my-microservice",
  "domain": "my-service.statex.cz",
  "docker_compose_file": "docker-compose.blue.yml",
  "docker_project_base": "my_microservice",
  "services": {
    "backend": {
      "container_name_base": "my-microservice",
      "container_port": 3000,
      "health_endpoint": "/health",
      "health_timeout": 5,
      "health_retries": 3,
      "startup_time": 5
    }
  },
  "shared_services": ["postgres"],
  "network": "nginx-network"
}
```

### Structure with Frontend and Backend

```json
{
  "service_name": "my-microservice",
  "service_path": "/path/to/my-microservice",
  "production_path": "/home/statex/my-microservice",
  "domain": "my-service.statex.cz",
  "docker_compose_file": "docker-compose.blue.yml",
  "docker_project_base": "my_microservice",
  "services": {
    "frontend": {
      "container_name_base": "my-microservice-frontend",
      "container_port": 3000,
      "health_endpoint": "/",
      "health_timeout": 5,
      "health_retries": 3,
      "startup_time": 5
    },
    "backend": {
      "container_name_base": "my-microservice-backend",
      "container_port": 8000,
      "health_endpoint": "/api/health",
      "health_timeout": 5,
      "health_retries": 3,
      "startup_time": 5
    }
  },
  "shared_services": [
    "postgres"
  ],
  "network": "nginx-network"
}
```

### Field Descriptions

- **service_name**: Name of the service (must end with `-microservice` for microservices)
- **service_path**: Local development path (optional)
- **production_path**: Production server path where the service code lives
- **domain**: Domain name for the service (e.g., `my-service.statex.cz`)
- **docker_compose_file**: Docker compose file to use (usually `docker-compose.blue.yml`)
- **docker_project_base**: Docker compose project name base
- **services**: Object defining all services (frontend, backend, etc.)
  - **container_name_base**: Base name for containers (will become `{base}-blue` and `{base}-green`)
  - **container_port**: Container port (optional - will be auto-detected from docker-compose.yml if missing)
  - **health_endpoint**: Health check endpoint path
  - **health_timeout**: Health check timeout in seconds
  - **health_retries**: Number of health check retries
  - **startup_time**: Expected startup time in seconds
- **shared_services**: Array of shared infrastructure services needed (postgres, redis)
- **network**: Docker network name (usually `nginx-network`)

### Important Notes

✅ **Port Auto-Detection (Simplified)**:

- **`container_port` is optional** in the registry file - the system will auto-detect it if missing
- **Auto-detection order**:
  1. From registry file (`container_port` if specified) - **recommended for clarity**
  2. From `docker-compose.yml` port mappings (container port)
  3. From `.env` file (`PORT` or service-specific port variable)
  4. From running container (if already started)
- **Best practice**: Include `container_port` in registry for clarity, but system will work without it
- **Port values are container ports** (not host ports) - the right side of `HOST:CONTAINER` mapping

## Step 2: Ensure Your Microservice is Set Up

Your microservice directory should have:

1. **docker-compose.blue.yml** - Blue environment compose file
2. **docker-compose.green.yml** - Green environment compose file (optional, can be same as blue)
3. **.env** file with environment variables
4. Containers must be on `nginx-network`
5. Container names should follow pattern: `{container_name_base}-blue` and `{container_name_base}-green`

### Example docker-compose.blue.yml

```yaml
services:
  backend:
    build: .
    container_name: my-microservice-blue
    ports:
      - "3000:3000"  # Host:Container - container port must match registry
    environment:
      - PORT=3000
      - DATABASE_URL=postgresql://...
    networks:
      - nginx-network
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
      interval: 10s
      timeout: 10s
      retries: 2

networks:
  nginx-network:
    external: true
    name: nginx-network
```

## Step 3: Deploy the Microservice

### Option 1: Deploy Single Microservice

```bash
cd /home/statex/nginx-microservice
./scripts/blue-green/deploy-smart.sh my-microservice
```

This will:

1. Check infrastructure (database, network)
2. Prepare green environment
3. Switch traffic to green
4. Monitor health
5. Generate nginx configs automatically

### Option 2: Start All Microservices

```bash
cd /home/statex/nginx-microservice
./scripts/start-microservices.sh
```

This will discover all microservices from `service-registry/` and start them.

### Option 3: Start Single Microservice via Start Script

```bash
cd /home/statex/nginx-microservice
./scripts/start-microservices.sh --service my-microservice
```

## Step 4: Verify Deployment

### Check Container Status

```bash
docker ps | grep my-microservice
```

### Check Nginx Config

```bash
ls -la nginx/conf.d/my-service.statex.cz.conf
cat nginx/conf.d/blue-green/my-service.statex.cz.blue.conf
```

### Test Health Endpoint

```bash
curl https://my-service.statex.cz/health
```

### Check Logs

```bash
# Nginx logs
docker logs nginx-microservice

# Service logs
docker logs my-microservice-blue
```

## Troubleshooting

### Service Not Found

If you get "Service not found in registry":

- Check that the registry file exists: `service-registry/my-microservice.json`
- Verify the filename matches the service name exactly
- Ensure the file is valid JSON

### Containers Not Starting

- Check docker-compose files exist
- Verify paths in registry file are correct
- Check container names match the pattern: `{container_name_base}-blue`
- Ensure containers are on `nginx-network`

### Nginx Config Not Generated

- Check that domain is set in registry file
- Verify nginx configs are generated: `ls nginx/conf.d/blue-green/`
- Check for rejected configs: `ls nginx/conf.d/rejected/`

### Port Conflicts

- **Port auto-detection**: If port is missing from registry, system will auto-detect from docker-compose.yml
- Check if ports are already in use: `docker ps --format "{{.Names}}\t{{.Ports}}"`
- **Container ports**: System uses container ports (right side of `HOST:CONTAINER` mapping)
- **Validation**: System will warn if port cannot be detected - check docker-compose.yml exists and has port mappings

## Example: Adding a Simple Backend Microservice

### **Create registry file** `service-registry/api-microservice.json`

**Minimal version** (port auto-detected from docker-compose.yml):

```json
{
  "service_name": "api-microservice",
  "production_path": "/home/statex/api-microservice",
  "domain": "api.statex.cz",
  "docker_compose_file": "docker-compose.blue.yml",
  "docker_project_base": "api_microservice",
  "services": {
    "backend": {
      "container_name_base": "api-microservice",
      "health_endpoint": "/health"
    }
  },
  "shared_services": ["postgres"],
  "network": "nginx-network"
}
```

**With explicit port** (recommended):

```json
{
  "service_name": "api-microservice",
  "production_path": "/home/statex/api-microservice",
  "domain": "api.statex.cz",
  "docker_compose_file": "docker-compose.blue.yml",
  "docker_project_base": "api_microservice",
  "services": {
    "backend": {
      "container_name_base": "api-microservice",
      "container_port": 8080,
      "health_endpoint": "/health"
    }
  },
  "shared_services": ["postgres"],
  "network": "nginx-network"
}
```

**Note**: If `port` is omitted, the system will automatically detect it from your `docker-compose.yml` file's port mappings (container port).

### **Deploy**

```bash
cd /home/statex/nginx-microservice
./scripts/blue-green/deploy-smart.sh api-microservice
```

### **Verify**

```bash
curl https://api.statex.cz/health
```

## Next Steps

After adding a microservice:

- SSL certificates are automatically requested via Let's Encrypt
- Nginx configs are automatically generated
- Health checks are performed automatically
- Blue/green deployment is set up automatically

For more details, see:

- [Blue/Green Deployment Guide](BLUE_GREEN_DEPLOYMENT.md)
- [Service Dependencies](SERVICE_DEPENDENCIES.md)
- [Troubleshooting Guide](BLUE_GREEN_TROUBLESHOOTING.md)
