# CLAUDE.md (nginx-microservice)

Ecosystem defaults: sibling [`../CLAUDE.md`](../CLAUDE.md) and [`../shared/docs/PROJECT_AGENT_DOCS_STANDARD.md`](../shared/docs/PROJECT_AGENT_DOCS_STANDARD.md).

Read this repo's `BUSINESS.md` → `SYSTEM.md` → `AGENTS.md` → `TASKS.md` → `STATE.json` first.

---

## nginx-microservice

**Purpose**: Centralized reverse proxy managing SSL (Let's Encrypt), routing, and blue/green deployments for all Statex domains.  
**Stack**: Nginx · Docker · Certbot (Let's Encrypt)

### CRITICAL: Never edit nginx-microservice files directly for a specific service

Each application service owns its nginx config under its own `nginx/` directory. The `deploy.sh` script patches the nginx-microservice config post-deploy via `sed -i`. Do not hand-edit files in this repo for another service's routing.

### Key constraints
- `*.alfares.cz` uses DNS-01 wildcard certs — keep `certbot/scripts/symlink-subdomains-to-wildcard.sh` `SUBDOMAINS` list aligned with every `*.alfares.cz` vhost
- Blue/green switch only via `deploy-smart.sh` — never manual
- SSL certs managed by Certbot — do not manually edit cert files

### Key scripts
```bash
# Deploy a service (run from nginx-microservice dir)
./scripts/blue-green/deploy-smart.sh <service-name>

# Config location per service
nginx/sites/<service>.conf
nginx-api-routes.conf
```
