# System: nginx-microservice

## Architecture

Nginx + Docker + Certbot. Runs on host (ports 80/443). Service registry in `service-registry/*.json`.

- Blue/green: `deploy-smart.sh <service>` — builds, health-checks, switches, stops old
- SSL: auto-renewed via Certbot cron; `*.alfares.cz` uses DNS-01 wildcard — keep `certbot/scripts/symlink-subdomains-to-wildcard.sh` `SUBDOMAINS` list aligned with every `*.alfares.cz` vhost
- Config: `../<service>/nginx/` → `nginx/sites/<service>.conf` + `nginx-api-routes.conf` per service
- Secrets: Cloudflare API token via Vault — see [../shared/docs/VAULT.md](../shared/docs/VAULT.md)

## Integrations

Routes traffic to all services by domain. Most downstream services run as **Kubernetes pods** in `statex-apps` namespace (`kubectl get svc -n statex-apps`). Nginx-microservice itself remains Docker on host.

## Current State
<!-- AI-maintained -->
Stage: production

## Known Issues
<!-- AI-maintained -->
- None
