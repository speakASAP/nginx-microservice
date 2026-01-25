# API Routes Registration

## Overview

This document explains how to register API routes for any microservice so they are handled by specific services instead of being intercepted by the generic `/api/` block.

## Problem

Nginx-microservice intercepts ALL `/api/*` routes and routes them to:

- Backend services (if `backend` service exists)
- API Gateway (if `api-gateway` service exists)

However, some services (like Next.js frontends) have their own API routes that should be handled by the frontend container, not backend/API gateway.

## Solution

We've implemented a universal system to register API routes for any microservice.

## How It Works

1. **Configuration File**: `nginx-api-routes.conf` or `nginx-frontend-api-routes.conf`
   - Lists API routes that should be handled by specific services
   - Located in service directory or `nginx/` subdirectory
   - Format: One route per line, starting with `/api/` or `/`

2. **Automatic Registration**: During deployment
   - `deploy-smart.sh` automatically reads the config file
   - Adds `api_routes` or `frontend_api_routes` array to service registry JSON
   - Nginx config generator creates specific location blocks BEFORE generic `/api/` block

3. **Nginx Configuration**: Generated automatically
   - Specific routes (e.g., `/api/users/collect-contact`) → Target service
   - Generic `/api/*` routes → Backend/API Gateway

## Configuration File Locations

The system looks for config files in the following order:

1. `${service_path}/nginx/nginx-api-routes.conf` (recommended)
2. `${service_path}/nginx-api-routes.conf`

**Single universal file**: All services use the same `nginx-api-routes.conf` file. The system automatically determines the target service:

- If service has frontend → routes go to frontend container
- Otherwise → routes go to backend/first service

## Adding API Routes

Create `nginx-api-routes.conf` in your service directory (preferably in `nginx/` subdirectory):

```bash
# API Routes Configuration
# Routes are automatically routed to:
# - Frontend container (if service has frontend)
# - Backend/first service (if service doesn't have frontend)

/api/users/collect-contact
/api/notifications/prototype-request
/api/custom-route-1
```

**That's it!** One file for all services. The system automatically determines where to route based on your service structure.

## Service Registry

The routes are automatically added to the service registry JSON:

```json
{
  "service_name": "allegro-service",
  "production_path": "/home/statex/allegro-service",
  "frontend_api_routes": [
    "/api/users/collect-contact",
    "/api/notifications/prototype-request"
  ],
  "api_routes": [
    "/api/custom-route-1",
    "/api/custom-route-2"
  ]
}
```

## Nginx Location Blocks

Nginx will generate location blocks like:

```nginx
# Frontend-specific API routes
location /api/users/collect-contact {
    set $FRONTEND_UPSTREAM statex-frontend-green;
    proxy_pass http://$FRONTEND_UPSTREAM/api/users/collect-contact;
    include /etc/nginx/includes/common-proxy-settings.conf;
    limit_req zone=api burst=20 nodelay;
}

# Service-specific API routes
location /api/custom-route-1 {
    set $TARGET_UPSTREAM allegro-backend-green;
    proxy_pass http://$TARGET_UPSTREAM/api/custom-route-1;
    include /etc/nginx/includes/common-proxy-settings.conf;
    limit_req zone=api burst=20 nodelay;
}

# Generic API routes (handled by backend/API gateway)
location /api/ {
    # ... routes to backend or API gateway
}
```

## Route Matching Priority

Nginx matches location blocks by specificity:

1. Most specific routes (e.g., `/api/users/collect-contact`) are matched first
2. Generic routes (e.g., `/api/`) are matched if no specific route matches

This ensures registered API routes take precedence over generic backend/API gateway routes.

## Examples

### Example 1: Service with Frontend (statex)

**File**: `statex/nginx/nginx-api-routes.conf`

```text
/api/users/collect-contact
/api/notifications/prototype-request
```

Routes automatically go to frontend container.

### Example 2: Service without Frontend (allegro-service)

**File**: `allegro-service/nginx/nginx-api-routes.conf`

```text
/api/allegro/custom-endpoint
/api/settings/custom-endpoint
```

Routes automatically go to backend/first service.

## Deployment

Routes are automatically registered during deployment:

```bash
./nginx-microservice/scripts/blue-green/deploy-smart.sh allegro-service
```

The deployment script will:

1. Look for `nginx-api-routes.conf` or `nginx-frontend-api-routes.conf`
2. Read routes from the file
3. Update service registry JSON
4. Regenerate nginx configuration

## Best Practices

1. **Store in codebase**: Commit config files to git
2. **Use nginx/ subdirectory**: Prefer `nginx/nginx-api-routes.conf` for organization
3. **Document routes**: Add comments explaining what each route does
4. **Test after deployment**: Verify routes work after deployment

## Troubleshooting

If a route is still being intercepted:

1. Check if route is in config file
2. Verify route is in service registry: `jq .frontend_api_routes nginx-microservice/service-registry/{service-name}.json`
3. Check nginx config: `grep -A 5 "location /api/your-route" /path/to/nginx/config`
4. Redeploy: `./nginx-microservice/scripts/blue-green/deploy-smart.sh {service-name}`

## Universal Support

This system works for:

- ✅ Frontend services (Next.js, React, etc.)
- ✅ Backend services
- ✅ API Gateway services
- ✅ Any microservice

Just create the appropriate config file in your service directory!
