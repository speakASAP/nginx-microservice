# CLAUDE.md (nginx-microservice)

→ Ecosystem: [../shared/CLAUDE.md](../shared/CLAUDE.md) | Reading order: `BUSINESS.md` → `SYSTEM.md` → `AGENTS.md` → `TASKS.md` → `STATE.json`

---

## nginx-microservice

**Purpose**: Centralized reverse proxy managing SSL (Let's Encrypt), routing, and blue/green deployments for all Statex domains. Docker on host — not in Kubernetes.
**Stack**: Nginx · Docker · Certbot (Let's Encrypt)

### CRITICAL: Never edit nginx-microservice files directly for a specific service

Each application service owns its nginx config under its own `nginx/` directory. The `deploy.sh` script patches the nginx-microservice config post-deploy. Do not hand-edit files in this repo for another service's routing.

### Key constraints

- `*.alfares.cz` uses DNS-01 wildcard certs — keep `certbot/scripts/symlink-subdomains-to-wildcard.sh` `SUBDOMAINS` list aligned with every `*.alfares.cz` vhost
- Blue/green switch only via `deploy-smart.sh` — never manual
- SSL certs managed by Certbot — do not manually edit cert files
- Secrets (Cloudflare API token) in Vault — see [../shared/docs/VAULT.md](../shared/docs/VAULT.md)
- Downstream services run in Kubernetes (`statex-apps` namespace) — see `kubectl get svc -n statex-apps`
