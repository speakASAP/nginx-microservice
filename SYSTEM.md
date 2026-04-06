# System: nginx-microservice

## Architecture

Nginx + Docker + Certbot. Service registry for all deployed services.

- Blue/green: `deploy-smart.sh <service>` — builds, health-checks, switches, stops old
- SSL: auto-renewed via Certbot cron
- Config: `nginx/sites/<service>.conf` + `nginx-api-routes.conf` per service

## Integrations

All services — nginx routes to them by domain.

## Current State
<!-- AI-maintained -->
Stage: production

## Known Issues
<!-- AI-maintained -->
- None
