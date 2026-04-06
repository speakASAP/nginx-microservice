# Business: nginx-microservice
>
> ⚠️ IMMUTABLE BY AI.

## Goal

Centralized reverse proxy managing SSL certificates (Let's Encrypt), routing, and blue/green deployments for all Statex domains.

## Constraints

- AI must never modify nginx configs that affect production routing without review
- SSL certs managed by Certbot — do not manually edit
- blue/green switch only via deploy-smart.sh script

## Consumers

All public-facing services.

## Key Scripts

- Deploy: `./scripts/blue-green/deploy-smart.sh <service>`
- SSL renew: automated via cron
