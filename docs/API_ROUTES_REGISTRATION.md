# API Routes Registration

Nginx intercepts all `/api/*` routes by default, routing them to backend/API gateway. To override for a specific service, create `../<service>/nginx/nginx-api-routes.conf` and deploy with `../<service>/scripts/deploy.sh`

## Config file location

Checked in order:

1. `<service>/nginx/nginx-api-routes.conf` (preferred)
2. `<service>/nginx-api-routes.conf`

## Format

```text
# One route prefix per line. Nginx uses prefix matching — /api/users also matches /api/users/123
/api/users/collect-contact
/api/notifications/prototype-request
/api/custom-route
```

Rules: paths must match `^[a-zA-Z0-9/._-]+$`. No Express-style dynamic segments (`:id`). List the shortest stable prefix needed.

Routes auto-detected during `deploy-smart.sh`:

- Service has frontend → routes go to frontend container
- No frontend → routes go to backend/first service

## Generated nginx location blocks

```nginx
location /api/users/collect-contact {
    proxy_pass http://service-frontend-green/api/users/collect-contact;
    include /etc/nginx/includes/common-proxy-settings.conf;
}

location /api/ {
    # generic — backend or API gateway
}
```

Most specific routes are matched first (nginx prefix matching by length).

## Route priority

Specific routes from `nginx-api-routes.conf` are generated **before** the generic `/api/` block, so they always take precedence.

## Troubleshooting

```bash
# Check route is in registry
jq .frontend_api_routes service-registry/<service>.json

# Check nginx location
grep -A 3 "location /api/your-route" nginx/conf.d/blue-green/<domain>.*.conf

# Redeploy to re-register
../<service>/scripts/deploy.sh
```

