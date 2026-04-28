# nginx-microservice

Centralized reverse proxy for all alfares.cz services. Runs as **Docker on host** (not in K8s). Manages SSL via Let's Encrypt with DNS-01 wildcard certs for `*.alfares.cz`.

## Key constraints

- Never edit configs in this repo for another service — each service owns its `nginx/` dir
- Blue/green switch only via `deploy-smart.sh` — never manual
- SSL certs managed by Certbot — do not manually edit cert files
- `*.alfares.cz` DNS-01 wildcard: keep `certbot/scripts/symlink-subdomains-to-wildcard.sh` `SUBDOMAINS` list aligned with every `*.alfares.cz` vhost
- Secrets (Cloudflare API token) stored in Vault — see [../shared/docs/VAULT.md](../shared/docs/VAULT.md)
- Most downstream services run in **Kubernetes** (`statex-apps` namespace) — nginx proxies to their ClusterIP endpoints

## Architecture

```
nginx-microservice/         # Docker on host — ports 80/443
├── nginx/conf.d/           # Generated configs (blue-green/ + staging/ + rejected/)
├── service-registry/       # Auto-managed JSON per service — DO NOT edit manually
├── state/                  # Blue/green state per service
├── certbot/                # Certbot scripts; secrets/cloudflare.ini → Vault
└── scripts/
    ├── blue-green/         # deploy-smart.sh, switch-traffic.sh, rollback.sh
    └── common/             # Shared modules (registry, state, config, nginx, etc.)
```

## Common operations

```bash
# Deploy a service
./scripts/blue-green/deploy-smart.sh <service-name>

# Restart nginx (auto-syncs symlinks first)
./scripts/restart-nginx.sh

# Renew SSL certificates
docker compose run --rm certbot /scripts/renew-cert.sh

# Check service status
./scripts/status-all-services.sh

# Diagnose nginx issues
./scripts/diagnose.sh nginx-microservice
```

## Config location per service

```
../<service>/nginx/                 # Service-owned nginx config
../<service>/nginx/nginx-api-routes.conf  # Custom API routes
nginx/sites/<service>.conf          # Symlink managed by deploy-smart.sh
```

## Documentation

| Topic | File |
|-------|------|
| Adding services | [docs/ADDING_MICROSERVICES.md](docs/ADDING_MICROSERVICES.md) |
| Blue/green deployment | [docs/BLUE_GREEN_DEPLOYMENT.md](docs/BLUE_GREEN_DEPLOYMENT.md) |
| Troubleshooting | [docs/BLUE_GREEN_TROUBLESHOOTING.md](docs/BLUE_GREEN_TROUBLESHOOTING.md) |
| Container/nginx sync | [docs/CONTAINER_NGINX_SYNC.md](docs/CONTAINER_NGINX_SYNC.md) |
| API routes registration | [docs/API_ROUTES_REGISTRATION.md](docs/API_ROUTES_REGISTRATION.md) |
| Multi-app routing | [docs/MULTI_APP_API_ROUTING.md](docs/MULTI_APP_API_ROUTING.md) |
| Service registry | [docs/SERVICE_REGISTRY.md](docs/SERVICE_REGISTRY.md) |
| Service dependencies | [docs/SERVICE_DEPENDENCIES.md](docs/SERVICE_DEPENDENCIES.md) |
