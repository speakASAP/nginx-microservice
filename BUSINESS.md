# Business: nginx-microservice

> ⚠️ IMMUTABLE BY AI.

## Goal

Centralized reverse proxy managing SSL certificates (Let's Encrypt), routing, and blue/green deployments for all alfares.cz domains.

## Constraints

- AI must never modify nginx configs that affect production routing without review
- SSL certs managed by Certbot — do not manually edit
- Blue/green switch only via `deploy-smart.sh`
- Secrets via Vault — see [../shared/docs/VAULT.md](../shared/docs/VAULT.md)

## Consumers

All public-facing services.

## Key Scripts

- Deploy: `../<service>/scripts/deploy.sh`
- SSL renew: automated via cron
